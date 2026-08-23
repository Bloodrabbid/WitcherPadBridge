#!/bin/bash
# WitcherPadBridge -- installer for the Windows build of the game.
#
# Works both on Linux (Steam Deck, Bazzite, ROG Ally -- the game runs under Proton, but its files
# are the plain Windows ones) and on Windows itself under Git Bash or MSYS. On Windows you can
# also just double-click install_windows.bat, which does the same thing in PowerShell.
#
# Nothing here needs an injector or a patched executable: the game tries to load
# System\lightfx\wxp\LightFX.dll on every start all by itself, and simply carries on when it is
# missing. That is the whole entry point.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
NAME="The Witcher Enhanced Edition"
. "$HERE/_log.sh"

is_game() { [ -f "$1/System/witcher.ini" ] || [ -f "$1/system/witcher.ini" ]; }

find_game() {
  local c lib vdf
  local candidates=()
  # Steam's own record of every library it knows about, on every layout it uses.
  for vdf in \
      "$HOME/.steam/steam/steamapps/libraryfolders.vdf" \
      "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" \
      "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/libraryfolders.vdf" \
      "/c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf" \
      "C:/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"; do
    [ -f "$vdf" ] || continue
    while IFS= read -r lib; do
      [ -n "$lib" ] && candidates+=("$lib/steamapps/common/$NAME")
    done < <(sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf" | sed 's/\\\\/\//g')
  done
  candidates+=(
    "$HOME/.steam/steam/steamapps/common/$NAME"
    "$HOME/.local/share/Steam/steamapps/common/$NAME"
    "/run/media/mmcblk0p1/steamapps/common/$NAME"
    "/c/Program Files (x86)/Steam/steamapps/common/$NAME"
    "/c/GOG Games/The Witcher Enhanced Edition"
  )
  for c in "${candidates[@]}"; do is_game "$c" && { echo "$c"; return 0; }; done
  return 1
}

GAME="${1:-}"
if [ -n "$GAME" ]; then
  is_game "$GAME" || die "В \"$GAME\" не видно System/witcher.ini — это не папка игры."
else
  GAME="$(find_game || true)"
fi
[ -n "$GAME" ] || {
  echo "Не нашёл The Witcher Enhanced Edition. Укажите папку игры явно:" >&2
  echo "    $0 \"/путь/к/The Witcher Enhanced Edition\"" >&2
  exit 1
}
wxp_log_open "$GAME" "install_win.sh"
say "== игра: $GAME =="

SYS="$GAME/System"; [ -d "$SYS" ] || SYS="$GAME/system"
SCRIPTS="$SYS/Scripts"; [ -d "$SCRIPTS" ] || SCRIPTS="$SYS/scripts"
BACKUP="$GAME/WitcherPadBridge/backup"
DLL="$ROOT/bridge/windows/LightFX.dll"

[ -f "$DLL" ] || die "нет $DLL — соберите мост (bridge/windows/build.sh)"
[ -d "$SCRIPTS" ] || die "нет папки скриптов: $SCRIPTS"

mkdir -p "$BACKUP"
# debug.luc is the game's own script with one line added to it -- it is the only script the engine
# loads unconditionally, which is why it is the entry point. Keep the stock copy before replacing.
if [ -f "$SCRIPTS/debug.luc" ] && [ ! -f "$BACKUP/debug.luc" ]; then
  say "== бэкап штатного debug.luc =="
  cp "$SCRIPTS/debug.luc" "$BACKUP/debug.luc"
fi

say "== мост =="
mkdir -p "$SYS/lightfx/wxp"
cp "$DLL" "$SYS/lightfx/wxp/LightFX.dll"

say "== Lua-слой =="
n=0
for f in "$ROOT"/mod/scripts/*.luc; do
  [ -f "$f" ] || continue
  cp "$f" "$SCRIPTS/"
  say "   $(basename "$f")"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || die "в mod/scripts нет .luc — соберите пакет через tools/package.sh"

if [ ! -f "$GAME/gamepad.ini" ]; then
  say "== gamepad.ini по умолчанию =="
  cp "$ROOT/mod/gamepad.ini" "$GAME/gamepad.ini"
fi

wxp_log_files "$SYS/lightfx/wxp/LightFX.dll" \
              "$SCRIPTS/debug.luc" "$SCRIPTS/wxp_gamepad.luc" "$SCRIPTS/wxp_ui.luc" \
              "$SCRIPTS/wxp_combat.luc" "$SCRIPTS/wxp_settings.luc" "$SCRIPTS/wxp_signwheel.luc" \
              "$GAME/gamepad.ini"
wxp_log_done

cat <<EOF

Готово. Запускайте игру обычным способом.

  Настройки: $GAME/gamepad.ini  (перечитывается на лету)
  Лог моста:  $SYS/wxp_bridge.log
  Лог Lua:    $SYS/wxp_gamepad.log
  Отчёт установки: $GAME/WitcherPadBridge/install.log
  Собрать всё для отчёта об ошибке: tools/diagnose.sh

ВАЖНО: в Steam выключите Steam Input для этой игры
  (Свойства → Контроллер → «Отключить Steam Input»)
  или переведите его в passthrough. Мод читает пад напрямую через XInput,
  а Steam Input перехватил бы его и превратил в клавиатуру.

Проверка целостности файлов в Steam откатывает debug.luc — после неё
запустите установщик ещё раз. Удаление: tools/uninstall_win.sh
EOF
