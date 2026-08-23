#!/bin/bash
set -e
CC=i686-w64-mingw32-gcc
OUT="${1:-LightFX.dll}"
$CC -O2 -shared -o "$OUT" dllmain.c \
    -ldinput8 -ldxguid -lole32 -luuid -luser32 -lgdi32 \
    -Wl,--kill-at -static-libgcc
echo "built $OUT"
i686-w64-mingw32-objdump -x "$OUT" 2>/dev/null | grep -A40 "Export Address Table" | head -45 || true
