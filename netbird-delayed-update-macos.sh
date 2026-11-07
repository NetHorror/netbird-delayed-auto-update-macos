#!/usr/bin/env bash
# Version: 0.2.0
#
# NetBird Delayed Auto-Update for macOS
#
# Delayed (staged) auto-update for the NetBird client on macOS.
#
# 0.2.0:
# - Detects a missing NetBird client and can install it (prompt on a terminal,
#   or --install-client). A first install takes the current latest version;
#   the delay applies only to updates.
# - Self-update downloads release assets and verifies them against SHA256SUMS
#   (no more `git pull` as root). Disable with --no-self-update.
#
# IMPORTANT SAFETY CHANGE (0.1.4 republish):
# - `--uninstall` ONLY removes this script's LaunchDaemon.
# - It does NOT touch NetBird (client/service) unless you explicitly pass
#   `--remove-netbird-auto-start`.

set -euo pipefail

# Preserve existing PATH order; append common locations if missing.
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
INSTALLED_SCRIPT_PATH="/usr/local/sbin/netbird-delayed-update-macos.sh"
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

# Only used with --uninstall when explicitly requested
REMOVE_NETBIRD_AUTOSTART="false"

# Install the NetBird client without asking if it is missing
INSTALL_CLIENT="false"

# Script self-update (best-effort). Keep this exact line format:
# 0.1.x copies verify `SCRIPT_VERSION="<tag>"` in the raw file of the tag.
SCRIPT_VERSION="0.2.0"
SELF_UPDATE="true"
SELFUPDATE_REPO="NetHorror/netbird-delayed-auto-update-macos"
SELFUPDATE_ASSET="netbird-delayed-update-macos.sh"
SELFUPDATE_SUMS_ASSET="SHA256SUMS"

# Lock stale policy:
# will be set to MAX_RANDOM_DELAY_SECONDS after args parsing; initialize to default
LOCK_STALE_SECONDS="$DEFAULT_MAX_RANDOM_DELAY_SECONDS"

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
  -u, --uninstall         Uninstall LaunchDaemon (does NOT touch NetBird by default)
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
  --remove-netbird-auto-start     With --uninstall: ALSO stop+uninstall NetBird daemon service
  --install-client                Install the NetBird client if missing, without asking
                                  (first install = current latest version; the delay
                                  applies only to updates)
  --no-self-update                Do not update this script from GitHub releases
  -h, --help                     Show help and exit
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

# Robust lock: stores PID + creation time.
# Removes stale lock if PID is dead and lock age >= LOCK_STALE_SECONDS.
# Improvements:
# - If lock predates last reboot, it is removed immediately (PID is already checked dead).
# - If lock is not old enough, logs remaining seconds + local time when it becomes stale.
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
    log "Another instance appears to be running (pid: $pid, lock: $lock_dir). Exiting."
    return 1
  fi

  # PID is dead/missing — compute lock age
  local created=""
  created="$(cat "$ts_file" 2>/dev/null || true)"
  if [[ ! "$created" =~ ^[0-9]+$ ]]; then
    created="$(stat -f %m "$lock_dir" 2>/dev/null || echo 0)"
  fi

  local age=$(( now - created ))
  (( age < 0 )) && age=0

  # Grace period: avoid racing with another instance that just created lock but hasn't written pid yet.
  if (( age < GRACE_SECONDS )); then
    log "Lock exists but looks very recent (age ${age}s). Assuming it's being created; exiting."
    return 1
  fi

  # If lock was created before the last reboot, it can't belong to a live process.
  local boot_sec="0"
  boot_sec="$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*sec = ([0-9]+).*/\1/' || echo 0)"
  [[ "$boot_sec" =~ ^[0-9]+$ ]] || boot_sec=0

  if (( boot_sec > 0 )) && [[ "$created" =~ ^[0-9]+$ ]] && (( created < boot_sec )); then
    log "Stale lock detected: lock predates last reboot (created_epoch=${created}, boot_epoch=${boot_sec}). Removing immediately and retrying..."
    rm -rf "$lock_dir" 2>/dev/null || true

    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$$" > "$pid_file"
      echo "$now" > "$ts_file"
      trap "rm -rf \"$lock_dir\" 2>/dev/null || true" EXIT INT TERM HUP
      return 0
    fi

    log "Failed to recreate lock after removing reboot-stale lock. Exiting."
    return 1
  fi

  # TTL behavior (same-boot stale lock)
  if (( age >= LOCK_STALE_SECONDS )); then
    log "Stale lock detected (age ${age}s >= ${LOCK_STALE_SECONDS}s, pid '${pid:-none}'). Removing lock and retrying..."
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

  # Log how long remains + local time when it becomes stale
  local remaining=$(( LOCK_STALE_SECONDS - age ))
  local eligible_epoch=$(( created + LOCK_STALE_SECONDS ))
  local eligible_local
  eligible_local="$(date -r "$eligible_epoch" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "unknown")"

  log "Lock exists (age ${age}s), PID is not running, but not old enough to auto-remove. Will be stale in ${remaining}s at ${eligible_local}. Exiting."
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
  have_cmd netbird || { log "netbird not found in PATH; cannot remove NetBird auto-start."; return 0; }
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
  local target="${2:-}"

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

  # Homebrew cannot install an arbitrary old version, so only upgrade when the
  # formula currently offers exactly the matured version. Otherwise wait.
  local offered
  offered="$(brew_as_owner info --json=v2 "$formula" 2>/dev/null \
    | grep -Eo '"stable"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
    | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  if [[ -n "$target" && "$offered" != "$target" ]]; then
    log "Homebrew offers '${offered:-unknown}', but the matured version is '${target}'; deferring upgrade."
    return 0
  fi

  log "Upgrading Homebrew formula: $formula"
  brew_as_owner upgrade "$formula"

  refresh_netbird_service_registration_if_present || true
  restart_netbird_service
}

pkg_arch() { [[ "$(uname -m)" == "arm64" ]] && echo "arm64" || echo "amd64"; }

# Print the version recorded in a flat .pkg (empty if it cannot be read).
pkg_version() {
  local pkg="$1" d ver=""
  d="$(mktemp -d "/tmp/nbpkg.XXXXXX")"
  if pkgutil --expand-full "$pkg" "$d/x" >/dev/null 2>&1; then
    ver="$(grep -Eho 'version="[^"]+"' "$d"/x/*/PackageInfo 2>/dev/null | head -n1 \
      | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  fi
  rm -rf "$d"
  echo "$ver"
}

pkg_upgrade_netbird() {
  local target="${1:-}"
  local arch tmp_pkg pkg_url
  arch="$(pkg_arch)"
  pkg_url="https://pkgs.netbird.io/macos/${arch}"
  tmp_pkg="$(mktemp "/tmp/netbird.pkg.XXXXXX")"

  log "Downloading NetBird pkg for arch ${arch} from ${pkg_url}"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 -o "$tmp_pkg" "$pkg_url" \
    || { rm -f "$tmp_pkg"; die "Failed to download NetBird pkg."; }

  # The URL always serves "latest", which may be newer than the version that
  # aged. Check the signer and the version before running anything as root.
  if ! pkgutil --check-signature "$tmp_pkg" 2>/dev/null | grep -q "NetBird GmbH"; then
    rm -f "$tmp_pkg"
    die "NetBird pkg is not signed by NetBird GmbH; not installing."
  fi
  if [[ -n "$target" ]]; then
    local pkg_ver
    pkg_ver="$(pkg_version "$tmp_pkg")"
    if [[ "$pkg_ver" != "$target" ]]; then
      rm -f "$tmp_pkg"
      log "Downloaded pkg is version '${pkg_ver:-unknown}', but the matured version is '${target}'; deferring."
      return 0
    fi
  fi

  log "Installing NetBird pkg..."
  installer -pkg "$tmp_pkg" -target / >/dev/null

  rm -f "$tmp_pkg" >/dev/null 2>&1 || true
  restart_netbird_service
}

other_upgrade_netbird() {
  local target="${1:-}"
  log "Install type is 'other' — attempting upgrade via pkg download+install as fallback."
  pkg_upgrade_netbird "$target"
}

perform_upgrade() {
  local target="${1:-}"
  local install_type
  install_type="$(detect_install_type)"
  log "Detected install type: $install_type"

  case "$install_type" in
    brew_formula) brew_upgrade_netbird "formula" "$target" ;;
    brew_cask)    brew_upgrade_netbird "cask" ;;
    pkg)          pkg_upgrade_netbird "$target" ;;
    *)            other_upgrade_netbird "$target" ;;
  esac
}

# -------------------- NetBird client presence / first install --------------------

netbird_client_present() {
  have_cmd netbird && return 0
  # Installed but not in PATH (e.g. app bundle only, or a brew formula/cask).
  [[ "$(detect_install_type)" != "other" ]] && return 0
  pkgutil --pkgs 2>/dev/null | grep -qi 'netbird' && return 0
  return 1
}

# First install: takes the CURRENT LATEST version. The delay window applies
# only to later updates, not to the initial install.
install_netbird_client() {
  [[ "$(id -u)" -eq 0 ]] || die "Installing the NetBird client requires root (sudo)."
  log "Installing NetBird client. A first install takes the current latest version; the ${DELAY_DAYS}-day delay applies only to later updates."

  if have_cmd brew; then
    log "Installing via Homebrew: netbirdio/tap/netbird"
    brew_as_owner install netbirdio/tap/netbird || die "Homebrew install of netbirdio/tap/netbird failed."
    hash -r
    if have_cmd netbird; then
      log "Registering and starting the NetBird daemon service..."
      netbird service install >/dev/null 2>&1 || true
      netbird service start >/dev/null 2>&1 || true
    fi
  else
    # No target version: install whatever pkgs.netbird.io serves now, after
    # the NetBird GmbH signature check in pkg_upgrade_netbird.
    pkg_upgrade_netbird ""
    hash -r
  fi

  have_cmd netbird || die "NetBird install finished, but 'netbird' is still not in PATH."
  log "NetBird client installed: $(netbird version 2>/dev/null | head -n1 || true)"
}

# Returns 0 if the client is (now) present, 1 if it is missing and was not installed.
ensure_netbird_client() {
  netbird_client_present && return 0

  if [[ "$INSTALL_CLIENT" == "true" ]]; then
    log "NetBird client not found; installing (--install-client)."
    install_netbird_client
    return 0
  fi

  if [[ -t 0 ]]; then
    local answer=""
    read -r -p "NetBird not found. Install now? [Y/n] " answer || answer="n"
    case "$answer" in
      ""|[Yy]|[Yy][Ee][Ss]) install_netbird_client; return 0 ;;
    esac
    log "NetBird client not installed (declined)."
    return 1
  fi

  log "WARNING: NetBird client not found; not installing in non-interactive mode (run from a terminal or pass --install-client)."
  return 1
}

# -------------------- LaunchDaemon management --------------------

plist_path() { echo "/Library/LaunchDaemons/${LABEL}.plist"; }

render_plist() {
  local hh="${DAILY_TIME%:*}" mm="${DAILY_TIME#*:}"
  hh=$((10#$hh)); mm=$((10#$mm))

  # Always run the root-owned copy, never a file the user can edit.
  local script_path="${INSTALLED_SCRIPT_PATH}"

  local args_xml="<string>${script_path}</string>
    <string>--delay-days</string><string>${DELAY_DAYS}</string>
    <string>--max-random-delay-seconds</string><string>${MAX_RANDOM_DELAY_SECONDS}</string>
    <string>--log-retention-days</string><string>${LOG_RETENTION_DAYS}</string>
    <string>--daily-time</string><string>${DAILY_TIME}</string>
    <string>--label</string><string>${LABEL}</string>"
  [[ "$AUTO_START" == "true" ]] && args_xml="${args_xml}
    <string>--auto-start</string>"
  [[ "$SELF_UPDATE" == "true" ]] || args_xml="${args_xml}
    <string>--no-self-update</string>"

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

  # Copy the script to a root-owned location so the root LaunchDaemon never
  # executes a file that an ordinary user can modify.
  local self_path; self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  if [[ "$self_path" != "${INSTALLED_SCRIPT_PATH}" ]]; then
    install -d -o root -g wheel -m 755 "$(dirname "${INSTALLED_SCRIPT_PATH}")"
    install -o root -g wheel -m 755 "$self_path" "${INSTALLED_SCRIPT_PATH}"
    log "Installed script copy: ${INSTALLED_SCRIPT_PATH}"
  fi

  local plist; plist="$(plist_path)"
  log "Installing LaunchDaemon at: $plist"

  render_plist >"$plist"
  chown root:wheel "$plist"
  chmod 644 "$plist"

  launchctl_bootout_or_unload
  launchctl_bootstrap_or_load

  log "LaunchDaemon installed and loaded."
  ensure_netbird_client || true
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

  # SAFETY: Do NOT touch NetBird unless explicitly requested.
  if [[ "$REMOVE_NETBIRD_AUTOSTART" == "true" ]]; then
    disable_netbird_auto_start
  else
    log "Not touching NetBird service auto-start (use --remove-netbird-auto-start to remove it)."
  fi

  log "Uninstall complete."

  if [[ "$REMOVE_STATE" == "true" ]]; then
    log "Removing state/logs directory: $STATE_DIR"
    rm -rf "$STATE_DIR" || true
  fi
}

# -------------------- Script self-update (best-effort) --------------------
# Protocol (0.2.0+):
#  1. GET releases/latest -> tag_name; version = tag without a leading "v",
#     must be X.Y.Z and newer than SCRIPT_VERSION.
#  2. Take the browser_download_url of the release assets
#     `netbird-delayed-update-macos.sh` and `SHA256SUMS`.
#  3. Download both next to the target file, verify the script's sha256 against
#     the SHA256SUMS line for its exact file name, and require
#     `SCRIPT_VERSION="<version>"` inside it.
#  4. Backup, then atomic mv; mode 755, owner root:wheel.
# Any failure leaves the current script untouched; the run continues.

# Print the browser_download_url of release asset $2 from release JSON $1.
release_asset_url() {
  local json="$1" name="$2"
  local prefix="https://github.com/${SELFUPDATE_REPO}/releases/download/"
  printf '%s\n' "$json" \
    | grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/' \
    | while IFS= read -r u; do
        if [[ "$u" == "$prefix"* && "${u##*/}" == "$name" ]]; then
          echo "$u"
          break
        fi
      done || true
}

# Print the lowercase sha256 recorded for file name $2 in SHA256SUMS file $1.
sums_lookup() {
  local sums="$1" name="$2"
  tr -d '\r' <"$sums" | awk -v n="$name" '
    { f = $2; sub(/^\*/, "", f); if (NF == 2 && f == n) { print tolower($1); exit } }'
}

file_sha256() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print tolower($1)}'
}

self_update_if_needed() {
  [[ "$SELF_UPDATE" == "true" ]] || { log "Self-update disabled (--no-self-update)."; return 0; }
  have_cmd curl || return 0

  local api="https://api.github.com/repos/${SELFUPDATE_REPO}/releases/latest"
  local release_json latest_tag latest_ver
  release_json="$(curl_fetch "$api" 2>/dev/null || true)"
  latest_tag="$(printf '%s\n' "$release_json" | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
    | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  [[ -n "$latest_tag" ]] || { log "Self-update: could not read the latest release tag; skipping."; return 0; }

  latest_ver="${latest_tag#v}"
  if [[ ! "$latest_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "Self-update: latest release tag '${latest_tag}' is not X.Y.Z; skipping."
    return 0
  fi

  version_gt "$latest_ver" "$SCRIPT_VERSION" || return 0

  log "Newer script version available: $latest_ver (current: $SCRIPT_VERSION). Attempting self-update..."

  local script_url sums_url
  script_url="$(release_asset_url "$release_json" "$SELFUPDATE_ASSET")"
  sums_url="$(release_asset_url "$release_json" "$SELFUPDATE_SUMS_ASSET")"
  if [[ -z "$script_url" || -z "$sums_url" ]]; then
    log "Self-update: release ${latest_tag} lacks the '${SELFUPDATE_ASSET}' and/or '${SELFUPDATE_SUMS_ASSET}' asset; keeping current script."
    return 0
  fi

  # Update the file that is running: the root-owned copy in /usr/local/sbin
  # when launched from there (LaunchDaemon), otherwise the current file.
  local self_path target script_dir base
  self_path="$(script_self_path)"
  target="$self_path"
  [[ "$self_path" == "$INSTALLED_SCRIPT_PATH" ]] && target="$INSTALLED_SCRIPT_PATH"
  script_dir="$(dirname "$target")"
  base="$(basename "$target")"

  # Temp files MUST be in the same directory as the target for an atomic mv.
  local tmp tmp_sums
  tmp="$(mktemp "${script_dir}/.${base}.new.XXXXXX")" \
    || { log "Self-update: cannot create a temp file in ${script_dir}; skipping."; return 0; }
  tmp_sums="$(mktemp "${script_dir}/.${base}.sums.XXXXXX")" \
    || { rm -f "$tmp"; log "Self-update: cannot create a temp file in ${script_dir}; skipping."; return 0; }

  log "Self-update: downloading ${script_url}"
  if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 -o "$tmp" "$script_url" \
     || ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 -o "$tmp_sums" "$sums_url"; then
    log "Self-update: download failed; keeping current script."
    rm -f "$tmp" "$tmp_sums" >/dev/null 2>&1 || true
    return 0
  fi

  local expected actual
  expected="$(sums_lookup "$tmp_sums" "$SELFUPDATE_ASSET" || true)"
  actual="$(file_sha256 "$tmp" || true)"
  rm -f "$tmp_sums" >/dev/null 2>&1 || true

  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    log "ERROR: Self-update: no valid sha256 for '${SELFUPDATE_ASSET}' in ${SELFUPDATE_SUMS_ASSET}; keeping current script."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ "$actual" != "$expected" ]]; then
    log "ERROR: Self-update: sha256 mismatch (expected ${expected}, got ${actual:-none}); keeping current script."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi

  if ! head -n 1 "$tmp" | grep -q '^#!/usr/bin/env bash'; then
    log "ERROR: Self-update: downloaded file doesn't look like a bash script; keeping current script."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi
  if ! grep -qF "SCRIPT_VERSION=\"${latest_ver}\"" "$tmp" 2>/dev/null; then
    log "ERROR: Self-update: downloaded script does not declare SCRIPT_VERSION=\"${latest_ver}\"; keeping current script."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    log "ERROR: Self-update: downloaded script fails 'bash -n'; keeping current script."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi

  # Set mode/owner on the temp file first, so the file swapped in is never
  # writable by anyone but root.
  if ! chmod 755 "$tmp" 2>/dev/null || ! chown root:wheel "$tmp" 2>/dev/null; then
    log "ERROR: Self-update: cannot set mode 755 / owner root:wheel; keeping current script."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi

  local backup
  backup="${target}.bak-$(date -u +%Y%m%d-%H%M%S)"
  if ! cp -p "$target" "$backup" 2>/dev/null; then
    log "ERROR: Self-update: cannot write backup ${backup}; keeping current script."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi

  if mv -f "$tmp" "$target" 2>/dev/null; then
    chmod 755 "$target" 2>/dev/null || true
    chown root:wheel "$target" 2>/dev/null || true
    log "Self-update: ${target} updated to ${latest_ver} (sha256 verified; backup: ${backup}). New version will run next cycle."
    return 0
  fi

  log "ERROR: Self-update: failed to atomically replace ${target}. Keeping current script."
  rm -f "$tmp" >/dev/null 2>&1 || true
  return 0
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

  local s
  if have_cmd jot; then
    s="$(jot -r 1 0 "$max")"
  else
    s=$((RANDOM % (max + 1)))
  fi

  local now_epoch wake_epoch now_local wake_local
  now_epoch="$(date +%s)"
  wake_epoch=$((now_epoch + s))

  # Local time (machine timezone / what you see in SSH)
  now_local="$(date "+%Y-%m-%d %H:%M:%S %Z")"
  wake_local="$(date -r "$wake_epoch" "+%Y-%m-%d %H:%M:%S %Z")"

  log "Random delay enabled: now ${now_local}; sleeping ${s}s until ${wake_local}..."
  sleep "$s"
}

run_cycle() {
  init_logging
  cleanup_old_logs

  log "Starting run cycle (script version: $SCRIPT_VERSION)"
  log "Lock stale TTL: ${LOCK_STALE_SECONDS}s (equals MAX_RANDOM_DELAY_SECONDS)"

  acquire_lock || return 0

  self_update_if_needed
  # Missing client: prompt on a terminal / install with --install-client;
  # under launchd only a WARNING is logged and the run ends with exit 0.
  ensure_netbird_client || return 0
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
    perform_upgrade "$cand"
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
    --remove-netbird-auto-start) REMOVE_NETBIRD_AUTOSTART="true"; shift ;;
    -as|--auto-start) AUTO_START="true"; shift ;;
    --install-client) INSTALL_CLIENT="true"; shift ;;
    --no-self-update) SELF_UPDATE="false"; shift ;;
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

# Lock TTL = MAX_RANDOM_DELAY_SECONDS
LOCK_STALE_SECONDS=$((10#$MAX_RANDOM_DELAY_SECONDS))

# -------------------- Main --------------------

case "$MODE" in
  install) init_logging; install_daemon ;;
  uninstall) init_logging; uninstall_daemon ;;
  run) [[ "$(id -u)" -eq 0 ]] || die "Run mode requires root (sudo)."; run_cycle ;;
  *) die "Invalid mode: $MODE" ;;
esac
