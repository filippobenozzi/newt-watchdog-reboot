#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
NEWT_ENV_FILE="${NEWT_ENV_FILE:-/etc/newt/newt.env}"
PERSIST_DIR="${NEWT_WATCHDOG_STATE_DIR:-/var/lib/newt-watchdog}"
RUNTIME_DIR="${NEWT_WATCHDOG_RUNTIME_DIR:-/run/newt-watchdog}"
LOCK_FILE="${RUNTIME_DIR}/watchdog.lock"

OFFLINE_MARKER="${PERSIST_DIR}/offline"
LAST_RESTART_MARKER="${PERSIST_DIR}/last_restart"
RESTART_HISTORY_FILE="${PERSIST_DIR}/restart_history"

ERROR_WINDOW_SEC="${NEWT_WATCHDOG_ERROR_WINDOW_SEC:-180}"
RESTART_COOLDOWN_SEC="${NEWT_WATCHDOG_RESTART_COOLDOWN_SEC:-120}"
RESTART_GRACE_SEC="${NEWT_WATCHDOG_RESTART_GRACE_SEC:-15}"
ERROR_MIN_HITS="${NEWT_WATCHDOG_ERROR_MIN_HITS:-1}"
RESTART_BURST_MAX="${NEWT_WATCHDOG_RESTART_BURST_MAX:-3}"
RESTART_BURST_WINDOW_SEC="${NEWT_WATCHDOG_RESTART_BURST_WINDOW_SEC:-900}"
RESTART_BACKOFF_SEC="${NEWT_WATCHDOG_RESTART_BACKOFF_SEC:-900}"

mkdir -p "${PERSIST_DIR}" "${RUNTIME_DIR}"

# Avoid overlapping executions if timer fires again while still running.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  exit 0
fi

# --- Environment loading ---
NEWT_ENABLED="0"
NEWT_ID=""
NEWT_SECRET=""
PANGOLIN_ENDPOINT=""
NEWT_ENDPOINT=""

if [[ -f "${NEWT_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "${NEWT_ENV_FILE}"
  set +a
fi

ENDPOINT="${PANGOLIN_ENDPOINT:-${NEWT_ENDPOINT:-}}"

now_epoch() {
  date +%s
}

read_int_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

write_int_file() {
  local file="$1"
  local value="$2"
  printf '%s\n' "$value" > "$file"
}

last_restart_epoch() {
  read_int_file "${LAST_RESTART_MARKER}"
}

can_restart_cooldown() {
  local now last
  now="$(now_epoch)"
  last="$(last_restart_epoch)"
  [[ $((now - last)) -ge "${RESTART_COOLDOWN_SEC}" ]]
}

restart_allowed_burst() {
  local now cutoff count last_burst
  now="$(now_epoch)"
  cutoff=$((now - RESTART_BURST_WINDOW_SEC))

  if [[ -f "${RESTART_HISTORY_FILE}" ]]; then
    awk -v cutoff="$cutoff" '$1 >= cutoff { print $1 }' "${RESTART_HISTORY_FILE}" > "${RESTART_HISTORY_FILE}.tmp" || true
    mv -f "${RESTART_HISTORY_FILE}.tmp" "${RESTART_HISTORY_FILE}"
  fi

  count=0
  if [[ -f "${RESTART_HISTORY_FILE}" ]]; then
    count="$(wc -l < "${RESTART_HISTORY_FILE}" | tr -d ' ')"
  fi

  if [[ "${count}" -ge "${RESTART_BURST_MAX}" ]]; then
    last_burst="$(tail -n 1 "${RESTART_HISTORY_FILE}" 2>/dev/null || echo 0)"
    [[ $((now - last_burst)) -ge "${RESTART_BACKOFF_SEC}" ]]
  else
    return 0
  fi
}

record_restart() {
  local now
  now="$(now_epoch)"
  write_int_file "${LAST_RESTART_MARKER}" "${now}"
  printf '%s\n' "${now}" >> "${RESTART_HISTORY_FILE}"
}

restart_newt() {
  local reason="$1"

  if ! can_restart_cooldown; then
    echo "watchdog: ${reason} -> no restart (cooldown ${RESTART_COOLDOWN_SEC}s active)"
    return 0
  fi

  if ! restart_allowed_burst; then
    echo "watchdog: ${reason} -> no restart (burst limit ${RESTART_BURST_MAX}/${RESTART_BURST_WINDOW_SEC}s, backoff ${RESTART_BACKOFF_SEC}s)"
    return 0
  fi

  record_restart
  systemctl restart newt.service
  echo "watchdog: ${reason} -> restarted newt.service"
}

log_since_epoch() {
  local now base_window last_restart after_restart since
  now="$(now_epoch)"
  base_window=$((now - ERROR_WINDOW_SEC))
  last_restart="$(last_restart_epoch)"
  since="${base_window}"

  if [[ "${last_restart}" -gt 0 ]]; then
    after_restart=$((last_restart + RESTART_GRACE_SEC))
    if [[ "${after_restart}" -gt "${since}" ]]; then
      since="${after_restart}"
    fi
  fi

  if [[ "${since}" -lt 0 ]]; then
    since=0
  fi

  echo "${since}"
}

recent_connection_error_hits() {
  local since_epoch

  if ! command -v journalctl >/dev/null 2>&1; then
    echo 0
    return 0
  fi

  since_epoch="$(log_since_epoch)"

  journalctl -u newt.service --since "@${since_epoch}" --no-pager 2>/dev/null \
    | grep -Eic \
      'failed to connect|failed to get token|failed to report peer bandwidth.*not connected|periodic ping failed|failed to connect to websocket|no route to host|ping failed:.*i/o timeout|failed to read icmp packet|Connection to server lost after [0-9]+ failures|Continuous reconnection attempts will be made' \
    || true
}

# --- Service configuration check ---
if [[ "${NEWT_ENABLED:-0}" != "1" || -z "${NEWT_ID:-}" || -z "${NEWT_SECRET:-}" || -z "${ENDPOINT:-}" ]]; then
  if systemctl is-active --quiet newt.service; then
    systemctl stop newt.service
    echo "watchdog: newt disabled or misconfigured -> stopped newt.service"
  fi
  rm -f "${OFFLINE_MARKER}" >/dev/null 2>&1 || true
  exit 0
fi

# --- Network reachability check ---
if ! ip route get 1.1.1.1 >/dev/null 2>&1 && ! ip route get 8.8.8.8 >/dev/null 2>&1; then
  touch "${OFFLINE_MARKER}"
  echo "watchdog: network unavailable -> waiting for recovery"
  exit 0
fi

if [[ -f "${OFFLINE_MARKER}" ]]; then
  rm -f "${OFFLINE_MARKER}" >/dev/null 2>&1 || true
  restart_newt "network recovered"
  exit 0
fi

# --- Process state check ---
if ! systemctl is-active --quiet newt.service; then
  restart_newt "newt.service inactive"
  exit 0
fi

# --- Log error check ---
ERROR_HITS="$(recent_connection_error_hits)"
if [[ "${ERROR_HITS}" -ge "${ERROR_MIN_HITS}" ]]; then
  restart_newt "recent connection errors (${ERROR_HITS})"
  exit 0
fi

echo "watchdog: OK"
