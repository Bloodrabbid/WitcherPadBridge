#!/bin/bash
# WitcherPadBridge -- shared installer transcript.
#
# Everything an installer prints also lands in <game>/WitcherPadBridge/install.log. When a report
# arrives from a machine nobody here can touch -- a Steam Deck, an Ally, someone else's Mac --
# that file is the whole story: which build, which game folder, what got copied over what, and
# which step was the last one to run before it stopped.
#
# Deliberately not `tee`: process substitution loses the tail when a script exits, and the tail
# is the part that says how it ended.

WXP_LOGFILE=""
WXP_LOGDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WXP_ROOT="$(dirname "$WXP_LOGDIR")"

wxp_version() {
    if [ -f "$WXP_ROOT/VERSION" ]; then cat "$WXP_ROOT/VERSION"; else echo "dev"; fi
}

# wxp_log_open <game dir> <label>. Called once the game folder is known -- before that there is
# nowhere to write, and a log in a random directory helps nobody.
wxp_log_open() {
    local game="$1" label="$2"
    [ -n "$game" ] || return 0
    mkdir -p "$game/WitcherPadBridge" 2>/dev/null || return 0
    WXP_LOGFILE="$game/WitcherPadBridge/install.log"
    {
        echo ""
        echo "==== $label   $(date '+%Y-%m-%d %H:%M:%S')   version $(wxp_version) ===="
        echo "     host    $(uname -a 2>/dev/null || echo unknown)"
        echo "     game    $game"
        echo "     package $WXP_ROOT"
    } >> "$WXP_LOGFILE" 2>/dev/null || WXP_LOGFILE=""
    return 0
}

say()  { echo "$@";      [ -n "$WXP_LOGFILE" ] && printf '  %s\n' "$*" >> "$WXP_LOGFILE"; return 0; }
note() {                 [ -n "$WXP_LOGFILE" ] && printf '  %s\n' "$*" >> "$WXP_LOGFILE"; return 0; }
die()  { echo "$@" >&2;  [ -n "$WXP_LOGFILE" ] && printf '  FAILED: %s\n' "$*" >> "$WXP_LOGFILE"; exit 1; }

# Sizes, not just names: this is what catches "the installer ran but copied yesterday's build",
# which otherwise looks exactly like "the mod does not work".
wxp_log_files() {
    [ -n "$WXP_LOGFILE" ] || return 0
    {
        echo "  result:"
        local f
        for f in "$@"; do
            if [ -f "$f" ]; then
                printf '    %10s bytes  %s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"
            else
                printf '    %10s        %s\n' "MISSING" "$f"
            fi
        done
    } >> "$WXP_LOGFILE"
    return 0
}

wxp_log_done() { note "done."; return 0; }
