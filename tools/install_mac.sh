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
. "$HERE/_log.sh"
GAME="$(wxp_game_or_die "${1:-}" "$0")"
wxp_log_open "$GAME" "install_mac.sh"
say "== игра: $GAME =="

APP="$GAME/The Witcher.app"
BIN="$APP/Contents/MacOS/The Witcher"
ROOT="$(dirname "$HERE")"
DYLIB="$ROOT/bridge/macos/wxp_bridge.dylib"
BACKUP="$GAME/WitcherPadBridge/backup"
WRITEDIR="$HOME/Library/Application Support/com.cdprojektred.TheWitcher"
LOADPATH="@executable_path/wxp_bridge.dylib"

[ -x "$BIN" ]    || die "no game binary at $BIN"
[ -f "$DYLIB" ]  || die "no bridge at $DYLIB -- build it first"

mkdir -p "$BACKUP"
if [ ! -f "$BACKUP/The Witcher.bin" ]; then
  say "== backing up the original executable =="
  cp "$BIN" "$BACKUP/The Witcher.bin"
fi

say "== installing the bridge into the bundle =="
cp "$DYLIB" "$APP/Contents/MacOS/wxp_bridge.dylib"
codesign -f -s - "$APP/Contents/MacOS/wxp_bridge.dylib"

say "== naming it in the executable's load commands =="
# Start from the pristine copy so repeated installs never stack duplicate entries.
cp "$BACKUP/The Witcher.bin" "$BIN"
python3 "$HERE/inject_loadcmd.py" add "$BIN" "$LOADPATH"

say "== re-signing the bundle =="
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

say "== walk speed table =="
# The game has no walk key and startup.lua turns always-run on, so the walk rate in the stock

say "== installing the Lua layer =="
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
    say "   compiled $(basename "$src" .lua).luc"
  done
else
  for f in "$ROOT"/mod/scripts/*.luc; do
    [ -f "$f" ] || { say "   no scripts in mod/scripts -- run tools/package.sh"; break; }
    cp "$f" "$SCRIPTS/"
  done
fi

mkdir -p "$WRITEDIR"
if [ ! -f "$WRITEDIR/gamepad.ini" ]; then
  say "== writing default gamepad.ini =="
  cp "$ROOT/mod/gamepad.ini" "$WRITEDIR/gamepad.ini"
fi

# What ended up on disk, with sizes: this is what tells a stale copy from a fresh one.
wxp_log_files "$APP/Contents/MacOS/wxp_bridge.dylib" "$BIN" \
              "$SCRIPTS/debug.luc" "$SCRIPTS/wxp_gamepad.luc" "$SCRIPTS/wxp_ui.luc" \
              "$SCRIPTS/wxp_combat.luc" "$SCRIPTS/wxp_settings.luc" "$SCRIPTS/wxp_signwheel.luc" \
              "$SCRIPTS/wxp_rumble.luc" \
              "$WRITEDIR/gamepad.ini"
note "codesign: $(codesign -dv "$APP" 2>&1 | tr '\n' ' ')"
wxp_log_done

echo
echo "Installed. Launch the game normally (Steam or the app icon)."
echo "Settings: $WRITEDIR/gamepad.ini"
echo "Logs: /tmp/wxp_bridge.log (bridge), $GAME/System/wxp_gamepad.log (Lua),"
echo "      $GAME/WitcherPadBridge/install.log (this install)."
echo "Collect everything for a bug report: tools/diagnose.sh"
echo "Note: Steam's 'Verify integrity of game files' undoes this -- rerun the installer after it."
