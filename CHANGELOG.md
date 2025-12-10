All notable changes to this project will be documented in this file.

## [0.1.3] – 2025-12-10

### Added

- `-as` / `--auto-start` flag:

  - Ensures the NetBird daemon is installed as a system service (`netbird service install`).
  - Starts the NetBird daemon (`netbird service start`).
  - Can be used in both one-shot (`run`) mode and together with `--install`.

- `disable_netbird_auto_start()` helper:

  - Stops the NetBird daemon (`netbird service stop`).
  - Uninstalls the NetBird daemon service (`netbird service uninstall`).

### Changed

- `--uninstall` mode now:

  - Unloads and removes the launchd plist.
  - Always attempts to remove the NetBird system auto-start by calling
    `disable_netbird_auto_start()`.

- README and release notes:

  - Quick start explicitly uses `--install --run-at-load` for better laptop behaviour.
  - `--delay-days` default is documented as `10` days.
  - Auto-start behaviour (`-as` / `--auto-start` and `-u` / `--uninstall`) and FileVault
    limitations are described in more detail.

## [0.1.2] – 2025-12-09

### Added

- Homebrew-aware upgrade:

  - Detects whether NetBird is installed via Homebrew.
  - Runs `brew upgrade` as the Homebrew owner user.
  - Supports both `netbirdio/tap/netbird` and `netbird` formulas.

- macOS pkg-based upgrade:

  - Detects standard GUI/pkg installations.
  - Downloads and installs the latest macOS `.pkg` from `pkgs.netbird.io`.
  - Restarts the NetBird service after upgrade.

- Script self-update:

  - Checks the latest GitHub release of this repository.
  - Downloads and replaces the local script when a newer version is available.

- Log retention:

  - Per-run logs are written to `/var/lib/netbird-delayed-update/netbird-delayed-update-*.log`.
  - `--log-retention-days` controls how long logs are kept.

### Changed

- Refined delayed rollout / aging logic and version detection.
- Improved state handling and robustness when `state.json` is missing or malformed.

## [0.1.1] – 2025-11-30

### Added

- `-r` / `--run-at-load` flag for install mode:

  - When used with `--install`, sets `RunAtLoad=true` in the launchd plist.
  - Ensures a run happens at boot if the scheduled time was missed (e.g. laptop was off).

### Changed

- Improved launchd friendliness:

  - Ensured `/opt/homebrew/bin` and `/usr/local/bin` are included in `PATH` when running
    under launchd as root.
  - Updated README with clearer installation and testing steps.

## [0.1.0] – 2025-11-30

### Added

- Initial implementation of delayed NetBird auto-update for macOS:

  - Daily launchd job that checks for new NetBird versions at a configured time.
  - Version aging: candidate version must stay unchanged for a configurable number of days
    (`--delay-days`) before rollout.
  - Optional random jitter (`--max-random-delay-seconds`) to spread task execution.
  - State tracking in `/var/lib/netbird-delayed-update/state.json`.
  - Detailed per-run logs in `/var/lib/netbird-delayed-update/`.
  - Single script responsible for:
    - `--install` / `-i` (install LaunchDaemon),
    - `--uninstall` / `-u` (remove LaunchDaemon),
    - run mode (delayed-update logic).

