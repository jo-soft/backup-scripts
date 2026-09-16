#!/bin/sh

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

. "$ENV_FILE"

if [ -z "$GPG_BACKUP_KEY_ID" ] || [ -z "$PREFIX" ]; then
    echo "Error: GPG_BACKUP_KEY_ID or PREFIX is not set in '$ENV_FILE'."
    exit 1
fi

N_BACKUP="${N:-2}"

cd "$TARGET_BASE_DIR" || { echo "Error: Cannot access '$TARGET_BASE_DIR'"; exit 1; }

TARGET=$(ls -1td [0-9]* 2>/dev/null | sed -n "${N_BACKUP}p")

if [ -z "$TARGET" ]; then
    echo "Error: Could not find the ${N_BACKUP}-th backup directory in '$TARGET_BASE_DIR'."
    exit 1
fi

ARCHIVE_DIR="${TARGET_BASE_DIR}/archives"
mkdir -p "$ARCHIVE_DIR"

DATE_STAMP=$(date +%Y-%m-%d)
OUT_FILE="${ARCHIVE_DIR}/${PREFIX}-${DATE_STAMP}.tar.gpg"

echo "Archiving '$TARGET'..."
tar -cf - "$TARGET" | gpg --encrypt --recipient "$GPG_BACKUP_KEY_ID" --trust-model always > "$OUT_FILE"

if [ $? -ne 0 ]; then
    echo "Error: Archiving/Encryption failed!"
    rm -f "$OUT_FILE"
    exit 1
fi

echo "Successfully created '$OUT_FILE'"

# Prune older archives, keeping only the 1 latest file
cd "$ARCHIVE_DIR" || exit 1
OLD_ARCHIVES=$(ls -1t "${PREFIX}"-*.tar.gpg 2>/dev/null | tail -n +2)
if [ -n "$OLD_ARCHIVES" ]; then
    printf '%s\n' "$OLD_ARCHIVES" | xargs rm -f
fi

echo "Cleanup complete."