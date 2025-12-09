# Changelog

All notable changes to this project will be documented in this file.  
This project uses semantic versioning (MAJOR.MINOR.PATCH).

## [0.1.2] – 2025-12-09

### Added

- **Support for multiple NetBird installation types on macOS**:
  - Detects whether `netbird` comes from Homebrew (`.../Cellar/netbird/...`) or from a pkg/app installation (`/Applications/NetBird.app/...` symlinked from `/usr/local/bin/netbird`), or from a custom location.
  - For Homebrew-based installations:
    - determines the owner user of the `brew` binary;
    - runs `brew upgrade` as that user to update either `netbirdio/tap/netbird` or `netbird`, depending on which formula is installed.
  - For pkg/app installations:
    - resolves the latest macOS installer URL from `https://pkgs.netbird.io/macos/<arch>`;
    - downloads the `.pkg` and installs it via the macOS `installer` tool.
  - In all cases the NetBird service is stopped before the upgrade and restarted afterwards.

- **Log retention**:
  - New option: `--log-retention-days` (default: `60`).
  - Log files `netbird-delayed-update-*.log` in `/var/lib/netbird-delayed-update/` older than the configured number of days are removed on each run.
  - `--log-retention-days 0` disables log cleanup.

- **Script self-update**:
  - Queries the latest GitHub release of `NetHorror/netbird-delayed-auto-update-macos`.
  - Parses the release tag (`X.Y.Z`) and compares it to `SCRIPT_VERSION` (`0.1.2`).
  - If a newer version exists:
    - tries `git pull --ff-only` when the script lives inside a git repository;
    - otherwise downloads `netbird-delayed-update-macos.sh` from the tagged version on `raw.githubusercontent.com` and overwrites the local file.
  - The new script is used on the next run.

### Changed

- **Version detection**:
  - Latest NetBird version is obtained from `https://pkgs.netbird.io/releases/latest`.
  - The script extracts a `vX.Y.Z` tag from the JSON response, normalises it to `X.Y.Z` and compares it with the local version from `netbird version`.

- **Age calculation**:
  - Age (in days) between `FirstSeenUtc` and the current time is clamped to a minimum of `0` days to avoid negative values if system time moves backwards.
  - The delayed rollout logic uses the clamped value.

### Fixed

- Removed reliance on `install.sh --update` on macOS, which refused to update pkg-based installations.
- Ensured that both Homebrew and pkg-based NetBird installations can be upgraded automatically by the script.

---

## [0.1.1] – 2025-12-08

### Fixed

- Ensured `netbird` CLI is visible when the script is run as root via launchd:
  - Extended `PATH` to include `/opt/homebrew/bin` and `/usr/local/bin`.
  - Prevented the script from incorrectly logging `netbird CLI not found in PATH` when NetBird is actually installed.

---

## [0.1.0] – 2025-12-08

### Added

- Initial delayed auto-update implementation for NetBird on macOS:
  - Queries local version via `netbird version`.
  - Queries latest available version and treats it as a "candidate".
  - Stores candidate version and first-seen timestamp in `/var/lib/netbird-delayed-update/state.json`.
  - Only upgrades once the candidate has "aged" for at least `--delay-days` days.
- Launchd integration:
  - `--install` / `--uninstall` to create/remove a root launchd daemon.
  - Daily schedule at a configurable time (`--daily-time`).
- Basic logging to `/var/lib/netbird-delayed-update/netbird-delayed-update-*.log`.
