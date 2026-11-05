# Backup Script

This repository contains a small local backup workflow and an optional encrypted archive helper for remote storage.

## Overview

- `backup.sh` backs up selected directories, dotfiles, and config into a local directory.
- `backup.service` and `backup.timer` install a user-level systemd timer on Linux.
- `setup.sh` creates the local install and can optionally copy the archive helper to a remote host.
- `zipAndEnc.sh` packs all rotated backup sets into one GPG-encrypted tar archive.

## Quick start

1. Copy the example config:
   ```bash
   cp backup.conig.example ~/.backup_config
   ```
2. Edit `~/.backup_config` and set your machine-specific values.
3. Run the installer:
   ```bash
   ./setup.sh
   ```
4. Check the timer status:
   ```bash
   systemctl --user status backup.timer
   ```

## Customizing the backup

The config file is the main place to tune behavior. Update these values in `~/.backup_config`:

- `LOCAL_BACKUP`: where the backup tree is stored locally.
- `SYNC_DIRS`: top-level directories relative to `$HOME` to include.
- `SYNC_DOTFILES`: individual dotfiles to copy.
- `SYNC_SECRETS`: sensitive config directories to preserve.
- `CONFIG_DIR`: local config directory to include.
- `NAS_MOUNT` / `NAS_BACKUP_DEST`: optional mounted remote target.
- `EXCLUDE_RULES`: patterns to skip during rsync.

## Optional remote encryption helper

If you want to archive the rotated backup sets on a remote host:

1. Edit the example environment file:
   ```bash
   cp zipAndEnc.env.example /path/to/remote/zipAndEnc.env
   ```
2. Fill in:
   - `GPG_BACKUP_KEY_ID`: the recipient key ID to encrypt to.
   - `PREFIX`: a short archive prefix.
   - `GNUPGHOME` (optional): keyring directory. On QNAP, use a path outside `/root`.
   - `KEEP_ARCHIVES` (optional): archives to keep, default 2.
3. Deploy via:
   ```bash
   ./setup.sh --with-nas 192.168.1.50 --target-dir /mnt/backups/rotation --user admin
   ```

## Notes

- The repository is intentionally generic and does not assume a specific host, user, or NAS model.
- The local timer is a user-level systemd service, so it works without root access.
- If `systemctl` is unavailable, the installer prints the manual commands needed to enable the timer.
- Files vanishing during a sync are tolerated. Any other rsync failure doesn't stop the remaining local syncs, but it skips the NAS sync and makes the run exit non-zero, so `systemctl --user status backup.service` shows it as failed.
- With `AUTO_MOUNT=true`, a NAS that can't be reached within 30 seconds also fails the run, after the local backup has finished. With `AUTO_MOUNT=false`, an unmounted NAS is skipped.
