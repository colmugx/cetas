#!/usr/bin/env bash
set -euo pipefail

DEFAULT_VERSION="0.1.0"
REPO="${CETAS_MEMOH_REPO:-colmugx/cetas}"
VERSION="${1:-${CETAS_MEMOH_VERSION:-$DEFAULT_VERSION}}"
INSTALL_DIR="${CETAS_MEMOH_INSTALL_DIR:-$HOME/.local/bin}"
ASSET="cetas-memoh-linux-x64.tar.gz"
CHECKSUMS="SHA256SUMS-memoh"
TAG="cetas-memoh-v$VERSION"
BASE_URL="https://github.com/$REPO/releases/download/$TAG"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "cetas-memoh currently supports Linux only" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) ;;
  *)
    echo "cetas-memoh currently supports Linux x86_64 only (got $(uname -m))" >&2
    exit 1
    ;;
esac

command -v tar >/dev/null || { echo "tar is required" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "sha256sum is required" >&2; exit 1; }

if command -v curl >/dev/null; then
  fetch() { curl -fL --retry 3 --connect-timeout 15 "$1" -o "$2"; }
elif command -v wget >/dev/null; then
  fetch() { wget -qO "$2" "$1"; }
else
  echo "curl or wget is required" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading cetas-memoh $VERSION for Linux x86_64..."
fetch "$BASE_URL/$ASSET" "$tmp/$ASSET"
fetch "$BASE_URL/$CHECKSUMS" "$tmp/$CHECKSUMS"

(
  cd "$tmp"
  grep -E "^[0-9a-fA-F]{64}[[:space:]]+\*?$ASSET$" "$CHECKSUMS" > "$CHECKSUMS.selected"
  [[ -s "$CHECKSUMS.selected" ]] || {
    echo "checksum entry for $ASSET not found" >&2
    exit 1
  }
  sha256sum -c "$CHECKSUMS.selected"
  tar -xzf "$ASSET"
)

mkdir -p "$INSTALL_DIR"
install -m 0755 "$tmp/cetas-memoh" "$INSTALL_DIR/cetas-memoh"

echo "Installed $INSTALL_DIR/cetas-memoh"
"$INSTALL_DIR/cetas-memoh" --version
