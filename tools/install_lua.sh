#!/bin/bash
# Compile the Lua layer and install it into the game's script directory.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
G="${WITCHER_DIR:-/Users/udinkirill/Documents/WitcherXinput/steamapps/common/The Witcher Enhanced Edition}"
for f in wxp_gamepad wxp_ui wxp_settings wxp_signwheel; do
  "$HERE/luac" -o "$G/System/Scripts/$f.luc" "$ROOT/mod/scripts/$f.lua"
  echo "installed $f.luc ($(stat -f%z "$G/System/Scripts/$f.luc") bytes)"
done
