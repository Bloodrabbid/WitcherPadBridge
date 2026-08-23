#!/bin/bash
# Build the Windows/Proton bridge. One 32-bit DLL; the game is a 32-bit PE.
set -e
CC=${CC:-i686-w64-mingw32-gcc}
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/LightFX.dll}"
VER="${WXP_VERSION:-dev}"
# -Wall -Wextra on by default: this DLL runs on machines nobody here can attach a debugger to,
# so anything the compiler can catch has to be caught before it ships.
$CC -O2 -Wall -Wextra -shared -municode -DWXP_VERSION="\"$VER\"" \
    -o "$OUT" "$HERE/wxp_bridge_win.c" "$HERE/lightfx.def" \
    -luser32 -lkernel32 -Wl,--kill-at -Wl,--enable-stdcall-fixup -static-libgcc
echo "built $OUT"
i686-w64-mingw32-objdump -p "$OUT" | grep -E "^\s+DLL Name:"
