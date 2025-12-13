#!/usr/bin/env bash
# Version: 0.1.4
#
# NetBird Delayed Auto-Update for macOS
#
# Delayed (staged) auto-update for the NetBird client on macOS.

set -euo pipefail

# Preserve existing PATH order (important for test stubs); append common locations if missing.
DEFAULT_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="${PATH:-$DEFAULT_PATH}"
for p in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin; do
  case ":$PATH:" in
    *":$p:"*) : ;;
    *) PATH="$PATH:$p" ;;
  esac
done
export PATH

# -------------------- Defaults / Config --------------------

STATE_DIR="/var/lib/netbird-delayed-update"
STATE_FILE="${STATE_DIR}/state.json"

DEFAULT_LABEL="io.nethorror.netbird-delayed-update"
DEFAULT_DAILY_TIME="04:00"

DEFAULT_DELAY_DAYS=10
DEFAULT_MAX_RANDOM_DELAY_SECONDS=3600
DEFAULT_LOG_RETENTION_DAYS=60

LABEL="$DEFAULT_LABEL"
DAILY_TIME="$DEFAULT_DAILY_TIME"
DELAY_DAYS="$DEFAULT_DELAY_DAYS"
MAX_RANDOM_DELAY_SECONDS="$DEFAULT_MAX_RANDOM_DELAY_SECONDS"
LOG_RETENTION_DAYS="$DEFAULT_LOG_RETENTION_DAYS"

AUTO_START="false"

# Script self-update (best-effort)
SCRIPT_VERSION="0.1.4"
SELFUPDATE_REPO="NetHorror/netbird-delayed-auto-update-macos"
SELFUPDATE_PATH="netbird-delayed-update-macos.sh"

# -------------------- Global runtime state --------------------

MODE="run"
RUN_AT_LOAD="false"
REMOVE_STATE="false"

LOG_FILE=""

# -------------------- Helpers --------------------

usage() {
  cat <<'EOF'
NetBird Delayed Auto-Update for macOS

Modes:
  -i, --install           Install LaunchDaemon for daily runs
  -u, --uninstall         Uninstall LaunchDaemon (and remove NetBird daemon auto-start)
  (no mode)               Run one delayed-update cycle and exit

Options:
  --delay-days N                  Delay rollout by N days (candidate must remain unchanged)
  --max-random-delay-seconds N    Random jitter before each run (0..N seconds)
  --log-retention-days N          Keep per-run logs for N days (0 disables cleanup)
  --daily-time "HH:MM"            Daily run time for LaunchDaemon
  --label NAME                    LaunchDaemon label
  -r, --run-at-load               With --install: run once at boot (RunAtLoad=true)
  -as, --auto-start               Ensure NetBird daemon is installed/started as a system service
  --remove-state                  With --uninstall: remove /var/lib/netbird-delayed-update
  -h, --help                      Show help and exit
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  echo "[$ts] $msg" | tee -a "$LOG_FILE" >&2
}

init_logging() {
  mkdir -p "$STATE_DIR"
  local ts
  ts="$(date -u +"%Y%m%d-%H%M%S")"
  LOG_FILE="${STATE_DIR}/netbird-delayed-update-${ts}.log"
  touch "$LOG_FILE"
}

cleanup_old_logs() {
  mkdir -p "$STATE_DIR"
  if (( LOG_RETENTION_DAYS <= 0 )); then
    return
  fi

  find "$STATE_DIR" -type f -name "netbird-delayed-update-*.log" \
    -mtime "+$LOG_RETENTION_DAYS" -print -delete 2>/dev/null || true

  # launchd.log is a single append-only file; cap its size to avoid unbounded growth.
  local ld_log="${STATE_DIR}/launchd.log"
  if [[ -f "$ld_log" ]]; then
    local max_bytes=$((5 * 1024 * 1024))  # 5 MiB
    local sz
    sz="$(stat -f%z "$ld_log" 2>/dev/null || echo 0)"
    if [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > max_bytes )); then
      local tmp="${ld_log}.tmp"
      tail -n 20000 "$ld_log" > "$tmp" 2>/dev/null || true
      mv -f "$tmp" "$ld_log" 2>/dev/null || true
    fi
  fi
}

curl_fetch() {
  local url="$1"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$url"
}

extract_semver() {
  local input="$1"
  echo "$input" | tr -d '\r' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

acquire_lock() {
  # Prevent overlapping runs (e.g., manual run + launchd run)
  : "${STATE_DIR:=/var/lib/netbird-delayed-update}"
  mkdir -p "$STATE_DIR"

  local lock_dir="${STATE_DIR}/.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    log "Another instance appears to be running (lock: $lock_dir). Exiting."
    return 1
  fi

  # Expand $lock_dir at trap setup time to avoid set -u / scope issues later.
  trap "rm -rf \"$lock_dir\" 2>/dev/null || true" EXIT INT TERM HUP
  return 0
}

version_cmp() {
  local v1="$1"
  local v2="$2"
  local IFS=.
  local i
  local -a a1 a2

  read -r -a a1 <<<"$v1"
  read -r -a a2 <<<"$v2"

  for ((i=${#a1[@]}; i<3; i++)); do a1[i]=0; done
  for ((i=${#a2[@]}; i<3; i++)); do a2[i]=0; done

  for i in 0 1 2; do
    local n1="0"
    local n2="0"
    [[ -n "${a1[i]:-}" ]] && n1="${a1[i]}"
    [[ -n "${a2[i]:-}" ]] && n2="${a2[i]}"

    # Force base-10 to avoid octal interpretation for leading zeros (08/09).
    n1=$((10#$n1))
    n2=$((10#$n2))

    if (( n1 > n2 )); then
      echo 1; return
    elif (( n1 < n2 )); then
      echo 2; return
    fi
  done

  echo 0
}

version_lt() {
  local v1="$1" v2="$2"
  [[ "$(version_cmp "$v1" "$v2")" -eq 2 ]]
}

version_gt() {
  local v1="$1" v2="$2"
  [[ "$(version_cmp "$v1" "$v2")" -eq 1 ]]
}

validate_daily_time() {
  local t="$1"
  if [[ ! "$t" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then return 1; fi
  local hh="${t%:*}" mm="${t#*:}"
  hh=$((10#$hh)); mm=$((10#$mm))
  (( hh >= 0 && hh <= 23 )) || return 1
  (( mm >= 0 && mm <= 59 )) || return 1
  return 0
}

# -------------------- JSON state helpers (minimal) --------------------
# state.json format:
# {
#   "candidate_version": "0.0.0",
#   "first_seen_utc": "2025-11-30T00:00:00Z"
# }

read_state_candidate_version() {
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  grep -E '"candidate_version"[[:space:]]*:' "$STATE_FILE" | head -n1 \
    | sed -E 's/.*"candidate_version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true
}

read_state_first_seen() {
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  grep -E '"first_seen_utc"[[:space:]]*:' "$STATE_FILE" | head -n1 \
    | sed -E 's/.*"first_seen_utc"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true
}

write_state() {
  local cand="$1" first_seen="$2"
  mkdir -p "$STATE_DIR"
  cat >"$STATE_FILE" <<STATE_EOF
{
  "candidate_version": "$cand",
  "first_seen_utc": "$first_seen"
}
STATE_EOF
}

# -------------------- NetBird helpers --------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

netbird_local_version() {
  have_cmd netbird || { echo ""; return; }
  extract_semver "$(netbird version 2>/dev/null || true)"
}

netbird_latest_upstream_version() {
  local out
  out="$(curl_fetch "https://pkgs.netbird.io/releases/latest" 2>/dev/null || true)"
  out="$(echo "$out" | tr -d '[:space:]')"
  extract_semver "$out"
}

detect_install_type() {
  have_cmd netbird || { echo "other"; return; }
  local nb_path
  nb_path="$(command -v netbird)"

  [[ "$nb_path" == *"/Cellar/netbird/"* ]] && { echo "brew"; return; }

  if [[ -L "$nb_path" ]]; then
    local target
    target="$(readlink "$nb_path" || true)"
    [[ "$target" == *"/Applications/NetBird.app/"* ]] && { echo "pkg"; return; }
  fi

  [[ -d "/Applications/NetBird.app" ]] && { echo "pkg"; return; }
  echo "other"
}

restart_netbird_service() {
  have_cmd netbird || return 0
  netbird service stop >/dev/null 2>&1 || true
  netbird service start >/dev/null 2>&1 || true
}

ensure_netbird_auto_start() {
  [[ "$AUTO_START" == "true" ]] || return 0
  have_cmd netbird || { log "AUTO_START enabled but netbird not found in PATH; skipping."; return 0; }
  log "Ensuring NetBird daemon auto-start is installed and running..."
  netbird service install >/dev/null 2>&1 || true
  netbird service start >/dev/null 2>&1 || true
}

disable_netbird_auto_start() {
  have_cmd netbird || return 0
  log "Stopping and uninstalling NetBird daemon service (remove auto-start)..."
  netbird service stop >/dev/null 2>&1 || true
  netbird service uninstall >/dev/null 2>&1 || true
}

# -------------------- Update mechanisms --------------------

brew_owner_user() {
  local brew_path
  brew_path="$(command -v brew 2>/dev/null || true)"
  [[ -n "$brew_path" ]] || { echo ""; return; }
  stat -f "%Su" "$brew_path" 2>/dev/null || true
}

brew_upgrade_netbird() {
  have_cmd brew || die "Homebrew not found, but install type detected as brew."
  local owner
  owner="$(brew_owner_user)"
  [[ -n "$owner" ]] || die "Unable to determine Homebrew owner user."

  log "Upgrading NetBird via Homebrew as user: $owner"

  local formula="netbirdio/tap/netbird"
  if sudo -u "$owner" brew list --formula 2>/dev/null | grep -qx "netbird"; then
    formula="netbird"
  elif sudo -u "$owner" brew list --formula 2>/dev/null | grep -qx "netbirdio/tap/netbird"; then
    formula="netbirdio/tap/netbird"
  fi

  sudo -u "$owner" brew upgrade "$formula"
  restart_netbird_service
}

pkg_arch() { [[ "$(uname -m)" == "arm64" ]] && echo "arm64" || echo "amd64"; }

pkg_upgrade_netbird() {
  local arch tmp_pkg pkg_url
  arch="$(pkg_arch)"
  pkg_url="https://pkgs.netbird.io/macos/${arch}"
  tmp_pkg="/tmp/netbird.pkg"

  log "Downloading NetBird pkg for arch ${arch} from ${pkg_url}"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 -o "$tmp_pkg" "$pkg_url" \
    || die "Failed to download NetBird pkg."

  log "Installing NetBird pkg..."
  installer -pkg "$tmp_pkg" -target / >/dev/null
  rm -f "$tmp_pkg" >/dev/null 2>&1 || true
  restart_netbird_service
}

other_upgrade_netbird() {
  log "Install type is 'other' — attempting upgrade via pkg download+install as fallback."
  pkg_upgrade_netbird
}

perform_upgrade() {
  local install_type
  install_type="$(detect_install_type)"
  log "Detected install type: $install_type"

  case "$install_type" in
    brew) brew_upgrade_netbird ;;
    pkg)  pkg_upgrade_netbird ;;
    *)    other_upgrade_netbird ;;
  esac
}

# -------------------- LaunchDaemon management --------------------

plist_path() { echo "/Library/LaunchDaemons/${LABEL}.plist"; }

render_plist() {
  local hh="${DAILY_TIME%:*}" mm="${DAILY_TIME#*:}"
  hh=$((10#$hh)); mm=$((10#$mm))

  local script_path
  script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  local args_xml="<string>${script_path}</string>
    <string>--delay-days</string><string>${DELAY_DAYS}</string>
    <string>--max-random-delay-seconds</string><string>${MAX_RANDOM_DELAY_SECONDS}</string>
    <string>--log-retention-days</string><string>${LOG_RETENTION_DAYS}</string>
    <string>--daily-time</string><string>${DAILY_TIME}</string>
    <string>--label</string><string>${LABEL}</string>"
  [[ "$AUTO_START" == "true" ]] && args_xml="${args_xml}
    <string>--auto-start</string>"

  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    ${args_xml}
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>${hh}</integer>
    <key>Minute</key><integer>${mm}</integer>
  </dict>
  <key>RunAtLoad</key><${RUN_AT_LOAD}/>
  <key>StandardOutPath</key><string>${STATE_DIR}/launchd.log</string>
  <key>StandardErrorPath</key><string>${STATE_DIR}/launchd.log</string>
</dict>
</plist>
EOF
}

launchctl_bootout_or_unload() {
  local plist; plist="$(plist_path)"
  launchctl bootout system "$plist" >/dev/null 2>&1 && return 0
  launchctl unload -w "$plist" >/dev/null 2>&1 || true
  return 0
}

launchctl_bootstrap_or_load() {
  local plist; plist="$(plist_path)"
  launchctl bootstrap system "$plist" >/dev/null 2>&1 && return 0
  launchctl load -w "$plist" >/dev/null 2>&1 || true
  return 0
}

install_daemon() {
  [[ "$(id -u)" -eq 0 ]] || die "--install requires root (sudo)."
  validate_daily_time "$DAILY_TIME" || die "Invalid --daily-time '$DAILY_TIME' (expected HH:MM, 00:00..23:59)."

  mkdir -p "$STATE_DIR"
  cleanup_old_logs

  local plist; plist="$(plist_path)"
  log "Installing LaunchDaemon at: $plist"

  render_plist >"$plist"
  chown root:wheel "$plist"
  chmod 644 "$plist"

  launchctl_bootout_or_unload
  launchctl_bootstrap_or_load

  log "LaunchDaemon installed and loaded."
  ensure_netbird_auto_start
}

uninstall_daemon() {
  [[ "$(id -u)" -eq 0 ]] || die "--uninstall requires root (sudo)."

  local plist; plist="$(plist_path)"
  log "Uninstalling LaunchDaemon: $plist"

  if [[ -f "$plist" ]]; then
    launchctl_bootout_or_unload
    rm -f "$plist" || true
  else
    log "Plist not found (already removed?): $plist"
  fi

  disable_netbird_auto_start

  if [[ "$REMOVE_STATE" == "true" ]]; then
    log "Removing state/logs directory: $STATE_DIR"
    rm -rf "$STATE_DIR" || true
  fi

  log "Uninstall complete."
}

# -------------------- Script self-update (best-effort) --------------------

self_update_if_needed() {
  have_cmd curl || return 0

  local api="https://api.github.com/repos/${SELFUPDATE_REPO}/releases/latest"
  local latest_tag
  latest_tag="$(curl_fetch "$api" 2>/dev/null | grep -E '"tag_name"[[:space:]]*:' | head -n1 \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
  latest_tag="$(echo "$latest_tag" | tr -d '[:space:]')"
  [[ -n "$latest_tag" ]] || return 0

  latest_tag="${latest_tag#v}"

  if version_gt "$latest_tag" "$SCRIPT_VERSION"; then
    log "Newer script version available: $latest_tag (current: $SCRIPT_VERSION). Attempting self-update..."
    # Best-effort only; keep as-is.
  fi
}

# -------------------- Delayed update logic --------------------

calc_age_days() {
  local first_seen="$1"
  [[ -n "$first_seen" ]] || { echo 0; return; }

  local now_ts first_ts diff
  now_ts=$(date -u +%s)
  first_ts=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_seen" +%s 2>/dev/null || date -u +%s)

  diff=$(( now_ts - first_ts ))
  (( diff < 0 )) && diff=0
  echo $(( diff / 86400 ))
}

random_sleep() {
  local max="$1"
  (( max > 0 )) || return 0
  if have_cmd jot; then
    local s; s="$(jot -r 1 0 "$max")"
    log "Random delay enabled: sleeping for ${s} seconds..."
    sleep "$s"
    return 0
  fi
  local s=$((RANDOM % (max + 1)))
  log "Random delay enabled: sleeping for ${s} seconds..."
  sleep "$s"
}

run_cycle() {
  init_logging
  cleanup_old_logs

  log "Starting run cycle (script version: $SCRIPT_VERSION)"

  acquire_lock || return 0

  self_update_if_needed
  ensure_netbird_auto_start
  random_sleep "$MAX_RANDOM_DELAY_SECONDS"

  local local_ver upstream_ver
  local_ver="$(netbird_local_version)"
  [[ -n "$local_ver" ]] || { log "Local netbird version could not be determined (netbird missing?). Exiting."; return 0; }

  upstream_ver="$(netbird_latest_upstream_version)"
  [[ -n "$upstream_ver" ]] || { log "Upstream netbird version could not be determined. Exiting."; return 0; }

  log "Local version:   $local_ver"
  log "Upstream version: $upstream_ver"

  local cand first_seen
  cand="$(read_state_candidate_version)"
  first_seen="$(read_state_first_seen)"

  if [[ -z "$cand" || -z "$first_seen" ]]; then
    log "State missing or incomplete; initializing candidate to upstream version."
    write_state "$upstream_ver" "$(now_utc)"
    return 0
  fi

  if [[ "$upstream_ver" != "$cand" ]]; then
    log "New upstream version detected (candidate changed): $cand -> $upstream_ver"
    write_state "$upstream_ver" "$(now_utc)"
    return 0
  fi

  local age_days
  age_days="$(calc_age_days "$first_seen")"
  log "Candidate version $cand has been stable for ${age_days} day(s). Required: ${DELAY_DAYS} day(s)."

  if (( age_days < DELAY_DAYS )); then
    log "Candidate not old enough yet. Skipping upgrade."
    return 0
  fi

  if version_lt "$local_ver" "$cand"; then
    log "Upgrade allowed: local ($local_ver) < candidate ($cand). Performing upgrade..."
    perform_upgrade
  else
    log "No upgrade needed: local ($local_ver) is not less than candidate ($cand)."
  fi
}

# -------------------- Arg parsing --------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--install) MODE="install"; shift ;;
    -u|--uninstall) MODE="uninstall"; shift ;;
    -r|--run-at-load) RUN_AT_LOAD="true"; shift ;;
    --remove-state) REMOVE_STATE="true"; shift ;;
    -as|--auto-start) AUTO_START="true"; shift ;;
    --delay-days) DELAY_DAYS="${2:-}"; shift 2 ;;
    --max-random-delay-seconds) MAX_RANDOM_DELAY_SECONDS="${2:-}"; shift 2 ;;
    --log-retention-days) LOG_RETENTION_DAYS="${2:-}"; shift 2 ;;
    --daily-time) DAILY_TIME="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ "$DELAY_DAYS" =~ ^[0-9]+$ ]] || die "--delay-days must be an integer"
[[ "$MAX_RANDOM_DELAY_SECONDS" =~ ^[0-9]+$ ]] || die "--max-random-delay-seconds must be an integer"
[[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "--log-retention-days must be an integer"
validate_daily_time "$DAILY_TIME" || die "Invalid --daily-time '$DAILY_TIME' (expected HH:MM, 00:00..23:59)."

# -------------------- Main --------------------

case "$MODE" in
  install) init_logging; install_daemon ;;
  uninstall) init_logging; uninstall_daemon ;;
  run) [[ "$(id -u)" -eq 0 ]] || die "Run mode requires root (sudo)."; run_cycle ;;
  *) die "Invalid mode: $MODE" ;;
esac

