#!/bin/sh
set -eu

SCRIPT_PATH=$0
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" 2>/dev/null && pwd)
REPO_ROOT=$SCRIPT_DIR
LOCAL_TEMPLATE="${REPO_ROOT}/backup.conig.example"
REMOTE_TEMPLATE="${REPO_ROOT}/zipAndEnc.env.example"

INSTALL_NAS=false
NAS_USER=${NAS_USER:-admin}
NAS_SCRIPT_DEST="/share/Public/scripts"
NAS_IP=""
NAS_TARGET_DIR=""
CRON_SCHEDULE="0 2 * * 3,6"
SSH_CONTROL_SOCKET=""

show_help() {
  cat <<'EOF'
Usage: ./setup.sh [OPTIONS]

Installs the local backup service and timer for the current machine.
Optionally deploys the archive/encryption helper to a remote server over SSH.

Options:
  --with-nas <IP>          Enable remote archive deployment over SSH.
  --target-dir <DIR>       Remote backup directory for the archive script.
  --user <USER>            Remote SSH username (default: "admin").
  --cron "<SCHEDULE>"      Remote cron schedule for archive jobs.
  --help                   Show this help message and exit.

Examples:
  ./setup.sh
  ./setup.sh --with-nas 192.168.1.20 --target-dir /mnt/backups/rotation
EOF
}

cleanup_ssh() {
  if [ -n "${SSH_CONTROL_SOCKET}" ] && [ -S "${SSH_CONTROL_SOCKET}" ]; then
    echo "[setup] Closing SSH multiplexing socket..."
    ssh -o ControlPath="${SSH_CONTROL_SOCKET}" -O exit "${NAS_USER}@${NAS_IP}" 2>/dev/null || true
    rm -f -- "${SSH_CONTROL_SOCKET}"
  fi
}
trap cleanup_ssh EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-nas)
      INSTALL_NAS=true
      if [ -z "${2:-}" ]; then
        echo "Error: --with-nas requires an IP address as the next argument." >&2
        exit 1
      fi
      case "${2:-}" in
        --*)
          echo "Error: --with-nas requires an IP address as the next argument." >&2
          exit 1
          ;;
      esac
      NAS_IP=$2
      shift 2
      ;;
    --target-dir)
      if [ -z "${2:-}" ]; then
        echo "Error: --target-dir requires a directory path." >&2
        exit 1
      fi
      case "${2:-}" in
        --*)
          echo "Error: --target-dir requires a directory path." >&2
          exit 1
          ;;
      esac
      NAS_TARGET_DIR=$2
      shift 2
      ;;
    --user)
      if [ -z "${2:-}" ]; then
        echo "Error: --user requires a username." >&2
        exit 1
      fi
      case "${2:-}" in
        --*)
          echo "Error: --user requires a username." >&2
          exit 1
          ;;
      esac
      NAS_USER=$2
      shift 2
      ;;
    --cron)
      if [ -z "${2:-}" ]; then
        echo "Error: --cron requires a cron schedule string." >&2
        exit 1
      fi
      case "${2:-}" in
        --*)
          echo "Error: --cron requires a cron schedule string." >&2
          exit 1
          ;;
      esac
      CRON_SCHEDULE=$2
      shift 2
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

if [ "$INSTALL_NAS" = "true" ]; then
  if [ -z "$NAS_IP" ]; then
    echo "Error: --with-nas requires a remote IP/hostname." >&2
    exit 1
  fi
  if [ -z "$NAS_TARGET_DIR" ]; then
    echo "Error: --target-dir is required when using --with-nas." >&2
    exit 1
  fi
fi

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
BIN_DIR="${HOME}/bin"
LOCAL_TARGET_SCRIPT="${BIN_DIR}/backup.sh"
LOCAL_TARGET_SERVICE="${SYSTEMD_USER_DIR}/backup.service"
LOCAL_TARGET_TIMER="${SYSTEMD_USER_DIR}/backup.timer"
LOCAL_CONFIG_FILE="${HOME}/.backup_config"

if [ ! -f "$LOCAL_TEMPLATE" ]; then
  echo "Error: Local config template not found at '$LOCAL_TEMPLATE'." >&2
  exit 1
fi

if [ ! -f "$LOCAL_CONFIG_FILE" ]; then
  echo "[setup] Creating local backup config from template: ${LOCAL_CONFIG_FILE}"
  cp "$LOCAL_TEMPLATE" "$LOCAL_CONFIG_FILE"
  echo "[setup] Edit ${LOCAL_CONFIG_FILE} to match your machine before enabling the timer."
fi

for repo_file in \
  "${REPO_ROOT}/backup.sh" \
  "${REPO_ROOT}/backup.service" \
  "${REPO_ROOT}/backup.timer"
do
  if [ ! -f "$repo_file" ]; then
    echo "Error: Required repository file '$repo_file' is missing." >&2
    exit 1
  fi
done

if [ "$INSTALL_NAS" = "true" ]; then
  if [ ! -f "${REMOTE_TEMPLATE}" ]; then
    echo "Error: Remote encryption template not found at '${REMOTE_TEMPLATE}'." >&2
    exit 1
  fi

  SSH_CONTROL_SOCKET=$(mktemp -u /tmp/backup-ssh-mux-XXXXXX)
  echo "[setup] Connecting to remote host ${NAS_USER}@${NAS_IP}..."
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="${SSH_CONTROL_SOCKET}" -o ControlPersist=60 -fN "${NAS_USER}@${NAS_IP}"
fi

ERRORS=0
for dest_file in "$LOCAL_TARGET_SCRIPT" "$LOCAL_TARGET_SERVICE" "$LOCAL_TARGET_TIMER"; do
  if [ -f "$dest_file" ]; then
    echo "Error: ${dest_file} already exists. Remove it or choose a fresh install." >&2
    ERRORS=$((ERRORS + 1))
  fi
done

if [ "$INSTALL_NAS" = "true" ]; then
  REMOTE_SCRIPT="${NAS_SCRIPT_DEST}/zipAndEnc.sh"
  REMOTE_ENV="${NAS_TARGET_DIR}/zipAndEnc.env"

  echo "[setup] Checking remote destination..."
  if ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="${SSH_CONTROL_SOCKET}" -o ControlPersist=60 "${NAS_USER}@${NAS_IP}" "[ -e '${REMOTE_SCRIPT}' ]"; then
    echo "Error: Remote script already exists: ${REMOTE_SCRIPT}" >&2
    ERRORS=$((ERRORS + 1))
  fi
  if ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="${SSH_CONTROL_SOCKET}" -o ControlPersist=60 "${NAS_USER}@${NAS_IP}" "[ -e '${REMOTE_ENV}' ]"; then
    echo "Error: Remote env file already exists: ${REMOTE_ENV}" >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "[setup] Aborting because one or more target files already exist." >&2
  exit 1
fi

mkdir -p "$SYSTEMD_USER_DIR" "$BIN_DIR"

echo "[setup] Installing local backup script..."
cp "${REPO_ROOT}/backup.sh" "$LOCAL_TARGET_SCRIPT"
chmod +x "$LOCAL_TARGET_SCRIPT"

echo "[setup] Installing local systemd timer..."
cp "${REPO_ROOT}/backup.service" "$LOCAL_TARGET_SERVICE"
cp "${REPO_ROOT}/backup.timer" "$LOCAL_TARGET_TIMER"

echo "[setup] Reloading user services..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
  systemctl --user enable --now backup.timer
  loginctl enable-linger "$USER" 2>/dev/null || true
else
  echo "[setup] systemctl is not available; the timer was installed in ${SYSTEMD_USER_DIR}."
  echo "[setup] Run 'systemctl --user daemon-reload' and 'systemctl --user enable --now backup.timer' manually."
fi

echo "[setup] Local setup complete."

if [ "$INSTALL_NAS" = "true" ]; then
  echo "[setup] Deploying archive helper to remote host..."
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="${SSH_CONTROL_SOCKET}" -o ControlPersist=60 "${NAS_USER}@${NAS_IP}" "mkdir -p '${NAS_SCRIPT_DEST}' '${NAS_TARGET_DIR}'"

  echo "[setup] Copying zipAndEnc.sh..."
  scp -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="${SSH_CONTROL_SOCKET}" -o ControlPersist=60 "${REPO_ROOT}/zipAndEnc.sh" "${NAS_USER}@${NAS_IP}:${REMOTE_SCRIPT}"
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="${SSH_CONTROL_SOCKET}" -o ControlPersist=60 "${NAS_USER}@${NAS_IP}" "chmod +x '${REMOTE_SCRIPT}'"

  echo "[setup] Copying zipAndEnc.env.example to remote target as zipAndEnc.env..."
  scp -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="${SSH_CONTROL_SOCKET}" -o ControlPersist=60 "${REMOTE_TEMPLATE}" "${NAS_USER}@${NAS_IP}:${REMOTE_ENV}"

  CRON_LINE="${CRON_SCHEDULE} ${NAS_SCRIPT_DEST}/zipAndEnc.sh ${NAS_TARGET_DIR} >> ${NAS_TARGET_DIR}/zipAndEnc.log 2>&1"
  echo "[setup] Updating remote crontab with schedule: ${CRON_SCHEDULE}"
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="${SSH_CONTROL_SOCKET}" -o ControlPersist=60 "${NAS_USER}@${NAS_IP}" "bash -c '
    grep -Fq \"zipAndEnc.sh\" /etc/config/crontab || printf '%s\n' \"${CRON_LINE}\" >> /etc/config/crontab
    crontab /etc/config/crontab
    /etc/init.d/crond.sh restart
  '"

  echo "[setup] Remote archive setup complete."
fi

echo "[setup] Done. Review ${LOCAL_CONFIG_FILE} and update any backup paths before your first run."
