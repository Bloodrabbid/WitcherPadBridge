#!/bin/bash
# WitcherPadBridge -- macOS uninstaller. Restores the stock executable and signature.
set -e
GAME="${1:-/Users/udinkirill/Documents/WitcherXinput/steamapps/common/The Witcher Enhanced Edition}"
APP="$GAME/The Witcher.app"
BIN="$APP/Contents/MacOS/The Witcher"
BACKUP="$GAME/WitcherPadBridge/backup"

if [ -f "$BACKUP/The Witcher.bin" ]; then
  echo "== restoring the original executable =="
  cp "$BACKUP/The Witcher.bin" "$BIN"
else
  echo "== no backup; stripping our load command instead =="
  python3 "$(dirname "$0")/inject_loadcmd.py" remove "$BIN" "@executable_path/wxp_bridge.dylib"
fi
rm -f "$APP/Contents/MacOS/wxp_bridge.dylib"

echo "== removing the Lua layer =="
SCRIPTS="$GAME/System/Scripts"
rm -f "$SCRIPTS/wxp_gamepad.luc" "$SCRIPTS/wxp_ui.luc"
if [ -f "$BACKUP/debug.luc" ]; then
  cp "$BACKUP/debug.luc" "$SCRIPTS/debug.luc"
else
  echo "   no debug.luc backup -- use Steam's verify to restore it"
fi

echo "== re-signing =="
# Still ad-hoc: the Developer ID signature cannot be recreated here. For a byte-exact stock
# bundle use Steam > Properties > Installed Files > Verify integrity of game files.
codesign --force --sign - --options runtime --timestamp=none "$APP" || true
echo
echo "Removed. For a fully stock install run Steam's 'Verify integrity of game files'."
