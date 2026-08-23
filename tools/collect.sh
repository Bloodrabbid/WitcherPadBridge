#!/bin/bash
# Dump everything relevant after a game run
WD="$HOME/Library/Application Support/com.cdprojektred.TheWitcher"
echo "########## bridge log candidates ##########"
for f in "$WD/GameDocuments/wxp_bridge.log" "$WD/DataChanges/System/wxp_bridge.log" "$WD/DataChanges/System/lightfx/wxp/wxp_bridge.log" "$WD/wxp_bridge.log"; do
  if [ -f "$f" ]; then echo "===== $f ====="; cat "$f"; fi
done
echo ""
echo "########## eon.txt: lightfx / DLL LOADING / gamepad ##########"
grep -niE "lightfx|LFX|gamepad|joystick|controller|DirectInput|Gamepads:" "$WD/eon.txt" 2>/dev/null | head -60
echo ""
echo "########## lightfx.txt ##########"
cat "$WD/AppDataLocal/The Witcher/logs/lightfx.txt" 2>/dev/null
