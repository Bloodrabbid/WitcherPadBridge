#!/bin/bash
# WitcherPadBridge -- крупнее текст в интерфейсе. Ставится и снимается отдельно от мода.
#
# Игра не растеризует шрифт, а берёт готовый атлас System/__cache/<шрифт>_<размер>_<o|n>.fontcache.
# Своих TTF у неё нет, и новых размеров она не печёт -- поэтому взять можно только тот размер,
# для которого атлас уже есть. Причём для русского годятся ТОЛЬКО размеры, которые использует
# штатная русская таблица: остальные атласы остались от латинских языков и кириллицы в них нет
# (текст тогда размечается, но не рисуется -- проверено).
#
# Какую таблицу читает игра, решает languages.2da, колонка Fonts: у русского там fonts_rus,
# у остальных -- штатная fonts. Поэтому кладём обе.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SRC="$ROOT/mod/extras/bigger-text"

GAME="${2:-}"
if [ -z "$GAME" ]; then
  for c in "$HOME/.steam/steam/steamapps/common/The Witcher Enhanced Edition" \
           "$HOME/.local/share/Steam/steamapps/common/The Witcher Enhanced Edition" \
           "/c/Program Files (x86)/Steam/steamapps/common/The Witcher Enhanced Edition"; do
    [ -f "$c/System/witcher.ini" ] && { GAME="$c"; break; }
  done
fi
[ -n "$GAME" ] || { echo "Не нашёл игру. Укажите папку: $0 ${1:-on} \"/путь/к/игре\"" >&2; exit 1; }

case "${1:-on}" in
  on)
    mkdir -p "$GAME/Data/2DA"
    cp "$SRC/fonts.2da"     "$GAME/Data/2DA/fonts.2da"
    cp "$SRC/fonts_rus.2da" "$GAME/Data/2DA/fonts_rus.2da"
    echo "Крупный текст включён. Перезапустите игру -- таблица читается только при старте."
    echo "  $GAME/Data/2DA/fonts.2da"
    echo "  $GAME/Data/2DA/fonts_rus.2da"
    ;;
  off)
    rm -f "$GAME/Data/2DA/fonts.2da" "$GAME/Data/2DA/fonts_rus.2da"
    rmdir "$GAME/Data/2DA" 2>/dev/null || true
    echo "Крупный текст выключен. После перезапуска игра возьмёт свои шрифты."
    ;;
  *)
    echo "Использование: $0 on|off [папка игры]" >&2; exit 1;;
esac
