#!/bin/bash
# Assemble a distributable WitcherPadBridge archive: both platforms, installers, docs.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
VER="${1:-0.4}"
OUT="$ROOT/dist/WitcherPadBridge-$VER"

rm -rf "$OUT"
mkdir -p "$OUT"/{bridge/macos,bridge/windows,mod/scripts,tools}

echo "== building =="
( cd "$ROOT/bridge/macos" && clang -dynamiclib -arch arm64 -arch arm64e -arch x86_64 -O2 -fobjc-arc \
    -framework Foundation -framework GameController -framework CoreGraphics -framework AppKit \
    -o wxp_bridge.dylib wxp_bridge.m && codesign -f -s - wxp_bridge.dylib )
"$ROOT/bridge/windows/build.sh" >/dev/null

echo "== collecting =="
cp "$ROOT/bridge/macos/wxp_bridge.dylib"  "$OUT/bridge/macos/"
cp "$ROOT/bridge/windows/LightFX.dll"     "$OUT/bridge/windows/"
cp "$ROOT/mod/gamepad.ini"                "$OUT/mod/"
# Compile the Lua layer straight into the package, so what ships is built from the sources in
# this tree rather than whatever happens to sit in a local game install.
for src in "$ROOT"/mod/scripts/*.lua; do
  [ -f "$src" ] || continue
  m="$(basename "$src" .lua)"
  "$HERE/luac" -o "$OUT/mod/scripts/$m.luc" "$src" || { echo "   FAILED to compile $m.lua"; exit 1; }
  echo "   compiled $m.luc"
done
cp "$ROOT/README.md"                      "$OUT/"
for f in install_mac.sh uninstall_mac.sh inject_loadcmd.py; do cp "$HERE/$f" "$OUT/tools/"; done

( cd "$ROOT/dist" && zip -qr "WitcherPadBridge-$VER.zip" "WitcherPadBridge-$VER" )
echo
echo "packaged $ROOT/dist/WitcherPadBridge-$VER.zip"
find "$OUT" -type f | sed "s|$OUT/|  |"
