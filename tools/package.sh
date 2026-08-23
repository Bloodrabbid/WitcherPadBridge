#!/bin/bash
# Assemble a distributable WitcherPadBridge archive: both platforms, installers, docs.
#
#   tools/package.sh [version]
#
# Everything that ships is built from this tree, never copied out of a local game install --
# shipping yesterday's bytecode is a trap worth closing here rather than remembering every time.
#
# CI splits the work across runners, so two pieces can be supplied prebuilt:
#   WXP_DYLIB=/path/wxp_bridge.dylib   skip the macOS build (needs clang + codesign)
#   WXP_DLL=/path/LightFX.dll          skip the Windows build (needs i686-w64-mingw32-gcc)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
VER="${1:-${WXP_VERSION:-dev}}"
OUT="$ROOT/dist/WitcherPadBridge-$VER"

rm -rf "$OUT"
mkdir -p "$OUT"/{bridge/macos,bridge/windows,mod/scripts,tools}

# ---------------------------------------------------------------- the Lua compiler
# Lua 5.0.3 patched to the dump format this build of the engine reads (4-byte size_t and
# lengths). The patched sources are in the tree, so build rather than trust a stale binary.
LUAC="$HERE/luac"
if [ ! -x "$LUAC" ] || [ "$HERE/lua-5.0.3/src/ldump.c" -nt "$LUAC" ]; then
  echo "== building luac (patched Lua 5.0.3) =="
  ( cd "$HERE/lua-5.0.3" && make -s >/dev/null 2>&1 )
  cp "$HERE/lua-5.0.3/bin/luac" "$LUAC"
  cp "$HERE/lua-5.0.3/bin/lua"  "$HERE/lua"
fi

# ---------------------------------------------------------------- binaries
echo "== building =="
if [ -n "${WXP_DYLIB:-}" ]; then
  cp "$WXP_DYLIB" "$ROOT/bridge/macos/wxp_bridge.dylib"
  echo "   macOS bridge: taken from $WXP_DYLIB"
else
  # arm64e is worth having (eON's own binary carries that slice) but not every toolchain will
  # emit it, so fall back rather than fail the build over a slice nothing strictly needs.
  ARCHS="-arch arm64 -arch arm64e -arch x86_64"
  ( cd "$ROOT/bridge/macos" && clang -dynamiclib $ARCHS -O2 -fobjc-arc -DWXP_VERSION="\"$VER\"" \
      -framework Foundation -framework GameController -framework CoreGraphics -framework AppKit \
      -framework CoreHaptics \
      -o wxp_bridge.dylib wxp_bridge.m 2>/dev/null ) || {
    echo "   (no arm64e from this toolchain, building arm64 + x86_64)"
    ARCHS="-arch arm64 -arch x86_64"
    ( cd "$ROOT/bridge/macos" && clang -dynamiclib $ARCHS -O2 -fobjc-arc -DWXP_VERSION="\"$VER\"" \
        -framework Foundation -framework GameController -framework CoreGraphics -framework AppKit \
      -framework CoreHaptics \
        -o wxp_bridge.dylib wxp_bridge.m )
  }
  codesign -f -s - "$ROOT/bridge/macos/wxp_bridge.dylib"
  echo "   macOS bridge: built"
fi
if [ -n "${WXP_DLL:-}" ]; then
  cp "$WXP_DLL" "$ROOT/bridge/windows/LightFX.dll"
  echo "   Windows bridge: taken from $WXP_DLL"
else
  WXP_VERSION="$VER" "$ROOT/bridge/windows/build.sh" >/dev/null
  echo "   Windows bridge: built"
fi

# ---------------------------------------------------------------- contents
echo "== collecting =="
cp "$ROOT/bridge/macos/wxp_bridge.dylib"  "$OUT/bridge/macos/"
cp "$ROOT/bridge/windows/LightFX.dll"     "$OUT/bridge/windows/"
cp "$ROOT/mod/gamepad.ini"                "$OUT/mod/"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
for src in "$ROOT"/mod/scripts/*.lua; do
  [ -f "$src" ] || continue
  m="$(basename "$src" .lua)"
  # Stamp the version into the source before compiling, so a log file mailed in from another
  # machine says which build wrote it. The placeholder is a plain assignment in wxp_gamepad.lua.
  sed 's|^local VERSION = "dev"|local VERSION = "'"$VER"'"|' "$src" > "$STAGE/$m.lua"
  "$LUAC" -o "$OUT/mod/scripts/$m.luc" "$STAGE/$m.lua" || { echo "   FAILED to compile $m.lua"; exit 1; }
  echo "   compiled $m.luc"
done
cp "$ROOT/README.md"                      "$OUT/"
for f in _game_mac.sh _log.sh _log.ps1 install_mac.sh uninstall_mac.sh inject_loadcmd.py \
         install_win.sh uninstall_win.sh \
         install_windows.ps1 uninstall_windows.ps1 install_windows.bat uninstall_windows.bat \
         diagnose.sh diagnose.ps1 diagnose.bat; do
  cp "$HERE/$f" "$OUT/tools/"
done
chmod +x "$OUT"/tools/*.sh
# The installers and the diagnostics collector all stamp this into their logs, so a file mailed
# in from another machine says which build wrote it.
echo "$VER" > "$OUT/VERSION"

# ---------------------------------------------------------------- checks
# The engine only accepts one dump layout, and a wrong luac produces files it silently refuses to
# load. Assert the header rather than find out on someone else's machine.
echo "== checking =="
WANT="1b4c75615001040404060809 0908"
WANT="${WANT// /}"
for f in "$OUT"/mod/scripts/*.luc; do
  GOT="$(xxd -p -l 14 "$f" | tr -d '\n')"
  [ "$GOT" = "$WANT" ] || { echo "   BAD HEADER in $(basename "$f"): $GOT != $WANT"; exit 1; }
done
echo "   .luc header ok ($WANT)"
file "$OUT/bridge/windows/LightFX.dll" | grep -q "PE32 " \
  || { echo "   LightFX.dll is not a 32-bit PE"; exit 1; }
echo "   LightFX.dll is PE32"
for arch in x86_64 arm64; do
  lipo -info "$OUT/bridge/macos/wxp_bridge.dylib" | grep -q "$arch" \
    || { echo "   wxp_bridge.dylib has no $arch slice"; exit 1; }
done
echo "   wxp_bridge.dylib: $(lipo -info "$OUT/bridge/macos/wxp_bridge.dylib" | sed 's/.*are: //')"
for n in wxp_gamepad wxp_ui wxp_settings wxp_signwheel wxp_combat wxp_rumble debug; do
  [ -f "$OUT/mod/scripts/$n.luc" ] || { echo "   missing $n.luc"; exit 1; }
done
echo "   all scripts present"
# Nothing about a release is harder to chase than a log that does not say which build it came
# from, so prove the stamp landed rather than trusting the sed above.
grep -q "$VER" "$OUT/mod/scripts/wxp_gamepad.luc" \
  || { echo "   version $VER was not stamped into wxp_gamepad.luc"; exit 1; }
echo "   version stamp ok ($VER)"
for f in _log.sh _log.ps1 diagnose.sh diagnose.ps1 diagnose.bat VERSION; do
  [ -e "$OUT/tools/$f" ] || [ -e "$OUT/$f" ] || { echo "   missing $f"; exit 1; }
done
echo "   support scripts present"

( cd "$ROOT/dist" && zip -qr "WitcherPadBridge-$VER.zip" "WitcherPadBridge-$VER" )
( cd "$ROOT/dist" && shasum -a 256 "WitcherPadBridge-$VER.zip" > "WitcherPadBridge-$VER.zip.sha256" )
echo
echo "packaged $ROOT/dist/WitcherPadBridge-$VER.zip"
find "$OUT" -type f | sed "s|$OUT/|  |" | sort
