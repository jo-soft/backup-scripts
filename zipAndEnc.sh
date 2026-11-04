#!/usr/bin/env bash
# usage: zipAndEnc.sh dir
#
# Pack the numbered backup sets in dir into an encrypted archive under
# dir/archives and prune old archives. Settings come from dir/zipAndEnc.env.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 dir" >&2; exit 2; }
cd "$1"

KEEP_ARCHIVES=2
. ./zipAndEnc.env
export GNUPGHOME

mkdir -p archives
tmp=.$PREFIX.$$
trap 'rm -f "$tmp"' EXIT

tar -czf - [0-9]* |
    gpg --batch --no-tty --trust-model always -e -r "$GPG_BACKUP_KEY_ID" >"$tmp"
mv "$tmp" "archives/$PREFIX-$(date +%F).tar.gz.gpg"

cd archives
find . -name "$PREFIX-*.tar.gz.gpg" -size 0 -exec rm -f {} \;
ls -1t "$PREFIX"-*.tar.gz.gpg | tail -n +$((KEEP_ARCHIVES + 1)) | xargs -r rm -f --
