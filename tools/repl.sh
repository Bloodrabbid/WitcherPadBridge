#!/bin/bash
# Send a Lua chunk into the running game and print what it logged.
G="/Users/udinkirill/Documents/WitcherXinput/steamapps/common/The Witcher Enhanced Edition"
LOG="$G/System/wxp_gamepad.log"
MARK="### $$ $(date +%s%N)"
printf 'wxp_log("%s")\n' "$MARK" > /tmp/wxp_chunk.lua
if [ -n "$1" ] && [ -f "$1" ]; then cat "$1" >> /tmp/wxp_chunk.lua; else cat >> /tmp/wxp_chunk.lua; fi
cp /tmp/wxp_chunk.lua "$G/System/wxp_cmd.txt"
for i in $(seq 1 40); do
  sleep 0.3
  if [ ! -f "$G/System/wxp_cmd.txt" ]; then break; fi
done
sleep 1.2
awk -v m="$MARK" 'index($0,m){f=1} f' "$LOG" | grep -v "^wxp_log(\"###"
