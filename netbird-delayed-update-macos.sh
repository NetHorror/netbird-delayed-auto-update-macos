#!/usr/bin/env bash
#
# NetBird Delayed Auto-Update for macOS
#
# Delayed (staged) auto-update for the NetBird client on macOS.
#
# Idea:
#  - Once per day (via launchd) we check the latest available NetBird version.
#  - A "candidate" version must stay unchanged for N days (DelayDays) before upgrade.
#  - If a newer version appears during aging, the timer is reset.
#  - Only upgrades an already installed NetBird client (no auto-install).
#
# Modes:
#  - Run (default, no -i / -u): perform a single delayed-update check.
#  - --install / -i: install a launchd daemon that runs this script once per day.
#  - --uninstall / -u: remove the launchd daemon (optionally also remove state/logs).
#

set -euo pipefail

# Ensure common Homebrew/bin locations are in PATH (for root / launchd)
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PATH

# -------- Config --------

STATE_DIR="/var/lib/netbird-delayed-update"
STATE_FILE="${STATE_DIR}/state.json"
LOG_PREFIX="${STATE_DIR}/netbird-delayed-update"
LAUNCHD_DIR="/Library/LaunchDaemons"

DELAY_DAYS=3
MAX_RANDOM_DELAY_SECONDS=3600
DAILY_TIME="04:00"
TASK_LABEL="io.nethorror.netbird-delayed-update"
LOG_RETENTION_DAYS=60

MODE="run"
REMOVE_STATE="false"
RUN_AT_LOAD="false"

# Will be set later
SCRIPT_PATH=""
LOG_FILE=""
NOW_UTC=""

# -------- Helpers --------

usage() {
  cat <<EOF
Usage:
  sudo \$0 [mode] [options]

Modes:
  -i, --install           Install launchd daemon (daily check).
  -u, --uninstall         Uninstall launchd daemon.
      (no mode)           Run a single delayed-update check.

Options:
  --delay-days N                How many days a new version must stay unchanged (default: ${DELAY_DAYS}).
  --max-random-delay-seconds N  Max random delay before check in seconds (default: ${MAX_RANDOM_DELAY_SECONDS}).
  --log-retention-days N        How many days to keep log files (0 = disable cleanup, default: ${LOG_RETENTION_DAYS}).
  --daily-time "HH:MM"          Time of day when launchd should run the check (default: ${DAILY_TIME}).
  --label NAME                  Launchd label (default: ${TASK_LABEL}).
  -r, --run-at-load             With --install: also run once at boot (RunAtLoad=true).
  --remove-state                With --uninstall: also remove ${STATE_DIR}.
  -h, --help                    Show this help.

Examples:

  # Install launchd task with defaults (DelayDays=3, jitter up to 1h, 04:00):
  sudo \$0 --install

  # Install with custom settings:
  sudo \$0 -i --delay-days 5 --max-random-delay-seconds 600 --daily-time "03:30"

  # Install with RunAtLoad enabled (run once at boot if missed):
  sudo \$0 -i -r --delay-days 3 --max-random-delay-seconds 3600 --daily-time "04:00"

  # Uninstall but keep state/logs:
  sudo \$0 --uninstall

  # Uninstall and delete state/logs directory:
  sudo \$0 -u --remove-state

  # One-off run (for testing), no delay, no aging:
  sudo \$0 --delay-days 0 --max-random-delay-seconds 0
EOF
}

log() {
  local msg="$1"
  local ts
  ts="$(date -u +"%Y-%m-%d %H:%M:%S")"
  echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
  fi
}

cleanup_old_logs() {
  local days="$LOG_RETENTION_DAYS"

  if [[ -z "$days" ]]; then
    return 0
  fi

  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  if (( days <= 0 )); then
    return 0
  fi

  if [[ ! -d "$STATE_DIR" ]]; then
    return 0
  fi

  local pattern
  pattern="$(basename "$LOG_PREFIX")-*.log"

  find "$STATE_DIR" -maxdepth 1 -type f -name "$pattern" -mtime +"$days" -print0 2>/dev/null | \
    while IFS= read -r -d '' f; do
      rm -f "$f" || true
    done
}

# Compare semantic versions: echo -1 if v1<v2, 0 if equal, 1 if v1>v2
vercmp() {
  local v1="$1" v2="$2"
  local IFS=.
  local i
  local -a a1 a2

  read -ra a1 <<< "$v1"
  read -ra a2 <<< "$v2"

  local len="${#a1[@]}"
  [[ ${#a2[@]} -gt $len ]] && len="${#a2[@]}"

  for ((i=0; i<len; i++)); do
    local n1="${a1[i]:-0}"
    local n2="${a2[i]:-0}"
    if ((10#$n1 < 10#$n2)); then
      echo -1
      return 0
    fi
    if ((10#$n1 > 10#$n2)); then
      echo 1
      return 0
    fi
  done
  echo 0
}

version_lt() {
  [[ "$(vercmp "$1" "$2")" -lt 0 ]]
}

# Get latest NetBird version tag (without 'v') from GitHub
get_latest_github_version() {
  local url="https://api.github.com/repos/netbirdio/netbird/releases/latest"
  local json

  if ! json="$(curl -fsSL "$url" 2>/dev/null || true)"; then
    echo ""
    return
  fi

  if [[ -z "$json" ]]; then
    echo ""
    return
  fi
  echo "$json" | sed -n 's/.*"tag_name":[[:space:]]*"v\([0-9.]*\)".*/\1/p' | head -n1
}

perform_upgrade() {
  log "Stopping NetBird service (if running)..."
  if command -v netbird >/dev/null 2>&1; then
    netbird service stop >/dev/null 2>&1 || true
  fi

  log "Downloading NetBird installer (install.sh --update)..."
  local tmpdir="/tmp/netbird-delayed-update"
  mkdir -p "$tmpdir"
  (
    cd "$tmpdir"
    curl -fsSLO https://pkgs.netbird.io/install.sh
    chmod +x install.sh
    ./install.sh --update
  )
  rm -rf "$tmpdir"

  log "Starting NetBird service..."
  if command -v netbird >/dev/null 2>&1; then
    netbird service start >/dev/null 2>&1 || true
  fi
}

install_launchd() {
  ensure_root
  mkdir -p "$STATE_DIR"

  local hour minute
  IFS=: read -r hour minute <<< "$DAILY_TIME"

  local plist_path="${LAUNCHD_DIR}/${TASK_LABEL}.plist"

  local run_at_load_tag
  if [[ "$RUN_AT_LOAD" == "true" ]]; then
    run_at_load_tag="<true/>"
  else
    run_at_load_tag="<false/>"
  fi

  cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${TASK_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_PATH}</string>
    <string>--delay-days</string>
    <string>${DELAY_DAYS}</string>
    <string>--max-random-delay-seconds</string>
    <string>${MAX_RANDOM_DELAY_SECONDS}</string>
    <string>--log-retention-days</string>
    <string>${LOG_RETENTION_DAYS}</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${hour}</integer>
    <key>Minute</key>
    <integer>${minute}</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${STATE_DIR}/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>${STATE_DIR}/launchd.log</string>

  <key>RunAtLoad</key>
  ${run_at_load_tag}
</dict>
</plist>
EOF

  chown root:wheel "$plist_path"
  chmod 644 "$plist_path"

  # Reload launchd job
  launchctl unload "$plist_path" >/dev/null 2>&1 || true
  launchctl load "$plist_path"

  echo "Installed launchd job: ${TASK_LABEL}"
  echo "Plist: ${plist_path}"
  echo "State/logs: ${STATE_DIR}"
}

uninstall_launchd() {
  ensure_root
  local plist_path="${LAUNCHD_DIR}/${TASK_LABEL}.plist"

  if [[ -f "$plist_path" ]]; then
    launchctl unload "$plist_path" >/dev/null 2>&1 || true
    rm -f "$plist_path"
    echo "Removed launchd job: ${TASK_LABEL}"
  else
    echo "Launchd plist not found: ${plist_path}"
  fi

  if [[ "$REMOVE_STATE" == "true" ]]; then
    rm -rf "$STATE_DIR"
    echo "Removed state/log directory: ${STATE_DIR}"
  fi
}

run_once() {
  ensure_root
  mkdir -p "$STATE_DIR"

  cleanup_old_logs

  LOG_FILE="${LOG_PREFIX}-$(date -u +%Y%m%d-%H%M%S).log"
  NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  log "=== NetBird delayed update started, DelayDays=${DELAY_DAYS}, MaxRandomDelaySeconds=${MAX_RANDOM_DELAY_SECONDS} ==="

  if (( MAX_RANDOM_DELAY_SECONDS > 0 )); then
    local delay
    delay=$(( RANDOM % (MAX_RANDOM_DELAY_SECONDS + 1) ))
    log "Random delay before check: ${delay} seconds."
    sleep "$delay"
  fi

  if ! command -v netbird >/dev/null 2>&1; then
    log "netbird CLI not found in PATH. Nothing to do."
    return 0
  fi

  local local_version
  local_version="$(netbird version 2>/dev/null | tr -d '[:space:]' || true)"

  if [[ -z "$local_version" ]]; then
    log "Could not determine local NetBird version. Aborting."
    return 1
  fi

  log "Local NetBird version: ${local_version}"

  # Get latest version from pkgs.netbird.io
  get_latest_version() {
    local url="https://pkgs.netbird.io/latest/version"
    local v
    v="$(curl -fsSL "$url" 2>/dev/null || true)"
    echo "$v"
  }

  local repo_version
  repo_version="$(get_latest_version)"

  if [[ -z "$repo_version" ]]; then
    log "Failed to determine latest NetBird version from pkgs.netbird.io. Aborting."
    return 1
  fi

  log "Latest NetBird version from repository: ${repo_version}"

  load_state

  if [[ -z "$CANDIDATE_VERSION" || "$CANDIDATE_VERSION" != "$repo_version" ]]; then
    CANDIDATE_VERSION="$repo_version"
    FIRST_SEEN_UTC="$NOW_UTC"
    log "New candidate version detected: ${CANDIDATE_VERSION}. Aging starts now."
  else
    log "Candidate version unchanged: ${CANDIDATE_VERSION}, first seen at ${FIRST_SEEN_UTC}."
  fi

  local age_days
  age_days="$(calc_age_days "$FIRST_SEEN_UTC")"
  log "Candidate has aged for ${age_days} day(s); required: ${DELAY_DAYS}."

  if (( age_days < DELAY_DAYS )); then
    log "Still aging. No upgrade will be performed."
    save_state
    return 0
  fi

  if ! version_lt "$local_version" "$CANDIDATE_VERSION"; then
    log "Local version (${local_version}) is not older than candidate (${CANDIDATE_VERSION}). No upgrade needed."
    save_state
    return 0
  fi

  log "Candidate version matured and local version is older. Proceeding with upgrade..."
  perform_upgrade

  local new_local
  new_local="$(netbird version 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$new_local" ]]; then
    log "Upgrade completed. New local version: ${new_local}"
  else
    log "Upgrade completed, but failed to read new local version."
  fi

  # After upgrade, reset aging for the current candidate
  FIRST_SEEN_UTC="$NOW_UTC"
  save_state
}

# -------- State handling --------

calc_age_days() {
  local first_seen="$1"
  local now_ts
  local first_ts

  now_ts=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$NOW_UTC" +%s 2>/dev/null || date -u +%s)
  first_ts=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_seen" +%s 2>/dev/null || date -u +%s)

  local diff=$(( now_ts - first_ts ))
  if (( diff < 0 )); then
    diff=0
  fi

  echo $(( diff / 86400 ))
}

load_state() {
  CANDIDATE_VERSION=""
  FIRST_SEEN_UTC="$NOW_UTC"

  if [[ ! -f "$STATE_FILE" ]]; then
    return
  fi

  local json
  if ! json="$(cat "$STATE_FILE" 2>/dev/null || true)"; then
    return
  fi

  if [[ -z "$json" ]]; then
    return
  fi

  CANDIDATE_VERSION="$(sed -n 's/.*"CandidateVersion":[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n1 || true)"
  FIRST_SEEN_UTC="$(sed -n 's/.*"FirstSeenUtc":[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n1 || echo "$NOW_UTC")"
}

save_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  cat >"$STATE_FILE" <<EOF
{
  "CandidateVersion": "$CANDIDATE_VERSION",
  "FirstSeenUtc": "$FIRST_SEEN_UTC",
  "LastCheckUtc": "$NOW_UTC"
}
EOF
}

# -------- Parse args --------

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--install)
      MODE="install"
      ;;
    -u|--uninstall)
      MODE="uninstall"
      ;;
    --remove-state)
      REMOVE_STATE="true"
      ;;
    --delay-days)
      shift
      DELAY_DAYS="${1:-$DELAY_DAYS}"
      ;;
    --max-random-delay-seconds)
      shift
      MAX_RANDOM_DELAY_SECONDS="${1:-$MAX_RANDOM_DELAY_SECONDS}"
      ;;
    --log-retention-days)
      shift
      LOG_RETENTION_DAYS="${1:-$LOG_RETENTION_DAYS}"
      ;;
    --daily-time)
      shift
      DAILY_TIME="${1:-$DAILY_TIME}"
      ;;
    --label)
      shift
      TASK_LABEL="${1:-$TASK_LABEL}"
      ;;
    -r|--run-at-load)
      RUN_AT_LOAD="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift || true
done

# -------- Dispatch --------

case "$MODE" in
  install)
    install_launchd
    ;;
  uninstall)
    uninstall_launchd
    ;;
  run)
    run_once
    ;;
  *)
    echo "Internal error: unknown MODE=${MODE}" >&2
    exit 1
    ;;
esac
