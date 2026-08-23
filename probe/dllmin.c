/* WitcherPadBridge Phase-0 probe DLL, FREESTANDING (no CRT) so eON can bind it.
 * Only kernel32 + dinput8 + user32 imports (all provided by eON / Wine).
 * Proves: PE loads (writes log w/ its own path), DI enumerates devices incl.
 * DualSense, vtable hooks on kbd/mouse GetDeviceState/Data fire; toggles W and
 * mouse dX injection every 2s so a human in-game sees Geralt walk / camera pan.
 */
#define DIRECTINPUT_VERSION 0x0800
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dinput.h>
#include <stdarg.h>

/* ---- freestanding helpers (no CRT) ---- */
void* memset(void* d,int c,size_t n){unsigned char*p=d;while(n--)*p++=(unsigned char)c;return d;}
void* memcpy(void* d,const void* s,size_t n){unsigned char*a=d;const unsigned char*b=s;while(n--)*a++=*b++;return d;}
static size_t slen(const char*s){size_t n=0;while(s&&s[n])n++;return n;}

/* GUIDs (define locally to avoid dxguid) */
static const GUID g_IID_IDirectInput8A={0xBF798030,0x483A,0x4DA2,{0xAA,0x99,0x5D,0x64,0xED,0x36,0x97,0x00}};
static const GUID g_GUID_SysKeyboard ={0x6F1D2B61,0xD5A0,0x11CF,{0xBF,0xC7,0x44,0x45,0x53,0x54,0x00,0x00}};
static const GUID g_GUID_SysMouse    ={0x6F1D2B60,0xD5A0,0x11CF,{0xBF,0xC7,0x44,0x45,0x53,0x54,0x00,0x00}};

/* ---- logging via kernel32 only ---- */
static char g_logpath[512];
static CRITICAL_SECTION g_cs;

static void appendfile(const char* path,const char* buf,int len){
    HANDLE h=CreateFileA(path,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
    if(h==INVALID_HANDLE_VALUE)return;
    SetFilePointer(h,0,0,FILE_END);
    DWORD wr; WriteFile(h,buf,(DWORD)len,&wr,0);
    CloseHandle(h);
}
static int puts_buf(char*out,int pos,const char*s){while(s&&*s&&pos<1000)out[pos++]=*s++;return pos;}
static int putu_buf(char*out,int pos,unsigned long v,int base){
    char tmp[32];int t=0;const char*dig="0123456789abcdef";
    if(v==0)tmp[t++]='0'; while(v){tmp[t++]=dig[v%base];v/=base;}
    while(t--&&pos<1000)out[pos++]=tmp[t];
    return pos;
}
static void wlog(const char* fmt,...){
    char out[1024]; int pos=0; va_list ap; va_start(ap,fmt);
    for(const char*p=fmt;*p&&pos<1000;p++){
        if(*p!='%'){out[pos++]=*p;continue;}
        p++;
        if(*p=='l'){p++; if(*p=='u'){pos=putu_buf(out,pos,va_arg(ap,unsigned long),10);}
                     else if(*p=='x'){pos=putu_buf(out,pos,va_arg(ap,unsigned long),16);}
                     else if(*p=='d'){long v=va_arg(ap,long); if(v<0){out[pos++]='-';v=-v;} pos=putu_buf(out,pos,(unsigned long)v,10);} }
        else if(*p=='s'){pos=puts_buf(out,pos,va_arg(ap,const char*));}
        else if(*p=='d'){int v=va_arg(ap,int); if(v<0){out[pos++]='-';v=-v;} pos=putu_buf(out,pos,(unsigned)v,10);}
        else if(*p=='u'){pos=putu_buf(out,pos,va_arg(ap,unsigned),10);}
        else if(*p=='x'){pos=putu_buf(out,pos,va_arg(ap,unsigned),16);}
        else if(*p=='p'){out[pos++]='0';out[pos++]='x';pos=putu_buf(out,pos,(unsigned long)(size_t)va_arg(ap,void*),16);}
        else out[pos++]=*p;
    }
    va_end(ap);
    out[pos++]='\r'; out[pos++]='\n';
    EnterCriticalSection(&g_cs);
    appendfile(g_logpath,out,pos);
    LeaveCriticalSection(&g_cs);
}

/* ---- vtable hooks ---- */
typedef HRESULT (WINAPI *GDS_t)(LPDIRECTINPUTDEVICE8A,DWORD,LPVOID);
typedef HRESULT (WINAPI *GDD_t)(LPDIRECTINPUTDEVICE8A,DWORD,LPDIDEVICEOBJECTDATA,LPDWORD,DWORD);
static GDS_t realKbdGDS,realMsGDS; static GDD_t realKbdGDD,realMsGDD;
static volatile LONG g_inject=0,g_kGDS=0,g_kGDD=0,g_mGDS=0,g_mGDD=0;

static HRESULT WINAPI hkKbdGDS(LPDIRECTINPUTDEVICE8A s,DWORD cb,LPVOID d){
    HRESULT hr=realKbdGDS(s,cb,d); LONG n=InterlockedIncrement(&g_kGDS);
    if(hr>=0&&d&&cb>=256&&g_inject)((BYTE*)d)[DIK_W]=0x80;
    if(n%300==1)wlog("hkKbdGDS #%ld cb=%lu hr=%lx inj=%ld",n,cb,(unsigned long)hr,g_inject);
    return hr;
}
static HRESULT WINAPI hkMsGDS(LPDIRECTINPUTDEVICE8A s,DWORD cb,LPVOID d){
    HRESULT hr=realMsGDS(s,cb,d); LONG n=InterlockedIncrement(&g_mGDS);
    if(hr>=0&&d&&cb>=(DWORD)sizeof(DIMOUSESTATE)&&g_inject)((DIMOUSESTATE*)d)->lX+=18;
    if(n%300==1)wlog("hkMsGDS  #%ld cb=%lu hr=%lx inj=%ld",n,cb,(unsigned long)hr,g_inject);
    return hr;
}
static HRESULT WINAPI hkKbdGDD(LPDIRECTINPUTDEVICE8A s,DWORD cb,LPDIDEVICEOBJECTDATA r,LPDWORD pn,DWORD f){
    HRESULT hr=realKbdGDD(s,cb,r,pn,f); LONG n=InterlockedIncrement(&g_kGDD);
    if(n%300==1)wlog("hkKbdGDD #%ld n=%lu hr=%lx",n,pn?(unsigned long)*pn:0,(unsigned long)hr); return hr;
}
static HRESULT WINAPI hkMsGDD(LPDIRECTINPUTDEVICE8A s,DWORD cb,LPDIDEVICEOBJECTDATA r,LPDWORD pn,DWORD f){
    HRESULT hr=realMsGDD(s,cb,r,pn,f); LONG n=InterlockedIncrement(&g_mGDD);
    if(n%300==1)wlog("hkMsGDD  #%ld n=%lu hr=%lx",n,pn?(unsigned long)*pn:0,(unsigned long)hr); return hr;
}
static void patch(void**vt,int i,void*hook,void**save){
    DWORD old; if(VirtualProtect(&vt[i],sizeof(void*),PAGE_EXECUTE_READWRITE,&old)){*save=vt[i];vt[i]=hook;VirtualProtect(&vt[i],sizeof(void*),old,&old);}
    else wlog("VirtualProtect FAIL vt[%d]",i);
}

typedef HRESULT (WINAPI *DI8C_t)(HINSTANCE,DWORD,REFIID,LPVOID*,LPUNKNOWN);
static LPDIRECTINPUT8A g_di=0;
static GUID g_padGuid;

static BOOL CALLBACK enumCB(LPCDIDEVICEINSTANCEA di,LPVOID c){
    wlog("DI-DEV type=%lx name='%s' product='%s'",(unsigned long)di->dwDevType,di->tszInstanceName,di->tszProductName);
    return DIENUM_CONTINUE;
}
static BOOL CALLBACK padCB(LPCDIDEVICEINSTANCEA di,LPVOID c){
    g_padGuid=di->guidInstance; wlog("PAD-PICK '%s'",di->tszProductName); return DIENUM_STOP;
}

static HINSTANCE g_self;
static DWORD WINAPI worker(LPVOID a){
    Sleep(2500);
    char mp[512]; DWORD ml=GetModuleFileNameA(g_self,mp,sizeof(mp)); mp[ml<511?ml:511]=0;
    wlog("=== WitcherPadBridge probe alive; OUR MODULE PATH = '%s' ===",mp);

    HMODULE hdi=LoadLibraryA("dinput8.dll");
    wlog("LoadLibrary(dinput8.dll)=%p",hdi);
    DI8C_t pDI8C = hdi? (DI8C_t)GetProcAddress(hdi,"DirectInput8Create"):0;
    wlog("DirectInput8Create=%p",pDI8C);
    if(pDI8C){
        HRESULT hr=pDI8C(GetModuleHandleA(0),DIRECTINPUT_VERSION,&g_IID_IDirectInput8A,(void**)&g_di,0);
        wlog("DI8Create hr=%lx di=%p",(unsigned long)hr,g_di);
        if(g_di){
            wlog("--- EnumDevices ALL ---");
            g_di->lpVtbl->EnumDevices(g_di,DI8DEVCLASS_ALL,enumCB,0,DIEDFL_ATTACHEDONLY);
            wlog("--- EnumDevices GAMECTRL ---");
            g_di->lpVtbl->EnumDevices(g_di,DI8DEVCLASS_GAMECTRL,padCB,0,DIEDFL_ATTACHEDONLY);
            LPDIRECTINPUTDEVICE8A kbd=0,ms=0;
            g_di->lpVtbl->CreateDevice(g_di,&g_GUID_SysKeyboard,&kbd,0);
            g_di->lpVtbl->CreateDevice(g_di,&g_GUID_SysMouse,&ms,0);
            wlog("kbd=%p ms=%p",kbd,ms);
            if(kbd){void**vt=*(void***)kbd; wlog("kbd vtbl=%p GDS=%p GDD=%p",vt,vt[9],vt[10]);
                patch(vt,9,(void*)hkKbdGDS,(void**)&realKbdGDS); patch(vt,10,(void*)hkKbdGDD,(void**)&realKbdGDD);}
            if(ms){void**vt=*(void***)ms; wlog("ms  vtbl=%p GDS=%p GDD=%p",vt,vt[9],vt[10]);
                patch(vt,9,(void*)hkMsGDS,(void**)&realMsGDS); patch(vt,10,(void*)hkMsGDD,(void**)&realMsGDD);}
        }
    }
    int t=0;
    for(;;){
        LONG want=((t/20)%2)?1:0;
        if(want!=g_inject){InterlockedExchange(&g_inject,want);wlog("inject=%ld (t=%ds)",want,t/10);}
        if(t%50==0)wlog("counters kGDS=%ld kGDD=%ld mGDS=%ld mGDD=%ld",g_kGDS,g_kGDD,g_mGDS,g_mGDD);
        Sleep(100); t++;
    }
    return 0;
}

/* ---- LFX stub exports (void-arg ones are convention-safe; return success) ---- */
#define X __declspec(dllexport) int __stdcall
X LFX_Initialize(void){return 0;}
X LFX_Release(void){return 0;}
X LFX_Reset(void){return 0;}
X LFX_Update(void){return 0;}
X LFX_UpdateDefault(void){return 0;}
X LFX_GetNumDevices(unsigned*n){if(n)*n=0;return 0;}
X LFX_GetDeviceDescription(unsigned a,char*b,unsigned c,unsigned char*d){return 3;}
X LFX_GetNumLights(unsigned a,unsigned*n){if(n)*n=0;return 0;}
X LFX_GetLightDescription(unsigned a,unsigned b,char*c,unsigned d){return 4;}
X LFX_GetLightLocation(unsigned a,unsigned b,void*c){return 4;}
X LFX_GetLightColor(unsigned a,unsigned b,void*c){return 4;}
X LFX_SetLightColor(unsigned a,unsigned b,const void*c){return 0;}
X LFX_Light(unsigned a,unsigned b){return 0;}
X LFX_SetLightActionColor(unsigned a,unsigned b,unsigned c,const void*d){return 0;}
X LFX_SetLightActionColorEx(unsigned a,unsigned b,unsigned c,const void*d,const void*e){return 0;}
X LFX_ActionColor(unsigned a,unsigned b,unsigned c){return 0;}
X LFX_ActionColorEx(unsigned a,unsigned b,unsigned c,unsigned d){return 0;}
X LFX_SetTiming(int a){return 0;}
X LFX_GetVersion(char*b,unsigned c){return 0;}

/* freestanding DLL entry (default entry name; no CRT pulled) */
BOOL WINAPI DllMainCRTStartup(HINSTANCE h,DWORD reason,LPVOID r){
    if(reason==DLL_PROCESS_ATTACH){
        g_self=h;
        DisableThreadLibraryCalls(h);
        { HMODULE s=0; GetModuleHandleExA(4|2,(LPCSTR)&DllMainCRTStartup,&s); } /* PIN|FROM_ADDRESS */
        /* build log path: C:\GameDocuments\wxp_bridge.log */
        const char* base="C:\\GameDocuments\\wxp_bridge.log";
        memcpy(g_logpath,base,slen(base)+1);
        InitializeCriticalSection(&g_cs);
        wlog("DllMainCRTStartup ATTACH: LightFX.dll (freestanding) loaded OK");
        CreateThread(0,0,worker,0,0,0);
    }
    return TRUE;
}
