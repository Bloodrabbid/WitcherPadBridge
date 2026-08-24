#!/bin/bash
# WitcherPadBridge -- macOS uninstaller. Restores the stock executable and signature.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_game_mac.sh"
. "$HERE/_log.sh"
GAME="$(wxp_game_or_die "${1:-}" "$0")"
wxp_log_open "$GAME" "uninstall_mac.sh"
say "== игра: $GAME =="
APP="$GAME/The Witcher.app"
BIN="$APP/Contents/MacOS/The Witcher"
BACKUP="$GAME/WitcherPadBridge/backup"

if [ -f "$BACKUP/The Witcher.bin" ]; then
  say "== restoring the original executable =="
  cp "$BACKUP/The Witcher.bin" "$BIN"
else
  say "== no backup; stripping our load command instead =="
  python3 "$HERE/inject_loadcmd.py" remove "$BIN" "@executable_path/wxp_bridge.dylib"
fi
rm -f "$APP/Contents/MacOS/wxp_bridge.dylib"

say "== removing the walk speed table =="
rm -f "$GAME/Data/2DA/CreatureSpeed.2da"
rmdir "$GAME/Data/2DA" 2>/dev/null || true

say "== removing the Lua layer =="
SCRIPTS="$GAME/System/Scripts"
rm -f "$SCRIPTS"/wxp_*.luc
if [ -f "$BACKUP/debug.luc" ]; then
  cp "$BACKUP/debug.luc" "$SCRIPTS/debug.luc"
else
  say "   no debug.luc backup -- use Steam's verify to restore it"
fi

say "== re-signing =="
# Still ad-hoc: the Developer ID signature cannot be recreated here. For a byte-exact stock
# bundle use Steam > Properties > Installed Files > Verify integrity of game files.
codesign --force --sign - --options runtime --timestamp=none "$APP" || true
wxp_log_done
echo
echo "Removed. For a fully stock install run Steam's 'Verify integrity of game files'."
