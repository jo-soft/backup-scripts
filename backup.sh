#!/usr/bin/env bash
set -euo pipefail

# backups hold credentials: folders created here stay private
umask 077

PATH="/usr/local/bin:/usr/bin:/bin:${HOME}/bin:${HOME}/.local/bin"
export PATH

CONFIG_FILE="${HOME}/.backup_config"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file $CONFIG_FILE not found." >&2
    exit 1
fi

# the backup is pruned to the synced sources, so a backup folder holding $HOME would delete it
backup_root=$(realpath -m -- "$LOCAL_BACKUP")
if [[ "$HOME/" == "${backup_root%/}/"* ]]; then
    echo "Error: LOCAL_BACKUP must not contain $HOME: $LOCAL_BACKUP" >&2
    exit 1
fi

RSYNC_FLAGS=(-aPc --delete --delete-excluded --quiet)
LOCK_FILE="${LOCK_FILE:-/tmp/backup.lock}"
NAS_TIMEOUT_SECONDS=30
has_failed_sync=false
synced_source_filters=()

# the lock file stays: removing it would let a later run lock a new file while this one still runs
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

EXCLUDE_FILE=$(mktemp "${TMPDIR:-/tmp}/backup-excludes.XXXXXX")
EMPTY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/backup-empty.XXXXXX")

cleanup() {
    rm -f -- "$EXCLUDE_FILE"
    rmdir -- "$EMPTY_DIR"
    echo "[backup] Cleanup complete"
}
trap cleanup EXIT

# files vanishing during a sync are normal on a live home directory; other failures are recorded
# so the remaining sources still get synced
run_rsync() {
    local -r vanished_files_status=24
    local status=0
    rsync "$@" || status=$?
    if [[ $status -ne 0 && $status -ne $vanished_files_status ]]; then
        echo "[backup] Error: rsync exited with status $status for: ${*: -2}" >&2
        has_failed_sync=true
    fi
}

warn_missing_dir() {
    echo "[backup] Warning: configured directory not found, its backup gets removed: $1" >&2
}

printf '%s\n' "$EXCLUDE_RULES" > "$EXCLUDE_FILE"
mkdir -p "$LOCAL_BACKUP/dotfiles"

for dir in $SYNC_DIRS; do
    if [[ -d "$HOME/$dir" ]]; then
        echo "[backup] Syncing directory: $dir"
        mkdir -p "$LOCAL_BACKUP/$dir"
        synced_source_filters+=(--filter="P /$dir/")
        run_rsync "${RSYNC_FLAGS[@]}" --exclude-from="$EXCLUDE_FILE" "$HOME/$dir/" "$LOCAL_BACKUP/$dir/"
    else
        warn_missing_dir "$HOME/$dir"
    fi
done

if [[ -d "$CONFIG_DIR" ]]; then
    echo "[backup] Syncing config: $CONFIG_DIR"
    synced_source_filters+=(--filter="P /dotfiles/.config/")
    run_rsync "${RSYNC_FLAGS[@]}" --exclude-from="$EXCLUDE_FILE" "$CONFIG_DIR/" "$LOCAL_BACKUP/dotfiles/.config/"
else
    warn_missing_dir "$CONFIG_DIR"
fi

for file in $SYNC_DOTFILES; do
    if [[ -f "$HOME/$file" ]]; then
        echo "[backup] Syncing dotfile: $file"
        synced_source_filters+=(--filter="P /dotfiles/$file")
        run_rsync "${RSYNC_FLAGS[@]}" "$HOME/$file" "$LOCAL_BACKUP/dotfiles/"
    fi
done

for sec in $SYNC_SECRETS; do
    if [[ -d "$HOME/$sec" ]]; then
        echo "[backup] Syncing secret directory: $sec"
        mkdir -p "$LOCAL_BACKUP/dotfiles/$sec"
        synced_source_filters+=(--filter="P /dotfiles/$sec/")
        run_rsync "${RSYNC_FLAGS[@]}" "$HOME/$sec/" "$LOCAL_BACKUP/dotfiles/$sec/"
    else
        warn_missing_dir "$HOME/$sec"
    fi
done

# sources dropped from the config or from $HOME would otherwise stay in the backup and on the NAS;
# syncing an empty folder deletes everything except the sources synced above
echo "[backup] Removing sources that are no longer synced"
run_rsync -r --delete --quiet "${synced_source_filters[@]}" "$EMPTY_DIR/" "$LOCAL_BACKUP/"

# the NAS sync deletes what the local backup lacks, so an incomplete local backup must not reach it
if [[ "$has_failed_sync" == true ]]; then
    echo "[backup] Error: local backup incomplete; skipping NAS sync" >&2
    exit 1
fi

# an automount point passes mountpoint even while the share is down, so the share also has to answer
is_nas_available() {
    timeout -k 5 "$NAS_TIMEOUT_SECONDS" ls "$NAS_MOUNT/" >/dev/null 2>&1 && mountpoint -q "$NAS_MOUNT" 2>/dev/null
}

if [[ "$AUTO_MOUNT" == true ]] && ! is_nas_available; then
    echo "[backup] Mounting NAS: $NAS_MOUNT"
    timeout -k 5 "$NAS_TIMEOUT_SECONDS" mount "$NAS_MOUNT" 2>/dev/null || true
fi

if is_nas_available; then
    echo "[backup] Syncing local backup to NAS: $NAS_BACKUP_DEST"
    mkdir -p "$NAS_BACKUP_DEST"
    run_rsync -aHAXx --numeric-ids --delete-after --whole-file "$LOCAL_BACKUP/" "$NAS_BACKUP_DEST/"
elif [[ "$AUTO_MOUNT" == true ]]; then
    echo "[backup] Error: NAS could not be mounted: $NAS_MOUNT" >&2
    has_failed_sync=true
else
    echo "[backup] NAS is not mounted; skipping NAS sync"
fi

if [[ "$has_failed_sync" == true ]]; then
    exit 1
fi
