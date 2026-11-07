# NetBird Delayed Auto-Update for macOS

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE) ![Platform: macOS](https://img.shields.io/badge/platform-macOS-informational) ![Init: launchd](https://img.shields.io/badge/init-launchd-blue) ![Shell: bash](https://img.shields.io/badge/shell-bash-green)

Instead of upgrading immediately when a new version is published, the script waits until the same
version has been available upstream for a configurable number of days. Short-lived or broken releases
that get replaced quickly will never reach your machines.

It supports both Homebrew-based NetBird installs and the official macOS `.pkg` installer, and can
optionally ensure the NetBird daemon starts before user logon (with an important limitation when
FileVault is enabled — see below).

---

## 🚀 Quick start

> ⚠️ FileVault note: if FileVault is enabled, you must unlock the disk at the FileVault prompt first. No VPN/launchd service can run *before* that.

### One-line install (release asset + SHA256 check)

Downloads the script and `SHA256SUMS` from the GitHub release, verifies the checksum, and installs
the LaunchDaemon. If NetBird is not installed, you are asked whether to install it now:

~~~bash
VER=0.2.0; B="https://github.com/NetHorror/netbird-delayed-auto-update-macos/releases/download/${VER}"; cd "$(mktemp -d)" && curl -fsSLO "$B/netbird-delayed-update-macos.sh" && curl -fsSLO "$B/SHA256SUMS" && grep -E ' \*?netbird-delayed-update-macos\.sh$' SHA256SUMS | shasum -a 256 -c - && sudo bash ./netbird-delayed-update-macos.sh --install --run-at-load
~~~

Add `--install-client` to install NetBird without the question (e.g. in MDM/unattended setups).

`--install` copies the script to `/usr/local/sbin/netbird-delayed-update-macos.sh` (`root:wheel`, `755`),
and the LaunchDaemon always runs that copy.

### Alternative: clone the repository

~~~bash
git clone https://github.com/NetHorror/netbird-delayed-auto-update-macos.git
cd netbird-delayed-auto-update-macos
chmod +x ./netbird-delayed-update-macos.sh
sudo ./netbird-delayed-update-macos.sh --install --run-at-load
~~~

### NetBird client: first install vs. updates

- If the `netbird` client is missing and the script runs **from a terminal**, it asks
  `NetBird not found. Install now? [Y/n]` (Enter = yes).
- With `--install-client` it installs without asking.
- Under launchd (no terminal) it never installs: it logs a `WARNING` and exits with code 0.
- Install method: Homebrew (`brew install netbirdio/tap/netbird`, run as the Homebrew owner) if `brew`
  exists; otherwise the official pkg from `https://pkgs.netbird.io/macos/<arch>`, installed only if
  `pkgutil --check-signature` shows `NetBird GmbH`.
- ⚠️ **A first install takes the current latest NetBird version.** The `--delay-days` window applies
  only to *updates* of an already installed client.

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

