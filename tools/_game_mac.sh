# Locate the game on macOS. Sourced by install_mac.sh and uninstall_mac.sh.
#
# A release lands on somebody else's disk, so nothing here may be baked in. Steam records every
# library it knows about in libraryfolders.vdf, which is the only source that is right by
# construction; the fixed paths after it are just the usual places.

wxp_find_game() {
  local given="${1:-}"
  local c
  if [ -n "$given" ]; then
    if [ -x "$given/The Witcher.app/Contents/MacOS/The Witcher" ]; then echo "$given"; return 0; fi
    echo "" ; return 1
  fi

  local candidates=()
  local vdf="$HOME/Library/Application Support/Steam/steamapps/libraryfolders.vdf"
  if [ -f "$vdf" ]; then
    while IFS= read -r lib; do
      [ -n "$lib" ] && candidates+=("$lib/steamapps/common/The Witcher Enhanced Edition")
    done < <(sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf")
  fi
  candidates+=(
    "$HOME/Library/Application Support/Steam/steamapps/common/The Witcher Enhanced Edition"
    "/Applications/The Witcher Enhanced Edition"
    "$HOME/Applications/The Witcher Enhanced Edition"
  )
  for c in "${candidates[@]}"; do
    if [ -x "$c/The Witcher.app/Contents/MacOS/The Witcher" ]; then echo "$c"; return 0; fi
  done
  echo ""; return 1
}

# Resolve or explain and exit. Usage: GAME="$(wxp_game_or_die "$1" "$0")"
wxp_game_or_die() {
  local g
  g="$(wxp_find_game "${1:-}")" || true
  if [ -z "$g" ]; then
    {
      echo "Не нашёл The Witcher Enhanced Edition."
      echo "Укажите папку игры явно:"
      echo "    ${2:-$0} \"/путь/к/The Witcher Enhanced Edition\""
      echo "В этой папке должен лежать The Witcher.app."
    } >&2
    exit 1
  fi
  echo "$g"
}
