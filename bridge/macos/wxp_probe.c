/* WitcherPadBridge — macOS probe dylib (Phase 0 verification, zero-hook design).
 * Injected via DYLD_INSERT_LIBRARIES into The Witcher.app (eON runtime).
 *
 * Proves, in ONE launch:
 *   - dylib loads inside the game process
 *   - eON's local symbols resolve at runtime (LC_SYMTAB + ASLR slide)
 *   - gRawInputKeyboard -> receiver -> device(+0x10) -> key state(+0xC0) is reachable
 *   - injecting input actually moves Geralt / pans the camera:
 *       method A: write the DIK byte directly into device+0xC0
 *       method B: call eON's own KeyboardEventReceiver::ProcessKeyDown/Up
 *     (alternates every few seconds so we can see which works)
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <pthread.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#define LOGPATH "/tmp/wxp_bridge.log"
static FILE* g_log;
static void L(const char* fmt, ...) {
    if (!g_log) { g_log = fopen(LOGPATH, "a"); if (!g_log) return; }
    va_list ap; va_start(ap, fmt);
    vfprintf(g_log, fmt, ap); va_end(ap);
    fputc('\n', g_log); fflush(g_log);
}

/* ---- resolve LOCAL symbols of the main executable via LC_SYMTAB ---- */
static const struct mach_header_64* g_mh;
static intptr_t g_slide;
static struct nlist_64* g_syms; static uint32_t g_nsyms; static char* g_strs;

static int symtab_init(void) {
    /* find the main executable image */
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header_64* mh = (const struct mach_header_64*)_dyld_get_image_header(i);
        if (mh && mh->filetype == MH_EXECUTE) { g_mh = mh; g_slide = _dyld_get_image_vmaddr_slide(i);
            L("main image #%u '%s' mh=%p slide=0x%lx", i, _dyld_get_image_name(i), mh, (long)g_slide); break; }
    }
    if (!g_mh) { L("no MH_EXECUTE image found"); return 0; }

    const struct load_command* lc = (const struct load_command*)((uint8_t*)g_mh + sizeof(*g_mh));
    const struct symtab_command* st = NULL;
    uint64_t le_vmaddr = 0, le_fileoff = 0;
    for (uint32_t i = 0; i < g_mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) st = (const struct symtab_command*)lc;
        else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* sc = (const struct segment_command_64*)lc;
            if (!strcmp(sc->segname, "__LINKEDIT")) { le_vmaddr = sc->vmaddr; le_fileoff = sc->fileoff; }
        }
        lc = (const struct load_command*)((uint8_t*)lc + lc->cmdsize);
    }
    if (!st || !le_vmaddr) { L("no LC_SYMTAB/__LINKEDIT"); return 0; }
    uint8_t* base = (uint8_t*)(uintptr_t)(le_vmaddr + g_slide - le_fileoff);
    g_syms = (struct nlist_64*)(base + st->symoff);
    g_strs = (char*)(base + st->stroff);
    g_nsyms = st->nsyms;
    L("symtab: %u symbols", g_nsyms);
    return 1;
}

static void* sym(const char* name) {
    for (uint32_t i = 0; i < g_nsyms; i++) {
        uint32_t sx = g_syms[i].n_un.n_strx;
        if (!sx) continue;
        const char* s = g_strs + sx;
        if (!strcmp(s, name)) {
            void* p = (void*)(uintptr_t)(g_syms[i].n_value + g_slide);
            L("  sym %-60s = %p", name, p);
            return p;
        }
    }
    L("  sym %-60s = NOT FOUND", name);
    return NULL;
}

/* eON entry points we use */
typedef void (*ProcessKey_t)(void* self, unsigned int a, unsigned short keycode);
static ProcessKey_t p_KeyDown, p_KeyUp;
static void** pp_kbd;      /* &gRawInputKeyboard */
static void** pp_mouse;    /* &gRawInputMouse    */

#define KBD_DEVICE_OFF   0x10   /* receiver + 0x10 -> DirectInputKeyboardDeviceImp */
#define KBD_STATE_OFF    0xC0   /* device   + 0xC0 -> 256-byte DIK state           */
#define DIK_W 0x11

#define MACKEY_W 13             /* macOS kVK_ANSI_W */

static void* worker(void* arg) {
    (void)arg;
    sleep(8);                      /* let eON create its input devices */
    L("=== WitcherPadBridge probe (macOS dylib) ===");
    if (!symtab_init()) return NULL;

    pp_kbd    = (void**)sym("_gKeyboardEventReceiver");
    pp_mouse  = (void**)sym("_gMouseEventReceiver");
    if (!pp_kbd) pp_kbd = (void**)sym("__ZL17gRawInputKeyboard");
    p_KeyDown = (ProcessKey_t)sym("__ZN21KeyboardEventReceiver14ProcessKeyDownEjt");
    p_KeyUp   = (ProcessKey_t)sym("__ZN21KeyboardEventReceiver12ProcessKeyUpEjt");

    /* command channel: write "<dikhex> <ms>" into /tmp/wxp_cmd, e.g. "11 1500" = hold W 1.5s
       method: file "/tmp/wxp_method" containing A (raw state) or B (native call), default A */
    for (int tick = 0;; tick++) {
        void* recv = pp_kbd ? *pp_kbd : NULL;
        void* dev  = recv ? *(void**)((uint8_t*)recv + KBD_DEVICE_OFF) : NULL;
        uint8_t* state = dev ? (uint8_t*)dev + KBD_STATE_OFF : NULL;

        if (tick % 40 == 0)
            L("t=%3.1fs recv=%p dev=%p state=%p", tick * 0.25, recv, dev, state);

        FILE* f = fopen("/tmp/wxp_cmd", "r");
        if (f) {
            unsigned dik = 0, ms = 0;
            int got = fscanf(f, "%x %u", &dik, &ms);
            fclose(f); unlink("/tmp/wxp_cmd");
            char meth = 'A';
            FILE* mf = fopen("/tmp/wxp_method", "r");
            if (mf) { int c = fgetc(mf); if (c=='B'||c=='b') meth='B'; fclose(mf); }
            if (got == 2 && dik < 256) {
                L(">>> CMD: hold DIK 0x%02x for %ums via METHOD %c (recv=%p state=%p)",
                  dik, ms, meth, recv, state);
                if (meth == 'B' && recv && p_KeyDown && p_KeyUp) {
                    p_KeyDown(recv, 0, (unsigned short)dik);   /* NOTE: expects macOS keycode */
                    usleep(ms * 1000);
                    p_KeyUp(recv, 0, (unsigned short)dik);
                } else if (state) {
                    unsigned held = 0;
                    while (held < ms) {                        /* keep re-asserting: the pump may clear it */
                        state[dik] = 0x80;
                        usleep(15 * 1000); held += 15;
                        recv = pp_kbd ? *pp_kbd : NULL;
                        dev  = recv ? *(void**)((uint8_t*)recv + KBD_DEVICE_OFF) : NULL;
                        state = dev ? (uint8_t*)dev + KBD_STATE_OFF : NULL;
                        if (!state) break;
                    }
                    if (state) state[dik] = 0x00;
                }
                L("<<< CMD done");
            }
        }
        usleep(250 * 1000);
    }
    return NULL;
}

__attribute__((constructor))
static void wxp_init(void) {
    char exe[1024]; uint32_t sz = sizeof(exe); exe[0]=0;
    _NSGetExecutablePath(exe, &sz);
    L("---- dylib loaded: pid=%d exe='%s' ----", getpid(), exe);
    pthread_t t; pthread_create(&t, NULL, worker, NULL); pthread_detach(t);
}
