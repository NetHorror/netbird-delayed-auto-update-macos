# NetBird Delayed Auto-Update for macOS (launchd)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![Platform: macOS](https://img.shields.io/badge/platform-macOS-informational) ![Init: launchd](https://img.shields.io/badge/init-launchd-blue) ![Shell: bash](https://img.shields.io/badge/shell-bash-green)

Delayed (staged) auto-update for the NetBird client on macOS.

> Don’t upgrade NetBird clients immediately when a new NetBird version appears.  
> Instead, wait **N days**. If that version is quickly replaced (bad release / hotfix),  
> clients will **never** upgrade to it.

---

## Idea

* A **candidate** NetBird version must “age” for **N days** before being deployed.
* If the same version stays available for `DelayDays` without changes, the installed client is upgraded.
* If a **newer** version appears during the aging period, the timer is reset and we start counting again.
* NetBird is **not auto-installed** – only upgraded if it is already installed locally.
* Uses `launchd` to run a small bash script once per day.

State and logs are stored in:

~~~text
/var/lib/netbird-delayed-update/
~~~

`state.json` keeps the “aging” state, logs go into timestamped `netbird-delayed-update-*.log` files.

---

## How updates are performed (predictable variant)

This script uses the **official NetBird installer**:

- It queries the latest version from `https://pkgs.netbird.io/releases/latest`.
- When it decides to upgrade, it downloads `install.sh` from `https://pkgs.netbird.io/install.sh`
  and runs it with `--update`.

This is the same mechanism that NetBird documents for macOS, and it automatically picks the
correct build for **Intel** and **Apple Silicon (M1/M2/M3)**.

---

## Features

- ⏳ **Version aging** – only upgrades after a candidate version has been stable for `DelayDays`.
- 🕓 **Daily launchd job** – runs once per day at a configurable time (default: `04:00`).
- 🎲 **Optional random delay** – spreads the actual execution time over a random window (`MaxRandomDelaySeconds`).
- 🧱 **Local state tracking** – remembers last seen candidate version and when it was first observed.
- 🛑 **No silent install** – if NetBird is not installed, the script exits without doing anything.
- 📜 **Detailed logs** – logs each decision (first seen, still aging, upgraded, already up-to-date, etc.).
- 🧩 **Single script** – one bash script handles install, uninstall and the actual update logic.

---

## Requirements

- macOS with `launchd` (обычная современная macOS)
- `bash` (встроенный в macOS)
- `curl`
- NetBird already installed (e.g. via the official `install.sh` or pkg)
- `sudo` / root access for:
  - installing/removing launchd daemons,
  - running updates.

NetBird install docs for macOS: https://docs.netbird.io/get-started/install/macos

---

## Repository structure

~~~text
netbird-delayed-auto-update-macos/
├─ README.md
├─ LICENSE
└─ netbird-delayed-update-macos.sh
~~~

---

## Quick start

Clone the repository and install the daily launchd job:

~~~bash
git clone https://github.com/NetHorror/netbird-delayed-auto-update-macos.git
cd netbird-delayed-auto-update-macos

# Default: DelayDays=3, MaxRandomDelaySeconds=3600, time 04:00
sudo ./netbird-delayed-update-macos.sh --install
# or shorter:
# sudo ./netbird-delayed-update-macos.sh -i
~~~

After successful installation, you should see a launchd daemon with label:

~~~text
io.nethorror.netbird-delayed-update
~~~

Check status:

~~~bash
sudo launchctl list | grep netbird-delayed-update
sudo launchctl print system/io.nethorror.netbird-delayed-update 2>/dev/null || true
~~~

The job is configured to run once per day at `04:00` (plus optional random delay).

---

## Installation options

The script has three modes:

- **Install mode** – `--install` / `-i`  
  Creates or updates the launchd plist and loads it.
- **Uninstall mode** – `--uninstall` / `-u`  
  Unloads and removes the launchd plist (optionally state/logs).
- **Run mode** – no `--install` / `--uninstall`  
  Performs a single delayed-update check. This is what launchd uses.

### Install parameters

Examples:

~~~bash
# Wait 5 days, no random delay, run at 03:30
sudo ./netbird-delayed-update-macos.sh -i \
  --delay-days 5 \
  --max-random-delay-seconds 0 \
  --daily-time "03:30"

# Custom launchd label (if you run multiple variants)
sudo ./netbird-delayed-update-macos.sh -i --label io.nethorror.netbird-delayed-update-custom
~~~

Supported options:

- `--delay-days N` – how many days a new NetBird version must stay unchanged before upgrade  
  (default: `3`).
- `--max-random-delay-seconds N` – max random delay added after the scheduled start time  
  (default: `3600` seconds).
- `--daily-time "HH:MM"` – time of day (24h) when launchd should start the job  
  (default: `04:00`).
- `--label NAME` – launchd label (default: `io.nethorror.netbird-delayed-update`).

---

## How it works (details)

Once per day, launchd runs:

~~~text
/var/root/path/to/netbird-delayed-update-macos.sh \
  --delay-days <DelayDays> \
  --max-random-delay-seconds <MaxRandomDelaySeconds>
~~~

On each run, the script:

1. Optionally sleeps for a **random delay** between `0` and `MaxRandomDelaySeconds` seconds.
2. Verifies that `netbird` CLI is available in `PATH`.
3. Reads the **local NetBird version** via:

   ~~~bash
   netbird version
   ~~~

4. Queries the **latest available version** from:

   ~~~bash
   curl -fsSL https://pkgs.netbird.io/releases/latest
   ~~~

   and extracts the `tag_name` (e.g. `v0.60.4` → `0.60.4`).

5. Loads `state.json` from `/var/lib/netbird-delayed-update/`:
   - candidate version (`CandidateVersion`),
   - when it was first seen (`FirstSeenUtc`),
   - when it was last checked (`LastCheckUtc`).

6. If a **new candidate version** appears:
   - updates `CandidateVersion`,
   - sets `FirstSeenUtc` to now,
   - starts the aging period.

7. Computes the **age in days** of the candidate version; if age `< DelayDays`:
   - logs that it is “still aging” and exits without upgrade.

8. If age `≥ DelayDays` and the **local version is older**:
   - logs the planned upgrade,
   - stops the NetBird service (via `netbird service stop`),
   - downloads the official installer and runs it:

     ~~~bash
     curl -fsSLO https://pkgs.netbird.io/install.sh
     chmod +x install.sh
     ./install.sh --update
     ~~~

   - starts the NetBird service again (`netbird service start`),
   - logs the new local version.

Short-lived or “bad” versions that are quickly replaced in the NetBird repo are **never** deployed to your clients,  
because they do not survive the `DelayDays` aging period.

---

## launchd notes

Launchd does not show “exit codes” as nicely as `schtasks`, but you can inspect logs:

~~~bash
sudo launchctl print system/io.nethorror.netbird-delayed-update | sed -n '1,80p'
~~~

The script writes its own logs into `/var/lib/netbird-delayed-update/`, which is usually проще, чем пытаться
выковыривать всё из unified logging macOS.

---

## Manual one-off run (for testing)

You can run the delayed-update logic manually without touching launchd:

~~~bash
# Run immediately, no random delay, no "aging" period (for testing)
sudo ./netbird-delayed-update-macos.sh \
  --delay-days 0 \
  --max-random-delay-seconds 0
~~~

This will:

- perform all checks,
- log the decisions,
- update `state.json`,
- and, if needed, run the official `install.sh --update` to upgrade NetBird.

---

## Logs

Log files are stored in:

~~~text
/var/lib/netbird-delayed-update/
~~~

File names look like:

~~~text
netbird-delayed-update-YYYYMMDD-HHMMSS.log
~~~

You can review these logs to see:

- when a candidate version was first observed,
- how long it aged,
- when an upgrade actually happened,
- any warnings or errors (missing `netbird`, network failures, etc.).

---

## Uninstall

To remove the launchd job (but keep state/logs):

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall
# or shorter:
# sudo ./netbird-delayed-update-macos.sh -u
~~~

To remove both the job **and** the state/logs directory:

~~~bash
sudo ./netbird-delayed-update-macos.sh -u --remove-state
~~~

NetBird itself is **not** removed – only the delayed update mechanism.

---

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![Platform: macOS](https://img.shields.io/badge/platform-macOS-informational) ![Init: launchd](https://img.shields.io/badge/init-launchd-blue) ![Shell: bash](https://img.shields.io/badge/shell-bash-green)
