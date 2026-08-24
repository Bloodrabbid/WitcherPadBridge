#!/bin/bash
# WitcherPadBridge -- remove the mod from the Windows build of the game.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="The Witcher Enhanced Edition"
. "$HERE/_log.sh"
is_game() { [ -f "$1/System/witcher.ini" ] || [ -f "$1/system/witcher.ini" ]; }

GAME="${1:-}"
if [ -z "$GAME" ]; then
  for c in \
      "$HOME/.steam/steam/steamapps/common/$NAME" \
      "$HOME/.local/share/Steam/steamapps/common/$NAME" \
      "/run/media/mmcblk0p1/steamapps/common/$NAME" \
      "/c/Program Files (x86)/Steam/steamapps/common/$NAME" \
      "/c/GOG Games/The Witcher Enhanced Edition"; do
    is_game "$c" && { GAME="$c"; break; }
  done
fi
[ -n "$GAME" ] && is_game "$GAME" || {
  echo "Укажите папку игры: $0 \"/путь/к/$NAME\"" >&2; exit 1; }
wxp_log_open "$GAME" "uninstall_win.sh"
say "== игра: $GAME =="

SYS="$GAME/System"; [ -d "$SYS" ] || SYS="$GAME/system"
SCRIPTS="$SYS/Scripts"; [ -d "$SCRIPTS" ] || SCRIPTS="$SYS/scripts"
BACKUP="$GAME/WitcherPadBridge/backup"

say "== мост =="
rm -f "$SYS/lightfx/wxp/LightFX.dll"
rmdir "$SYS/lightfx/wxp" "$SYS/lightfx" 2>/dev/null || true

say "== таблица скорости шага =="
rm -f "$GAME/Data/2DA/CreatureSpeed.2da"
rmdir "$GAME/Data/2DA" 2>/dev/null || true

say "== Lua-слой =="
rm -f "$SCRIPTS"/wxp_*.luc
if [ -f "$BACKUP/debug.luc" ]; then
  cp "$BACKUP/debug.luc" "$SCRIPTS/debug.luc"
  say "   debug.luc восстановлен из бэкапа"
else
  say "   бэкапа debug.luc нет — восстановите его проверкой целостности файлов в Steam"
fi

wxp_log_done
echo
echo "Удалено. gamepad.ini оставлен на месте — сотрите вручную, если он больше не нужен."
