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
 */
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <math.h>

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
static char    g_log_path[WXP_PATH];
static FILETIME g_ini_time, g_ini2_time;

static struct {
    int   enabled;
    float dz_l, dz_r, curve;
    float sens_x, sens_y, menu_sens;
    int   invert_y;
} g_cfg = { 1, 0.20f, 0.16f, 1.7f, 1400.f, 900.f, 700.f, 0 };

static void wlog(const char* fmt, ...) {
    FILE* f = fopen(g_log_path, "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

/* ------------------------------------------------------------------- config */
static void cfg_parse(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char key[64]; float v;
        if (sscanf(line, " %63[A-Za-z] = %f", key, &v) != 2) continue;
        if      (!_stricmp(key, "Enabled"))         g_cfg.enabled  = (int)v;
        else if (!_stricmp(key, "DeadzoneLeft"))    g_cfg.dz_l     = v;
        else if (!_stricmp(key, "DeadzoneRight"))   g_cfg.dz_r     = v;
        else if (!_stricmp(key, "SensitivityX"))    g_cfg.sens_x   = v;
        else if (!_stricmp(key, "SensitivityY"))    g_cfg.sens_y   = v;
        else if (!_stricmp(key, "CameraCurve"))     g_cfg.curve    = v;
        else if (!_stricmp(key, "InvertY"))         g_cfg.invert_y = (int)v;
        else if (!_stricmp(key, "MenuSensitivity")) g_cfg.menu_sens = v;
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
    if (has_a) cfg_parse(g_ini);
    if (has_b) cfg_parse(g_ini2);
    wlog("config: dzL=%.2f dzR=%.2f sens=%.0f/%.0f curve=%.2f invY=%d en=%d menu=%.0f (tab: %s)",
         g_cfg.dz_l, g_cfg.dz_r, g_cfg.sens_x, g_cfg.sens_y, g_cfg.curve,
         g_cfg.invert_y, g_cfg.enabled, g_cfg.menu_sens, has_b ? "yes" : "no");
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
    if (!f) return;
    fprintf(f, "%lu %s\n", (unsigned long)++g_nav_seq, intent);
    fclose(f);
}

static void poll_lua_state(void) {
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (!GetFileAttributesExA(g_state_path, GetFileExInfoStandard, &fa)) return;
    if (CompareFileTime(&fa.ftLastWriteTime, &g_state_time) == 0) return;
    g_state_time = fa.ftLastWriteTime;
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
    if (!XInputGetState) { wlog("xinput: none found -- pad support off"); return 0; }

    load_config(1);

    BYTE want[256];
    double acc_x = 0, acc_y = 0;
    DWORD prev_ms = GetTickCount();
    int p_a = 0, p_b = 0, p_y = 0, p_lb = 0, p_rb = 0, p_lt = 0, p_rt = 0;
    int prev_nav_x = 0, prev_nav_y = 0;
    double nav_hold = 0, nav_next = 0;
    int held_l = 0, held_r = 0;
    unsigned tick = 0;

    for (;;) {
        Sleep(4);
        tick++;
        if ((tick % 250) == 0) load_config(0);
        if ((tick % 25) == 0) poll_lua_state();

        ZeroMemory(want, sizeof want);
        WXP_STATE st;
        ZeroMemory(&st, sizeof st);
        if (XInputGetState(0, &st) != ERROR_SUCCESS || !g_cfg.enabled) {
            keys_apply(want);
            continue;
        }

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
            if (g->wButtons & PAD_LTHUMB) want[SC_C] = 1;
            if (g->wButtons & PAD_RTHUMB) want[SC_F] = 1;

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
        p_a = a; p_b = b; p_y = y; p_lb = lb; p_rb = rb; p_lt = lt; p_rt = rt;

        for (int i = 0; i < 256; i++) if (g_tap[i]) { want[i] = 1; g_tap[i]--; }
        keys_apply(want);
        if (lmb != held_l) { held_l = lmb; mouse_button(0, lmb); }
        if (rmb != held_r) { held_r = rmb; mouse_button(1, rmb); }
    }
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
        wlog("---- WitcherPadBridge (Windows) loaded, pid %lu ----", (unsigned long)GetCurrentProcessId());
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
