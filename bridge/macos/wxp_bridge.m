/* WitcherPadBridge — macOS input bridge for The Witcher: Enhanced Edition (eON port).
 *
 * Zero-hook design: we never patch code. We resolve eON's (unstripped) local symbols,
 * find its live DirectInput keyboard/mouse device objects and write the very same state
 * fields eON's own event pump writes. The game polls DirectInput as usual, so gamepad
 * input is indistinguishable from real keyboard/mouse input.
 *
 * eON layout (verified by disassembly + live probing):
 *   receiver          = *(void**)&_gKeyboardEventReceiver / _gMouseEventReceiver
 *   device            = *(void**)(receiver + 0x10)
 *   keyboard: state   = device + 0xC0   (256 bytes, indexed by DIK, 0x80 = down)
 *             mutex   = device + 0x80
 *   mouse:    dX      = device + 0x88   (int32, accumulated)
 *             dY      = device + 0x8C
 *             buttons = device + 0xA0 + n  (byte, 1 = down)
 *             mutex   = device + 0xA8
 */
#import <Foundation/Foundation.h>
#include <math.h>
#import <GameController/GameController.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#import <objc/message.h>
#include <pthread.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <sys/stat.h>

/* ------------------------------------------------------------------ logging */
static FILE* g_log;
static void L(const char* fmt, ...) {
    if (!g_log) { g_log = fopen("/tmp/wxp_bridge.log", "a"); if (!g_log) return; }
    va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
    fputc('\n', g_log); fflush(g_log);
}

/* ------------------------------------------------------- eON symbol resolution */
static struct nlist_64* g_syms; static uint32_t g_nsyms; static char* g_strs; static intptr_t g_slide;

static int symtab_init(void) {
    const struct mach_header_64* mh = NULL;
    for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
        const struct mach_header_64* h = (const struct mach_header_64*)_dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) { mh = h; g_slide = _dyld_get_image_vmaddr_slide(i); break; }
    }
    if (!mh) return 0;
    const struct load_command* lc = (const struct load_command*)((uint8_t*)mh + sizeof(*mh));
    const struct symtab_command* st = NULL; uint64_t le_v = 0, le_f = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) st = (const struct symtab_command*)lc;
        else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* sc = (const struct segment_command_64*)lc;
            if (!strcmp(sc->segname, "__LINKEDIT")) { le_v = sc->vmaddr; le_f = sc->fileoff; }
        }
        lc = (const struct load_command*)((uint8_t*)lc + lc->cmdsize);
    }
    if (!st || !le_v) return 0;
    uint8_t* base = (uint8_t*)(uintptr_t)(le_v + g_slide - le_f);
    g_syms = (struct nlist_64*)(base + st->symoff);
    g_strs = (char*)(base + st->stroff); g_nsyms = st->nsyms;
    return 1;
}
static void* sym(const char* name) {
    for (uint32_t i = 0; i < g_nsyms; i++) {
        uint32_t sx = g_syms[i].n_un.n_strx; if (!sx) continue;
        if (!strcmp(g_strs + sx, name)) return (void*)(uintptr_t)(g_syms[i].n_value + g_slide);
    }
    L("symbol NOT FOUND: %s", name);
    return NULL;
}

static void** pp_kbd; static void** pp_mouse;

/* eON native input entry points: they update BOTH the immediate state and the
   buffered event queue, which is what Aurora's ReadInputBuffer actually reads. */
typedef void (*ProcessKey_t)(void* self, unsigned int a, unsigned short mac_keycode);
typedef void (*ProcessBtn_t)(void* self, unsigned int a, unsigned char button);
static ProcessKey_t p_KeyDown, p_KeyUp;
static ProcessBtn_t p_BtnDown, p_BtnUp;
typedef void (*ProcessMoved_t)(void* self, unsigned int seq);
static ProcessMoved_t p_MouseMoved;
/* sMouseDeltas globals: mutex @ base, accum slots @ base+0x40, gDX @ base+0x70, gDY @ base+0x74 */
static uint8_t* g_mdelta_base;
/* DirectInput dwSequence: engine stores our 2nd arg straight into DIDEVICEOBJECTDATA.dwSequence.
   Always sending 0 makes every buffered event look like the same stale event. */
static uint32_t g_seq = 1;
/* eON virtual cursor: the game polls the cursor POSITION for camera/UI, not the DI mouse axes.
   GetCurrentCursorPosition(): sClipping==1 ? sCurrentCursorPos : real NSEvent mouseLocation. */
typedef void (*WinMouseMoved_t)(void* win, uint64_t packed_point);
static WinMouseMoved_t p_WinMouseMoved;
static void* (*p_GetFocusWindow)(void);
static void**   pp_mainwin;
static int32_t* g_curpos;     /* [0]=x [1]=y, screen coords, top-left origin */
static int32_t* g_clipping;
static int      g_cam_owned;
static int32_t  g_clip_prev;      /* sClipping value before we took over */
static CGPoint  g_real_seen;      /* last real cursor position we observed */
/* In gameplay the engine recentres the cursor every frame (mouse-look), so a value we wrote
   never survives to the next tick. In a panel or menu nobody touches it. That difference is a
   free, Lua-free way to tell the two apart -- but only while the stick is actually moving. */
static int32_t  g_expect[2];
static int      g_have_expect;
static int      g_ui_mode;
static int      g_mode_votes;
/* wxp_gamepad.luc writes <game>/System/wxp_state.ini on every panel open/close. When it is
   present that is authoritative; the cursor-recentring heuristic is only the fallback. */
static char     g_state_path[1024];
static time_t   g_state_mtime;
static int      g_lua_ui = -1;      /* -1 = no report yet */
/* The Lua layer only ticks while a module is loaded, so at the main menu nobody writes the
   state file. A stale file therefore means "no Lua" -- and there the pad has to fall back to
   driving the cursor itself, because there is no focus layer to send intents to. */
static time_t   g_state_seen;
static int      g_lua_alive;

/* g_lua_alive: the state file has been seen at least once, i.e. the Lua layer is installed.
   lua_alive(): it is also ticking right now. The two differ exactly where it matters -- a
   bridge-only install has to keep the gameplay bindings, while an installed-but-silent Lua
   layer means the module is not running, which is the main menu or a loading screen. */
static int lua_alive(void) {
    if (!g_lua_alive) return 0;
    return (time(NULL) - g_state_seen) < 3;
}

/* The Lua layer owns panel focus: it knows which control is next in a direction and how to
   activate it, which no amount of cursor geometry can match. So the pad does not move a cursor
   in menus -- it writes an intent here and wxp_ui.luc acts on it at the next heartbeat. The
   sequence number is what separates a fresh press from a still-held one. */
static char     g_nav_path[1024];
static uint32_t g_nav_seq;
static char     g_panel[64] = "-";

static void cursor_goto_game(int gx, int gy);
static void tap_key(int kvk);

/* A tap is a press the pad is not holding -- the sign wheel needs one. Holding it for a few
   ticks rather than releasing immediately keeps it a normal press as far as the engine's
   buffered input is concerned. */
static int g_tap[256];
static void tap_key(int kvk) { if (kvk >= 0 && kvk < 256) g_tap[kvk] = 12; }   /* ~48 ms */

static int g_wheel_sect = -1;   /* sector the sign wheel is showing, -1 = closed */
static int g_wheel_used;        /* a sign was picked during this LB hold */

static void nav_send(const char* intent) {
    if (!g_nav_path[0]) return;
    FILE* f = fopen(g_nav_path, "w");
    if (!f) return;
    fprintf(f, "%u %s\n", ++g_nav_seq, intent);
    fclose(f);
    L("nav: %u %s", g_nav_seq, intent);
}

static void poll_lua_state(void) {
    if (!g_state_path[0]) return;
    struct stat st;
    if (stat(g_state_path, &st) != 0) return;
    if (st.st_mtime != g_state_mtime) { g_state_mtime = st.st_mtime; g_state_seen = time(NULL); g_lua_alive = 1; }
    else return;
    FILE* f = fopen(g_state_path, "r");
    if (!f) return;
    char line[256];
    int ui = -1;                 /* -1 until the file actually says something we understand */
    char panel[64] = "-";
    while (fgets(line, sizeof line, f)) {
        char word[64];
        int v;
        if (sscanf(line, " Mode = %63s", word) == 1) {
            if      (!strcasecmp(word, "ui"))    ui = 1;
            else if (!strcasecmp(word, "world")) ui = 0;
            /* anything else (a placeholder written before the first real state) stays unknown */
        }
        else if (sscanf(line, " Panel = %63s", word) == 1) snprintf(panel, sizeof panel, "%s", word);
        else if (sscanf(line, " UI = %d", &v) == 1) ui = (v > 0);
    }
    fclose(f);
    if (ui < 0) return;          /* nothing usable yet: keep the previous belief */
    if (ui != g_lua_ui || strcmp(panel, g_panel)) {
        int entering = (ui && g_lua_ui <= 0);
        g_lua_ui = ui;
        snprintf(g_panel, sizeof g_panel, "%s", panel);
        L("lua: mode=%s panel=%s", ui ? "ui" : "world", panel);
        /* The engine keeps hit-testing the real cursor and highlights whatever sits under it,
           so a parked cursor would light up a second row next to the one the pad has focused.
           Park it in the top-left corner of the render area, where no control lives. */
        if (entering) cursor_goto_game(4, 4);
    }
}
static inline uint32_t next_seq(void) { return __atomic_fetch_add(&g_seq, 1, __ATOMIC_RELAXED); }

/* macOS virtual keycodes (kVK_*) — ProcessKeyDown indexes its diTable by these */
enum {
 MK_A=0, MK_S=1, MK_D=2, MK_F=3, MK_H=4, MK_G=5, MK_Z=6, MK_X=7, MK_C=8,
 MK_Q=12, MK_W=13, MK_E=14, MK_1=18, MK_2=19, MK_3=20, MK_4=21, MK_6=22,
 MK_5=23, MK_EQUALS=24, MK_7=26, MK_MINUS=27, MK_8=28,
 MK_I=34, MK_L=37, MK_J=38, MK_M=46, MK_RETURN=36, MK_TAB=48, MK_SPACE=49,
 MK_ESC=53, MK_LALT=58, MK_F5=96, MK_F3=99, MK_F9=101, MK_F2=120, MK_F1=122,
 MK_LEFT=123, MK_RIGHT=124, MK_DOWN=125, MK_UP=126, MK_PGUP=116, MK_PGDN=121
};

#define KBD_STATE   0xC0
#define KBD_MUTEX   0x80
#define MS_DX       0x88
#define MS_DY       0x8C
#define MS_BTN      0xA0
#define MS_MUTEX    0xA8
#define DEV_OFF     0x10


/* ---------------------------------------------------------------- DIK codes */
enum {
 DIK_ESC=0x01, DIK_1=0x02, DIK_2=0x03, DIK_3=0x04, DIK_4=0x05, DIK_5=0x06, DIK_6=0x07,
 DIK_7=0x08, DIK_8=0x09, DIK_MINUS=0x0C, DIK_EQUALS=0x0D, DIK_TAB=0x0F,
 DIK_Q=0x10, DIK_W=0x11, DIK_E=0x12, DIK_I=0x17, DIK_RETURN=0x1C,
 DIK_A=0x1E, DIK_S=0x1F, DIK_D=0x20, DIK_F=0x21, DIK_G=0x22, DIK_H=0x23, DIK_J=0x24,
 DIK_L=0x26, DIK_Z=0x2C, DIK_X=0x2D, DIK_C=0x2E, DIK_M=0x32, DIK_SPACE=0x39,
 DIK_F1=0x3B, DIK_F2=0x3C, DIK_F3=0x3D, DIK_F5=0x3F, DIK_F9=0x43,
 DIK_PGUP=0xC9, DIK_PGDN=0xD1, DIK_UP=0xC8, DIK_DOWN=0xD0, DIK_LEFT=0xCB, DIK_RIGHT=0xCD,
 DIK_LALT=0x38
};

/* ------------------------------------------------------------------- config */
typedef struct {
    float dz_l, dz_r;        /* stick deadzones            */
    float sens_x, sens_y;    /* camera speed, virtual-cursor px per second at full stick */
    float menu_sens;         /* cursor speed while a panel/menu is up */
    float curve;             /* camera response exponent   */
    int   invert_y;
    int   enabled;
} Cfg;
static Cfg g_cfg = { .dz_l=0.20f, .dz_r=0.18f, .sens_x=1400.f, .sens_y=900.f, .menu_sens=700.f, .curve=1.7f, .invert_y=0, .enabled=1 };
static char g_cfg_path[1024];      /* gamepad.ini in the write dir, edited by hand */
static char g_cfg2_path[1024];     /* wxp_config.ini next to the game's scripts, written by
                                      the in-game Gamepad settings tab. Lua cannot reach the
                                      write dir, so it writes here and this wins. */
static time_t g_cfg_mtime, g_cfg2_mtime;

static void cfg_parse(const char* path) {
    FILE* f = fopen(path, "r"); if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char k[64]; float v;
        if (sscanf(line, " %63[^= ] = %f", k, &v) == 2) {
            if      (!strcasecmp(k,"DeadzoneLeft"))  g_cfg.dz_l   = v;
            else if (!strcasecmp(k,"DeadzoneRight")) g_cfg.dz_r   = v;
            else if (!strcasecmp(k,"SensitivityX"))  g_cfg.sens_x = v;
            else if (!strcasecmp(k,"SensitivityY"))  g_cfg.sens_y = v;
            else if (!strcasecmp(k,"MenuSensitivity")) g_cfg.menu_sens = v;
            else if (!strcasecmp(k,"CameraCurve"))   g_cfg.curve  = v;
            else if (!strcasecmp(k,"InvertY"))       g_cfg.invert_y = (int)v;
            else if (!strcasecmp(k,"Enabled"))       g_cfg.enabled  = (int)v;
        }
    }
    fclose(f);
}

static void cfg_load(void) {
    struct stat a, b;
    int has_a = (stat(g_cfg_path,  &a) == 0);
    int has_b = (g_cfg2_path[0] && stat(g_cfg2_path, &b) == 0);
    int fresh = (has_a && a.st_mtime != g_cfg_mtime) || (has_b && b.st_mtime != g_cfg2_mtime);
    if (!fresh) return;
    if (has_a) g_cfg_mtime  = a.st_mtime;
    if (has_b) g_cfg2_mtime = b.st_mtime;
    /* Reload both from scratch so clearing a key in one file cannot leave a stale value. */
    if (has_a) cfg_parse(g_cfg_path);
    if (has_b) cfg_parse(g_cfg2_path);
    L("config reloaded: dzL=%.2f dzR=%.2f sens=%.1f/%.1f curve=%.2f invY=%d en=%d",
      g_cfg.dz_l, g_cfg.dz_r, g_cfg.sens_x, g_cfg.sens_y, g_cfg.curve, g_cfg.invert_y, g_cfg.enabled);
    L("           menu sensitivity=%.0f  (in-game tab: %s)", g_cfg.menu_sens, has_b ? "yes" : "no");
}

/* ------------------------------------------------------------- injection I/O */
static uint8_t g_held[256];      /* macOS keycodes we currently hold */

/* Send press/release only on transitions, via eON's own handlers. */
static void kbd_apply(const uint8_t* want) {
    void* recv = pp_kbd ? *pp_kbd : NULL;
    if (!recv || !p_KeyDown || !p_KeyUp) return;
    for (int k = 0; k < 256; k++) {
        if (want[k] && !g_held[k])      { p_KeyDown(recv, next_seq(), (unsigned short)k); g_held[k] = 1; }
        else if (!want[k] && g_held[k]) { p_KeyUp  (recv, next_seq(), (unsigned short)k); g_held[k] = 0; }
    }
}

static void post_mouse_event(NSEventType type, int clicks);

/* Put the virtual cursor at a point in the game's own 800x600 render space. The engine reports
   client coords as (screen - windowOrigin) with a 1px/32px offset for border and title bar,
   measured against getMousePosFromEvent:. Lets menus be driven without reading the screen. */
static void cursor_goto_game(int gx, int gy) {
    if (!g_curpos) return;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSApplication* app = NSApp;
            NSWindow* win = app ? ([app keyWindow] ?: [app mainWindow]) : nil;
            if (!win) { NSArray* ws = app ? [app windows] : nil; if (ws.count) win = ws[0]; }
            if (!win) { L("goto: no window"); return; }
            NSRect wf = [win frame];
            NSRect sf = [[NSScreen mainScreen] frame];
            int win_left = (int)wf.origin.x;
            int win_top  = (int)(sf.size.height - (wf.origin.y + wf.size.height));
            {   /* taking the cursor here too, so seed the release baseline from the real one,
                   otherwise the first check compares against a point from a previous run */
                CGEventRef e = CGEventCreate(NULL);
                if (e) { g_real_seen = CGEventGetLocation(e); CFRelease(e); }
            }
            g_curpos[0] = gx + win_left + 1;
            g_curpos[1] = gy + win_top + 32;
            g_expect[0] = g_curpos[0]; g_expect[1] = g_curpos[1]; g_have_expect = 1;
            L("goto: game(%d,%d) -> screen(%d,%d)  window at %d,%d size %.0fx%.0f",
              gx, gy, g_curpos[0], g_curpos[1], win_left, win_top, wf.size.width, wf.size.height);
        }
    });
    post_mouse_event(NSEventTypeMouseMoved, 0);
}

/* Camera: drive eON's virtual cursor. Take it over on first use, seeding from the real cursor
   so the view does not jump. */
static void cam_apply(int dx, int dy) {
    if (!g_curpos || !g_clipping || (!dx && !dy)) return;
    if (!g_cam_owned || *g_clipping != 1) {
        if (*g_clipping != 1) {
            g_clip_prev = *g_clipping;
            CGEventRef e = CGEventCreate(NULL);
            if (e) { CGPoint pt = CGEventGetLocation(e); CFRelease(e);
                     g_curpos[0] = (int32_t)pt.x; g_curpos[1] = (int32_t)pt.y; g_real_seen = pt; }
            *g_clipping = 1;
            L("camera: took over virtual cursor at %d,%d (was clipping=%d)", g_curpos[0], g_curpos[1], g_clip_prev);
        }
        g_cam_owned = 1;
    }
    if (g_have_expect) {
        int ours = (g_curpos[0] == g_expect[0]) && (g_curpos[1] == g_expect[1]);
        if (ours == g_ui_mode) g_mode_votes = 0;
        else if (++g_mode_votes >= 3) {
            g_ui_mode = ours; g_mode_votes = 0;
            L("mode: %s", g_ui_mode ? "UI (cursor is ours)" : "gameplay (engine recentres)");
        }
    }
    g_curpos[0] += dx;
    g_curpos[1] += dy;
    g_expect[0] = g_curpos[0]; g_expect[1] = g_curpos[1]; g_have_expect = 1;
    post_mouse_event(NSEventTypeMouseMoved, 0);
}

/* The game's UI/camera react to real window events, so after moving the virtual cursor we
   post genuine NSEvents into our own app queue. getMousePosFromEvent: reads sCurrentCursorPos
   when sClipping==1, so the event's own location only needs to be plausible. */
/* eON's mouse handlers live on the eON_CustomWindow *view*, not on the NSWindow. */
static NSView* find_eon_view(NSView* v) {
    if (!v) return nil;
    if ([NSStringFromClass([v class]) isEqualToString:@"eON_CustomWindow"]) return v;
    for (NSView* sub in [v subviews]) { NSView* r = find_eon_view(sub); if (r) return r; }
    return nil;
}

static void post_mouse_event(NSEventType type, int clicks) {
    static int logged = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSApplication* app = NSApp;
            NSWindow* win = app ? ([app keyWindow] ?: [app mainWindow]) : nil;
            if (!win) { NSArray* ws = app ? [app windows] : nil; if (ws.count) win = ws[0]; }
            if (!win) { if (logged < 5) { logged++; L("post_mouse_event: no window (app=%p)", app); } return; }
            NSRect wf = [win frame];
            NSRect sf = [[NSScreen mainScreen] frame];
            CGFloat lx = 10, ly = 10;
            if (g_curpos) {
                lx = (CGFloat)g_curpos[0] - wf.origin.x;
                ly = (sf.size.height - (CGFloat)g_curpos[1]) - wf.origin.y;
            }
            NSEvent* ev = [NSEvent mouseEventWithType:type
                                             location:NSMakePoint(lx, ly)
                                        modifierFlags:0
                                            timestamp:[[NSProcessInfo processInfo] systemUptime]
                                         windowNumber:[win windowNumber]
                                              context:nil
                                          eventNumber:(NSInteger)next_seq()
                                           clickCount:clicks
                                             pressure:clicks ? 1.0 : 0.0];
            if (!ev) return;
            /* eON implements the handlers on its NSWindow subclass; invoking them directly is
               deterministic, unlike relying on AppKit to route a posted event. */
            SEL sel = nil;
            switch (type) {
                case NSEventTypeMouseMoved:      sel = @selector(mouseMoved:);      break;
                case NSEventTypeLeftMouseDown:   sel = @selector(mouseDown:);       break;
                case NSEventTypeLeftMouseUp:     sel = @selector(mouseUp:);         break;
                case NSEventTypeRightMouseDown:  sel = @selector(rightMouseDown:);  break;
                case NSEventTypeRightMouseUp:    sel = @selector(rightMouseUp:);    break;
                default: break;
            }
            id target = find_eon_view([win contentView]);

            if (logged < 3) { logged++;
                L("mouse events -> %s (window %s)",
                  target ? [NSStringFromClass([target class]) UTF8String] : "(none)",
                  [NSStringFromClass([win class]) UTF8String]); }
            if (sel && target) ((void (*)(id, SEL, id))objc_msgSend)(target, sel, ev);
            else               [app postEvent:ev atStart:NO];
        }
    });
}

/* Give the cursor back as soon as the player touches a real mouse, so pad and mouse coexist. */
/* Hand the cursor back as soon as the player touches a real mouse -- but only then. The
   baseline has to be seeded by whoever takes ownership, and a single reading is not enough:
   one stale or jittery sample used to drop the virtual cursor mid-menu, which sent the next
   click to wherever the physical mouse happened to be sitting. */
static void cam_release_if_real_mouse(void) {
    if (!g_cam_owned || !g_clipping) return;
    CGEventRef e = CGEventCreate(NULL);
    if (!e) return;
    CGPoint pt = CGEventGetLocation(e); CFRelease(e);
    static int votes = 0;
    if (fabs(pt.x - g_real_seen.x) + fabs(pt.y - g_real_seen.y) > 6.0) {
        if (++votes < 2) return;
        votes = 0;
        if (*g_clipping == 1) *g_clipping = g_clip_prev;
        g_cam_owned = 0;
        g_real_seen = pt;
        L("camera: real mouse moved, released virtual cursor (clipping=%d)", *g_clipping);
    } else {
        votes = 0;
    }
}

static void mouse_apply(int dx, int dy, int lmb, int rmb) {
    static int held_l = 0, held_r = 0;
    void* recv = pp_mouse ? *pp_mouse : NULL;

    /* Legacy DirectInput axes -- the game ignores them, kept only as a harmless extra. */
    if ((dx || dy) && recv && g_mdelta_base && p_MouseMoved) {
        pthread_mutex_t* mm = (pthread_mutex_t*)g_mdelta_base;
        pthread_mutex_lock(mm);
        *(float*)(g_mdelta_base + 0x70) += (float)dx;
        *(float*)(g_mdelta_base + 0x74) += (float)dy;
        pthread_mutex_unlock(mm);
        p_MouseMoved(recv, next_seq());
    }

    /* Buttons: the window-event path is what the game actually listens to, so it must not be
       gated on the DirectInput device existing. */
    if (lmb != held_l) {
        held_l = lmb;
        if (recv && p_BtnDown && p_BtnUp) (lmb ? p_BtnDown : p_BtnUp)(recv, next_seq(), 0);
        post_mouse_event(lmb ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp, 1);
    }
    if (rmb != held_r) {
        held_r = rmb;
        if (recv && p_BtnDown && p_BtnUp) (rmb ? p_BtnDown : p_BtnUp)(recv, next_seq(), 1);
        post_mouse_event(rmb ? NSEventTypeRightMouseDown : NSEventTypeRightMouseUp, 1);
    }
}

/* ------------------------------------------------------------------ helpers */
static float dz_curve(float v, float dz, float curve) {
    float a = fabsf(v);
    if (a <= dz) return 0.f;
    float n = (a - dz) / (1.f - dz);
    n = powf(n, curve);
    return v < 0 ? -n : n;
}

/* --------------------------------------------------------------- main thread */
static void* worker(void* unused) {
    (void)unused;
    @autoreleasepool {
        L("=== WitcherPadBridge %s ===", "v0.1 (phase 1)");
        if (!symtab_init()) { L("symtab init FAILED"); return NULL; }
        pp_kbd   = (void**)sym("_gKeyboardEventReceiver");
        pp_mouse = (void**)sym("_gMouseEventReceiver");
        p_KeyDown = (ProcessKey_t)sym("__ZN21KeyboardEventReceiver14ProcessKeyDownEjt");
        p_KeyUp   = (ProcessKey_t)sym("__ZN21KeyboardEventReceiver12ProcessKeyUpEjt");
        p_BtnDown = (ProcessBtn_t)sym("__ZN18MouseEventReceiver22ProcessMouseButtonDownEjh");
        p_BtnUp   = (ProcessBtn_t)sym("__ZN18MouseEventReceiver20ProcessMouseButtonUpEjh");
        p_MouseMoved  = (ProcessMoved_t)sym("__ZN18MouseEventReceiver17ProcessMouseMovedEj");
        p_WinMouseMoved  = (WinMouseMoved_t)sym("__ZN10eON_Window10MouseMovedE8tagPOINT");
        p_GetFocusWindow = (void*(*)(void))sym("__Z14GetFocusWindowv");
        pp_mainwin  = (void**)sym("_sMainGameWindow");
        g_curpos    = (int32_t*)sym("__ZL17sCurrentCursorPos");
        g_clipping  = (int32_t*)sym("__ZL9sClipping");
        L("cursor: curpos=%p clipping=%p winMouseMoved=%p mainwin=%p",
          g_curpos, g_clipping, p_WinMouseMoved, pp_mainwin);
        g_mdelta_base = (uint8_t*)sym("__ZL17sMouseDeltasMutex");
        {   /* cross-check against a second anchor: FeedMouseDeltaFromEvent::lastDeltaX == base+0x78 */
            uint8_t* alt = (uint8_t*)sym("__ZZ35MouseDeltas_FeedMouseDeltaFromEventE10lastDeltaX");
            L("mouse: moved=%p deltas_base=%p altbase=%p (%s)", p_MouseMoved, g_mdelta_base,
              alt ? alt - 0x78 : NULL, (alt && g_mdelta_base == alt - 0x78) ? "OK" : "MISMATCH");
            if (!g_mdelta_base && alt) g_mdelta_base = alt - 0x78;
        }
        L("mouse device: *pp_mouse=%p", pp_mouse ? *pp_mouse : NULL);
        L("recv kbd=%p mouse=%p | KeyDown=%p KeyUp=%p BtnDown=%p BtnUp=%p",
          pp_kbd, pp_mouse, p_KeyDown, p_KeyUp, p_BtnDown, p_BtnUp);

        const char* home = getenv("HOME");
        snprintf(g_cfg_path, sizeof(g_cfg_path),
                 "%s/Library/Application Support/com.cdprojektred.TheWitcher/gamepad.ini",
                 home ? home : "/tmp");
        cfg_load();
        L("config path: %s", g_cfg_path);
        {   /* The process cwd is the game's System/ dir, not the root, so anchor on the
               executable instead of guessing: .../<game>/The Witcher.app/Contents/MacOS/<exe> */
            char exe[1024]; uint32_t sz = sizeof exe;
            if (_NSGetExecutablePath(exe, &sz) == 0) {
                char* p = exe;
                for (int i = 0; i < 4; i++) { char* q = strrchr(p, '/'); if (!q) break; *q = 0; }
                snprintf(g_state_path, sizeof(g_state_path), "%s/System/wxp_state.ini", p);
                snprintf(g_nav_path,   sizeof(g_nav_path),   "%s/System/wxp_nav.txt",   p);
                snprintf(g_cfg2_path,  sizeof(g_cfg2_path),  "%s/System/wxp_config.ini", p);
            } else {
                snprintf(g_state_path, sizeof(g_state_path), "wxp_state.ini");
                snprintf(g_nav_path,   sizeof(g_nav_path),   "wxp_nav.txt");
                snprintf(g_cfg2_path,  sizeof(g_cfg2_path),  "wxp_config.ini");
            }
            struct stat st;
            L("lua state path: %s (%s)", g_state_path,
              stat(g_state_path, &st) == 0 ? "present" : "not created yet");
        }
    }

    uint8_t want[256];
    int logged_pad = 0, tick = 0;

    for (;; tick++) {
        @autoreleasepool {
            if ((tick & 0xFF) == 0) cfg_load();

            memset(want, 0, sizeof(want));
            int dx = 0, dy = 0, lmb = 0, rmb = 0;

            GCExtendedGamepad* g = nil;
            for (GCController* c in [GCController controllers]) {
                if (c.extendedGamepad) { g = c.extendedGamepad; 
                    if (!logged_pad) { L("gamepad: %s", [[c vendorName] UTF8String] ?: "?"); logged_pad = 1; }
                    break; }
            }

            if ((tick % 250) == 0 && !g) L("no extendedGamepad visible (controllers=%lu)",
                                          (unsigned long)[[GCController controllers] count]);
            double dt;
            {
                static uint64_t prev_ns = 0;
                struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
                uint64_t now_ns = (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
                dt = prev_ns ? (double)(now_ns - prev_ns) / 1e9 : 0.004;
                if (dt > 0.1) dt = 0.1;       /* survive a stall without a camera jump */
                prev_ns = now_ns;
            }
            if (g && g_cfg.enabled) {
                float lx = dz_curve(g.leftThumbstick.xAxis.value,  g_cfg.dz_l, 1.0f);
                float ly = dz_curve(g.leftThumbstick.yAxis.value,  g_cfg.dz_l, 1.0f);
                float rx = dz_curve(g.rightThumbstick.xAxis.value, g_cfg.dz_r, g_cfg.curve);
                float ry = dz_curve(g.rightThumbstick.yAxis.value, g_cfg.dz_r, g_cfg.curve);

                /* three states, not two: gameplay, a panel the Lua layer owns, and the main
                   menu where there is no Lua at all and the cursor is the only way in */
                int have_lua = lua_alive();
                int in_ui    = have_lua && g_lua_ui > 0;
                int in_menu  = g_lua_alive ? !have_lua       /* installed but not ticking */
                                           : g_ui_mode;      /* no Lua at all: guess from the cursor */

                /* movement: left stick -> WASD (gameplay only; in a panel it walks the focus) */
                if (!in_ui && !in_menu) {
                    if (ly >  0.35f) want[MK_W] = 1;
                    if (ly < -0.35f) want[MK_S] = 1;
                    if (lx < -0.35f) want[MK_A] = 1;
                    if (lx >  0.35f) want[MK_D] = 1;
                }

                /* Camera: speed is px/sec, integrated over real elapsed time, so the feel does
                   not change with loop or frame rate. Sub-pixel remainder is carried over. */
                {
                    static double acc_x = 0, acc_y = 0;
                    int ui = in_ui || in_menu;
                    float sx = ui ? g_cfg.menu_sens : g_cfg.sens_x;
                    float sy = ui ? g_cfg.menu_sens : g_cfg.sens_y;
                    if (in_ui || (g.leftShoulder.pressed && !in_menu)) {
                        acc_x = acc_y = 0;      /* the focus layer or the sign wheel owns it */
                    } else {
                        acc_x += (double)rx * sx * dt;
                        acc_y += (double)(ui ? ry : (g_cfg.invert_y ? ry : -ry)) * sy * dt;
                        dx = (int)acc_x; acc_x -= dx;
                        dy = (int)acc_y; acc_y -= dy;
                    }
                }

                /* Buttons. In a panel the same physical buttons mean confirm/back/section, so
                   they are routed to the Lua focus layer instead of the gameplay bindings. */
                {
                    int a  = g.buttonA.pressed,  b  = g.buttonB.pressed;
                    int lb = g.leftShoulder.pressed, rb = g.rightShoulder.pressed;
                    int lt = g.leftTrigger.value  > 0.4f;
                    int rt = g.rightTrigger.value > 0.4f;
                    static int p_a, p_b, p_lb, p_rb, p_lt, p_rt;

                    if (in_ui) {
                        int y = g.buttonY.pressed;
                        static int p_y;
                        if (a  && !p_a)  nav_send("activate");
                        if (b  && !p_b)  nav_send("cancel");
                        if (y  && !p_y)  nav_send("alt");        /* drop / split / context   */
                        if (lt && !p_lt) nav_send("sect-");      /* the bag's own sections   */
                        if (rt && !p_rt) nav_send("sect+");
                        if (lb && !p_lb) nav_send("tab-");       /* panel tabs where they are */
                        if (rb && !p_rb) nav_send("tab+");
                        p_y = y;
                    } else if (in_menu) {
                        /* No Lua here: the cursor is the focus and the clicks are real. */
                        lmb = a;
                        rmb = g.buttonX.pressed;
                        if (b) want[MK_ESC] = 1;
                    } else {
                        lmb = a;                                 /* attack / interact  */
                        rmb = g.buttonX.pressed;                 /* cast active sign   */
                        if (g.buttonY.pressed) want[MK_I]   = 1; /* inventory          */
                        if (b)                 want[MK_ESC] = 1; /* cancel / back      */
                        if (rb) want[MK_E] = 1;                  /* silver sword       */
                        if (lt) want[MK_X] = 1;                  /* fast style         */
                        if (rt) want[MK_Z] = 1;                  /* strong style       */
                        if (g.leftThumbstickButton.pressed)  want[MK_C] = 1;  /* group style  */
                        if (g.rightThumbstickButton.pressed) want[MK_F] = 1;  /* flip camera  */

                        /* Sign wheel. Every combat binding here is a one-shot toggle, so
                           holding LB costs nothing and buys the five signs a home: flick the
                           right stick to a sector and that sign becomes active, X casts it.
                           Let go without flicking and it was just the steel sword. */
                        if (lb && !p_lb) nav_send("signmenu:on");
                        if (lb) {
                            float m = sqrtf(rx * rx + ry * ry);
                            if (m > 0.6f) {
                                float ang = atan2f(rx, ry);                   /* 0 = up, cw */
                                if (ang < 0) ang += 6.28318531f;
                                int sect = (int)((ang + 0.62831853f) / 1.25663706f) % 5;
                                if (sect != g_wheel_sect) {
                                    static const int sign_key[5] =
                                        { MK_1, MK_2, MK_3, MK_4, MK_5 };
                                    static const char* sign_name[5] =
                                        { "Aard", "Quen", "Yrden", "Igni", "Axii" };
                                    char msg[16];
                                    g_wheel_sect = sect;
                                    g_wheel_used = 1;
                                    tap_key(sign_key[sect]);
                                    snprintf(msg, sizeof msg, "sign:%d", sect + 1);
                                    nav_send(msg);
                                    L("sign wheel: %s", sign_name[sect]);
                                }
                            }
                        } else if (p_lb) {
                            if (!g_wheel_used) want[MK_Q] = 1;   /* plain tap: steel sword */
                            nav_send("signmenu:off");
                            g_wheel_used = 0;
                            g_wheel_sect = -1;
                        }
                    }
                    p_a = a; p_b = b; p_lb = lb; p_rb = rb; p_lt = lt; p_rt = rt;
                }

                /* Direction input: panels in gameplay, focus steps inside a panel. The stick
                   doubles for the dpad in UI so either one navigates, and both auto-repeat
                   after a hold so long lists are not a hundred taps. */
                {
                    int nav_x = (g.dpad.right.pressed ? 1 : 0) - (g.dpad.left.pressed ? 1 : 0);
                    int nav_y = (g.dpad.down.pressed  ? 1 : 0) - (g.dpad.up.pressed   ? 1 : 0);
                    if ((in_ui || in_menu) && !nav_x && !nav_y) {
                        if (lx >  0.55f) nav_x =  1; else if (lx < -0.55f) nav_x = -1;
                        if (ly < -0.55f) nav_y =  1; else if (ly >  0.55f) nav_y = -1;
                    }
                    static int   prev_nav_x = 0, prev_nav_y = 0;
                    static double nav_hold = 0, nav_next = 0;
                    int changed = (nav_x != prev_nav_x || nav_y != prev_nav_y);
                    if (changed) { prev_nav_x = nav_x; prev_nav_y = nav_y; nav_hold = 0; nav_next = 0.42; }
                    else if (nav_x || nav_y) nav_hold += dt;
                    int fire = 0;
                    if (in_ui && (nav_x || nav_y)) {          /* menus are steered by cursor */
                        if (changed) fire = 1;
                        else if (nav_hold >= nav_next) { fire = 1; nav_next = nav_hold + 0.11; }
                    }
                    if (fire) {
                        if      (nav_y < 0) nav_send("up");
                        else if (nav_y > 0) nav_send("down");
                        else if (nav_x < 0) nav_send("left");
                        else                nav_send("right");
                    }
                    if (!in_ui && !in_menu) {
                        if (g.dpad.up.pressed)    want[MK_J] = 1;   /* diary     */
                        if (g.dpad.down.pressed)  want[MK_M] = 1;   /* map       */
                        if (g.dpad.left.pressed)  want[MK_H] = 1;   /* character */
                        if (g.dpad.right.pressed) want[MK_L] = 1;   /* alchemy   */
                    }
                }

                /* menu / system */
                if (g.buttonMenu.pressed)    want[MK_ESC] = 1;
                if (g.buttonOptions.pressed) want[MK_F5]  = 1;   /* quicksave */

                if ((tick % 250) == 0) {
                    int nk = 0; for (int i=0;i<256;i++) if (want[i]) nk++;
                    L("pad lx=%.2f ly=%.2f rx=%.2f ry=%.2f dx=%d dy=%d keys=%d lmb=%d recv=%p",
                      lx, ly, rx, ry, dx, dy, nk, lmb, pp_kbd ? *pp_kbd : NULL);
                }
            }

            /* manual test channel:
                 echo "k <kVK> <ms>"      > /tmp/wxp_cmd   key press
                 echo "m <dx> <dy> <n>"   > /tmp/wxp_cmd   n mouse-move steps
                 echo "b <0|1> <ms>"      > /tmp/wxp_cmd   mouse button (0=L,1=R)
                 echo "p <dx> <dy> <n>"   > /tmp/wxp_cmd   camera / cursor delta
                 echo "g <gx> <gy>"       > /tmp/wxp_cmd   cursor to a point in game space
                 echo "n <intent>"        > /tmp/wxp_cmd   navigation intent to the Lua layer
               (bare "<kVK> <ms>" still works) */
            {
                FILE* cf = fopen("/tmp/wxp_cmd", "r");
                if (cf) {
                    char line[128] = {0};
                    if (fgets(line, sizeof line, cf)) { }
                    fclose(cf); unlink("/tmp/wxp_cmd");
                    /* "n <intent>" fires a navigation intent by hand, so the pad -> Lua chain
                       can be exercised without a controller in the room. */
                    char intent[32] = {0};
                    int handled = 0;
                    if (sscanf(line, " n %31s", intent) == 1) {
                        L(">>> TEST n %s", intent);
                        nav_send(intent);
                        L("<<< TEST done");
                        handled = 1;
                    }
                    char op = 0; int a = 0, b = 0, c = 0;
                    if (handled) {
                        /* already dispatched; skip the numeric forms below */
                    } else if (sscanf(line, " %c %d %d %d", &op, &a, &b, &c) >= 2 && (op=='k'||op=='m'||op=='b'||op=='p'||op=='g')) {
                        L(">>> TEST %c %d %d %d", op, a, b, c);
                        if (op == 'k' && a >= 0 && a < 256) {
                            void* r = pp_kbd ? *pp_kbd : NULL;
                            if (r) { p_KeyDown(r, next_seq(), (unsigned short)a); usleep(b*1000);
                                     r = pp_kbd ? *pp_kbd : NULL; if (r) p_KeyUp(r, next_seq(), (unsigned short)a); }
                        } else if (op == 'm') {
                            int n = c > 0 ? c : 1;
                            for (int i = 0; i < n; i++) { mouse_apply(a, b, 0, 0); usleep(8000); }
                        } else if (op == 'p') {
                            int n = c > 0 ? c : 1;
                            L("   clipping=%d curpos=%d,%d", g_clipping?*g_clipping:-99,
                              g_curpos?g_curpos[0]:-1, g_curpos?g_curpos[1]:-1);
                            for (int i = 0; i < n; i++) { cam_apply(a, b); usleep(8000); }
                            L("   -> curpos=%d,%d", g_curpos?g_curpos[0]:-1, g_curpos?g_curpos[1]:-1);
                        } else if (op == 'g') {
                            g_cam_owned = 1;
                            if (g_clipping && *g_clipping != 1) { g_clip_prev = *g_clipping; *g_clipping = 1; }
                            cursor_goto_game(a, b);
                        } else if (op == 'b') {
                            mouse_apply(0, 0, a == 0, a == 1);
                            usleep((b > 0 ? b : 100) * 1000);
                            mouse_apply(0, 0, 0, 0);
                        }
                        L("<<< TEST done");
                    } else if (sscanf(line, " %d %d", &a, &b) == 2 && a >= 0 && a < 256) {
                        void* r = pp_kbd ? *pp_kbd : NULL;
                        L(">>> TEST: kVK %d for %dms (recv=%p)", a, b, r);
                        if (r) { p_KeyDown(r, next_seq(), (unsigned short)a); usleep(b*1000);
                                 r = pp_kbd ? *pp_kbd : NULL; if (r) p_KeyUp(r, next_seq(), (unsigned short)a); }
                        L("<<< TEST done");
                    }
                }
            }

            for (int i = 0; i < 256; i++) if (g_tap[i]) { want[i] = 1; g_tap[i]--; }
            kbd_apply(want);
            if ((tick % 25) == 0) poll_lua_state();
            if (dx || dy) cam_apply(dx, dy);
            else if ((tick % 25) == 0) cam_release_if_real_mouse();
            mouse_apply(0, 0, lmb, rmb);
        }
        usleep(4000);   /* ~250 Hz */
    }
    return NULL;
}

__attribute__((constructor))
static void wxp_init(void) {
    /* The bundle names us in its load commands, and a developer may still inject a build over
       the top with DYLD_INSERT_LIBRARIES. Two copies would each drive the pad and every press
       would land twice, so only the first one to arrive starts a worker. */
    if (getenv("WXP_BRIDGE_ACTIVE")) {
        L("---- second copy in pid %d, standing down ----", getpid());
        return;
    }
    setenv("WXP_BRIDGE_ACTIVE", "1", 1);
    L("---- WitcherPadBridge loaded, pid %d ----", getpid());
    pthread_t t; pthread_create(&t, NULL, worker, NULL); pthread_detach(t);
}
