#!/bin/bash
# Clear logs and launch the game directly (bypasses Steam so we control it)
WD="$HOME/Library/Application Support/com.cdprojektred.TheWitcher"
APP="/Users/udinkirill/Documents/WitcherXinput/steamapps/common/The Witcher Enhanced Edition/The Witcher.app"
rm -f "$WD/GameDocuments/wxp_bridge.log" "$WD/DataChanges/System/wxp_bridge.log" \
      "$WD/DataChanges/System/lightfx/wxp/wxp_bridge.log" "$WD/wxp_bridge.log" 2>/dev/null
echo "launching $APP ..."
open "$APP"
