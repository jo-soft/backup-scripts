#!/bin/sh

set -e

if [ -z "$1" ]; then
    echo "Error: No target directory path provided."
    echo "Usage: $0 /path/to/backup_dir"
    exit 1
fi

TARGET_BASE_DIR="$1"
ENV_FILE="${TARGET_BASE_DIR}/zipAndEnc.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Environment file not found at '$ENV_FILE'."
    exit 1
fi

# Load environment variables from the specified file
. "$ENV_FILE"

if [ -z "$GPG_BACKUP_KEY_ID" ] || [ -z "$PREFIX" ]; then
    echo "Error: GPG_BACKUP_KEY_ID or PREFIX is not set in '$ENV_FILE'."
    exit 1
fi

cd "$TARGET_BASE_DIR" || { echo "Error: Cannot access '$TARGET_BASE_DIR'"; exit 1; }

BACKUP_DIRS=$(ls -1d [0-9]* 2>/dev/null)

if [ -z "$BACKUP_DIRS" ]; then
    echo "Error: No backup directories found in '$TARGET_BASE_DIR'."
    exit 1
fi

ARCHIVE_DIR="${TARGET_BASE_DIR}/archives"
mkdir -p "$ARCHIVE_DIR"

DATE_STAMP=$(date +%Y-%m-%d)
OUT_FILE="${ARCHIVE_DIR}/${PREFIX}-${DATE_STAMP}.tar.gz.gpg"

echo "Archiving all backup directories..."

tar -czf - $BACKUP_DIRS | gpg --encrypt --recipient "$GPG_BACKUP_KEY_ID" --trust-model always > "$OUT_FILE"

if [ ! -s "$OUT_FILE" ]; then
    echo "Error: Archiving/Encryption failed or resulted in an empty file!"
    rm -f "$OUT_FILE"
    exit 1
fi

echo "Successfully created new archive: '$OUT_FILE'"

cd "$ARCHIVE_DIR" || exit 1
OLD_ARCHIVES=$(ls -1t "${PREFIX}"-*.tar.gpg 2>/dev/null | tail -n +2)

if [ -n "$OLD_ARCHIVES" ]; then
    printf '%s\n' "$OLD_ARCHIVES" | xargs rm -f
    echo "Removed old archives."
fi

echo "Process complete."