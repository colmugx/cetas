#!/usr/bin/env bash
# Install the native Cetas trio from a GitHub release:
#   cetas      terminal UI, and the `cetas acp` / `cetas run` entry points
#   cetas-acp  editor / ACP host
#   cetas-run  one-turn native runner
# The three must live in the same directory: `cetas acp` hands the process over
# to the sibling binary, it does not search far and wide for a stand-in.
set -euo pipefail

REPO="${CETAS_REPO:-colmugx/cetas}"
INSTALL_DIR="${CETAS_INSTALL_DIR:-$HOME/.local/bin}"
VERSION=""

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --version X.Y.Z   install a specific release (default: the latest one)
  --dir DIR         install into DIR (default: $CETAS_INSTALL_DIR or ~/.local/bin)
  -h, --help        this help

Installs cetas, cetas-acp and cetas-run. Supports macOS arm64 and Linux x64.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --dir) INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *)
    echo "cetas native supports macOS and Linux; $(uname -s) has no build yet." >&2
    echo "The JS host (npm i -g @posoco/cetas) does run there." >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=x64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# The release matrix publishes darwin-arm64 and linux-x64 only.
if [[ "$os" == darwin && "$arch" != arm64 ]] || [[ "$os" == linux && "$arch" != x64 ]]; then
  echo "no $os-$arch build; published targets are darwin-arm64 and linux-x64" >&2
  exit 1
fi
TARGET="$os-$arch"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 is required" >&2; exit 1; }
}
need tar
need uname

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fL --retry 3 --connect-timeout 15 -sS "$1" -o "$2"; }
  fetch_stdout() { curl -fL --retry 3 --connect-timeout 15 -sS "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
  fetch_stdout() { wget -qO- "$1"; }
else
  echo "curl or wget is required" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum -c "$1"; }
elif command -v shasum >/dev/null 2>&1; then
  checksum() { shasum -a 256 -c "$1"; }
else
  echo "sha256sum or shasum is required" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  # Newest tag that looks like a cetas release: the repo also publishes
  # cetas-memoh-v* releases, so "latest release" alone would pick the wrong one.
  body="$(fetch_stdout "https://api.github.com/repos/$REPO/releases?per_page=30" || true)"
  tag="$(printf '%s' "$body" | grep -o '"tag_name": *"cetas-v[0-9][^"]*"' | head -1 | sed 's/.*"\(cetas-v[^"]*\)"/\1/')"
  if [[ -z "$tag" ]]; then
    echo "could not resolve the latest cetas release tag; pass --version X.Y.Z" >&2
    exit 1
  fi
  VERSION="${tag#cetas-v}"
fi
VERSION="${VERSION#cetas-v}"
TAG="cetas-v$VERSION"
BASE_URL="https://github.com/$REPO/releases/download/$TAG"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Installing cetas $VERSION ($TARGET)"
fetch "$BASE_URL/SHA256SUMS" "$tmp/SHA256SUMS"

for name in cetas cetas-acp cetas-run; do
  asset="$name-$TARGET.tar.gz"
  echo "  $asset"
  fetch "$BASE_URL/$asset" "$tmp/$asset"
  grep -E "^[0-9a-fA-F]{64}[[:space:]]+\*?$asset$" "$tmp/SHA256SUMS" > "$tmp/$asset.sum" || {
    echo "no checksum for $asset in SHA256SUMS" >&2
    exit 1
  }
  ( cd "$tmp" && checksum "$asset.sum" )
done

mkdir -p "$INSTALL_DIR"
for name in cetas cetas-acp cetas-run; do
  tar -xzf "$tmp/$name-$TARGET.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/$name" "$INSTALL_DIR/$name"
done

# The npm package @posoco/cetas also installs a `cetas` command (the JS host).
# Whichever directory comes first on PATH wins, so say it out loud.
existing="$(command -v cetas || true)"
if [[ -n "$existing" && "$existing" != "$INSTALL_DIR/cetas" ]]; then
  echo
  echo "warning: PATH resolves cetas to $existing (probably the npm JS host)."
  echo "         Put $INSTALL_DIR first on PATH to run the native one."
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo; echo "note: $INSTALL_DIR is not on PATH yet." ;;
esac

for name in cetas cetas-acp cetas-run; do
  "$INSTALL_DIR/$name" --version
done
echo "Installed into $INSTALL_DIR"
