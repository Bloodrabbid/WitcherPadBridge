#!/bin/bash
# Ad-hoc re-sign The Witcher.app so DYLD_INSERT_LIBRARIES works.
# Keeps hardened runtime + allow-jit (eON needs JIT), adds injection entitlements.
set -e
APP="/Users/udinkirill/Documents/WitcherXinput/steamapps/common/The Witcher Enhanced Edition/The Witcher.app"
ENT=/tmp/wxp_entitlements.plist

echo "== current signature =="
codesign -dv "$APP" 2>&1 | grep -E "Authority|flags" | head -3 || true

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
PLIST
echo "</plist>" >> "$ENT"

echo "== re-signing ad-hoc (this replaces the Developer ID signature) =="
codesign --force --sign - --options runtime --entitlements "$ENT" --timestamp=none "$APP"

echo "== new signature =="
codesign -dv "$APP" 2>&1 | grep -E "Signature|flags" | head -3 || true
echo "== entitlements now =="
codesign -d --entitlements :- "$APP" 2>/dev/null | tr -d '\0' | grep -oE "com\.apple\.security\.cs\.[a-z-]+" || true
echo
echo "DONE. Restore anytime via Steam: Properties > Installed Files > Verify integrity."
