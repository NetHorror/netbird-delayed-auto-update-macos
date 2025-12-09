# NetBird Delayed Auto-Update for macOS

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![Platform: macOS](https://img.shields.io/badge/platform-macOS-informational) ![Init: launchd](https://img.shields.io/badge/init-launchd-blue) ![Shell: bash](https://img.shields.io/badge/shell-bash-green)

Helper script that implements **delayed / staged** updates for the NetBird client on macOS.

Instead of upgrading to the latest available version immediately, new versions must "age" for a configurable number of days before they are installed. Short-lived or broken releases that are quickly replaced will never reach your machine.

This project mirrors the behaviour of the Windows delayed update script but is tailored to macOS (launchd, `/usr/local/bin`, `/opt/homebrew/bin`, pkg/app vs Homebrew, etc.).

Current script version: **0.1.2**

---

## Features

- **Delayed rollout (version aging)**
  - New NetBird versions become "candidates".
  - A candidate must stay unchanged for `--delay-days` days before upgrade is allowed.
  - State is stored in a small JSON file under:
    ~~~text
    /var/lib/netbird-delayed-update/state.json
    ~~~

- **Supports multiple installation types**
  - Works with NetBird installed via:
    - the official macOS installer (`.pkg` / `/Applications/NetBird.app`), or
    - Homebrew (`netbirdio/tap/netbird` or `netbird`), or
    - other custom CLI-only setups.
  - Automatically selects the appropriate update mechanism:
    - **Homebrew** → `brew upgrade` as the Homebrew owner user.
    - **pkg/app** → downloads and installs the latest macOS `.pkg` from `https://pkgs.netbird.io/macos/<arch>` using `installer`.

- **Safe CLI detection**
  - Ensures `/opt/homebrew/bin` and `/usr/local/bin` are part of `PATH` even when launched by `launchd` as root.
  - Uses `netbird version` to read the local version before and after upgrade.

- **Log files with retention**
  - Logs are written to:
    ~~~text
    /var/lib/netbird-delayed-update/netbird-delayed-update-*.log
    ~~~
  - `--log-retention-days` (default: `60`) controls how long to keep old logs.
  - `--log-retention-days 0` disables log cleanup.

- **Script self-update (optional)**
  - On each run, the script checks the latest GitHub release of this repository.
  - If a newer version exists, it:
    - runs `git pull --ff-only` when inside a git repository, or
    - downloads `netbird-delayed-update-macos.sh` from the tagged version on `raw.githubusercontent.com` and overwrites the local file.
  - The new script is used on the next run.

- **Launchd-friendly**
  - `--install` / `--uninstall` to manage a root launchd daemon.
  - Configurable run time (`--daily-time "HH:MM"`).
  - Optional `RunAtLoad` flag (`-r` / `--run-at-load`) to run once when the machine boots.

---

## Requirements

- macOS with a working `bash` and `curl`.
- NetBird installed either via:
  - the official macOS installer (`.pkg` / `/Applications/NetBird.app`), or
  - Homebrew (`netbirdio/tap/netbird` or `netbird`), or
  - another supported CLI installation.
- Root privileges (via `sudo`) to:
  - install / uninstall the launchd daemon,
  - run the delayed-update script in production.

---

## Installation

1. Clone or download this repository:

   ~~~bash
   git clone https://github.com/NetHorror/netbird-delayed-auto-update-macos.git
   cd netbird-delayed-auto-update-macos
   ~~~

2. Make sure the script is executable:

   ~~~bash
   chmod +x ./netbird-delayed-update-macos.sh
   ~~~

3. (Optional) Test a one-off run with no delay and no random jitter:

   ~~~bash
   sudo ./netbird-delayed-update-macos.sh \
     --delay-days 0 \
     --max-random-delay-seconds 0 \
     --log-retention-days 60
   ~~~

You should see log output mentioning the local NetBird version and the latest version from `pkgs.netbird.io`. The full log file is stored under:

~~~text
/var/lib/netbird-delayed-update/netbird-delayed-update-YYYYMMDD-HHMMSS.log
~~~

---

## Installing the launchd daemon

To install a daily check with default settings:

- delay: 10 days  
- random jitter: up to 3600 seconds  
- time: 04:00 UTC  
- log retention: 60 days  

run:

~~~bash
sudo ./netbird-delayed-update-macos.sh --install
~~~

To customise the schedule and settings:

~~~bash
sudo ./netbird-delayed-update-macos.sh --install \
  --delay-days 10 \
  --max-random-delay-seconds 3600 \
  --log-retention-days 60 \
  --daily-time "04:00" \
  -r
~~~

This will:

- create `/Library/LaunchDaemons/io.nethorror.netbird-delayed-update.plist`;
- schedule the script to run daily at the specified time;
- configure `RunAtLoad` (if `-r` is used), so a run happens soon after boot if the scheduled time was missed;
- log stdout/stderr to `/var/lib/netbird-delayed-update/launchd.log`.

---

## Uninstalling the launchd daemon

To remove only the launchd job:

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall
~~~

To also remove state and logs under `/var/lib/netbird-delayed-update`:

~~~bash
sudo ./netbird-delayed-update-macos.sh --uninstall --remove-state
~~~

---

## Behaviour details

### Where state and logs are stored

All runtime files live under:

~~~text
/var/lib/netbird-delayed-update/
~~~

- `state.json` – delayed rollout state:
  - `CandidateVersion`
  - `FirstSeenUtc`
  - `LastCheckUtc`
- `netbird-delayed-update-*.log` – per-run logs.
- `launchd.log` – stdout/stderr from the launchd daemon.

### Delayed rollout logic

On each run (either manual or via launchd), the script:

1. Ensures NetBird CLI is available in `PATH` (`netbird` must resolve).
2. Reads the local version:
   ~~~bash
   netbird version
   ~~~
3. Fetches the latest available version from:
   ~~~text
   https://pkgs.netbird.io/releases/latest
   ~~~
   and extracts a `vX.Y.Z` tag, which is normalised to `X.Y.Z`.
4. Loads `state.json`. If the candidate version changed compared to the last run:
   - updates `CandidateVersion` and resets `FirstSeenUtc` to now.
5. Computes the age (in days) of the candidate:
   - age is clamped to at least 0 days (no negative values on clock skew).
6. If `age < delayDays`:
   - logs that the version is still aging and **does not** upgrade.
7. If the candidate has aged enough:
   - compares local vs candidate version semantically;
   - if local is older:
     - determines installation type:
       - **Homebrew**: runs a `brew upgrade` as the Homebrew owner user;
       - **pkg/app/other**: downloads the latest macOS `.pkg` and installs it via `installer`;
     - restarts the NetBird service via `netbird service stop/start`.

---

## Script self-update

In run mode, the script first checks whether there is a newer version of itself:

1. Queries the GitHub API for the latest release of this repo.
2. Parses the tag name (expected `X.Y.Z`).
3. Compares it with `SCRIPT_VERSION` defined near the top.

If a newer version exists:

- If the script lives inside a git repository and `git` is available:
  - `git pull --ff-only` is executed in the repo root.
- Otherwise:
  - the script is downloaded from:

    ~~~text
    https://raw.githubusercontent.com/NetHorror/netbird-delayed-auto-update-macos/<tag>/netbird-delayed-update-macos.sh
    ~~~

  - and overwrites the local file.

The current run continues with the old version; the next run will use the updated script.

To disable self-update, set:

~~~bash
SELFUPDATE_REPO=""
~~~

inside `netbird-delayed-update-macos.sh`.

---

## Versioning

This project uses semantic versioning:

- **0.1.2** – script self-update, log retention, robust version detection, and support for both Homebrew and macOS pkg/app NetBird installations.
- **0.1.1** – ensured NetBird CLI is visible under launchd/root via PATH adjustments.
- **0.1.0** – initial delayed-update implementation + launchd integration.

See [`CHANGELOG.md`](./CHANGELOG.md) for details.
