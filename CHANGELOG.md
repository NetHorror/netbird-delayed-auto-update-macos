## [0.2.0] - 2026-11-08

### ✨ Added

* 📦 NetBird client detection and first install: if `netbird` is missing, a terminal run asks `NetBird not found. Install now? [Y/n]`; `--install-client` installs without asking; under launchd only a `WARNING` is logged (exit 0). Install via `brew install netbirdio/tap/netbird` (as the Homebrew owner) or, without Homebrew, the official pkg after a `NetBird GmbH` signature check. **A first install takes the current latest version; the delay applies only to updates.**
* 🚫 `--no-self-update` disables script self-update (also written into the LaunchDaemon when given with `--install`).

### 🔒 Security

* 🔁 Self-update rewritten: it downloads the `netbird-delayed-update-macos.sh` and `SHA256SUMS` assets of the latest GitHub release (tag must be `X.Y.Z` and newer), verifies the sha256 and `SCRIPT_VERSION`, keeps a `.bak-<timestamp>` backup, and swaps the file atomically (`755`, `root:wheel`). `git pull` as root and the raw-by-tag download are removed.
* 📦 The pkg path checks the `NetBird GmbH` signature and the matured version before `installer` runs; Homebrew upgrades only when the formula offers exactly the matured version.
* 🗂️ `--install` copies the script to `/usr/local/sbin/netbird-delayed-update-macos.sh` (`root:wheel`) and the LaunchDaemon runs that copy.

### 🔄 Changed

* 🏷️ Header `# Version:` now matches `SCRIPT_VERSION` (CI checks it).
* ✅ CI: `--help` check; smoke test runs with `--no-self-update` and asserts the missing-client `WARNING` without installing anything.

## [0.1.6] - 2026-08-12

### 🐛 Fixed

* 🧹 `--uninstall --remove-state` could report a false failure (exit code 1): the final "Uninstall complete." log line was written *after* the state/logs directory was deleted, so its `tee` into the now-missing log file failed under `pipefail`. The completion log line now runs before the directory is removed.

### 🔄 Changed

* ✅ CI ShellCheck step now only fails on `error`-severity findings, so pre-existing style/warning-level notes don't block the pipeline.

## [0.1.5] - 2026-08-12

### ✨ Added

* 🤖 CI workflow (GitHub Actions): syntax check, ShellCheck, an install/uninstall LaunchDaemon smoke test, and a check that release tags match `SCRIPT_VERSION`.
* 🔗 `README.md` cross-links to the Windows and Linux sibling projects.

## [0.1.4] - 2025-12-14

### ✨ Added

* 🔒 Concurrency protection (lock) to prevent overlapping executions (e.g., launchd + manual run).
* ♻️ Stale-lock recovery (TTL = `--max-random-delay-seconds`): if a lock is left behind after a crash/kill, it’s automatically removed on the next run **only when the PID is not running** and the lock is older than the TTL.
* 🌐 curl wrapper with timeouts and retries for upstream checks, pkg downloads, and self-update checks.
* 🧾 Size cap for `launchd.log` to prevent unbounded growth.
* 🔁 Self-update can now actually update the script (tries `git pull --ff-only`, otherwise downloads the tagged raw script and replaces itself). **Best-effort:** failures are logged and the script continues without aborting the run.

### 🔄 Changed

* 🧠 More robust local version parsing: extracts a clean `X.Y.Z` token from `netbird version` output.
* 🧮 Version comparison hardened to handle leading zeros safely.
* 🕒 Candidate “age in days” is computed from actual run time (works correctly with random jitter).
* ✅ `--daily-time` validation tightened.
* 🧷 In `--install` mode, `--auto-start` is persisted into the installed LaunchDaemon arguments.
* 🧰 `PATH` handling improved: preserves existing `PATH` order and appends common macOS locations (better compatibility and testability).
* 📝 README updated: Quick start moved to the top and documentation adjusted for the changes above.

### 🐛 Fixed

* 🧹 Lock cleanup reliability under `set -u` (prevents stale locks caused by trap scope/variable issues).
* 📦 PKG download now uses a secure temporary file (`mktemp`) instead of a fixed `/tmp/netbird.pkg` path.



## [0.1.3] - 2025-12-10

### ✨ Added
- 🧷 `-as` / `--auto-start` flag:
  - 🛠️ Ensures the NetBird daemon is installed as a system service (`netbird service install`).
  - ▶️ Starts the NetBird daemon (`netbird service start`).
  - 🔁 Works both in one-shot (`run`) mode and together with `--install`.
- 🧰 `disable_netbird_auto_start()` helper:
  - ⏹️ Stops the NetBird daemon (`netbird service stop`).
  - 🗑️ Uninstalls the NetBird daemon service (`netbird service uninstall`).

### 🔄 Changed
- 🧹 `--uninstall` mode now:
  - 🧩 Unloads and removes the launchd plist.
  - 🧷 Always attempts to remove NetBird system auto-start via `disable_netbird_auto_start()`.
- 📝 README and release notes:
  - 🚀 Quick start explicitly uses `--install --run-at-load` for better laptop behavior.
  - ⏳ `--delay-days` default is documented as `10`.
  - 🔒 Auto-start behavior and FileVault limitations are documented in more detail.

## [0.1.2] - 2025-12-09

### ✨ Added
- 🍺 Homebrew-aware upgrade:
  - 🔍 Detects whether NetBird is installed via Homebrew.
  - 👤 Runs `brew upgrade` as the Homebrew owner user.
  - 🧩 Supports both `netbirdio/tap/netbird` and `netbird` formulas.
- 📦 macOS pkg-based upgrade:
  - 🖥️ Detects standard GUI/pkg installations.
  - ⬇️ Downloads and installs the latest macOS `.pkg` from `pkgs.netbird.io`.
  - 🔄 Restarts the NetBird service after upgrade.
- 🔁 Script self-update:
  - 🏷️ Checks the latest GitHub release of this repository.
  - ⬇️ Downloads and replaces the local script when a newer version is available.
- 🧾 Log retention:
  - 🗂️ Per-run logs are written to `/var/lib/netbird-delayed-update/netbird-delayed-update-*.log`.
  - 🧹 `--log-retention-days` controls how long logs are kept.

### 🔄 Changed
- 🧪 Refined delayed rollout / aging logic and version detection.
- 🛡️ Improved state handling and robustness when `state.json` is missing or malformed.

## [0.1.1] - 2025-11-30

### ✨ Added
- 🔁 `-r` / `--run-at-load` flag for install mode:
  - 🚀 When used with `--install`, sets `RunAtLoad=true` in the launchd plist.
  - 🕒 Ensures a run happens at boot if the scheduled time was missed (e.g., laptop was off).

### 🔄 Changed
- 🧰 Improved launchd friendliness:
  - ➕ Ensured `/opt/homebrew/bin` and `/usr/local/bin` are included in `PATH` when running under launchd as root.
  - 📝 Updated README with clearer installation and testing steps.

## [0.1.0] - 2025-11-30

### ✨ Added
- 🚀 Initial implementation of delayed NetBird auto-update for macOS:
  - 🕒 Daily launchd job that checks for new NetBird versions at a configured time.
  - ⏳ Version aging: candidate must stay unchanged for `--delay-days` days before rollout.
  - 🎲 Optional random jitter (`--max-random-delay-seconds`) to spread task execution.
  - 🧠 State tracking in `/var/lib/netbird-delayed-update/state.json`.
  - 🧾 Detailed per-run logs in `/var/lib/netbird-delayed-update/`.
  - 🧩 Single script supports:
    - 🧱 `--install` / `-i` (install LaunchDaemon)
    - 🗑️ `--uninstall` / `-u` (remove LaunchDaemon)
    - ▶️ run mode (delayed-update logic)
- 🧷 Install behavior improved: `--auto-start` is now persisted into the installed LaunchDaemon.
- 🧰 PATH handling improved for better compatibility across environments.
