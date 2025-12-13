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

This is the shortest way to get a daily delayed-update job running with reasonable defaults.

> ⚠️ FileVault note: if FileVault is enabled, you must unlock the disk at the FileVault prompt first.
> No VPN or launchd service can run *before* that.

### ✅ Option A: clone the repository

1) Clone and prepare:

~~~bash
git clone https://github.com/NetHorror/netbird-delayed-auto-update-macos.git
cd netbird-delayed-auto-update-macos
chmod +x ./netbird-delayed-update-macos.sh
~~~

2) Install the LaunchDaemon with defaults **and** `RunAtLoad`:

~~~bash
sudo ./netbird-delayed-update-macos.sh --install --run-at-load
~~~

This will:

- Install `/Library/LaunchDaemons/io.nethorror.netbird-delayed-update.plist`
- ⏰ Schedule a daily run at `04:00` (system time)
- 🎲 Add random jitter up to `3600` seconds before each run
- 🗂️ Keep logs for `60` days
- 🚀 Run once at boot too (because of `--run-at-load`)

3) (Optional) Ensure NetBird daemon auto-start after boot:

~~~bash
sudo ./netbird-delayed-update-macos.sh --install --run-at-load --auto-start
~~~

This additionally runs (best-effort):

- `netbird service install`
- `netbird service start`

### ✅ Option B: download the tagged script

~~~bash
# Pick a specific release tag (recommended for reproducible installs)
VERSION="0.1.4"

curl -fsSL -o netbird-delayed-update-macos.sh \
  "https://raw.githubusercontent.com/NetHorror/netbird-delayed-auto-update-macos/${VERSION}/netbird-delayed-update-macos.sh"

chmod +x ./netbird-delayed-update-macos.sh
sudo ./netbird-delayed-update-macos.sh --install --run-at-load
~~~

Tip: Replace `VERSION` with the tag you want (or point to `main` if you explicitly want the latest development version).

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

- **Automatic version detection**
  - Local version via `netbird version` (extracts a clean `X.Y.Z`)
  - Upstream version via `https://pkgs.netbird.io/releases/latest`
  - Safe semantic version comparison (including leading zeros)

- **launchd integration**
  - System `LaunchDaemon` scheduled daily at a configurable time
  - `--run-at-load` is useful for laptops / machines that might be off at the scheduled time

- **NetBird daemon auto-start**
  - `--auto-start` ensures `netbird service install/start` (best-effort)
  - `--uninstall` also removes NetBird daemon auto-start (`service stop/uninstall`, best-effort)
  - ⚠️ FileVault limitation applies (see below)

- **Logs and retention**
  - Per-run logs: `/var/lib/netbird-delayed-update/netbird-delayed-update-YYYYMMDD-HHMMSS.log`
  - launchd output: `/var/lib/netbird-delayed-update/launchd.log`
  - Old per-run logs are pruned via `--log-retention-days` (default **60**)
  - `launchd.log` is capped in size to avoid unbounded growth

- **Concurrency guard**
  - Prevents overlapping runs (manual + scheduled) using a lock directory under `/var/lib/netbird-delayed-update/`
  - ♻️ **Stale-lock recovery (TTL):** if a lock is left behind after a crash/kill, it’s automatically removed on the next run **only when the stored PID is not running** and the lock is older than `--max-random-delay-seconds` (TTL = `MAX_RANDOM_DELAY_SECONDS`)

- **Self-update (best-effort)**
  - The script checks the latest GitHub release and may update itself (git pull / tagged raw download)
  - Failures are logged and the run continues (no hard failure)
  - The updated script is used on the next run

---

## Installation (alternate layout)

If you prefer a system path (e.g. `/usr/local/sbin`):

1) Place the script:

~~~bash
sudo mkdir -p /usr/local/sbin
sudo cp netbird-delayed-update-macos.sh /usr/local/sbin/
sudo chmod +x /usr/local/sbin/netbird-delayed-update-macos.sh
~~~

2) Smoke-test a one-off run:

~~~bash
sudo /usr/local/sbin/netbird-delayed-update-macos.sh \
  --delay-days 0 \
  --max-random-delay-seconds 0 \
  --log-retention-days 60
~~~

3) Install the daily LaunchDaemon:

~~~bash
sudo /usr/local/sbin/netbird-delayed-update-macos.sh --install --run-at-load
~~~

---

## ⏰ Using the LaunchDaemon

### Defaults

Running:

~~~bash
sudo ./netbird-delayed-update-macos.sh --install --run-at-load
~~~

uses:

- `--daily-time "04:00"`
- ⏳ `--delay-days 10`
- 🎲 `--max-random-delay-seconds 3600`
- 🗂️ `--log-retention-days 60`
- `RunAtLoad=true`

### Custom schedule

~~~bash
sudo ./netbird-delayed-update-macos.sh --install --run-at-load \
  --delay-days 10 \
  --max-random-delay-seconds 1800 \
  --log-retention-days 30 \
  --daily-time "03:15" \
  --label "io.example.netbird-delayed-update"
~~~

---

## NetBird auto-start before user logon

### Enable auto-start (`--auto-start`)

- Run mode:

~~~bash
sudo ./netbird-delayed-update-macos.sh --auto-start
~~~

- Install mode (persisted into LaunchDaemon args):

~~~bash
sudo ./netbird-delayed-update-macos.sh --install --run-at-load --auto-start
~~~

If `netbird` is not in `PATH`, the script logs a message and continues.

### Remove auto-start (`--uninstall`)

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall
~~~

Also remove state/logs:

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall --remove-state
~~~

---

## Manual / one-shot runs

~~~bash
sudo ./netbird-delayed-update-macos.sh \
  --delay-days 10 \
  --max-random-delay-seconds 0 \
  --log-retention-days 60 \
  --auto-start
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
(Replace the label if you installed with `--label`.)

### “Another instance appears to be running” / lock behaviour
The script uses a lock under `/var/lib/netbird-delayed-update/.lock` to avoid overlapping executions.

- A normal run may sleep up to `--max-random-delay-seconds` (random jitter) **while holding the lock**.
- If a previous run crashed and left the lock behind, the script will automatically remove it on the next run **only if the stored PID is not running** and the lock age is at least `--max-random-delay-seconds`.

Manual (last resort) lock removal:

~~~bash
sudo rm -rf /var/lib/netbird-delayed-update/.lock
~~~

Tip: for immediate manual testing, set jitter to zero:

~~~bash
sudo ./netbird-delayed-update-macos.sh --max-random-delay-seconds 0
~~~

---

## Limitations with FileVault / full-disk encryption

If **FileVault** is enabled:

- After a cold boot/reboot, you get a FileVault unlock screen
- Until the disk is unlocked:
  - macOS is not fully running
  - `launchd` jobs do not run
  - ✅ **no VPN (including NetBird) can run**

So:

- You cannot rely on NetBird being reachable immediately after a cold boot on a FileVault-encrypted Mac
- ✅ Things work only after someone unlocks the disk and macOS finishes booting

For true headless behaviour after power-on, you need either:

- a system without full-disk encryption, or
- to keep the machine running and avoid full reboots (sleep/hibernate instead).

---

## Command-line reference

### Modes
- `--install` — install the LaunchDaemon
- `--uninstall` — uninstall the LaunchDaemon and remove NetBird daemon auto-start
- *(no mode)* — run one cycle and exit

### Options
- ⏳ `--delay-days N` (default: `10`)
- 🎲 `--max-random-delay-seconds N` (default: `3600`)
- 🗂️ `--log-retention-days N` (default: `60`, set `0` to disable cleanup)
- ⏰ `--daily-time "HH:MM"` (default: `04:00`)
- 🏷️ `--label NAME` (default: `io.nethorror.netbird-delayed-update`)
- `--auto-start` (`netbird service install/start`)
- `--run-at-load` (with `--install`)
- `--remove-state` (with `--uninstall`)
- `--help`

---

## State and logs

Everything lives under:

- `/var/lib/netbird-delayed-update/state.json`
- `/var/lib/netbird-delayed-update/netbird-delayed-update-*.log`
- `/var/lib/netbird-delayed-update/launchd.log`

