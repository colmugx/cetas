#!/usr/bin/env python3
"""Build the cgo bridge archive from Moon's foreign-library output.

Moon's native backend links the generated bridge C, the MoonBit runtime and
every dependency stub into one static archive; this script runs that build,
copies the artifact to go_bridge/lib and verifies the symbols cgo imports.
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
BRIDGE_PATH = "cetas-native/native_bridge"
PACKAGE = "colmugx/cetas-native/native_bridge"
ARCHIVE = ROOT / "go_bridge/lib/libcetas_moon.a"
REQUIRED_SYMBOLS = ("cetas_infra_run", "moonbit_init", "moonbit_runtime_init")


def moon_archive():
    command = ["moon", "build", BRIDGE_PATH, "--target", "native", "--release",
               "--output-json"]
    print("+", " ".join(command), flush=True)
    proc = subprocess.run(command, cwd=WORKSPACE, check=True,
                          capture_output=True, text=True, encoding="utf-8")
    artifacts = []
    for line in proc.stdout.splitlines():
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (message.get("$message_type") == "artifact"
                and message.get("package") == PACKAGE
                and str(message.get("path", "")).endswith(".a")):
            artifacts.append(Path(message["path"]))
    if not artifacts:
        raise RuntimeError(f"moon produced no foreign-library artifact for {PACKAGE}")
    return artifacts[0]


def verify(archive):
    nm = shutil.which("llvm-nm") if sys.platform == "win32" else shutil.which("nm")
    if not nm:
        raise RuntimeError("nm not found (llvm-nm on Windows)")
    symbols = subprocess.run([nm, "-g", str(archive)], capture_output=True,
                             text=True, check=True).stdout
    missing = [s for s in REQUIRED_SYMBOLS if s not in symbols]
    if missing:
        raise RuntimeError("bridge archive missing symbols: " + ", ".join(missing))


def main():
    built = moon_archive()
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    ARCHIVE.unlink(missing_ok=True)
    shutil.copy2(built, ARCHIVE)
    verify(ARCHIVE)
    print(f"Static MoonBit archive: {ARCHIVE}, from {built}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        for stream in (e.stdout, e.stderr):
            if stream:
                sys.stderr.write(stream)
        print(f"Cetas static build failed: {e}", file=sys.stderr)
        sys.exit(1)
    except (OSError, RuntimeError) as e:
        print(f"Cetas static build failed: {e}", file=sys.stderr)
        sys.exit(1)
