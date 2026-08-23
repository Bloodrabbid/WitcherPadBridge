/* WitcherPadBridge Phase-0 probe DLL, shipped as LightFX.dll
 * Goals (single launch):
 *   0.1 confirm eON/Wine JIT-loads our PE from System\lightfx\wxp\
 *   0.6/0.7 enumerate DirectInput devices -> is the DualSense visible to DI8?
 *   0.2 hook IDirectInputDevice8::GetDeviceState/GetDeviceData on the shared
 *       keyboard & mouse vtables and (a) log calls, (b) inject W / mouse dX so a
 *       human in-game sees Geralt walk / camera pan on a 2s on/off cadence.
 *   also: try keybd_event + SendInput (expected no-op under eON) and log.
 * All findings go to a log file we can read from the host.
 */
#define DIRECTINPUT_VERSION 0x0800
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dinput.h>
#include <stdio.h>
#include <stdarg.h>
#include "lightfx.h"

static FILE *g_log = NULL;
static CRITICAL_SECTION g_logcs;
static volatile LONG g_inject = 0;          /* toggled every 2s */
static volatile LONG g_kbdGDS_calls = 0;    /* keyboard GetDeviceState hits */
static volatile LONG g_kbdGDD_calls = 0;    /* keyboard GetDeviceData  hits */
static volatile LONG g_msGDS_calls  = 0;    /* mouse GetDeviceState hits */
static volatile LONG g_msGDD_calls  = 0;    /* mouse GetDeviceData  hits */

static void wlog(const char *fmt, ...) {
    if (!g_log) return;
    EnterCriticalSection(&g_logcs);
    va_list ap; va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
    LeaveCriticalSection(&g_logcs);
}

static void open_log(void) {
    /* try a few emulated-FS paths; keep the first that opens */
    const char *cands[] = {
        "C:\\GameDocuments\\wxp_bridge.log",
        "wxp_bridge.log",
        "C:\\wxp_bridge.log",
        NULL
    };
    for (int i = 0; cands[i]; ++i) {
        FILE *f = fopen(cands[i], "w");
        if (f) { g_log = f; fprintf(f, "[log opened at %s]\n", cands[i]); fflush(f); return; }
    }
}

/* ---- vtable hooks ---- */
typedef HRESULT (WINAPI *GDS_t)(LPDIRECTINPUTDEVICE8A, DWORD, LPVOID);
typedef HRESULT (WINAPI *GDD_t)(LPDIRECTINPUTDEVICE8A, DWORD, LPDIDEVICEOBJECTDATA, LPDWORD, DWORD);

static GDS_t realKbdGDS = NULL, realMsGDS = NULL;
static GDD_t realKbdGDD = NULL, realMsGDD = NULL;

static HRESULT WINAPI hookKbdGDS(LPDIRECTINPUTDEVICE8A self, DWORD cb, LPVOID data) {
    HRESULT hr = realKbdGDS(self, cb, data);
    LONG n = InterlockedIncrement(&g_kbdGDS_calls);
    if (SUCCEEDED(hr) && data && cb >= 256 && g_inject) {
        ((BYTE*)data)[DIK_W] = 0x80;   /* hold W */
    }
    if ((n % 300) == 1) wlog("hookKbdGDS: call#%ld self=%p cb=%lu hr=0x%lx inject=%ld", n, self, cb, (long)hr, g_inject);
    return hr;
}
static HRESULT WINAPI hookMsGDS(LPDIRECTINPUTDEVICE8A self, DWORD cb, LPVOID data) {
    HRESULT hr = realMsGDS(self, cb, data);
    LONG n = InterlockedIncrement(&g_msGDS_calls);
    if (SUCCEEDED(hr) && data && cb >= sizeof(DIMOUSESTATE) && g_inject) {
        ((DIMOUSESTATE*)data)->lX += 18;  /* pan right */
    }
    if ((n % 300) == 1) wlog("hookMsGDS : call#%ld self=%p cb=%lu hr=0x%lx inject=%ld", n, self, cb, (long)hr, g_inject);
    return hr;
}
static HRESULT WINAPI hookKbdGDD(LPDIRECTINPUTDEVICE8A self, DWORD cbObj, LPDIDEVICEOBJECTDATA rgdod, LPDWORD pn, DWORD fl) {
    HRESULT hr = realKbdGDD(self, cbObj, rgdod, pn, fl);
    LONG n = InterlockedIncrement(&g_kbdGDD_calls);
    if ((n % 300) == 1) wlog("hookKbdGDD: call#%ld self=%p cbObj=%lu n=%lu hr=0x%lx", n, self, cbObj, pn?*pn:0, (long)hr);
    return hr;
}
static HRESULT WINAPI hookMsGDD(LPDIRECTINPUTDEVICE8A self, DWORD cbObj, LPDIDEVICEOBJECTDATA rgdod, LPDWORD pn, DWORD fl) {
    HRESULT hr = realMsGDD(self, cbObj, rgdod, pn, fl);
    LONG n = InterlockedIncrement(&g_msGDD_calls);
    if ((n % 300) == 1) wlog("hookMsGDD : call#%ld self=%p cbObj=%lu n=%lu hr=0x%lx", n, self, cbObj, pn?*pn:0, (long)hr);
    return hr;
}

static void patch_slot(void **vtbl, int idx, void *hook, void **saveReal) {
    DWORD old;
    if (VirtualProtect(&vtbl[idx], sizeof(void*), PAGE_EXECUTE_READWRITE, &old)) {
        *saveReal = vtbl[idx];
        vtbl[idx] = hook;
        VirtualProtect(&vtbl[idx], sizeof(void*), old, &old);
    } else {
        wlog("VirtualProtect FAILED on vtbl[%d]=%p err=%lu", idx, &vtbl[idx], GetLastError());
    }
}

static HINSTANCE g_self = NULL;
static LPDIRECTINPUT8A g_di = NULL;

static BOOL CALLBACK enumCB(LPCDIDEVICEINSTANCEA di, LPVOID ctx) {
    wlog("DI-DEVICE: type=0x%08lx subtype=%u name='%s' product='%s'",
         di->dwDevType, (unsigned)GET_DIDEVICE_SUBTYPE(di->dwDevType),
         di->tszInstanceName, di->tszProductName);
    return DIENUM_CONTINUE;
}

static LPDIRECTINPUTDEVICE8A g_pad = NULL;

static void setup_gamepad(void) {
    /* enumerate + create first game controller, log live state */
    LPCDIDEVICEINSTANCEA found = NULL;
    /* we can't easily capture from the C callback into a struct without ctx; do a 2-pass with a static */
}

static BOOL CALLBACK padPick(LPCDIDEVICEINSTANCEA di, LPVOID ctx) {
    GUID *out = (GUID*)ctx;
    *out = di->guidInstance;
    wlog("PAD-PICK: name='%s' product='%s' type=0x%08lx", di->tszInstanceName, di->tszProductName, di->dwDevType);
    return DIENUM_STOP;
}

static DWORD WINAPI worker(LPVOID arg) {
    (void)arg;
    Sleep(2000); /* let the game finish DI init */
    {
        char mp[1024]; mp[0]=0;
        GetModuleFileNameA(g_self, mp, sizeof(mp));
        wlog("worker: start; pid=%lu OUR MODULE PATH = '%s'", GetCurrentProcessId(), mp);
    }

    HINSTANCE hInst = GetModuleHandleA(NULL);
    HRESULT hr = DirectInput8Create(hInst, DIRECTINPUT_VERSION, &IID_IDirectInput8A, (void**)&g_di, NULL);
    wlog("DirectInput8Create -> 0x%lx di=%p", (long)hr, g_di);
    if (FAILED(hr) || !g_di) { wlog("no DI; abort DI probes"); }
    else {
        wlog("--- EnumDevices(ALL) ---");
        g_di->lpVtbl->EnumDevices(g_di, DI8DEVCLASS_ALL, enumCB, NULL, DIEDFL_ATTACHEDONLY);
        wlog("--- EnumDevices(GAMECTRL) ---");
        GUID padGuid; ZeroMemory(&padGuid, sizeof(padGuid));
        g_di->lpVtbl->EnumDevices(g_di, DI8DEVCLASS_GAMECTRL, padPick, &padGuid, DIEDFL_ATTACHEDONLY);

        /* create keyboard + mouse to grab shared vtables and hook them */
        LPDIRECTINPUTDEVICE8A kbd = NULL, ms = NULL;
        hr = g_di->lpVtbl->CreateDevice(g_di, &GUID_SysKeyboard, &kbd, NULL);
        wlog("CreateDevice(SysKeyboard) -> 0x%lx dev=%p", (long)hr, kbd);
        hr = g_di->lpVtbl->CreateDevice(g_di, &GUID_SysMouse, &ms, NULL);
        wlog("CreateDevice(SysMouse) -> 0x%lx dev=%p", (long)hr, ms);

        if (kbd) {
            void **vt = *(void***)kbd;
            wlog("kbd vtbl=%p GDS(9)=%p GDD(10)=%p", vt, vt[9], vt[10]);
            patch_slot(vt, 9,  (void*)hookKbdGDS, (void**)&realKbdGDS);
            patch_slot(vt, 10, (void*)hookKbdGDD, (void**)&realKbdGDD);
        }
        if (ms) {
            void **vt = *(void***)ms;
            wlog("ms  vtbl=%p GDS(9)=%p GDD(10)=%p", vt, vt[9], vt[10]);
            patch_slot(vt, 9,  (void*)hookMsGDS, (void**)&realMsGDS);
            patch_slot(vt, 10, (void*)hookMsGDD, (void**)&realMsGDD);
        }

        /* try to open the picked gamepad and read state */
        if (padGuid.Data1 || padGuid.Data2) {
            hr = g_di->lpVtbl->CreateDevice(g_di, &padGuid, &g_pad, NULL);
            wlog("CreateDevice(pad) -> 0x%lx dev=%p", (long)hr, g_pad);
            if (g_pad) {
                hr = g_pad->lpVtbl->SetDataFormat(g_pad, &c_dfDIJoystick2);
                wlog("pad SetDataFormat -> 0x%lx", (long)hr);
                HWND hwnd = GetForegroundWindow();
                hr = g_pad->lpVtbl->SetCooperativeLevel(g_pad, hwnd, DISCL_BACKGROUND|DISCL_NONEXCLUSIVE);
                wlog("pad SetCooperativeLevel(hwnd=%p) -> 0x%lx", hwnd, (long)hr);
                hr = g_pad->lpVtbl->Acquire(g_pad);
                wlog("pad Acquire -> 0x%lx", (long)hr);
            }
        } else {
            wlog("no gamepad picked by enumeration");
        }
    }

    /* main loop: toggle inject every 2s, poll pad, exercise keybd_event/SendInput */
    int tick = 0;
    for (;;) {
        LONG want = ((tick / 20) % 2) ? 1 : 0;   /* 20 * 100ms = 2s */
        if (want != g_inject) { InterlockedExchange(&g_inject, want); wlog("inject -> %ld (t=%ds)", want, tick/10); }

        if (g_pad) {
            DIJOYSTATE2 js; ZeroMemory(&js, sizeof(js));
            HRESULT pr = g_pad->lpVtbl->Poll(g_pad);
            HRESULT gr = g_pad->lpVtbl->GetDeviceState(g_pad, sizeof(js), &js);
            if (gr == DIERR_INPUTLOST || gr == DIERR_NOTACQUIRED) g_pad->lpVtbl->Acquire(g_pad);
            if ((tick % 20) == 0)
                wlog("PAD state poll=0x%lx get=0x%lx lX=%ld lY=%ld lRx=%ld lRy=%ld b0=%02x b1=%02x pov0=%lu",
                     (long)pr,(long)gr, js.lX, js.lY, js.lRx, js.lRy, js.rgbButtons[0], js.rgbButtons[1], js.rgdwPOV[0]);
        }

        if ((tick % 30) == 5) {
            /* control experiment: does keybd_event / SendInput reach the game? (expected: no) */
            keybd_event(0x57 /*VK_W*/, 0x11, 0, 0);
            Sleep(120);
            keybd_event(0x57, 0x11, KEYEVENTF_KEYUP, 0);
            INPUT in; ZeroMemory(&in, sizeof(in));
            in.type = INPUT_KEYBOARD; in.ki.wScan = 0x11; in.ki.dwFlags = KEYEVENTF_SCANCODE;
            UINT sent = SendInput(1, &in, sizeof(INPUT));
            in.ki.dwFlags |= KEYEVENTF_KEYUP; SendInput(1, &in, sizeof(INPUT));
            wlog("control: keybd_event+SendInput fired (SendInput ret=%u)", sent);
        }

        if ((tick % 50) == 0)
            wlog("counters: kbdGDS=%ld kbdGDD=%ld msGDS=%ld msGDD=%ld inject=%ld",
                 g_kbdGDS_calls, g_kbdGDD_calls, g_msGDS_calls, g_msGDD_calls, g_inject);

        Sleep(100);
        tick++;
    }
    return 0;
}

/* ---- LFX stub exports ---- */
#define LFX_API __declspec(dllexport) int __stdcall
LFX_API LFX_Initialize(void){ wlog("LFX_Initialize called"); return LFX_SUCCESS; }
LFX_API LFX_Release(void){ return LFX_SUCCESS; }
LFX_API LFX_Reset(void){ return LFX_SUCCESS; }
LFX_API LFX_Update(void){ return LFX_SUCCESS; }
LFX_API LFX_UpdateDefault(void){ return LFX_SUCCESS; }
LFX_API LFX_GetNumDevices(unsigned int* n){ if(n)*n=0; return LFX_SUCCESS; }
LFX_API LFX_GetDeviceDescription(unsigned int a,char* b,unsigned int c,unsigned char* d){ (void)a;(void)b;(void)c;(void)d; return LFX_ERROR_NODEVS; }
LFX_API LFX_GetNumLights(unsigned int a,unsigned int* n){ (void)a; if(n)*n=0; return LFX_SUCCESS; }
LFX_API LFX_GetLightDescription(unsigned int a,unsigned int b,char* c,unsigned int d){ (void)a;(void)b;(void)c;(void)d; return LFX_ERROR_NOLIGHTS; }
LFX_API LFX_GetLightLocation(unsigned int a,unsigned int b,void* c){ (void)a;(void)b;(void)c; return LFX_ERROR_NOLIGHTS; }
LFX_API LFX_GetLightColor(unsigned int a,unsigned int b,void* c){ (void)a;(void)b;(void)c; return LFX_ERROR_NOLIGHTS; }
LFX_API LFX_SetLightColor(unsigned int a,unsigned int b,const void* c){ (void)a;(void)b;(void)c; return LFX_SUCCESS; }
LFX_API LFX_Light(unsigned int a,unsigned int b){ (void)a;(void)b; return LFX_SUCCESS; }
LFX_API LFX_SetLightActionColor(unsigned int a,unsigned int b,unsigned int c,const void* d){ (void)a;(void)b;(void)c;(void)d; return LFX_SUCCESS; }
LFX_API LFX_SetLightActionColorEx(unsigned int a,unsigned int b,unsigned int c,const void* d,const void* e){ (void)a;(void)b;(void)c;(void)d;(void)e; return LFX_SUCCESS; }
LFX_API LFX_ActionColor(unsigned int a,unsigned int b,unsigned int c){ (void)a;(void)b;(void)c; return LFX_SUCCESS; }
LFX_API LFX_ActionColorEx(unsigned int a,unsigned int b,unsigned int c,unsigned int d){ (void)a;(void)b;(void)c;(void)d; return LFX_SUCCESS; }
LFX_API LFX_SetTiming(int a){ (void)a; return LFX_SUCCESS; }
LFX_API LFX_GetVersion(char* b,unsigned int c){ if(b&&c) lstrcpynA(b,"2.2.0.0",c); return LFX_SUCCESS; }

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
    (void)r;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = h;
        DisableThreadLibraryCalls(h);
        { HMODULE self=NULL; GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_PIN|GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,(LPCSTR)&DllMain,&self); }
        InitializeCriticalSection(&g_logcs);
        open_log();
        wlog("DllMain ATTACH: LightFX.dll loaded OK");
        CreateThread(NULL, 0, worker, NULL, 0, NULL);
    }
    return TRUE;
}
