#!/usr/bin/env bash
# Live restic backup of the running distro, from inside it, as root.
#
# Run by Invoke-WslResticBackup (the 'WSL Ubuntu Daily Backup' scheduled task) as:
#
#   wsl.exe -d <distro> -u root --cd <scripts dir> --exec /bin/bash ./wsl-restic-backup.sh \
#       <repo> <password file> <excludes file> <maintenance: none|weekly>
#
# Unlike 'wsl --export', this never stops the distro, so running Claude Code
# sessions survive the backup. The repository lives on the local Windows disk
# (for example /mnt/d/Backups/wsl-restic); the caller copies it into the
# OneDrive-synced backup dir afterwards.
#
# Exit codes:
#    0  backup, forget and check all OK
#   10  backup PARTIAL (snapshot saved, some files unreadable); the rest OK
#    2  bad arguments
#   20  restic is not installed
#   21  password file or repository missing
#   30  backup failed (no snapshot)
#   40  forget (and, weekly, prune) failed
#   50  check failed
#
# Output is the backup's two summary lines as restic prints them ("Added to the
# repository: ..." and "processed ... files ..."), then errors=<n>, the number
# of error lines restic wrote to stderr during the backup. Nothing else of
# restic's output is printed - its other lines can carry file paths.
set -euo pipefail

usage() {
    printf '%s\n' 'usage: wsl-restic-backup.sh <repo> <password-file> <excludes-file> <none|weekly>' >&2
}

if (($# != 4)); then
    usage
    exit 2
fi

repo=$1
password_file=$2
excludes_file=$3
maintenance=$4

if [[ -z $repo || -z $password_file || ! -f $excludes_file ]]; then
    usage
    exit 2
fi
case $maintenance in
    none | weekly) ;;
    *)
        usage
        exit 2
        ;;
esac

if ! command -v restic >/dev/null 2>&1; then
    printf '%s\n' 'restic is not installed'
    exit 20
fi

# A restic repository always has a config file at its root.
if [[ ! -f $password_file || ! -f $repo/config ]]; then
    printf '%s\n' 'restic password file or repository missing'
    exit 21
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

restic_global=(-r "$repo" --password-file "$password_file")

# Lowest CPU and I/O priority when available, so a daily run never competes
# with interactive work in the distro.
low_priority=()
if command -v nice >/dev/null 2>&1; then low_priority+=(nice -n 19); fi
if command -v ionice >/dev/null 2>&1; then low_priority+=(ionice -c3); fi

# Clears only stale locks (from a run killed mid-way); a live lock held by
# another restic process is left alone. A failure here surfaces as a backup
# failure below, so it is not fatal on its own.
restic "${restic_global[@]}" unlock >/dev/null 2>&1 || true

# --one-file-system keeps the backup on the root filesystem (no /mnt/c, no
# /proc). /mnt/wslg/distro is a bind mount of / on the same device, which is
# why the excludes file also lists /mnt/*.
backup_rc=0
"${low_priority[@]}" restic "${restic_global[@]}" backup / --one-file-system --exclude-caches \
    --exclude-file "$excludes_file" >"$work/stdout" 2>"$work/stderr" || backup_rc=$?

while IFS= read -r line; do
    case $line in
        'Added to the repository:'* | 'processed '*) printf '%s\n' "$line" ;;
    esac
done <"$work/stdout"

# restic reports each unreadable file as one "error: ..." line on stderr.
error_count=0
while IFS= read -r line; do
    case ${line,,} in
        error*) error_count=$((error_count + 1)) ;;
    esac
done <"$work/stderr"
printf 'errors=%s\n' "$error_count"

case $backup_rc in
    0) partial=false ;;
    3) partial=true ;;
    *) exit 30 ;;
esac

forget_args=(forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3)
check_args=(check)
if [[ $maintenance == weekly ]]; then
    forget_args+=(--prune)
    check_args+=(--read-data-subset=5%)
fi

"${low_priority[@]}" restic "${restic_global[@]}" "${forget_args[@]}" >/dev/null 2>&1 || exit 40
"${low_priority[@]}" restic "${restic_global[@]}" "${check_args[@]}" >/dev/null 2>&1 || exit 50

if [[ $partial == true ]]; then
    exit 10
fi
exit 0
