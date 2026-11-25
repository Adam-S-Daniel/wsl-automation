# shellcheck shell=bash
# Small helpers that behave the same with GNU and BSD (macOS) tools. Each one
# probes what the installed tool accepts instead of branching on uname, so
# Homebrew's gnubin on PATH and a stock macOS both work.
#
#   wsl_automation_epoch_format EPOCH FORMAT   UTC text for an epoch
#   wsl_automation_local_to_epoch 'YYYY-MM-DD HH:MM:SS'   epoch of a local time
#   wsl_automation_file_mtime FILE             modification time as epoch
#   wsl_automation_touch_epoch EPOCH FILE      set a file's modification time

# GNU date reads "-d @EPOCH"; BSD date reads "-r EPOCH".
wsl_automation_epoch_format() {
    date -u -d "@$1" "+$2" 2>/dev/null || date -u -r "$1" "+$2"
}

# GNU date parses free text with -d; BSD date needs -j -f with the format.
wsl_automation_local_to_epoch() {
    date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null
}

# GNU stat prints with -c; BSD stat with -f.
wsl_automation_file_mtime() {
    stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null
}

# GNU touch takes -d @EPOCH; BSD touch takes -t in local time.
wsl_automation_touch_epoch() {
    touch -d "@$1" -- "$2" 2>/dev/null ||
        touch -t "$(date -r "$1" +%Y%m%d%H%M.%S)" -- "$2"
}
