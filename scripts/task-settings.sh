# shellcheck shell=bash
# Shared settings resolver for the scheduled-task entry points that run as Bash
# in WSL. A value that names one of the owner's own resources (a repository, a
# URL) is set in ONE place and has no fallback in code: when it is missing the
# task fails with an error that names the setting and where to set it.
#
# Source this file, then call, before using the value:
#
#   wsl_automation_require_setting KEY || exit 2
#
# KEY resolves from the environment first (a non-empty value wins). Otherwise it
# is read from the settings file, ${WSL_AUTOMATION_SETTINGS:-~/.config/wsl-automation/settings.env}.
# Windows Task Scheduler starts these tasks through wsl.exe with no environment
# of their own, which is why the value needs a file to live in. The file is read
# as DATA, never sourced:
#   - blank lines and lines starting with # are skipped;
#   - every other line must be KEY=VALUE with KEY matching [A-Z_][A-Z0-9_]*;
#   - only the requested KEY is taken (one file serves every task); the last
#     occurrence wins;
#   - a value starting with ~/ expands to $HOME/; nothing else is expanded and
#     quotes are not stripped.
# A malformed line is an error that names its line NUMBER, never the file path
# (the path contains the user name). The settings file's format is shown in
# config/settings.env.example.
#
# On success the value is exported and the function returns 0. When KEY is still
# empty or unset it prints the error to stderr and returns 2.

wsl_automation_require_setting() {
    local key=$1
    local file=${WSL_AUTOMATION_SETTINGS:-$HOME/.config/wsl-automation/settings.env}
    local line number=0 value='' found=0 line_re='^([A-Z_][A-Z0-9_]*)=(.*)$'

    if [[ -n ${!key:-} ]]; then
        export "$key=${!key}"
        return 0
    fi

    if [[ -r $file && -f $file ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            number=$((number + 1))
            line=${line%$'\r'}
            if [[ $line =~ ^[[:space:]]*(#.*)?$ ]]; then continue; fi
            if [[ ! $line =~ $line_re ]]; then
                printf 'malformed line %d in the settings file (expected KEY=VALUE, a # comment or a blank line)\n' "$number" >&2
                return 2
            fi
            if [[ ${BASH_REMATCH[1]} == "$key" ]]; then
                value=${BASH_REMATCH[2]}
                found=1
            fi
        done <"$file"
        if ((found)) && [[ ${value:0:2} == "~"/ ]]; then
            value=$HOME/${value:2}
        fi
    fi

    if [[ -z $value ]]; then
        printf '%s is not set; set it in ~/.config/wsl-automation/settings.env (WSL_AUTOMATION_SETTINGS; see config/settings.env.example) or the environment\n' "$key" >&2
        return 2
    fi
    export "$key=$value"
}
