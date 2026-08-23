#!/bin/bash
# WitcherPadBridge -- collect everything needed to diagnose "не работает" into one folder.
#
#     tools/diagnose.sh ["/путь/к/игре"]
#
# Works on macOS and on Linux/Proton (Steam Deck, Bazzite, ROG Ally). On Windows use
# tools\diagnose.ps1 instead. Nothing here is uploaded anywhere -- it writes a folder and a
# .tar.gz next to itself and prints the path; look inside before sending it on. Save games and
# anything else personal are deliberately left out; the file paths do contain your user name.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
NAME="The Witcher Enhanced Edition"

is_game_win() { [ -f "$1/System/witcher.ini" ] || [ -f "$1/system/witcher.ini" ]; }
is_game_mac() { [ -x "$1/The Witcher.app/Contents/MacOS/The Witcher" ]; }
is_game()     { is_game_win "$1" || is_game_mac "$1"; }

# One finder for both platforms: the same release folder is handed to a Mac and to a Deck, and
# asking the user which one they are on would be one question too many.
find_game() {
  local c lib vdf
  local candidates=()
  for vdf in \
      "$HOME/Library/Application Support/Steam/steamapps/libraryfolders.vdf" \
      "$HOME/.steam/steam/steamapps/libraryfolders.vdf" \
      "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" \
      "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/libraryfolders.vdf" \
      "/c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"; do
    [ -f "$vdf" ] || continue
    while IFS= read -r lib; do
      [ -n "$lib" ] && candidates+=("$lib/steamapps/common/$NAME")
    done < <(sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf" | sed 's/\\\\/\//g')
  done
  candidates+=(
    "$HOME/Library/Application Support/Steam/steamapps/common/$NAME"
    "$HOME/.steam/steam/steamapps/common/$NAME"
    "$HOME/.local/share/Steam/steamapps/common/$NAME"
    "/run/media/mmcblk0p1/steamapps/common/$NAME"
    "/Applications/$NAME"
    "/c/Program Files (x86)/Steam/steamapps/common/$NAME"
    "/c/GOG Games/The Witcher Enhanced Edition"
  )
  for c in "${candidates[@]}"; do is_game "$c" && { echo "$c"; return 0; }; done
  return 1
}

GAME="${1:-}"
[ -n "$GAME" ] || GAME="$(find_game || true)"

STAMP="$(date '+%Y%m%d-%H%M%S')"
OUT="$ROOT/wxp-diag-$STAMP"
mkdir -p "$OUT/logs" "$OUT/config"
REPORT="$OUT/report.txt"

h()   { { echo; echo "=== $* ==="; } >> "$REPORT"; }
line(){ echo "$*" >> "$REPORT"; }
# Copy if it exists, and say either way -- an absent log is itself a finding.
grab() { # <dest subdir> <path...>
  local sub="$1"; shift
  local f base dest n
  for f in "$@"; do
    if [ -f "$f" ]; then
      # gamepad.ini exists in two places at once (game root and the macOS write dir) and which
      # one the bridge actually read is half the question, so neither may overwrite the other.
      base="$(basename "$f")"; dest="$OUT/$sub/$base"; n=2
      while [ -e "$dest" ]; do dest="$OUT/$sub/${base%.*}-$n.${base##*.}"; n=$((n + 1)); done
      cp "$f" "$dest" 2>/dev/null && line "  collected  $f  ($(wc -c < "$f" | tr -d ' ') bytes) -> $(basename "$dest")"
    else
      line "  absent     $f"
    fi
  done
}

{
  echo "WitcherPadBridge diagnostics"
  echo "generated $(date '+%Y-%m-%d %H:%M:%S')"
} > "$REPORT"

h "package"
line "package folder: $ROOT"
line "version: $([ -f "$ROOT/VERSION" ] && cat "$ROOT/VERSION" || echo 'unknown (source tree?)')"
for f in "$ROOT/bridge/macos/wxp_bridge.dylib" "$ROOT/bridge/windows/LightFX.dll"; do
  if [ -f "$f" ]; then
    line "  $(wc -c < "$f" | tr -d ' ') bytes  $f"
  fi
done

h "host"
line "uname: $(uname -a 2>/dev/null)"
[ "$(uname -s)" = "Darwin" ] && line "macOS: $(sw_vers -productVersion 2>/dev/null)"
[ -f /etc/os-release ] && line "distro: $(. /etc/os-release; echo "$PRETTY_NAME")"
line "shell: $BASH_VERSION"

h "game"
if [ -z "$GAME" ]; then
  line "NOT FOUND. Rerun as: $0 \"/путь/к/$NAME\""
else
  line "folder: $GAME"
  SYS="$GAME/System"; [ -d "$SYS" ] || SYS="$GAME/system"
  SCRIPTS="$SYS/Scripts"; [ -d "$SCRIPTS" ] || SCRIPTS="$SYS/scripts"
  line "system:  $SYS"
  line "scripts: $SCRIPTS"
  # Writable or not decides whether the pad can talk to the script layer at all.
  if touch "$SYS/wxp_diag_probe.tmp" 2>/dev/null; then
    rm -f "$SYS/wxp_diag_probe.tmp"; line "System writable: yes"
  else
    line "System writable: NO  <-- the channels live there; nothing will work"
  fi

  h "installed files"
  line " -- the bridge --"
  for f in "$SYS/lightfx/wxp/LightFX.dll" "$GAME/The Witcher.app/Contents/MacOS/wxp_bridge.dylib"; do
    if [ -f "$f" ]; then line "  $(wc -c < "$f" | tr -d ' ') bytes  $f"; else line "  absent  $f"; fi
  done
  line " -- the script layer --"
  for n in debug wxp_gamepad wxp_ui wxp_combat wxp_settings wxp_signwheel; do
    f="$SCRIPTS/$n.luc"
    if [ -f "$f" ]; then line "  $(wc -c < "$f" | tr -d ' ') bytes  $f"; else line "  MISSING  $f"; fi
  done
  # debug.luc is the entry point: without our line in it nothing Lua-side ever runs.
  if [ -f "$SCRIPTS/debug.luc" ]; then
    if strings "$SCRIPTS/debug.luc" 2>/dev/null | grep -q wxp_gamepad; then
      line "  debug.luc calls wxp_gamepad: yes"
    else
      line "  debug.luc calls wxp_gamepad: NO  <-- Steam verify probably restored it; rerun the installer"
    fi
  fi
  if [ -x "$GAME/The Witcher.app/Contents/MacOS/The Witcher" ]; then
    if otool -l "$GAME/The Witcher.app/Contents/MacOS/The Witcher" 2>/dev/null | grep -q wxp_bridge.dylib; then
      line "  load command present: yes"
    else
      line "  load command present: NO  <-- rerun tools/install_mac.sh"
    fi
    line "  signature: $(codesign -dv "$GAME/The Witcher.app" 2>&1 | tr '\n' ' ')"
  fi

  h "logs"
  grab logs "$SYS/wxp_bridge.log" "$SYS/wxp_bridge.log.1" \
            "$SYS/wxp_gamepad.log" "$SYS/wxp_gamepad.log.1" \
            "$GAME/WitcherPadBridge/install.log"
  grab logs /tmp/wxp_bridge.log /tmp/wxp_bridge.log.1

  h "config and channels"
  grab config "$GAME/gamepad.ini" "$SYS/wxp_config.ini" \
              "$SYS/wxp_state.ini" "$SYS/wxp_nav.txt" "$SYS/wxp_aim.txt"
fi

if [ "$(uname -s)" = "Darwin" ]; then
  WD="$HOME/Library/Application Support/com.cdprojektred.TheWitcher"
  h "macOS write dir"
  line "$WD"
  grab config "$WD/gamepad.ini"
  # eON's own logs say whether the wrapper even got as far as our library.
  grab logs "$WD/eon.txt" "$WD/lightfx.txt"
  h "controllers"
  # Deliberately not system_profiler: it takes tens of seconds and this has to stay quick.
  ioreg -c IOHIDDevice -r -d 1 2>/dev/null | grep -E '"Product"|"Manufacturer"' | head -30 >> "$REPORT" || true
else
  h "controllers"
  ls -l /dev/input/by-id 2>/dev/null | head -30 >> "$REPORT" || line "(no /dev/input/by-id)"
  command -v lsusb >/dev/null && lsusb 2>/dev/null | head -30 >> "$REPORT"
  h "proton"
  line "STEAM_COMPAT_DATA_PATH=${STEAM_COMPAT_DATA_PATH:-(unset)}"
fi

h "running processes"
# Anchored on the real names: a bare "witcher" also matches every *Switcher* on the machine.
ps ax 2>/dev/null | grep -E "MacOS/The Witcher|[wW]itcher\.exe|witcher\.vpfs" | grep -v grep \
  >> "$REPORT" || line "(the game is not running)"

( cd "$ROOT" && tar czf "wxp-diag-$STAMP.tar.gz" "wxp-diag-$STAMP" ) 2>/dev/null

echo
echo "Собрано: $OUT"
echo "Архив:   $ROOT/wxp-diag-$STAMP.tar.gz"
echo
echo "Загляните в report.txt перед отправкой — там пути с вашим именем пользователя."
