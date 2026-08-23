#!/bin/bash
# Launch the game with the bridge, for development.
# SteamAppId/SteamGameId stop steam_api from bouncing the process through Steam (that bounce is
# what dropped the injection before). If install_mac.sh has already put the bridge in the
# bundle's load commands, DYLD_INSERT would load a second copy -- so it is skipped.
GAME="${1:-/Users/udinkirill/Documents/WitcherXinput/steamapps/common/The Witcher Enhanced Edition}"
APP="$GAME/The Witcher.app"
BIN="$APP/Contents/MacOS/The Witcher"
DYLIB="/Users/udinkirill/Documents/WitcherXinput/WitcherPadBridge/bridge/macos/wxp_bridge.dylib"
rm -f /tmp/wxp_bridge.log
cd "$GAME"
export SteamAppId=20900
export SteamGameId=20900
if otool -l "$BIN" | grep -q "wxp_bridge.dylib"; then
  echo "bridge is installed in the bundle; launching without DYLD_INSERT"
else
  export DYLD_INSERT_LIBRARIES="$DYLIB"
fi
"$BIN" >/tmp/wxp_game_stdout.txt 2>&1 &
echo "launched pid $!  (log: /tmp/wxp_bridge.log)"
