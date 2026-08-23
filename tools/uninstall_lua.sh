#!/bin/bash
# Reverts the two Lua-side changes: restores the shipped debug.luc and drops our script.
set -e
G="/Users/udinkirill/Documents/WitcherXinput/steamapps/common/The Witcher Enhanced Edition"
B="$G/WitcherPadBridge/backup"
[ -f "$B/debug.luc" ] && cp "$B/debug.luc" "$G/System/Scripts/debug.luc" && echo "debug.luc restored"
rm -f "$G/System/Scripts/wxp_gamepad.luc" && echo "wxp_gamepad.luc removed"
rm -f "$G/System/wxp_gamepad.log"
# restore intro movies if they were parked for headless testing
for f in "$G/Data/Movies"/*.wxp-off; do
  [ -f "$f" ] && mv "$f" "${f%.wxp-off}" && echo "restored $(basename "${f%.wxp-off}")"
done
