#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/local/bin:/usr/bin:/bin:${HOME}/bin:${HOME}/.local/bin"
export PATH

CONFIG_FILE="${HOME}/.backup_config"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file $CONFIG_FILE not found." >&2
    exit 1
fi

RSYNC_FLAGS=(-aPc --delete --quiet)
LOCK_FILE="${LOCK_FILE:-/tmp/backup.lock}"
EXCLUDE_FILE=$(mktemp "${TMPDIR:-/tmp}/backup-excludes.XXXXXX")

cleanup() {
    rm -f -- "$EXCLUDE_FILE" "$LOCK_FILE"
    echo "[backup] Cleanup complete"
}
trap cleanup EXIT

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

printf '%s\n' "$EXCLUDE_RULES" > "$EXCLUDE_FILE"
mkdir -p "$LOCAL_BACKUP/dotfiles"

for dir in $SYNC_DIRS; do
    if [[ -d "$HOME/$dir" ]]; then
        echo "[backup] Syncing directory: $dir"
        rsync "${RSYNC_FLAGS[@]}" --exclude-from="$EXCLUDE_FILE" "$HOME/$dir/" "$LOCAL_BACKUP/$dir/"
    fi
done

if [[ -d "$CONFIG_DIR" ]]; then
    echo "[backup] Syncing config: $CONFIG_DIR"
    rsync "${RSYNC_FLAGS[@]}" --exclude-from="$EXCLUDE_FILE" "$CONFIG_DIR/" "$LOCAL_BACKUP/dotfiles/.config/"
fi

for file in $SYNC_DOTFILES; do
    if [[ -f "$HOME/$file" ]]; then
        echo "[backup] Syncing dotfile: $file"
        rsync "${RSYNC_FLAGS[@]}" "$HOME/$file" "$LOCAL_BACKUP/dotfiles/"
    fi
done

for sec in $SYNC_SECRETS; do
    if [[ -d "$HOME/$sec" ]]; then
        echo "[backup] Syncing secret directory: $sec"
        rsync "${RSYNC_FLAGS[@]}" "$HOME/$sec/" "$LOCAL_BACKUP/dotfiles/$sec/"
    fi
done

if [[ "$AUTO_MOUNT" == true ]] && ! mountpoint -q "$NAS_MOUNT"; then
    echo "[backup] Mounting NAS: $NAS_MOUNT"
    mount "$NAS_MOUNT" 2>/dev/null || true
fi

if mountpoint -q "$NAS_MOUNT" 2>/dev/null; then
    echo "[backup] Syncing local backup to NAS: $NAS_BACKUP_DEST"
    mkdir -p "$NAS_BACKUP_DEST"
    rsync -aHAXx --numeric-ids --delete-after --whole-file "$LOCAL_BACKUP/" "$NAS_BACKUP_DEST/"
else
    echo "[backup] NAS is not mounted; skipping NAS sync"
fi
