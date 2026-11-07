# NetBird Delayed Auto-Update for macOS

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE) ![Platform: macOS](https://img.shields.io/badge/platform-macOS-informational) ![Init: launchd](https://img.shields.io/badge/init-launchd-blue) ![Shell: bash](https://img.shields.io/badge/shell-bash-green)

Instead of upgrading immediately when a new version is published, the script waits until the same
version has been available upstream for a configurable number of days. Short-lived or broken releases
that get replaced quickly will never reach your machines.

It supports both Homebrew-based NetBird installs and the official macOS `.pkg` installer, and can
optionally ensure the NetBird daemon starts before user logon (with an important limitation when
FileVault is enabled — see below).

---

## Quick start

> ⚠️ **FileVault:** if FileVault is enabled, the disk must be unlocked at the FileVault prompt before anything runs. See [Limitations with FileVault](#limitations-with-filevault).

### 1. Install

~~~bash
VER=0.2.0
BASE=https://github.com/NetHorror/netbird-delayed-auto-update-macos/releases/download/$VER
curl -fsSLO "$BASE/netbird-delayed-update-macos.sh"
curl -fsSLO "$BASE/SHA256SUMS"
shasum -a 256 -c SHA256SUMS --ignore-missing && sudo bash netbird-delayed-update-macos.sh --install --install-client
~~~

The install command:

1. checks the script against `SHA256SUMS` from the release (the chain stops if the check fails);
2. installs NetBird if it is missing (`--install-client`): with Homebrew (`netbirdio/tap/netbird`) if it is present, otherwise the official `.pkg` after a `NetBird GmbH` signature check;
3. copies the script to `/usr/local/sbin/netbird-delayed-update-macos.sh` (`root:wheel`) and installs a daily LaunchDaemon (04:00).

> **The first install takes the current latest NetBird version.** The delay (`--delay-days`, 10 days by default) applies only to later updates.

Optional: `--run-at-load` runs the check once at boot, `--auto-start` makes sure the NetBird daemon starts before logon.

### 2. Check

~~~bash
sudo launchctl print system/io.nethorror.netbird-delayed-update | head -5
sudo bash netbird-delayed-update-macos.sh --delay-days 0 --max-random-delay-seconds 0
~~~

The second command is a one-off run without delay. It can upgrade NetBird right away if a newer version exists.

---

## ✨ Features

- **Delayed rollout window**
  - New NetBird versions become *candidates*
  - A candidate must remain unchanged for `--delay-days` days
  - Default: **10 days**
  - State file: `/var/lib/netbird-delayed-update/state.json`

- **Supports multiple installation types**
  - Homebrew installs (`netbirdio/tap/netbird` or `netbird`)
  - Official macOS `.pkg` / GUI installs (`/Applications/NetBird.app`)
  - Other setups where `netbird` is available in `PATH`

- **Networking robustness**
  - `curl` timeouts + retries for upstream checks and downloads

- **Version parsing/comparison hardened**
  - Extracts a clean `X.Y.Z`
  - Handles leading zeros safely

- **launchd integration**
  - System `LaunchDaemon` scheduled daily at a configurable time
  - `--run-at-load` is useful for laptops / machines that might be off at the scheduled time

- **Logs and retention**
  - Per-run logs: `/var/lib/netbird-delayed-update/netbird-delayed-update-YYYYMMDD-HHMMSS.log`
  - launchd output: `/var/lib/netbird-delayed-update/launchd.log`
  - Old per-run logs are pruned automatically via `--log-retention-days`
  - `launchd.log` is capped in size to avoid unbounded growth

- **Concurrency guard (lock)**
  - Prevents overlapping runs (manual + scheduled)
  - ♻️ Stale-lock recovery:
    - If a lock is left behind after a crash/kill, it is removed automatically when stale
    - If the lock predates the last reboot, it is removed immediately
    - If it is not stale yet, the script logs how long remains and the local time it becomes stale

- **Self-update (best-effort, on by default)**
  - Checks the latest GitHub release (`X.Y.Z` tag, newer than the running version)
  - Downloads the release assets `netbird-delayed-update-macos.sh` and `SHA256SUMS`, and replaces the
    script only if the sha256 matches and the file declares the release version
  - Updates `/usr/local/sbin/netbird-delayed-update-macos.sh` when run from there (otherwise the running file);
    keeps a `<path>.bak-<timestamp>` backup; atomic `mv`, `755`, `root:wheel`
  - No `git pull` as root
  - Failures are logged and the run continues (no hard failure); the updated script is used on the next run
  - Disable with `--no-self-update` (also written into the LaunchDaemon when given with `--install`)

- **Safety fix**
  - `--uninstall` removes only this script’s LaunchDaemon by default and does **not** touch NetBird
  - To also remove NetBird daemon auto-start, use `--remove-netbird-auto-start`

---

## Usage

### Install LaunchDaemon

~~~bash
sudo ./netbird-delayed-update-macos.sh --install --run-at-load
~~~

With auto-start for NetBird daemon:

~~~bash
sudo ./netbird-delayed-update-macos.sh --install --run-at-load --auto-start
~~~

### Uninstall LaunchDaemon

Safe uninstall (does NOT touch NetBird):

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall
~~~

Also remove state/logs:

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall --remove-state
~~~

If you explicitly want to remove NetBird daemon auto-start too:

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall --remove-netbird-auto-start
~~~

### Manual one-shot run

~~~bash
sudo ./netbird-delayed-update-macos.sh --max-random-delay-seconds 0
~~~

---

## Troubleshooting

### Where to look for logs
- Per-run logs: `/var/lib/netbird-delayed-update/netbird-delayed-update-*.log`
- launchd combined stdout/stderr: `/var/lib/netbird-delayed-update/launchd.log`

### LaunchDaemon looks “not running” — is that OK?
Yes. This job is not a long-running daemon. It runs, logs, and exits.  
So `launchctl print system/<label>` often shows `state = not running` between runs.

### Force a run now (LaunchDaemon)

~~~bash
sudo launchctl kickstart -k system/io.nethorror.netbird-delayed-update
~~~

### Random delay log format
When jitter is enabled, the script logs local time (same as you see in SSH):

- `Random delay enabled: now <LOCAL TIME>; sleeping <S>s until <LOCAL TIME>...`

### Lock messages: how to interpret
- If another instance is running, you’ll see a PID and it will exit.
- If PID is not running but lock is still too new, it will log how long remains, e.g.:

`Will be stale in 1234s at 2025-12-14 03:12:00 CET`

- If the lock predates the last reboot, it is removed immediately.

Manual lock removal (last resort; only if no script instance is running):

~~~bash
sudo rm -rf /var/lib/netbird-delayed-update/.lock
~~~

---

## Limitations with FileVault

If FileVault is enabled:

- After a cold boot/reboot, you get a FileVault unlock screen
- Until the disk is unlocked, macOS is not fully running and launchd jobs do not run

So NetBird (and this updater) cannot run before the disk is unlocked.

---

## Command-line reference

### Modes
- `--install` — install the LaunchDaemon
- `--uninstall` — uninstall the LaunchDaemon
- *(no mode)* — run one cycle and exit

### Options
- `--delay-days N` (default: `10`)
- `--max-random-delay-seconds N` (default: `3600`)
- `--log-retention-days N` (default: `60`, set `0` to disable cleanup)
- `--daily-time "HH:MM"` (default: `04:00`)
- `--label NAME` (default: `io.nethorror.netbird-delayed-update`)
- `--auto-start` (ensure NetBird daemon is installed/started)
- `--run-at-load` (with `--install`)
- `--remove-state` (with `--uninstall`)
- `--remove-netbird-auto-start` (with `--uninstall`, explicitly removes NetBird daemon auto-start)
- `--install-client` (install the NetBird client if missing, without asking; first install = latest version)
- `--no-self-update` (do not update this script from GitHub releases)
- `--help`

---

## Releasing (maintainers)

Self-update of 0.2.0+ needs two assets on every release: `netbird-delayed-update-macos.sh` and
`SHA256SUMS` (produced with `shasum -a 256 netbird-delayed-update-macos.sh > SHA256SUMS`). The tag
(e.g. `0.2.0`) must equal `SCRIPT_VERSION`. Without the assets, installed copies log it and stay as they are.

---

## Related projects

- Windows (Chocolatey + Scheduled Task): [`NetHorror/netbird-delayed-auto-update-windows`](https://github.com/NetHorror/netbird-delayed-auto-update-windows)
- Linux (APT + systemd): [`NetHorror/netbird-delayed-auto-update-linux`](https://github.com/NetHorror/netbird-delayed-auto-update-linux)

