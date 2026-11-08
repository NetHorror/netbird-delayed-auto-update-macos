#!/usr/bin/env bash
# One-line installer for netbird-delayed-update-macos.
#   curl -fsSL https://github.com/NetHorror/netbird-delayed-auto-update-macos/releases/download/0.2.0/install.sh | sudo bash
# Downloads the script and SHA256SUMS of release 0.2.0, verifies the SHA-256 hash,
# then runs the script with --install --install-client (extra arguments are passed on).
main() {
  set -euo pipefail
  local VER=0.2.0
  local NAME=netbird-delayed-update-macos.sh
  local BASE="https://github.com/NetHorror/netbird-delayed-auto-update-macos/releases/download/${VER}"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This installer is for macOS." >&2
    exit 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: curl -fsSL <url>/install.sh | sudo bash" >&2
    exit 1
  fi

  NBTMP="$(mktemp -d)"
  trap 'rm -rf "$NBTMP"' EXIT
  cd "$NBTMP"

  echo "Downloading ${NAME} ${VER}..."
  curl -fsSL -o "$NAME" "${BASE}/${NAME}"
  curl -fsSL -o SHA256SUMS "${BASE}/SHA256SUMS"

  echo "Verifying SHA-256..."
  local LINE
  LINE="$(grep -E "[[:space:]*]${NAME}\$" SHA256SUMS | head -n1 || true)"
  if [[ -z "$LINE" ]]; then
    echo "No checksum for ${NAME} in SHA256SUMS; nothing installed." >&2
    exit 1
  fi
  printf '%s\n' "$LINE" > check.txt
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c check.txt; else shasum -a 256 -c check.txt; fi

  echo "Installing (systemd timer + NetBird client if missing)..."
  bash ./"$NAME" --install --install-client "$@" </dev/null
}
main "$@"
