#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer as root."
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="/usr/local/sbin/newt-watchdog.sh"
SERVICE_FILE="/etc/systemd/system/newt-watchdog.service"
TIMER_FILE="/etc/systemd/system/newt-watchdog.timer"
ENV_DIR="/etc/newt"
ENV_FILE="${ENV_DIR}/newt.env"
STATE_DIR="/var/lib/newt-watchdog"
RUNTIME_DIR="/run/newt-watchdog"
BACKUP_DIR="/root/newt-watchdog-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -a "$file" "$BACKUP_DIR/"
  fi
}

backup_if_exists "$INSTALL_SCRIPT"
backup_if_exists "$SERVICE_FILE"
backup_if_exists "$TIMER_FILE"

install -d -m 0755 /usr/local/sbin
install -d -m 0755 /etc/systemd/system
install -d -m 0755 "$ENV_DIR"
install -d -m 0755 "$STATE_DIR"
install -d -m 0755 "$RUNTIME_DIR"

install -m 0755 "$SCRIPT_DIR/newt-watchdog.sh" "$INSTALL_SCRIPT"
install -m 0644 "$SCRIPT_DIR/newt-watchdog.service" "$SERVICE_FILE"
install -m 0644 "$SCRIPT_DIR/newt-watchdog.timer" "$TIMER_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<'ENVEOF'
# Enable watchdog management of newt.service
NEWT_ENABLED=1

# Required credentials / endpoint
NEWT_ID=""
NEWT_SECRET=""
PANGOLIN_ENDPOINT=""
# Alternative if you do not use PANGOLIN_ENDPOINT:
# NEWT_ENDPOINT=""

# Optional watchdog tuning
# NEWT_WATCHDOG_ERROR_WINDOW_SEC=180
# NEWT_WATCHDOG_RESTART_COOLDOWN_SEC=120
# NEWT_WATCHDOG_RESTART_GRACE_SEC=15
# NEWT_WATCHDOG_ERROR_MIN_HITS=1
# NEWT_WATCHDOG_RESTART_BURST_MAX=3
# NEWT_WATCHDOG_RESTART_BURST_WINDOW_SEC=900
# NEWT_WATCHDOG_RESTART_BACKOFF_SEC=900
ENVEOF
  chmod 0600 "$ENV_FILE"
fi

systemctl daemon-reload
systemctl enable --now newt-watchdog.timer

cat <<MSG
Installation completed.

Files installed:
- $INSTALL_SCRIPT
- $SERVICE_FILE
- $TIMER_FILE
- $ENV_FILE

Backup directory (if old files existed):
- $BACKUP_DIR

Useful commands:
- systemctl status newt-watchdog.timer
- systemctl start newt-watchdog.service
- journalctl -u newt-watchdog.service -n 100 --no-pager
MSG
