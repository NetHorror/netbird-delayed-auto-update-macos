# Changelog

All notable changes to this project will be documented in this file.  
This project uses semantic versioning (MAJOR.MINOR.PATCH).

## [0.1.2] – 2025-12-09

### Added

- **Script self-update**:
  - Checks the latest GitHub release of `NetHorror/netbird-delayed-auto-update-macos`.
  - Compares `SCRIPT_VERSION` with the release tag (`X.Y.Z`).
  - If newer:
    - attempts `git pull --ff-only` when inside a git repository;
    - otherwise downloads `netbird-delayed-update-macos.sh` from the tagged version on `raw.githubusercontent.com` and overwrites the local script.
  - The new script is used on the next run.

- **Log retention**:
  - New option: `--log-retention-days` (default: 60).
  - Log files `netbird-delayed-update-*.log` in `/var/lib/netbird-delayed-update/` older than the configured number of days are removed on each run.
  - `--log-retention-days 0` disables log cleanup.

### Changed

- **Version detection**:
  - Latest NetBird version is now obtained from `https://pkgs.netbird.io/releases/latest`.
  - The script extracts a `vX.Y.Z` tag from the JSON response and normalises it to `X.Y.Z` before comparing with the local version from `netbird version`.

- **Age calculation**:
  - Age in days is clamped to a minimum of `0` to avoid negative values if system time moves backwards.
  - The delayed rollout logic uses the clamped value.

### Fixed

- Various robustness improvements and log message clean-ups.

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
