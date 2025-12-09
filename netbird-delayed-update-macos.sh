#!/usr/bin/env bash
# Version: 0.1.2
#
# NetBird Delayed Auto-Update for macOS
#
# Delayed (staged) auto-update for the NetBird client on macOS.

set -euo pipefail

# Ensure common Homebrew/bin locations are in PATH (for root / launchd)
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PATH

# -------------------- Defaults / Config --------------------

STATE_DIR="/var/lib/netbird-delayed-update"
STATE_FILE="${STATE_DIR}/state.json"
LOG_PREFIX="${STATE_DIR}/netbird-delayed-update"
LAUNCHD_DIR="/Library/LaunchDaemons"

DELAY_DAYS=10
MAX_RANDOM_DELAY_SECONDS=3600
DAILY_TIME="04:00"
TASK_LABEL="io.nethorror.netbird-delayed-update"
LOG_RETENTION_DAYS=60

# Script self-update
SCRIPT_VERSION="0.1.2"
SELFUPDATE_REPO="NetHorror/netbird-delayed-auto-update-macos"
SELFUPDATE_PATH="netbird-delayed-update-macos.sh"

MODE="run"
REMOVE_STATE="false"
RUN_AT_LOAD="false"

SCRIPT_PATH=""
LOG_FILE=""
NOW_UTC=""

# State variables
CANDIDATE_VERSION=""
FIRST_SEEN_UTC=""

# -------------------- Helper functions --------------------

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
EOF
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
  fi
}

log() {
  local msg="$1"
  local ts
  ts="$(date -u +"%Y-%m-%d %H:%M:%S")"
  echo "[$ts] $msg" | tee -a "$LOG_FILE"
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

# -------------------- Script self-update --------------------

self_update_script() {
  if [[ -z "$SELFUPDATE_REPO" ]]; then
    return 0
  fi

  local api_url="https://api.github.com/repos/${SELFUPDATE_REPO}/releases/latest"
  log "Self-update: checking latest script release at ${api_url}"

  local json
  json="$(curl -fsSL "$api_url" 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    log "Self-update: failed to query GitHub releases (empty response)."
    return 0
  fi

  local remote_tag
  remote_tag="$(echo "$json" \
    | sed -n 's/.*\"tag_name\":[[:space:]]*\"\([0-9]\+\.[0-9]\+\.[0-9]\+\)\".*/\1/p' \
    | head -n1)"

  if [[ -z "$remote_tag" ]]; then
    log "Self-update: cannot parse release tag_name as X.Y.Z; skipping."
    return 0
  fi

  log "Self-update: local script version ${SCRIPT_VERSION}, latest release ${remote_tag}"

  if [[ "$(vercmp "$SCRIPT_VERSION" "$remote_tag")" -ge 0 ]]; then
    log "Self-update: script is up to date."
    return 0
  fi

  log "Self-update: newer script version available."

  if command -v git >/dev/null 2>&1; then
    local repo_dir
    repo_dir="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    while [[ "$repo_dir" != "/" && ! -d "${repo_dir}/.git" ]]; do
      repo_dir="$(dirname "$repo_dir")"
    done
    if [[ -d "${repo_dir}/.git" ]]; then
      log "Self-update: running 'git pull --ff-only' in ${repo_dir}"
      if git -C "$repo_dir" pull --ff-only; then
        log "Self-update: git pull completed. New script will be used on next run."
        return 0
      else
        log "Self-update: git pull failed; falling back to raw download."
      fi
    else
      log "Self-update: script is not inside a git repository."
    fi
  else
    log "Self-update: git not found in PATH."
  fi

  local raw_url="https://raw.githubusercontent.com/${SELFUPDATE_REPO}/${remote_tag}/${SELFUPDATE_PATH}"
  log "Self-update: downloading script from ${raw_url}"

  local tmp
  tmp="$(mktemp "/tmp/netbird-delayed-update-macos.XXXXXX")" || {
    log "Self-update: failed to create temporary file."
    return 0
  }

  if ! curl -fsSL "$raw_url" -o "$tmp" 2>/dev/null; then
    log "Self-update: failed to download script from raw GitHub."
    rm -f "$tmp" || true
    return 0
  fi

  if ! cp "$tmp" "$SCRIPT_PATH"; then
    log "Self-update: failed to overwrite local script."
    rm -f "$tmp" || true
    return 0
  fi

  chmod +x "$SCRIPT_PATH" || true
  rm -f "$tmp" || true

  log "Self-update: script updated from raw GitHub. New version will be used on next run."
}

# -------------------- State handling --------------------

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
  json="$(cat "$STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    return
  fi

  CANDIDATE_VERSION="$(echo "$json" | sed -n 's/.*\"CandidateVersion\":[[:space:]]*\"\([^"]*\)\".*/\1/p' | head -n1 || true)"
  FIRST_SEEN_UTC="$(echo "$json" | sed -n 's/.*\"FirstSeenUtc\":[[:space:]]*\"\([^"]*\)\".*/\1/p' | head -n1 || echo "$NOW_UTC")"
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

# -------------------- NetBird upgrade logic --------------------

get_latest_netbird_version() {
  local url="https://pkgs.netbird.io/releases/latest"
  local output tag

  output="$(curl -fsSL "$url" 2>/dev/null || true)"
  if [[ -z "$output" ]]; then
    echo ""
    return
  fi

  tag="$(echo "$output" \
    | grep -Eo '\"tag_name\":\s*\"v([0-9]+\.){2}[0-9]+"' \
    | tail -n 1 \
    | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+')"

  if [[ -z "$tag" ]]; then
    echo ""
    return
  fi

  echo "${tag#v}"
}

detect_install_type() {
  local nb_path
  nb_path="$(command -v netbird 2>/dev/null || true)"
  if [[ -z "$nb_path" ]]; then
    echo "other"
    return
  fi

  local target="$nb_path"
  local link

  if [ -L "$nb_path" ]; then
    link="$(ls -l "$nb_path" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="->") {print $(i+1); exit}}')"
    if [[ -n "$link" ]]; then
      target="$link"
    fi
  fi

  if [[ "$target" == *"/Cellar/netbird/"* ]]; then
    echo "brew"
  else
    echo "other"
  fi
}

brew_upgrade_netbird() {
  local brew_bin brew_owner formula

  brew_bin="$(command -v brew 2>/dev/null || true)"
  if [[ -z "$brew_bin" ]]; then
    log "Homebrew binary 'brew' not found in PATH; cannot upgrade NetBird via Homebrew."
    return 1
  fi

  brew_owner="$(stat -f "%Su" "$brew_bin" 2>/dev/null || true)"
  if [[ -z "$brew_owner" ]]; then
    log "Failed to determine Homebrew owner user; cannot upgrade NetBird via Homebrew."
    return 1
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    log "Command 'sudo' not found; cannot run Homebrew as non-root user."
    return 1
  fi

  if sudo -u "$brew_owner" "$brew_bin" list --formula netbirdio/tap/netbird >/dev/null 2>&1; then
    formula="netbirdio/tap/netbird"
  elif sudo -u "$brew_owner" "$brew_bin" list --formula netbird >/dev/null 2>&1; then
    formula="netbird"
  else
    log "NetBird formula not found in Homebrew list for user ${brew_owner}; cannot upgrade via Homebrew."
    return 1
  fi

  log "Attempting to upgrade NetBird via Homebrew as user '${brew_owner}' using formula '${formula}'..."

  if sudo -u "$brew_owner" "$brew_bin" upgrade "$formula"; then
    log "Homebrew upgrade of NetBird completed successfully."
    return 0
  else
    log "Homebrew upgrade of NetBird failed."
    return 1
  fi
}

install_mac_pkg_direct() {
  local arch
  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      log "Unsupported macOS arch: $(uname -m)"
      return 1
      ;;
  esac

  local pkg_url
  pkg_url="$(curl -sIL -o /dev/null -w '%{url_effective}' "https://pkgs.netbird.io/macos/${arch}" 2>/dev/null || true)"
  if [[ -z "$pkg_url" ]]; then
    log "Failed to determine NetBird macOS installer URL."
    return 1
  fi

  log "Downloading NetBird macOS installer from https://pkgs.netbird.io/macos/${arch}"
  if ! curl -fsSL -o /tmp/netbird.pkg "$pkg_url"; then
    log "Failed to download NetBird macOS installer."
    return 1
  fi

  if ! installer -pkg /tmp/netbird.pkg -target /; then
    log "Failed to run macOS installer."
    rm -f /tmp/netbird.pkg || true
    return 1
  fi

  rm -f /tmp/netbird.pkg || true
  log "macOS pkg installation completed."
  return 0
}

perform_upgrade() {
  local install_type
  install_type="$(detect_install_type)"
  log "Detected NetBird installation type: ${install_type}"

  log "Stopping NetBird service (if running)..."
  if command -v netbird >/dev/null 2>&1; then
    netbird service stop >/dev/null 2>&1 || true
  fi

  if [[ "$install_type" == "brew" ]]; then
    log "NetBird appears to be installed via Homebrew."
    if ! brew_upgrade_netbird; then
      log "Homebrew-based NetBird upgrade failed; NetBird version might be unchanged."
    fi
  else
    log "NetBird appears to be installed via macOS pkg / app. Running pkg-based installer..."
    if ! install_mac_pkg_direct; then
      log "macOS pkg-based NetBird upgrade failed; NetBird version might be unchanged."
    fi
  fi

  log "Starting NetBird service..."
  if command -v netbird >/dev/null 2>&1; then
    netbird service start >/dev/null 2>&1 || true
  fi
}

run_once() {
  ensure_root
  mkdir -p "$STATE_DIR"

  cleanup_old_logs

  LOG_FILE="${LOG_PREFIX}-$(date -u +%Y%m%d-%H%M%S).log"
  NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  log "=== NetBird delayed update started, DelayDays=${DELAY_DAYS}, MaxRandomDelaySeconds=${MAX_RANDOM_DELAY_SECONDS} ==="

  self_update_script

  if (( MAX_RANDOM_DELAY_SECONDS > 0 )); then
    local delay
    delay=$(( RANDOM % (MAX_RANDOM_DELAY_SECONDS + 1) ))
    log "Random delay before check: ${delay} seconds."
    sleep "$delay"
  else
    log "Random delay disabled (MaxRandomDelaySeconds=0)."
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

  local repo_version
  repo_version="$(get_latest_netbird_version)"

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

  if (( DELAY_DAYS > 0 && age_days < DELAY_DAYS )); then
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

  FIRST_SEEN_UTC="$NOW_UTC"
  save_state
}

# -------------------- launchd integration --------------------

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

# -------------------- Argument parsing --------------------

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

# -------------------- Main dispatch --------------------

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
