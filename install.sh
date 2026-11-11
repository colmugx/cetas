#!/usr/bin/env bash
# Install the native Cetas CLI. With a controlling TTY, ask for confirmation
# before downloading release assets or changing the installation directory.
set -euo pipefail

REPO="${CETAS_REPO:-colmugx/cetas}"
INSTALL_DIR="${CETAS_INSTALL_DIR:-$HOME/.local/bin}"
VERSION=""
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --version X.Y.Z   install a specific release (default: latest Cetas release)
  --dir DIR         install into DIR (default: $CETAS_INSTALL_DIR or ~/.local/bin)
  -y, --yes         skip confirmation (for automated installs)
  -h, --help        print this help

macOS arm64 and Linux x64: installs cetas, cetas-acp, cetas-run.
Windows x64 (Git Bash/MSYS2): installs those three .exe files plus cetas_moon.dll.
For native Windows PowerShell use install.ps1 instead.

Requires a terminal for confirmation unless --yes is specified.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --dir) INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

SYSTEM="$(uname -s)"
MACHINE="$(uname -m)"
case "$SYSTEM" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  *) printf 'unsupported operating system: %s\n' "$SYSTEM" >&2; exit 1 ;;
esac
case "$MACHINE" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=x64 ;;
  *) printf 'unsupported architecture: %s\n' "$MACHINE" >&2; exit 1 ;;
esac
TARGET="$os-$arch"
case "$TARGET" in
  darwin-arm64|linux-x64|windows-x64) ;;
  *) printf 'no native release for %s\n' "$TARGET" >&2; exit 1 ;;
esac

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '%s is required\n' "$1" >&2
    exit 1
  }
}
need install
if [[ "$os" == windows ]]; then need unzip; else need tar; fi

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fL --retry 3 --connect-timeout 15 -sS "$1" -o "$2"; }
  fetch_stdout() { curl -fL --retry 3 --connect-timeout 15 -sS "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
  fetch_stdout() { wget -qO- "$1"; }
else
  printf 'curl or wget is required\n' >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum -c "$1"; }
elif command -v shasum >/dev/null 2>&1; then
  checksum() { shasum -a 256 -c "$1"; }
else
  printf 'sha256sum or shasum is required\n' >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  # The repository publishes other release families; choose only cetas-v tags.
  listing="$(fetch_stdout "https://api.github.com/repos/$REPO/releases?per_page=30")"
  tag="$(printf '%s' "$listing" | grep -m1 -oE '"tag_name"[[:space:]]*:[[:space:]]*"cetas-v[0-9]+\.[0-9]+\.[0-9]+"' | sed -E 's/.*"(cetas-v[^"]+)"/\1/' || true)"
  if [[ -z "$tag" ]]; then
    printf 'cannot resolve latest Cetas release; pass --version X.Y.Z\n' >&2
    exit 1
  fi
  VERSION="${tag#cetas-v}"
fi
VERSION="${VERSION#cetas-v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'invalid version: %s (expected X.Y.Z)\n' "$VERSION" >&2
  exit 2
fi

TAG="cetas-v$VERSION"
BASE_URL="https://github.com/$REPO/releases/download/$TAG"
release_metadata="$(fetch_stdout "https://api.github.com/repos/$REPO/releases/tags/$TAG")"

if [[ "$os" == windows ]]; then
  files=(cetas.exe cetas-acp.exe cetas-run.exe cetas_moon.dll)
  assets=(cetas-windows-x64.zip)
else
  files=(cetas cetas-acp cetas-run)
  assets=("cetas-$TARGET.tar.gz" "cetas-acp-$TARGET.tar.gz" "cetas-run-$TARGET.tar.gz")
fi

# Fail before asking for approval if this version has no package for the host.
for asset in "${assets[@]}"; do
  if ! printf '%s' "$release_metadata" | grep -Fq "\"name\": \"$asset\""; then
    printf 'Cetas %s does not publish %s; no installation attempted\n' "$VERSION" "$asset" >&2
    exit 1
  fi
done

printf '\nCetas Native installation plan\n'
printf '  System:       %s (%s)\n' "$SYSTEM" "$MACHINE"
printf '  Target:       %s\n' "$TARGET"
printf '  Version:      %s\n' "$VERSION"
printf '  Repository:   %s\n' "$REPO"
printf '  Destination:  %s\n' "$INSTALL_DIR"
printf '  Release:      %s\n' "$BASE_URL"
printf '  Archives:\n'
printf '    %s\n' "${assets[@]}"
printf '  Files to install:\n'
for name in "${files[@]}"; do
  if [[ -e "$INSTALL_DIR/$name" ]]; then
    printf '    %s (will replace existing file)\n' "$name"
  else
    printf '    %s\n' "$name"
  fi
done
if [[ "$os" == windows ]]; then
  printf '  DLL loading:  cetas_moon.dll must remain beside cetas.exe\n'
fi
printf '\n'

if (( ! ASSUME_YES )); then
  # /dev/tty still works when the script is piped from curl into bash.
  if ! { exec 3<> /dev/tty; } 2>/dev/null; then
    printf 'no interactive terminal; installation cancelled (use --yes for automation)\n' >&2
    exit 1
  fi
  printf 'Proceed with installation? [y/N]: ' >&3
  response=""
  IFS= read -r response <&3 || true
  exec 3>&- 3<&-
  response="${response%$'\r'}"
  case "$response" in
    y|Y|yes|YES|Yes) ;;
    *) printf 'Installation cancelled; no files changed.\n'; exit 0 ;;
  esac
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fetch "$BASE_URL/SHA256SUMS" "$tmp/SHA256SUMS"
for asset in "${assets[@]}"; do
  printf 'Downloading %s\n' "$asset"
  fetch "$BASE_URL/$asset" "$tmp/$asset"
  # Select exactly the requested asset from the release checksum manifest.
  if ! awk -v expected="$asset" '
    {
      file = $2
      sub(/^\*/, "", file)
      if (file == expected && $1 ~ /^[0-9a-fA-F]+$/ && length($1) == 64) {
        print $1 "  " expected
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "$tmp/SHA256SUMS" > "$tmp/$asset.sum"; then
    printf 'missing SHA256 checksum for %s\n' "$asset" >&2
    exit 1
  fi
  (cd "$tmp" && checksum "$asset.sum")
done

mkdir -p "$tmp/unpacked"
if [[ "$os" == windows ]]; then
  unzip -j -qq "$tmp/${assets[0]}" "${files[@]}" -d "$tmp/unpacked"
else
  for name in "${files[@]}"; do
    tar -xzf "$tmp/$name-$TARGET.tar.gz" -C "$tmp/unpacked" "$name"
  done
fi
for name in "${files[@]}"; do
  if [[ ! -f "$tmp/unpacked/$name" || -L "$tmp/unpacked/$name" ]]; then
    printf 'invalid release payload: %s\n' "$name" >&2
    exit 1
  fi
done

mkdir -p "$INSTALL_DIR"
for name in "${files[@]}"; do
  if [[ "$name" == *.dll ]]; then
    install -m 0644 "$tmp/unpacked/$name" "$INSTALL_DIR/$name"
  else
    install -m 0755 "$tmp/unpacked/$name" "$INSTALL_DIR/$name"
  fi
done

printf '\nInstalled Cetas Native %s into %s\n' "$VERSION" "$INSTALL_DIR"
if [[ "$os" == windows ]]; then
  "$INSTALL_DIR/cetas.exe" --version
  "$INSTALL_DIR/cetas.exe" acp --version
  "$INSTALL_DIR/cetas.exe" run --version
else
  "$INSTALL_DIR/cetas" --version
  "$INSTALL_DIR/cetas" acp --version
  "$INSTALL_DIR/cetas" run --version
fi

existing="$(command -v cetas || true)"
if [[ -n "$existing" && "$existing" != "$INSTALL_DIR/cetas" && "$existing" != "$INSTALL_DIR/cetas.exe" ]]; then
  printf 'warning: PATH resolves cetas to %s, not the new installation\n' "$existing"
fi
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) printf 'note: %s is not currently on PATH\n' "$INSTALL_DIR" ;;
esac
