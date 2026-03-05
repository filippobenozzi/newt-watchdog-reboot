#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this uninstaller as root."
  exit 1
fi

systemctl disable --now newt-watchdog.timer 2>/dev/null || true
systemctl stop newt-watchdog.service 2>/dev/null || true

rm -f /etc/systemd/system/newt-watchdog.timer
rm -f /etc/systemd/system/newt-watchdog.service
rm -f /usr/local/sbin/newt-watchdog.sh

systemctl daemon-reload

echo "Watchdog removed."
echo "State left in place: /var/lib/newt-watchdog"
