# NetBird Delayed Auto-Update for macOS

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![Platform: macOS](https://img.shields.io/badge/platform-macOS-informational) ![Init: launchd](https://img.shields.io/badge/init-launchd-blue) ![Shell: bash](https://img.shields.io/badge/shell-bash-green)

This project provides a delayed (staged) auto-update mechanism for the NetBird client on macOS.

Instead of upgrading immediately when a new version is published, the script waits until the same
version has been available in the upstream repository for a configurable number of days. Short-lived
or broken releases that get replaced quickly will never reach your machines.

The script supports both Homebrew-based NetBird installs and the official macOS `.pkg` installer,
and can optionally ensure that the NetBird daemon starts before any user logon.

Current script version: **0.1.3** (unreleased, trunk).

## Features

- **Delayed rollout window**

  - New NetBird versions become *candidates*.
  - A candidate must remain unchanged for `--delay-days` days before automatic upgrade is allowed.
  - Default: **10 days**.
  - State is stored under `/var/lib/netbird-delayed-update/state.json`.

- **Supports multiple installation types**

  - Homebrew installations (`netbirdio/tap/netbird` or `netbird` formulas).
  - Official macOS `.pkg` / GUI installations (`/Applications/NetBird.app`).
  - Other CLI-only setups where `netbird` is in `PATH`.

- **Automatic version detection**

  - Reads local version via `netbird version`.
  - Fetches latest upstream version from `https://pkgs.netbird.io/releases/latest`.

- **Launchd integration**

  - Installs a system `LaunchDaemon` which runs once per day at a configurable time.
  - Optional `RunAtLoad` behaviour (`-r` / `--run-at-load`) for laptops and machines that are
    often powered off at night.

- **NetBird daemon auto-start before logon**

  - `-as` / `--auto-start` ensures the NetBird daemon is installed as a system service and started
    so that connectivity is available before anyone logs in.
  - `-u` / `--uninstall` also stops and uninstalls the NetBird daemon service to remove system
    auto-start.

- **Self-updating helper**

  - On each run, the script checks the latest GitHub release of this repository.
  - If the tagged version is newer than the local `SCRIPT_VERSION`, the script can download and
    replace itself with the new release.

- **Logs and retention**

  - Per-run logs: `/var/lib/netbird-delayed-update/netbird-delayed-update-YYYYMMDD-HHMMSS.log`.
  - Launchd output: `/var/lib/netbird-delayed-update/launchd.log`.
  - Old logs are pruned based on `--log-retention-days` (default **60 days**).

---

## Quick start

This is the shortest way to get a daily delayed-update job running with reasonable defaults:

1. Clone the repository (or copy the script):

   ~~~bash
   git clone https://github.com/NetHorror/netbird-delayed-auto-update-macos.git
   cd netbird-delayed-auto-update-macos
   chmod +x ./netbird-delayed-update-macos.sh
   ~~~

2. Install the LaunchDaemon with default schedule **and** `RunAtLoad` enabled:

   ~~~bash
   sudo ./netbird-delayed-update-macos.sh --install -r
   ~~~

   This will:

   - Install `/Library/LaunchDaemons/io.nethorror.netbird-delayed-update.plist`.
   - Schedule a daily run at `04:00` (system time).
   - Allow a random jitter of up to `3600` seconds before each check.
   - Keep logs for `60` days.
   - Run the job once at boot as well (because of `-r`), in case the machine was off at 04:00.

3. (Optional) Ensure NetBird daemon starts before user logon:

   ~~~bash
   sudo ./netbird-delayed-update-macos.sh --install -r --auto-start
   ~~~

   In addition to the LaunchDaemon installation, this will:

   - Run `netbird service install`.
   - Run `netbird service start`.

---

## Installation (alternate layout)

If you prefer to place the script into a system-wide directory (e.g. `/usr/local/sbin`):

1. Download and install the script:

   ~~~bash
   sudo mkdir -p /usr/local/sbin
   sudo cp netbird-delayed-update-macos.sh /usr/local/sbin/
   sudo chmod +x /usr/local/sbin/netbird-delayed-update-macos.sh
   ~~~

2. Test a one-off run (no delay, no random jitter):

   ~~~bash
   sudo /usr/local/sbin/netbird-delayed-update-macos.sh \
     --delay-days 0 \
     --max-random-delay-seconds 0 \
     --log-retention-days 60
   ~~~

   This should log the local NetBird version, the latest upstream version, and record state under:

   - `/var/lib/netbird-delayed-update/state.json`
   - `/var/lib/netbird-delayed-update/netbird-delayed-update-*.log`

3. To install the daily LaunchDaemon from that location:

   ~~~bash
   sudo /usr/local/sbin/netbird-delayed-update-macos.sh --install -r
   ~~~

---

## Using the LaunchDaemon

### Defaults

When you run:

~~~bash
sudo ./netbird-delayed-update-macos.sh --install -r
~~~

the following defaults are used:

- `--delay-days 10` — the candidate version must age for 10 days.
- `--max-random-delay-seconds 3600` — up to 1 hour random jitter.
- `--daily-time "04:00"` — scheduled time.
- `--log-retention-days 60` — keep logs for 60 days.
- `RunAtLoad=true` — one run at boot in addition to the daily schedule.

### Customising the schedule

You can override any of the defaults when installing the daemon:

~~~bash
sudo ./netbird-delayed-update-macos.sh --install -r \
  --delay-days 10 \
  --max-random-delay-seconds 1800 \
  --log-retention-days 30 \
  --daily-time "03:15" \
  --label "io.example.netbird-delayed-update"
~~~

This will generate a corresponding `LaunchDaemon` plist under `/Library/LaunchDaemons/`.

---

## NetBird auto-start before user logon

The script can optionally manage the NetBird daemon service for you.

### Enabling auto-start (`-as` / `--auto-start`)

- In **run mode**, using `-as` will ensure the NetBird daemon service is installed and started:

  ~~~bash
  sudo ./netbird-delayed-update-macos.sh --auto-start
  ~~~

- In **install mode**, combining `--install` and `--auto-start`:

  ~~~bash
  sudo ./netbird-delayed-update-macos.sh --install -r --auto-start
  ~~~

  will:

  - Install / update the LaunchDaemon, and
  - Call `netbird service install` + `netbird service start`.

If `netbird` is not in `PATH`, the script logs a message and continues without failing.

### Removing auto-start (`-u` / `--uninstall`)

When you uninstall the LaunchDaemon, the script also removes the NetBird system daemon auto-start:

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall
~~~

Internally, this calls:

- `netbird service stop`
- `netbird service uninstall`

so that NetBird no longer starts at boot before user logon.

To additionally remove the state/logs directory:

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall --remove-state
~~~

---

## Manual / one-shot runs

You can run the delayed-update logic once, without touching launchd:

~~~bash
sudo ./netbird-delayed-update-macos.sh \
  --delay-days 10 \
  --max-random-delay-seconds 0 \
  --log-retention-days 60 \
  --auto-start
~~~

This will:

- Self-update the script (if a newer release exists).
- Ensure NetBird daemon auto-start is configured (`--auto-start`).
- Perform the delayed rollout logic and upgrade NetBird when conditions are met.

---

## Command-line reference

### Modes

- `-i`, `--install`  
  Install the `LaunchDaemon` that runs the delayed update daily.

- `-u`, `--uninstall`  
  Uninstall the `LaunchDaemon` **and** remove NetBird system daemon auto-start.

- *(no mode)*  
  Run a single delayed-update cycle and exit.

### Options

- `--delay-days N`  
  Minimal aging time for a new candidate version, in days.  
  Default: `10`.

- `--max-random-delay-seconds N`  
  Random jitter (0–N seconds) added before each run.  
  Default: `3600`.

- `--log-retention-days N`  
  Number of days to keep log files in `/var/lib/netbird-delayed-update`.  
  Default: `60` (use `0` to disable cleanup).

- `--daily-time "HH:MM"`  
  Time of day when the LaunchDaemon should run.  
  Default: `04:00`.

- `--label NAME`  
  LaunchDaemon label.  
  Default: `io.nethorror.netbird-delayed-update`.

- `-as`, `--auto-start`  
  Ensure NetBird daemon is installed and configured to start at boot (`netbird service install/start`).

- `-r`, `--run-at-load`  
  When used with `--install`, sets `RunAtLoad=true` in the LaunchDaemon plist so that the job
  runs once at boot.

- `--remove-state`  
  With `--uninstall`: also remove `/var/lib/netbird-delayed-update`.

- `-h`, `--help`  
  Show help and exit.

---

## State and logs

All runtime data lives under:

- `/var/lib/netbird-delayed-update/state.json`
- `/var/lib/netbird-delayed-update/netbird-delayed-update-*.log`
- `/var/lib/netbird-delayed-update/launchd.log`

---
