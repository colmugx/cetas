#!/usr/bin/env bash
# Real Cetas core: MoonBit source -> captured generated C -> Rust/GPUI binary.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GPUI="$ROOT/cetas-gpui"
WEB="$ROOT/cetas-web"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "This POC is macOS arm64 only" >&2; exit 1;
}
export MOON_HOME="${MOON_HOME:-$HOME/.moon}"
export MOONBIT_NEW_NATIVE=0
export CETAS_MOON_CAPTURE="$GPUI/generated"
export MOON_CC_CAPTURE_DIR="$CETAS_MOON_CAPTURE"
rm -rf "$CETAS_MOON_CAPTURE"
mkdir -p "$CETAS_MOON_CAPTURE"
original="$WEB/server/moon.pkg"
backup="$(mktemp)"
cp "$original" "$backup"
restore() { cp "$backup" "$original"; rm -f "$backup"; }
trap restore EXIT INT TERM

# Do not commit or permanently mutate cetas-web's build metadata.
python3 - "$original" "$GPUI/scripts/moon_cc_capture.py" <<'PY'
from pathlib import Path
import json, sys
pkg = Path(sys.argv[1])
source = pkg.read_text()
needle = 'pkgtype(kind: "executable")'
assert source.count(needle) == 1, "unexpected cetas-web/server moon.pkg"
shim = json.dumps(str(Path(sys.argv[2]).resolve()))
pkg.write_text(source.replace(needle, needle + '\noptions(link: { "native": { "cc": ' + shim + ' } })'))
PY
(
 cd "$WEB"
 moon update
 moon build --target native --release
)
restore
trap - EXIT INT TERM
test -s "$CETAS_MOON_CAPTURE/sources.txt" || {
  echo "MoonBit generated-C capture failed" >&2; exit 1;
}
# This is not a subprocess backend: Cargo compiles every generated C source
# and the final macOS binary includes MoonBit code and its runtime.
export MACOSX_DEPLOYMENT_TARGET=15.0
cargo build --manifest-path "$GPUI/Cargo.toml" --release --target aarch64-apple-darwin
exe="$GPUI/target/aarch64-apple-darwin/release/cetas-gpui"
test -x "$exe"
app="$GPUI/dist/Cetas.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$exe" "$app/Contents/MacOS/Cetas"
cp "$GPUI/Info.plist" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
echo "Created $app"
