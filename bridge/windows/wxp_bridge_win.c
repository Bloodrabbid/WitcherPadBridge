/* WitcherPadBridge -- Windows/Proton side.
 *
 * The game tries to load System\lightfx\wxp\LightFX.dll (Alienware LightFX) on every start and
 * shrugs off a failure, which makes it a free entry point: export the LightFX API as stubs and
 * the engine loads us itself. No patching, no launcher, no injector.
 *
 * Input goes in the way a real device's would. The keyboard is read through DirectInput, whose
 * "DIK" codes are just PS/2 scan codes, so SendInput with KEYEVENTF_SCANCODE lands in the same
 * place a keypress does. The camera is not a DirectInput axis at all -- the engine never creates
 * a mouse device and instead reads the cursor position every frame -- so the camera is driven by
 * moving the cursor, exactly as the macOS bridge does.
 *
 * Config and the two channels shared with the Lua layer live in the same places as on macOS:
 *   <game>\gamepad.ini          settings, re-read when it changes
 *   <game>\System\wxp_state.ini Lua -> here: Mode / Panel / Tick
 *   <game>\System\wxp_nav.txt   here -> Lua: "<seq> <intent>"
 *   <game>\System\wxp_aim.txt   Lua -> here: "<seq> <dx> <dy> <ready>"
 *
 * Nobody debugging this on a Deck or an Ally can attach to the process, so the log has to answer
 * the questions on its own: where it loaded from, what it derived from that, whether each file it
 * needs is there and writable, whether a pad is connected and on which slot, and whether the Lua
 * half is alive. All of that goes in at startup, and a heartbeat line every few seconds says the
 * worker is still running. <game>\System\wxp_bridge.log, LogLevel in gamepad.ini turns the
 * per-event detail on.
 */
#include <windows.h>
#include <stdio.h>
#ifndef WXP_VERSION
#define WXP_VERSION "dev"
#endif
#include <stdarg.h>
#include <string.h>
#include <math.h>
#include <time.h>

/* ------------------------------------------------------------------ XInput */
/* Loaded by name: which xinput a Proton prefix has depends on the runtime. */
typedef struct { WORD  wButtons; BYTE bLeftTrigger, bRightTrigger;
                 SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } WXP_GAMEPAD;
typedef struct { DWORD dwPacketNumber; WXP_GAMEPAD Gamepad; } WXP_STATE;
typedef DWORD (WINAPI *PFN_XInputGetState)(DWORD, WXP_STATE*);

#define PAD_DPAD_UP 0x0001
#define PAD_DPAD_DOWN 0x0002
#define PAD_DPAD_LEFT 0x0004
#define PAD_DPAD_RIGHT 0x0008
#define PAD_START 0x0010
#define PAD_BACK 0x0020
#define PAD_LTHUMB 0x0040
#define PAD_RTHUMB 0x0080
#define PAD_LSHOULDER 0x0100
#define PAD_RSHOULDER 0x0200
#define PAD_A 0x1000
#define PAD_B 0x2000
#define PAD_X 0x4000
#define PAD_Y 0x8000

/* --------------------------------------------------------------- scan codes */
/* DirectInput DIK_* values; these are what the game's key bindings are in terms of. */
enum {
 SC_ESC=0x01, SC_1=0x02, SC_2=0x03, SC_3=0x04, SC_4=0x05, SC_5=0x06,
 SC_6=0x07, SC_7=0x08, SC_8=0x09,
 SC_Q=0x10, SC_W=0x11, SC_E=0x12, SC_R=0x13, SC_T=0x14, SC_Y=0x15, SC_U=0x16,
 SC_I=0x17, SC_O=0x18, SC_P=0x19,
 SC_A=0x1E, SC_S=0x1F, SC_D=0x20, SC_F=0x21, SC_G=0x22, SC_H=0x23, SC_J=0x24,
 SC_K=0x25, SC_L=0x26,
 SC_Z=0x2C, SC_X=0x2D, SC_C=0x2E, SC_V=0x2F, SC_B=0x30, SC_N=0x31, SC_M=0x32,
 SC_LALT=0x38, SC_SPACE=0x39, SC_F5=0x3F, SC_F9=0x43
};

/* ------------------------------------------------------------------ globals */
static HMODULE g_self;
#define WXP_PATH (MAX_PATH * 2)
static char    g_root[MAX_PATH];      /* game root */
static char    g_ini[WXP_PATH];       /* gamepad.ini, edited by hand */
static char    g_ini2[WXP_PATH];      /* wxp_config.ini, written by the in-game settings tab */
static char    g_state_path[WXP_PATH];
static char    g_nav_path[WXP_PATH];
static char    g_aim_path[WXP_PATH];
static char    g_log_path[WXP_PATH];
static FILETIME g_ini_time, g_ini2_time;

typedef struct {
    int   enabled;
    float dz_l, dz_r, curve;
    float sens_x, sens_y, menu_sens;
    int   invert_y;
    int   aim;               /* 0 off, 1 while the attack button is held, 2 while aim_btn is */
    int   aim_btn;           /* which button mode 2 listens to; see AIM_BTN_* */
    float aim_speed;         /* how fast the assist may turn the camera, px per second */
    int   log_level;         /* 0 quiet, 1 normal, 2 every event */
} Cfg;

/* Mode 2 exists because the assist turning the camera by itself, unasked, is unpleasant even
   when it aims correctly -- so there is a mode where it only ever moves the view while the
   player is holding a button and asking for it. */
enum { AIM_BTN_R3 = 0, AIM_BTN_L3, AIM_BTN_LB, AIM_BTN_RB, AIM_BTN_LT, AIM_BTN_RT };
static const char* const AIM_BTN_NAMES[] = { "r3", "l3", "lb", "rb", "lt", "rt" };

/* One initialiser, used twice: the live config and the copy to fall back on. */
#define WXP_CFG_DEFAULTS { 1, 0.20f, 0.16f, 1.7f, 1400.f, 900.f, 700.f, 0, \
                           1, AIM_BTN_R3, 2200.f, 1 }
static const Cfg g_cfg_defaults = WXP_CFG_DEFAULTS;
static Cfg       g_cfg          = WXP_CFG_DEFAULTS;

static void vwlog(const char* fmt, va_list ap) {
    FILE* f = fopen(g_log_path, "a");
    if (!f) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    fprintf(f, "%02d:%02d:%02d.%03d  ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    vfprintf(f, fmt, ap);
    fputc('\n', f);
    fclose(f);
}

static void wlog(const char* fmt, ...) {
    if (g_cfg.log_level < 1) return;
    va_list ap; va_start(ap, fmt); vwlog(fmt, ap); va_end(ap);
}

/* Detail that is worth having when something is wrong and unbearable when it is not. */
static void wlogv(const char* fmt, ...) {
    if (g_cfg.log_level < 2) return;
    va_list ap; va_start(ap, fmt); vwlog(fmt, ap); va_end(ap);
}

/* Sessions append, so keep the file from growing without bound across months of play, but never
   throw away the run that just failed: the previous log is kept as .1. */
static void log_rotate(void) {
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (!GetFileAttributesExA(g_log_path, GetFileExInfoStandard, &fa)) return;
    if (fa.nFileSizeHigh == 0 && fa.nFileSizeLow < 512 * 1024) return;
    char old_path[WXP_PATH + 8];
    snprintf(old_path, sizeof old_path, "%s.1", g_log_path);
    DeleteFileA(old_path);
    MoveFileA(g_log_path, old_path);
}

/* ------------------------------------------------------------------- config */
static void cfg_parse(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char key[64], word[32]; float v;
        /* AimButton is the one key whose value is a word rather than a number, so it has to be
           taken before the numeric parse drops the line on the floor. */
        if (sscanf(line, " %63[A-Za-z] = %31s", key, word) == 2 && !_stricmp(key, "AimButton")) {
            int i;
            for (i = 0; i < (int)(sizeof AIM_BTN_NAMES / sizeof *AIM_BTN_NAMES); i++)
                if (!_stricmp(word, AIM_BTN_NAMES[i])) { g_cfg.aim_btn = i; break; }
            continue;
        }
        if (sscanf(line, " %63[A-Za-z] = %f", key, &v) != 2) continue;
        if      (!_stricmp(key, "Enabled"))         g_cfg.enabled  = (int)v;
        else if (!_stricmp(key, "DeadzoneLeft"))    g_cfg.dz_l     = v;
        else if (!_stricmp(key, "DeadzoneRight"))   g_cfg.dz_r     = v;
        else if (!_stricmp(key, "SensitivityX"))    g_cfg.sens_x   = v;
        else if (!_stricmp(key, "SensitivityY"))    g_cfg.sens_y   = v;
        else if (!_stricmp(key, "CameraCurve"))     g_cfg.curve    = v;
        else if (!_stricmp(key, "InvertY"))         g_cfg.invert_y = (int)v;
        else if (!_stricmp(key, "MenuSensitivity")) g_cfg.menu_sens = v;
        else if (!_stricmp(key, "AimAssist"))       g_cfg.aim      = (int)v;
        else if (!_stricmp(key, "AimSpeed"))        g_cfg.aim_speed = v;
        else if (!_stricmp(key, "LogLevel"))        g_cfg.log_level = (int)v;
    }
    fclose(f);
}

/* gamepad.ini is the hand-edited file; wxp_config.ini is what the in-game Gamepad tab writes
   (Lua cannot reach a per-user config directory, so it writes beside the scripts). The tab
   wins, and both are re-read whole so clearing a key never leaves a stale value behind. */
static void load_config(int force) {
    WIN32_FILE_ATTRIBUTE_DATA a, b;
    int has_a = GetFileAttributesExA(g_ini,  GetFileExInfoStandard, &a) != 0;
    int has_b = GetFileAttributesExA(g_ini2, GetFileExInfoStandard, &b) != 0;
    int fresh = force
             || (has_a && CompareFileTime(&a.ftLastWriteTime, &g_ini_time)  != 0)
             || (has_b && CompareFileTime(&b.ftLastWriteTime, &g_ini2_time) != 0);
    if (!fresh) return;
    if (has_a) g_ini_time  = a.ftLastWriteTime;
    if (has_b) g_ini2_time = b.ftLastWriteTime;
    /* From scratch, so deleting a key really does restore its default -- parsing over the live
       values would leave the last thing that key ever had, which is the opposite of what
       deleting a line looks like it should do. */
    g_cfg = g_cfg_defaults;
    if (has_a) cfg_parse(g_ini);
    if (has_b) cfg_parse(g_ini2);
    wlog("config: dzL=%.2f dzR=%.2f sens=%.0f/%.0f curve=%.2f invY=%d en=%d menu=%.0f (tab: %s)",
         g_cfg.dz_l, g_cfg.dz_r, g_cfg.sens_x, g_cfg.sens_y, g_cfg.curve,
         g_cfg.invert_y, g_cfg.enabled, g_cfg.menu_sens, has_b ? "yes" : "no");
    wlog("config: aim=%d (%s) aimSpeed=%.0f logLevel=%d  (%s%s)",
         g_cfg.aim,
         g_cfg.aim == 0 ? "off" : (g_cfg.aim == 2 ? AIM_BTN_NAMES[g_cfg.aim_btn] : "on attack"),
         g_cfg.aim_speed, g_cfg.log_level,
         has_a ? "gamepad.ini" : "no gamepad.ini",
         has_b ? " + wxp_config.ini" : "");
}

/* --------------------------------------------------------------- Lua channels */
static DWORD    g_nav_seq;
static int      g_lua_ui = -1;
static char     g_panel[64] = "-";
static FILETIME g_state_time;
static DWORD    g_state_seen;
static int      g_lua_alive;

/* g_lua_alive: the state file has been seen at least once, i.e. the Lua layer is installed.
   lua_alive(): it is also ticking right now. A bridge-only install has to keep the gameplay
   bindings; an installed-but-silent Lua layer means the main menu or a loading screen. */
static int lua_alive(void) {
    return g_lua_alive && (GetTickCount() - g_state_seen) < 3000;
}

/* strncpy leaves the destination unterminated when the source exactly fills it. */
static void copy_str(char* dst, size_t cap, const char* src) {
    size_t i = 0;
    for (; i + 1 < cap && src[i]; i++) dst[i] = src[i];
    dst[i] = 0;
}

static void nav_send(const char* intent) {
    FILE* f = fopen(g_nav_path, "w");
    if (!f) { wlog("nav: cannot write %s -- the script layer will never hear this", g_nav_path); return; }
    fprintf(f, "%lu %s\n", (unsigned long)++g_nav_seq, intent);
    fclose(f);
    wlog("nav: %lu %s", (unsigned long)g_nav_seq, intent);
}

/* Aim assist. An attack lands on whoever is under the reticle -- the engine's attack lock only
   drives the selection ring -- and the reticle is pinned to the centre of the screen, so aiming
   is turning the camera. Only Lua can see where the target is, so it writes the residual turn
   here in the same pixels the camera already speaks and this side decides when to spend it.
   dx is an absolute residual (Lua recomputes it from a camera that has already moved, so it
   replaces); dy has no feedback and arrives as increments to add up. */
static DWORD  g_aim_seq;
static double g_aim_px, g_aim_py;
static int    g_aim_ready;
static DWORD  g_aim_fresh;

static void poll_aim(void) {
    FILE* f = fopen(g_aim_path, "r");
    if (!f) return;
    unsigned long seq = 0; double ax = 0, ay = 0; int ready = 0;
    int n = fscanf(f, "%lu %lf %lf %d", &seq, &ax, &ay, &ready);
    fclose(f);
    if (n < 3 || (DWORD)seq == g_aim_seq) return;
    g_aim_seq   = (DWORD)seq;
    g_aim_px    = ax;
    g_aim_py   += ay;
    g_aim_ready = (n >= 4) ? ready : 1;
    g_aim_fresh = GetTickCount();
}

static void poll_lua_state(void) {
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (!GetFileAttributesExA(g_state_path, GetFileExInfoStandard, &fa)) return;
    if (CompareFileTime(&fa.ftLastWriteTime, &g_state_time) == 0) return;
    g_state_time = fa.ftLastWriteTime;
    if (!g_lua_alive) wlog("lua: state file seen -- the script layer is installed and ticking");
    g_state_seen = GetTickCount();
    g_lua_alive  = 1;

    FILE* f = fopen(g_state_path, "r");
    if (!f) return;
    char line[256], word[64], panel[64] = "-";
    int ui = -1;                 /* -1 until the file says something we understand */
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, " Mode = %63s", word) == 1) {
            if      (!_stricmp(word, "ui"))    ui = 1;
            else if (!_stricmp(word, "world")) ui = 0;
            /* a placeholder written before the first real state stays unknown */
        }
        else if (sscanf(line, " Panel = %63s", word) == 1) copy_str(panel, sizeof panel, word);
    }
    fclose(f);
    if (ui < 0) return;          /* nothing usable yet: keep the previous belief */
    if (ui != g_lua_ui || strcmp(panel, g_panel)) {
        g_lua_ui = ui;
        copy_str(g_panel, sizeof g_panel, panel);
        wlog("lua: mode=%s panel=%s", ui ? "ui" : "world", panel);
    }
}

/* ------------------------------------------------------------- synthesis */
static void key_send(WORD scan, int down) {
    INPUT in;
    ZeroMemory(&in, sizeof in);
    in.type = INPUT_KEYBOARD;
    in.ki.wScan = scan;
    in.ki.dwFlags = KEYEVENTF_SCANCODE | (down ? 0 : KEYEVENTF_KEYUP);
    SendInput(1, &in, sizeof in);
}

static void mouse_button(int right, int down) {
    INPUT in;
    ZeroMemory(&in, sizeof in);
    in.type = INPUT_MOUSE;
    in.mi.dwFlags = right ? (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP)
                          : (down ? MOUSEEVENTF_LEFTDOWN  : MOUSEEVENTF_LEFTUP);
    SendInput(1, &in, sizeof in);
}

/* The engine re-centres the cursor every frame while mouse-looking, so an absolute move is both
   simpler than relative deltas and immune to pointer acceleration. */
static void cursor_move(int dx, int dy) {
    POINT p;
    if (!GetCursorPos(&p)) return;
    SetCursorPos(p.x + dx, p.y + dy);
}

/* Track only the keys we pressed, so a key the player is really holding is never released. */
static BYTE g_held[256];

/* A tap is a press the pad is not holding -- the sign wheel needs one. Holding it for a few
   ticks rather than releasing immediately keeps it a normal press as far as the engine's
   buffered input is concerned. */
static int g_tap[256];
static void tap_key(int sc) { if (sc >= 0 && sc < 256) g_tap[sc] = 12; }   /* ~48 ms */

static int g_wheel_sect = -1;   /* sector the sign wheel is showing, -1 = closed */
static int g_wheel_used;        /* a sign was picked during this LB hold */

static void keys_apply(const BYTE* want) {
    for (int i = 0; i < 256; i++) {
        if (want[i] && !g_held[i]) { key_send((WORD)i, 1); g_held[i] = 1; }
        else if (!want[i] && g_held[i]) { key_send((WORD)i, 0); g_held[i] = 0; }
    }
}

/* --------------------------------------------------------------- pad maths */
static float dz_curve(float v, float dz, float curve) {
    float a = fabsf(v);
    if (a <= dz) return 0.f;
    float n = (a - dz) / (1.f - dz);
    if (n > 1.f) n = 1.f;
    n = powf(n, curve);
    return v < 0 ? -n : n;
}

static float axis(SHORT s) { return (float)s / 32767.f; }

/* ------------------------------------------------------------------ worker */
static DWORD WINAPI worker(LPVOID unused) {
    (void)unused;
    PFN_XInputGetState XInputGetState = NULL;
    const char* names[] = { "xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll", "xinput1_2.dll" };
    for (int i = 0; i < 4 && !XInputGetState; i++) {
        HMODULE m = LoadLibraryA(names[i]);
        if (m) {
            XInputGetState = (PFN_XInputGetState)(void*)GetProcAddress(m, "XInputGetState");
            if (XInputGetState) wlog("xinput: %s", names[i]);
        }
    }
    if (!XInputGetState) {
        wlog("xinput: none of xinput1_4/1_3/9_1_0/1_2 could be loaded -- no pad support.");
        wlog("        on Proton this usually means the prefix has no xinput override;");
        wlog("        on Windows, that the DirectX runtime is missing.");
        return 0;
    }

    load_config(1);

    BYTE want[256];
    double acc_x = 0, acc_y = 0;
    DWORD prev_ms = GetTickCount();
    int p_a = 0, p_b = 0, p_y = 0, p_lb = 0, p_rb = 0, p_lt = 0, p_rt = 0;
    int prev_nav_x = 0, prev_nav_y = 0;
    double nav_hold = 0, nav_next = 0;
    int held_l = 0, held_r = 0;
    unsigned tick = 0;
    /* A pad is not always on slot 0 -- a Deck's built-in controls, a plugged-in second pad or a
       Steam Input virtual device can take it. Reading only slot 0 looks exactly like "the mod
       does not work", so scan, and say which one answered. */
    int slot = -1;
    int said_no_pad = 0;

    for (;;) {
        Sleep(4);
        tick++;
        if ((tick % 250) == 0) load_config(0);
        if ((tick % 25) == 0) poll_lua_state();
        if ((tick % 5)  == 0) poll_aim();

        ZeroMemory(want, sizeof want);
        WXP_STATE st;
        ZeroMemory(&st, sizeof st);
        DWORD rc = (slot >= 0) ? XInputGetState((DWORD)slot, &st) : ERROR_DEVICE_NOT_CONNECTED;
        if (rc != ERROR_SUCCESS) {
            if (slot >= 0) { wlog("pad: slot %d disconnected", slot); slot = -1; }
            /* Re-scan a few times a second, not every 4 ms: XInputGetState on an empty slot is
               slow enough that polling all four in a tight loop is a real cost. */
            if ((tick % 100) == 0) {
                for (int i = 0; i < 4; i++) {
                    if (XInputGetState((DWORD)i, &st) == ERROR_SUCCESS) {
                        slot = i;
                        wlog("pad: connected on slot %d", i);
                        said_no_pad = 0;
                        rc = ERROR_SUCCESS;
                        break;
                    }
                }
            }
            if (rc != ERROR_SUCCESS) {
                if (!said_no_pad && tick > 500) {
                    said_no_pad = 1;
                    wlog("pad: no controller on any XInput slot.");
                    wlog("     if one is plugged in, Steam Input is probably holding it --");
                    wlog("     Properties -> Controller -> Disable Steam Input, then relaunch.");
                }
                keys_apply(want);
                continue;
            }
        }
        if (!g_cfg.enabled) { keys_apply(want); continue; }

        DWORD now = GetTickCount();
        double dt = (now - prev_ms) / 1000.0;
        prev_ms = now;
        if (dt > 0.1) dt = 0.1;

        const WXP_GAMEPAD* g = &st.Gamepad;
        float lx = dz_curve(axis(g->sThumbLX), g_cfg.dz_l, 1.0f);
        float ly = dz_curve(axis(g->sThumbLY), g_cfg.dz_l, 1.0f);
        float rx = dz_curve(axis(g->sThumbRX), g_cfg.dz_r, g_cfg.curve);
        float ry = dz_curve(axis(g->sThumbRY), g_cfg.dz_r, g_cfg.curve);

        int have_lua = lua_alive();
        int in_ui    = have_lua && g_lua_ui > 0;
        int in_menu  = g_lua_alive && !have_lua;  /* installed but silent: main menu / loading */

        int a  = (g->wButtons & PAD_A)  != 0, b = (g->wButtons & PAD_B) != 0;
        int y  = (g->wButtons & PAD_Y)  != 0;
        int lb = (g->wButtons & PAD_LSHOULDER) != 0, rb = (g->wButtons & PAD_RSHOULDER) != 0;
        int lt = g->bLeftTrigger  > 100, rt = g->bRightTrigger > 100;
        int l3 = (g->wButtons & PAD_LTHUMB) != 0, r3 = (g->wButtons & PAD_RTHUMB) != 0;

        /* Which physical button mode 2 watches, and whether the assist may move the camera at
           all this frame. In mode 2 that button stops doing its usual job -- the assist is a
           hold, and a hold that also fires an action every time would be worse than the problem
           it solves. */
        int aim_hold;
        switch (g_cfg.aim_btn) {
            case AIM_BTN_L3: aim_hold = l3; break;
            case AIM_BTN_LB: aim_hold = lb; break;
            case AIM_BTN_RB: aim_hold = rb; break;
            case AIM_BTN_LT: aim_hold = lt; break;
            case AIM_BTN_RT: aim_hold = rt; break;
            default:         aim_hold = r3; break;
        }
        {
            int mode2 = (g_cfg.aim == 2);
            if (mode2) {
                if (g_cfg.aim_btn == AIM_BTN_L3) l3 = 0;
                if (g_cfg.aim_btn == AIM_BTN_R3) r3 = 0;
                if (g_cfg.aim_btn == AIM_BTN_LB) lb = 0;
                if (g_cfg.aim_btn == AIM_BTN_RB) rb = 0;
                if (g_cfg.aim_btn == AIM_BTN_LT) lt = 0;
                if (g_cfg.aim_btn == AIM_BTN_RT) rt = 0;
            }
        }
        int aim_active = (g_cfg.aim == 1 && a) || (g_cfg.aim == 2 && aim_hold);
        int lmb = 0, rmb = 0;

        if (!in_ui && !in_menu) {
            if (ly >  0.35f) want[SC_W] = 1;
            if (ly < -0.35f) want[SC_S] = 1;
            if (lx < -0.35f) want[SC_A] = 1;
            if (lx >  0.35f) want[SC_D] = 1;
        }

        /* camera / cursor */
        if (!in_ui && !(lb && !in_menu)) {
            float sx = in_menu ? g_cfg.menu_sens : g_cfg.sens_x;
            float sy = in_menu ? g_cfg.menu_sens : g_cfg.sens_y;
            acc_x += (double)rx * sx * dt;
            acc_y += (double)(in_menu ? -ry : (g_cfg.invert_y ? ry : -ry)) * sy * dt;
            int dx = (int)acc_x; acc_x -= dx;
            int dy = (int)acc_y; acc_y -= dy;
            if (dx || dy) cursor_move(dx, dy);
        } else {
            acc_x = acc_y = 0;
        }

        /* direction: panels in gameplay, focus steps inside one */
        {
            int nav_x = ((g->wButtons & PAD_DPAD_RIGHT) ? 1 : 0) - ((g->wButtons & PAD_DPAD_LEFT) ? 1 : 0);
            int nav_y = ((g->wButtons & PAD_DPAD_DOWN)  ? 1 : 0) - ((g->wButtons & PAD_DPAD_UP)   ? 1 : 0);
            if (in_ui && !nav_x && !nav_y) {
                if (lx >  0.55f) nav_x =  1; else if (lx < -0.55f) nav_x = -1;
                if (ly < -0.55f) nav_y =  1; else if (ly >  0.55f) nav_y = -1;
            }
            int changed = (nav_x != prev_nav_x || nav_y != prev_nav_y);
            if (changed) { prev_nav_x = nav_x; prev_nav_y = nav_y; nav_hold = 0; nav_next = 0.42; }
            else if (nav_x || nav_y) nav_hold += dt;
            int fire = 0;
            if (in_ui && (nav_x || nav_y)) {
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
                if (g->wButtons & PAD_DPAD_UP)    want[SC_J] = 1;   /* diary     */
                if (g->wButtons & PAD_DPAD_DOWN)  want[SC_M] = 1;   /* map       */
                if (g->wButtons & PAD_DPAD_LEFT)  want[SC_H] = 1;   /* character */
                if (g->wButtons & PAD_DPAD_RIGHT) want[SC_L] = 1;   /* alchemy   */
            }
        }

        if (in_ui) {
            if (a  && !p_a)  nav_send("activate");
            if (b  && !p_b)  nav_send("cancel");
            if (y  && !p_y)  nav_send("alt");
            if (lt && !p_lt) nav_send("sect-");
            if (rt && !p_rt) nav_send("sect+");
            if (lb && !p_lb) nav_send("tab-");
            if (rb && !p_rb) nav_send("tab+");
        } else if (in_menu) {
            lmb = a;
            rmb = (g->wButtons & PAD_X) != 0;
            if (b) want[SC_ESC] = 1;
        } else {
            lmb = a;
            rmb = (g->wButtons & PAD_X) != 0;
            if (y)  want[SC_I]   = 1;
            if (b)  want[SC_ESC] = 1;
            if (rb) want[SC_E] = 1;
            if (lt) want[SC_X] = 1;
            if (rt) want[SC_Z] = 1;
            if (l3) want[SC_C] = 1;
            if (r3) want[SC_F] = 1;

            /* Sign wheel. Every combat binding here is a one-shot toggle, so holding LB costs
               nothing and buys the five signs a home: flick the right stick to a sector and
               that sign becomes active, X casts it. Let go without flicking and it was just
               the steel sword. */
            if (lb && !p_lb) nav_send("signmenu:on");
            if (lb) {
                float m = sqrtf(rx * rx + ry * ry);
                if (m > 0.6f) {
                    float ang = atan2f(rx, ry);                  /* 0 = up, clockwise */
                    if (ang < 0) ang += 6.28318531f;
                    int sect = (int)((ang + 0.62831853f) / 1.25663706f) % 5;
                    if (sect != g_wheel_sect) {
                        static const int sign_key[5] = { SC_1, SC_2, SC_3, SC_4, SC_5 };
                        static const char* sign_name[5] =
                            { "Aard", "Quen", "Yrden", "Igni", "Axii" };
                        char msg[16];
                        g_wheel_sect = sect;
                        g_wheel_used = 1;
                        tap_key(sign_key[sect]);
                        snprintf(msg, sizeof msg, "sign:%d", sect + 1);
                        nav_send(msg);
                        wlog("sign wheel: %s", sign_name[sect]);
                    }
                }
            } else if (p_lb) {
                if (!g_wheel_used) want[SC_Q] = 1;   /* plain tap: steel sword */
                nav_send("signmenu:off");
                g_wheel_used = 0;
                g_wheel_sect = -1;
            }
        }
        if (g->wButtons & PAD_START) want[SC_ESC] = 1;
        if (g->wButtons & PAD_BACK)  want[SC_F5]  = 1;

        /* Aim assist: spend the residual Lua published, but only while the player is asking to
           attack and is not steering the camera themselves. Rate-limited rather than snapped --
           a jump cut would read as the game grabbing the camera, and the residual is recomputed
           every frame anyway, so a ramp converges just as fast. */
        if (g_cfg.aim && !in_ui && !in_menu && aim_active
            && fabsf(rx) < 0.25f && fabsf(ry) < 0.25f
            && (GetTickCount() - g_aim_fresh) < 2000) {
            static double rem_x = 0, rem_y = 0;
            double budget = (double)g_cfg.aim_speed * dt;
            double stepx = g_aim_px, stepy = g_aim_py;
            double mag = sqrt(stepx * stepx + stepy * stepy);
            if (mag > budget && mag > 0.0001) { stepx *= budget / mag; stepy *= budget / mag; }
            g_aim_px -= stepx; g_aim_py -= stepy;
            rem_x += stepx; rem_y += stepy;
            int ix = (int)rem_x, iy = (int)rem_y;
            rem_x -= ix; rem_y -= iy;
            if (ix || iy) cursor_move(ix, iy);
        } else {
            g_aim_px = g_aim_py = 0;
        }

        /* A swing sent a frame too early is a swing at empty air -- exactly what the assist is
           for -- so hold the press until Lua reports the reticle has arrived. Bounded: a target
           that cannot be acquired must still not cost the player the ability to attack. */
        {
            static int    p_attack = 0;
            static double aim_wait = 0;
            int attacking = lmb && !in_ui && !in_menu;
            if (!attacking) aim_wait = 0;
            else {
                if (!p_attack) aim_wait = 0;
                /* Only while the assist is actually engaged: in mode 2 an attack with no aim
                   button held is the player's own, and delaying it would be the assist
                   interfering exactly where it was told not to. */
                if (aim_active && !g_aim_ready && (GetTickCount() - g_aim_fresh) < 2000
                    && aim_wait < 0.35) { aim_wait += dt; lmb = 0; }
            }
            p_attack = attacking;
        }

        p_a = a; p_b = b; p_y = y; p_lb = lb; p_rb = rb; p_lt = lt; p_rt = rt;

        for (int i = 0; i < 256; i++) if (g_tap[i]) { want[i] = 1; g_tap[i]--; }
        keys_apply(want);
        if (lmb != held_l) { held_l = lmb; mouse_button(0, lmb); wlogv("mouse: L %d", lmb); }
        if (rmb != held_r) { held_r = rmb; mouse_button(1, rmb); wlogv("mouse: R %d", rmb); }

        /* A heartbeat, so a log from a machine nobody can reach still proves the worker is alive
           and shows what it was seeing. Every ~10 s, and only what changes a diagnosis. */
        if ((tick % 2500) == 0) {
            int nk = 0; for (int i = 0; i < 256; i++) if (want[i]) nk++;
            /* g_aim_ready starts at 1, so without this a heartbeat with no aim data at all
               would claim the reticle is on target. */
            int aim_live = g_aim_fresh && (GetTickCount() - g_aim_fresh) < 2000;
            wlog("alive: slot=%d lx=%.2f ly=%.2f rx=%.2f ry=%.2f btn=%04x keys=%d "
                 "mode=%s lua=%s aim=%s%.0f/%.0f%s",
                 slot, lx, ly, rx, ry, (unsigned)g->wButtons, nk,
                 in_ui ? "ui" : (in_menu ? "menu" : "world"),
                 have_lua ? "ticking" : (g_lua_alive ? "silent" : "NOT INSTALLED"),
                 aim_live ? "" : "stale ", g_aim_px, g_aim_py,
                 (aim_live && g_aim_ready) ? " ready" : "");
        }
    }
}

/* ------------------------------------------------------- startup diagnostics */
/* Nobody can attach a debugger to this on a Steam Deck, so the log has to answer the obvious
   questions before anything goes wrong: where we loaded from, what we derived from that, and
   whether each file we depend on is actually there. Almost every failure report is one of these
   lines being wrong. */
static void note_path(const char* label, const char* path) {
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (GetFileAttributesExA(path, GetFileExInfoStandard, &fa))
        wlog("  %-12s %s  (%lu bytes)", label, path, (unsigned long)fa.nFileSizeLow);
    else
        wlog("  %-12s %s  -- NOT PRESENT", label, path);
}

static int dir_writable(const char* dir) {
    char probe[WXP_PATH + 64];
    snprintf(probe, sizeof probe, "%s\\wxp_write_probe.tmp", dir);
    FILE* f = fopen(probe, "w");
    if (!f) return 0;
    fclose(f);
    DeleteFileA(probe);
    return 1;
}

static void log_environment(void) {
    char self[MAX_PATH] = {0};
    GetModuleFileNameA(g_self, self, sizeof self);
    wlog("loaded from : %s", self);
    wlog("game root   : %s", g_root);

    /* Proton and Wine both answer this; on real Windows it is absent. Knowing which one you are
       looking at decides half the follow-up questions. */
    {
        HMODULE nt = GetModuleHandleA("ntdll.dll");
        const char* (CDECL *wine_ver)(void) = NULL;
        if (nt) wine_ver = (const char* (CDECL *)(void))(void*)GetProcAddress(nt, "wine_get_version");
        if (wine_ver) wlog("runtime     : Wine/Proton %s", wine_ver());
        else          wlog("runtime     : native Windows");
    }
    {
        OSVERSIONINFOA v; ZeroMemory(&v, sizeof v); v.dwOSVersionInfoSize = sizeof v;
        #pragma GCC diagnostic push
        #pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        if (GetVersionExA(&v)) wlog("reported ver: %lu.%lu build %lu",
            (unsigned long)v.dwMajorVersion, (unsigned long)v.dwMinorVersion,
            (unsigned long)v.dwBuildNumber);
        #pragma GCC diagnostic pop
    }

    char scripts[WXP_PATH + 16], sys[WXP_PATH + 16];
    snprintf(sys,     sizeof sys,     "%s\\System", g_root);
    snprintf(scripts, sizeof scripts, "%s\\System\\Scripts", g_root);
    wlog("files:");
    note_path("config",  g_ini);
    note_path("tab cfg", g_ini2);
    {   /* The script half is a separate install step, and forgetting it is the single most
           likely way for this to be half-working: the pad moves but no menu responds. */
        char luc[WXP_PATH + 32];
        snprintf(luc, sizeof luc, "%s\\wxp_gamepad.luc", scripts);
        note_path("lua layer", luc);
        snprintf(luc, sizeof luc, "%s\\wxp_ui.luc", scripts);
        note_path("lua ui", luc);
        snprintf(luc, sizeof luc, "%s\\debug.luc", scripts);
        note_path("entry", luc);
    }
    wlog("System writable: %s   (channels live there)", dir_writable(sys) ? "yes" : "NO");
    if (!dir_writable(sys))
        wlog("  ^ without this the pad cannot talk to the script layer at all");
}

/* --------------------------------------------------------------- entry point */
static void derive_paths(void) {
    /* <game>\System\lightfx\wxp\LightFX.dll -> <game> */
    GetModuleFileNameA(g_self, g_root, sizeof g_root);
    for (int i = 0; i < 4; i++) {
        char* p = strrchr(g_root, '\\');
        if (!p) break;
        *p = 0;
    }
    snprintf(g_ini,        sizeof g_ini,        "%s\\gamepad.ini", g_root);
    snprintf(g_ini2,       sizeof g_ini2,       "%s\\System\\wxp_config.ini", g_root);
    snprintf(g_state_path, sizeof g_state_path, "%s\\System\\wxp_state.ini", g_root);
    snprintf(g_nav_path,   sizeof g_nav_path,   "%s\\System\\wxp_nav.txt", g_root);
    snprintf(g_aim_path,   sizeof g_aim_path,   "%s\\System\\wxp_aim.txt", g_root);
    snprintf(g_log_path,   sizeof g_log_path,   "%s\\System\\wxp_bridge.log", g_root);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = (HMODULE)inst;
        DisableThreadLibraryCalls(inst);
        /* The engine may drop its reference once LightFX "fails"; pin ourselves so the worker
           thread does not get unloaded out from under itself. */
        {
            char self[MAX_PATH];
            GetModuleFileNameA(g_self, self, sizeof self);
            LoadLibraryA(self);
        }
        derive_paths();
        log_rotate();
        {
            /* The epoch too: the script layer's log is timestamped by the engine's own clock,
               which need not agree with this one, and lining the two up is the whole point. */
            SYSTEMTIME t; GetLocalTime(&t);
            wlog("==== WitcherPadBridge (Windows) %s, pid %lu, %04d-%02d-%02d, epoch %lld ====",
                 WXP_VERSION, (unsigned long)GetCurrentProcessId(), t.wYear, t.wMonth, t.wDay,
                 (long long)time(NULL));
        }
        log_environment();
        CreateThread(NULL, 0, worker, NULL, 0, NULL);
    }
    return TRUE;
}

/* -------------------------------------------------- LightFX API, all stubbed */
/* The engine only needs these to resolve; it ignores what they return. */
#define LFX_FAILURE 1
#define LFX_EXPORT __declspec(dllexport) int __stdcall

LFX_EXPORT LFX_Initialize(void) { return LFX_FAILURE; }
LFX_EXPORT LFX_Release(void) { return LFX_FAILURE; }
LFX_EXPORT LFX_Reset(void) { return LFX_FAILURE; }
LFX_EXPORT LFX_Update(void) { return LFX_FAILURE; }
LFX_EXPORT LFX_UpdateDefault(void) { return LFX_FAILURE; }
LFX_EXPORT LFX_GetNumDevices(unsigned int* n) { if (n) *n = 0; return LFX_FAILURE; }
LFX_EXPORT LFX_GetDeviceDescription(unsigned int a, char* b, unsigned int c, unsigned char* d)
{ (void)a;(void)b;(void)c;(void)d; return LFX_FAILURE; }
LFX_EXPORT LFX_GetNumLights(unsigned int a, unsigned int* b) { (void)a; if (b) *b = 0; return LFX_FAILURE; }
LFX_EXPORT LFX_GetLightDescription(unsigned int a, unsigned int b, char* c, unsigned int d)
{ (void)a;(void)b;(void)c;(void)d; return LFX_FAILURE; }
LFX_EXPORT LFX_GetLightLocation(unsigned int a, unsigned int b, void* c) { (void)a;(void)b;(void)c; return LFX_FAILURE; }
LFX_EXPORT LFX_GetLightColor(unsigned int a, unsigned int b, void* c) { (void)a;(void)b;(void)c; return LFX_FAILURE; }
LFX_EXPORT LFX_SetLightColor(unsigned int a, unsigned int b, const void* c) { (void)a;(void)b;(void)c; return LFX_FAILURE; }
LFX_EXPORT LFX_Light(unsigned int a, unsigned int b) { (void)a;(void)b; return LFX_FAILURE; }
LFX_EXPORT LFX_SetLightActionColor(unsigned int a, unsigned int b, unsigned int c, const void* d)
{ (void)a;(void)b;(void)c;(void)d; return LFX_FAILURE; }
LFX_EXPORT LFX_SetLightActionColorEx(unsigned int a, unsigned int b, unsigned int c, const void* d, const void* e)
{ (void)a;(void)b;(void)c;(void)d;(void)e; return LFX_FAILURE; }
LFX_EXPORT LFX_ActionColor(unsigned int a, unsigned int b, const void* c) { (void)a;(void)b;(void)c; return LFX_FAILURE; }
LFX_EXPORT LFX_ActionColorEx(unsigned int a, unsigned int b, const void* c, const void* d)
{ (void)a;(void)b;(void)c;(void)d; return LFX_FAILURE; }
LFX_EXPORT LFX_SetTiming(int a) { (void)a; return LFX_FAILURE; }
LFX_EXPORT LFX_GetVersion(char* a, unsigned int b) { (void)a;(void)b; return LFX_FAILURE; }
