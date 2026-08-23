#!/bin/bash
# WitcherPadBridge -- macOS installer.
#
# Puts the bridge inside the app bundle and names it in the executable's load commands, so a
# normal Steam launch loads it. (Steam on macOS cannot pass DYLD_INSERT_LIBRARIES to a game --
# the VAR=val %command% syntax is Linux-only -- so an env-var scheme would need its own
# launcher, which is exactly what "just launch and play" rules out.)
#
# Everything it touches is backed up; uninstall_mac.sh puts it all back.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_game_mac.sh"
GAME="$(wxp_game_or_die "${1:-}" "$0")"
echo "== игра: $GAME =="

APP="$GAME/The Witcher.app"
BIN="$APP/Contents/MacOS/The Witcher"
ROOT="$(dirname "$HERE")"
DYLIB="$ROOT/bridge/macos/wxp_bridge.dylib"
BACKUP="$GAME/WitcherPadBridge/backup"
WRITEDIR="$HOME/Library/Application Support/com.cdprojektred.TheWitcher"
LOADPATH="@executable_path/wxp_bridge.dylib"

[ -x "$BIN" ]    || { echo "no game binary at $BIN"; exit 1; }
[ -f "$DYLIB" ]  || { echo "no bridge at $DYLIB -- build it first"; exit 1; }

mkdir -p "$BACKUP"
if [ ! -f "$BACKUP/The Witcher.bin" ]; then
  echo "== backing up the original executable =="
  cp "$BIN" "$BACKUP/The Witcher.bin"
fi

echo "== installing the bridge into the bundle =="
cp "$DYLIB" "$APP/Contents/MacOS/wxp_bridge.dylib"
codesign -f -s - "$APP/Contents/MacOS/wxp_bridge.dylib"

echo "== naming it in the executable's load commands =="
# Start from the pristine copy so repeated installs never stack duplicate entries.
cp "$BACKUP/The Witcher.bin" "$BIN"
python3 "$HERE/inject_loadcmd.py" add "$BIN" "$LOADPATH"

echo "== re-signing the bundle =="
# The stock signature is Developer ID + hardened runtime with only allow-jit, which refuses to
# load an ad-hoc signed library. Ad-hoc re-signing with library validation off is what makes the
# bridge loadable; allow-jit stays because eON translates x86 at runtime.
ENT="$(mktemp -t wxp_ent).plist"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$ENT" --timestamp=none "$APP"
rm -f "$ENT"

echo "== installing the Lua layer =="
# debug.luc is a shipped file and our only entry point: it is the one script the engine loads
# unconditionally, before the GUI exists. Back up the stock copy before replacing it.
SCRIPTS="$GAME/System/Scripts"
if [ -f "$SCRIPTS/debug.luc" ] && [ ! -f "$BACKUP/debug.luc" ]; then
  cp "$SCRIPTS/debug.luc" "$BACKUP/debug.luc"
fi
# In a release package mod/scripts holds prebuilt .luc. In the source tree it holds .lua next to
# a stale .luc, so compile instead of copying -- installing yesterday's bytecode over a freshly
# edited script is a trap worth closing here rather than remembering every time.
if [ -x "$HERE/luac" ] && ls "$ROOT"/mod/scripts/*.lua >/dev/null 2>&1; then
  for src in "$ROOT"/mod/scripts/*.lua; do
    "$HERE/luac" -o "$SCRIPTS/$(basename "$src" .lua).luc" "$src"
    echo "   compiled $(basename "$src" .lua).luc"
  done
else
  for f in "$ROOT"/mod/scripts/*.luc; do
    [ -f "$f" ] || { echo "   no scripts in mod/scripts -- run tools/package.sh"; break; }
    cp "$f" "$SCRIPTS/"
  done
fi

mkdir -p "$WRITEDIR"
if [ ! -f "$WRITEDIR/gamepad.ini" ]; then
  echo "== writing default gamepad.ini =="
  cp "$ROOT/mod/gamepad.ini" "$WRITEDIR/gamepad.ini"
fi

echo
echo "Installed. Launch the game normally (Steam or the app icon)."
echo "Settings: $WRITEDIR/gamepad.ini   Log: /tmp/wxp_bridge.log"
echo "Note: Steam's 'Verify integrity of game files' undoes this -- rerun the installer after it."
