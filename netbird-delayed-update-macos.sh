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

# Lock stale policy: if lock exists, PID is not running, and lock age >= this -> remove lock
LOCK_STALE_SECONDS=3600  # 1 hour

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

resolve_path() {
  # macOS has no `readlink -f`, so resolve symlinks manually.
  local p="$1"
  local target dir
  while [[ -L "$p" ]]; do
    dir="$(cd "$(dirname "$p")" && pwd)"
    target="$(readlink "$p" 2>/dev/null || true)"
    [[ -n "$target" ]] || break
    if [[ "$target" == /* ]]; then
      p="$target"
    else
      p="$dir/$target"
    fi
  done
  echo "$p"
}

script_self_path() {
  local src="${BASH_SOURCE[0]}"
  local dir
  dir="$(cd "$(dirname "$src")" && pwd)"
  resolve_path "$dir/$(basename "$src")"
}

# Robust lock: stores PID + creation time. Removes stale lock if PID is dead and lock is old.
acquire_lock() {
  mkdir -p "$STATE_DIR"

  local lock_dir="${STATE_DIR}/.lock"
  local pid_file="${lock_dir}/pid"
  local ts_file="${lock_dir}/created_epoch"
  local now
  now="$(date +%s)"

  local GRACE_SECONDS=15

  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" > "$pid_file"
    echo "$now" > "$ts_file"
    trap "rm -rf \"$lock_dir\" 2>/dev/null || true" EXIT INT TERM HUP
    return 0
  fi

  # lock already exists — read PID (if any)
  local pid=""
  pid="$(cat "$pid_file" 2>/dev/null || true)"

  # If PID is alive, do not touch the lock.
  if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
    # Optional: detect very old lock with live PID (hung process). We keep it to avoid concurrency.
    local created_live=""
    created_live="$(cat "$ts_file" 2>/dev/null || true)"
    if [[ ! "$created_live" =~ ^[0-9]+$ ]]; then
      created_live="$(stat -f %m "$lock_dir" 2>/dev/null || echo 0)"
    fi
    local age_live=$(( now - created_live ))
    if (( age_live >= LOCK_STALE_SECONDS )); then
      log "Lock is older than ${LOCK_STALE_SECONDS}s but PID $pid is still running. Leaving lock intact."
    else
      log "Another instance appears to be running (pid: $pid, lock: $lock_dir). Exiting."
    fi
    return 1
  fi

  # PID is dead/missing — compute lock age
  local created=""
  created="$(cat "$ts_file" 2>/dev/null || true)"
  if [[ ! "$created" =~ ^[0-9]+$ ]]; then
    created="$(stat -f %m "$lock_dir" 2>/dev/null || echo 0)"
  fi

  local age=$(( now - created ))
  if (( age < 0 )); then age=0; fi

  # Grace period: avoid racing with another instance that just created lock but hasn't written pid yet.
  if (( age < GRACE_SECONDS )); then
    log "Lock exists but looks very recent (age ${age}s). Assuming it's being created; exiting."
    return 1
  fi

  if (( age >= LOCK_STALE_SECONDS )); then
    log "Stale lock detected (age ${age}s, pid '${pid:-none}'). Removing lock and retrying..."
    rm -rf "$lock_dir" 2>/dev/null || true

    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$$" > "$pid_file"
      echo "$now" > "$ts_file"
      trap "rm -rf \"$lock_dir\" 2>/dev/null || true" EXIT INT TERM HUP
      return 0
    fi
    log "Failed to recreate lock after removing stale lock. Exiting."
    return 1
  fi

  log "Lock exists (age ${age}s) and PID is not running, but not old enough to auto-remove. Exiting."
  return 1
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
  # Prefer explicit Homebrew detection first
  if have_cmd brew; then
    if brew_has_formula "netbird" || brew_has_formula "netbirdio/tap/netbird"; then
      echo "brew_formula"; return
    fi
    if brew_has_cask "netbird-ui" || brew_has_cask "netbirdio/tap/netbird-ui"; then
      echo "brew_cask"; return
    fi
  fi

  [[ -d "/Applications/NetBird.app" ]] && { echo "pkg"; return; }

  # Heuristics based on `netbird` path (may be a symlink).
  if have_cmd netbird; then
    local nb_path resolved
    nb_path="$(command -v netbird)"
    resolved="$(resolve_path "$nb_path")"

    [[ "$resolved" == *"/Cellar/netbird/"* ]] && { echo "brew_formula"; return; }
    [[ "$resolved" == *"/Applications/NetBird.app/"* ]] && { echo "pkg"; return; }
  fi

  echo "other"
}

restart_netbird_service() {
  have_cmd netbird || return 0
  netbird service stop >/dev/null 2>&1 || true
  netbird service start >/dev/null 2>&1 || true
}

refresh_netbird_service_registration_if_present() {
  have_cmd netbird || return 0

  local plist_found="false"
  for p in \
    "/Library/LaunchDaemons/netbird.plist" \
    "/Library/LaunchDaemons/io.netbird.client.plist" \
    "/Library/LaunchDaemons/io.netbird.daemon.plist"; do
    if [[ -f "$p" ]]; then
      plist_found="true"
      break
    fi
  done

  [[ "$plist_found" == "true" ]] || return 0

  log "Refreshing NetBird daemon service registration (best-effort)..."
  netbird service stop >/dev/null 2>&1 || true
  netbird service uninstall >/dev/null 2>&1 || true
  netbird service install >/dev/null 2>&1 || true
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
  local console_user=""
  console_user="$(stat -f "%Su" /dev/console 2>/dev/null || true)"
  if [[ -n "$console_user" && "$console_user" != "root" ]]; then
    echo "$console_user"
    return
  fi

  local owner=""
  if [[ -d "/opt/homebrew" ]]; then
    owner="$(stat -f "%Su" "/opt/homebrew" 2>/dev/null || true)"
  fi
  if [[ -z "$owner" && -d "/usr/local/Homebrew" ]]; then
    owner="$(stat -f "%Su" "/usr/local/Homebrew" 2>/dev/null || true)"
  fi
  if [[ -z "$owner" ]]; then
    local brew_path
    brew_path="$(command -v brew 2>/dev/null || true)"
    [[ -n "$brew_path" ]] && owner="$(stat -f "%Su" "$brew_path" 2>/dev/null || true)"
  fi

  echo "$owner"
}

brew_as_owner() {
  have_cmd brew || return 1
  local owner
  owner="$(brew_owner_user)"

  if [[ -z "$owner" ]]; then
    brew "$@"
    return $?
  fi

  if [[ "$owner" == "root" ]]; then
    HOMEBREW_ALLOW_SUPERUSER=1 brew "$@"
    return $?
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    sudo -H -u "$owner" brew "$@"
  else
    brew "$@"
  fi
}

brew_has_formula() {
  local name="$1"
  brew_as_owner list --formula 2>/dev/null | grep -qx "$name"
}

brew_has_cask() {
  local name="$1"
  brew_as_owner list --cask 2>/dev/null | grep -qx "$name"
}

brew_upgrade_netbird() {
  local kind="${1:-formula}"

  have_cmd brew || die "Homebrew not found, but install type detected as brew."

  log "Upgrading NetBird via Homebrew (${kind})"
  brew_as_owner update >/dev/null 2>&1 || true

  if [[ "$kind" == "cask" ]]; then
    local cask=""
    if brew_has_cask "netbird-ui"; then
      cask="netbird-ui"
    elif brew_has_cask "netbirdio/tap/netbird-ui"; then
      cask="netbirdio/tap/netbird-ui"
    fi
    [[ -n "$cask" ]] || die "NetBird UI cask not found in Homebrew."
    log "Upgrading Homebrew cask: $cask"
    brew_as_owner upgrade --cask "$cask"
    restart_netbird_service
    return 0
  fi

  local formula="netbirdio/tap/netbird"
  if brew_has_formula "netbird"; then
    formula="netbird"
  elif brew_has_formula "netbirdio/tap/netbird"; then
    formula="netbirdio/tap/netbird"
  fi

  log "Upgrading Homebrew formula: $formula"
  brew_as_owner upgrade "$formula"

  refresh_netbird_service_registration_if_present || true
  restart_netbird_service
}

pkg_arch() { [[ "$(uname -m)" == "arm64" ]] && echo "arm64" || echo "amd64"; }

pkg_upgrade_netbird() {
  local arch tmp_pkg pkg_url
  arch="$(pkg_arch)"
  pkg_url="https://pkgs.netbird.io/macos/${arch}"
  tmp_pkg="$(mktemp "/tmp/netbird.pkg.XXXXXX")"

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
    brew_formula) brew_upgrade_netbird "formula" ;;
    brew_cask)    brew_upgrade_netbird "cask" ;;
    pkg)          pkg_upgrade_netbird ;;
    *)            other_upgrade_netbird ;;
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

  if ! version_gt "$latest_tag" "$SCRIPT_VERSION"; then
    return 0
  fi

  log "Newer script version available: $latest_tag (current: $SCRIPT_VERSION). Attempting self-update..."

  local self_path script_dir
  self_path="$(script_self_path)"
  script_dir="$(dirname "$self_path")"

  # 1) If we're inside a git checkout, try `git pull --ff-only` first.
  if have_cmd git && git -C "$script_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "Self-update: attempting git pull --ff-only in $script_dir"
    if git -C "$script_dir" pull --ff-only >/dev/null 2>&1; then
      log "Self-update: git pull completed. Updated script will be used on the next run."
      return 0
    fi
    log "Self-update: git pull failed; falling back to raw download."
  fi

  # 2) Download the script from the tagged release and overwrite ourselves.
  local url tmp
  url="https://raw.githubusercontent.com/${SELFUPDATE_REPO}/${latest_tag}/${SELFUPDATE_PATH}"
  tmp="$(mktemp "${STATE_DIR}/selfupdate.XXXXXX")"

  log "Self-update: downloading ${url}"
  if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 -o "$tmp" "$url"; then
    log "Self-update: download failed; keeping current script."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi

  if ! head -n 1 "$tmp" | grep -q '^#!/usr/bin/env bash'; then
    log "Self-update: downloaded file doesn't look like a bash script; aborting."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi

  if ! grep -q "SCRIPT_VERSION=\"${latest_tag}\"" "$tmp" 2>/dev/null; then
    log "Self-update: sanity check failed (SCRIPT_VERSION mismatch); aborting."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi

  local backup="${self_path}.bak-$(date -u +%Y%m%d-%H%M%S)"
  cp -f "$self_path" "$backup" >/dev/null 2>&1 || true

  cp -f "$tmp" "$self_path"
  chmod 755 "$self_path" >/dev/null 2>&1 || true
  chown root:wheel "$self_path" >/dev/null 2>&1 || true
  rm -f "$tmp" >/dev/null 2>&1 || true

  log "Self-update: updated script written to $self_path (backup: $backup). New version will run next cycle."
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
