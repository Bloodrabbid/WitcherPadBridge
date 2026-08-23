#!/bin/bash
# Run AFTER launching the game (via Steam), reaching the menu, and quitting.
# Prints a clear verdict on Phase-0 probes.
WD="$HOME/Library/Application Support/com.cdprojektred.TheWitcher"
EON="$WD/eon.txt"
say(){ printf "%s\n" "$*"; }
line(){ printf -- '----------------------------------------\n'; }

line; say "1) DID OUR DLL LOAD?"
if grep -q "couldn't load 'lightfx" "$EON" 2>/dev/null; then
  say "   ❌ NOT loaded — eON still reports: $(grep -m1 "couldn't load 'lightfx" "$EON")"
else
  say "   ✅ no 'couldn't load lightfx' warning (good sign)"
fi
# our bridge log
BL=""
for f in "$WD/GameDocuments/wxp_bridge.log" "$WD/DataChanges/System/wxp_bridge.log" "$WD/wxp_bridge.log" "$WD/AppDataLocal/wxp_bridge.log"; do
  [ -f "$f" ] && BL="$f" && break
done
if [ -n "$BL" ]; then
  say "   ✅ BRIDGE LOG FOUND: $BL"
  say "   --- our module path (canonical location) ---"
  grep -m1 "OUR MODULE PATH" "$BL" | sed 's/^/     /'
else
  say "   ⚠️  no bridge log yet (DLL DllMain didn't run, or wrote elsewhere)"
fi

line; say "2) DID DIRECTINPUT ENUMERATE THE DUALSENSE?"
if [ -n "$BL" ]; then
  grep -E "DI-DEVICE|PAD-PICK|CreateDevice|DirectInput8Create" "$BL" | sed 's/^/   /'
else
  say "   (needs bridge log)"
fi

line; say "3) DID THE VTABLE HOOKS FIRE (kbd/mouse GetDeviceState/Data)?"
if [ -n "$BL" ]; then
  grep -E "hookKbd|hookMs|counters:|vtbl=" "$BL" | tail -8 | sed 's/^/   /'
else
  say "   (needs bridge log)"
fi

line; say "4) PAD LIVE STATE (axes/buttons):"
if [ -n "$BL" ]; then grep -E "PAD state" "$BL" | tail -4 | sed 's/^/   /'; fi

line; say "5) SDLGamepad.config parsed?"
grep -E "AppendGameMappingsFromSDLGamepadConfigFile|Parsed .* mappings|Gamepads: setting up" "$EON" | sed 's/^/   /'

line; say "6) LFX status:"
cat "$WD/AppDataLocal/The Witcher/logs/lightfx.txt" 2>/dev/null | sed 's/^/   /'
line
