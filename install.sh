#!/usr/bin/env bash
# One-line installer for netbird-delayed-update-macos.
#   curl -fsSL https://github.com/NetHorror/netbird-delayed-auto-update-macos/releases/download/0.2.0/install.sh | sudo bash
# Downloads the script and SHA256SUMS of the same release, verifies the hash,
# then runs the script with --install --install-client.
set -euo pipefail

VER="${NB_DELAYED_VERSION:-0.2.0}"
BASE="${NB_DELAYED_BASE:-https://github.com/NetHorror/netbird-delayed-auto-update-macos/releases/download/${VER}}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is for macOS." >&2
  exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "This installer must run as root: curl -fsSL <url>/install.sh | sudo bash" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

echo "Downloading netbird-delayed-update-macos ${VER}..."
curl -fsSLO "${BASE}/netbird-delayed-update-macos.sh"
curl -fsSLO "${BASE}/SHA256SUMS"

echo "Verifying SHA-256..."
# macOS ships shasum, not sha256sum.
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c SHA256SUMS --ignore-missing
else
  shasum -a 256 -c SHA256SUMS --ignore-missing
fi

echo "Installing (LaunchDaemon + NetBird client if missing)..."
bash ./netbird-delayed-update-macos.sh --install --install-client
