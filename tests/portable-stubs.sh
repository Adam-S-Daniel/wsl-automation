# shellcheck shell=bash
# Source this from a test, then call make_bsd_bin DIR. It writes date, stat and
# touch stubs into DIR that behave like the BSD (macOS) tools: they reject the
# GNU-only forms (date -d, stat -c, touch -d) and accept the BSD ones (date -r,
# date -j -f, stat -f %m, touch -t), answering with the real GNU tool so the
# result is deterministic. Put DIR first on PATH to run a script "on macOS".

make_bsd_bin() {
    local dir=$1 real_date real_stat real_touch
    real_date=$(command -v date)
    real_stat=$(command -v stat)
    real_touch=$(command -v touch)
    mkdir -p -- "$dir"
    cat >"$dir/date" <<EOF_DATE
#!/usr/bin/env bash
# BSD date: no -d, no --date; -r EPOCH and -j -f FORMAT STRING instead.
for a in "\$@"; do
    case \$a in -d | --date* | -I*) echo "date: illegal option -- \${a#-}" >&2; exit 1 ;; esac
done
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
    if [[ \${args[i]} == -r ]]; then
        epoch=\${args[i + 1]}
        unset 'args[i]' 'args[i+1]'
        exec "$real_date" "\${args[@]}" -d "@\$epoch"
    fi
    if [[ \${args[i]} == -j ]]; then
        # -j -f '%Y-%m-%d %H:%M:%S' STRING +FORMAT
        string=\${args[i + 3]}
        exec "$real_date" -d "\$string" "\${args[i + 4]}"
    fi
done
exec "$real_date" "\$@"
EOF_DATE
    cat >"$dir/stat" <<EOF_STAT
#!/usr/bin/env bash
# BSD stat: -f FORMAT, no -c.
if [[ \${1:-} == -c ]]; then echo "stat: illegal option -- c" >&2; exit 1; fi
if [[ \${1:-} == -f && \${2:-} == %m ]]; then
    shift 2
    [[ \${1:-} != -- ]] || shift
    exec "$real_stat" -c %Y -- "\$@"
fi
exec "$real_stat" "\$@"
EOF_STAT
    cat >"$dir/touch" <<EOF_TOUCH
#!/usr/bin/env bash
# BSD touch: -t STAMP (local time), no -d.
for a in "\$@"; do
    if [[ \$a == -d ]]; then echo "touch: illegal option -- d" >&2; exit 1; fi
done
exec "$real_touch" "\$@"
EOF_TOUCH
    chmod +x "$dir/date" "$dir/stat" "$dir/touch"
}
