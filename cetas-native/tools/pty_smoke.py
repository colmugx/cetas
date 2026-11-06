#!/usr/bin/env python3
"""Exercise the *real* Bubble Tea terminal under a pseudo-terminal.

This runs without credentials or model network traffic. It verifies terminal
ownership/restoration and Ctrl+C while MoonBit's task group is alive.
"""
import errno
import json
import os
import pty
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "_build" / "cetas-native-go"

def read_available(fd, seconds):
    readable, _, _ = select.select([fd], [], [], seconds)
    if not readable:
        return b""
    try:
        return os.read(fd, 65536)
    except OSError as exc:
        if exc.errno == errno.EIO:
            return b""
        raise

def main():
    if not BINARY.is_file():
        raise RuntimeError(f"native executable missing: {BINARY}")
    result = subprocess.run([str(BINARY), "--version"], capture_output=True,
                            text=True, timeout=5, check=True)
    expected = "cetas " + (ROOT / "VERSION").read_text().strip()
    if result.stdout.strip() != expected:
        raise AssertionError(f"--version {result.stdout.strip()!r} != {expected!r}")

    with tempfile.TemporaryDirectory(prefix="cetas-pty-") as home:
        settings_dir = Path(home) / ".cetas"
        settings_dir.mkdir()
        (settings_dir / "settings.json").write_text(json.dumps({
            "providers": {
                "native-ci": {
                    "base_url": "http://127.0.0.1:1/v1",
                    "model": "native-pty",
                    "api_key": "ci-only-not-secret"
                }
            }
        }))
        master, slave = pty.openpty()
        env = dict(os.environ, CETAS_HOME=home, TERM="xterm-256color",
                   NO_COLOR="1")
        proc = subprocess.Popen([str(BINARY)], cwd=ROOT, stdin=slave,
                                stdout=slave, stderr=slave, env=env,
                                start_new_session=True)
        os.close(slave)
        output = bytearray()
        started = time.monotonic()
        try:
            while time.monotonic() - started < 25:
                output.extend(read_available(master, 0.15))
                if b"\x1b[?1049h" in output:
                    break
                if proc.poll() is not None:
                    raise AssertionError(f"TUI exited before alt screen: {output[-1000:]!r}")
            else:
                raise TimeoutError(f"TUI never opened alternate screen: {output[-1000:]!r}")

            os.write(master, b"\x03")
            deadline = time.monotonic() + 20
            while proc.poll() is None and time.monotonic() < deadline:
                output.extend(read_available(master, 0.15))
            if proc.poll() is None:
                raise TimeoutError("Ctrl+C did not complete MoonBit shutdown")
            output.extend(read_available(master, 0.05))
            if proc.returncode != 0:
                raise AssertionError(f"TUI exit {proc.returncode}: {output[-1600:]!r}")
            if b"\x1b[?1049l" not in output:
                raise AssertionError(f"alternate screen was not restored: {output[-1600:]!r}")
            print("PTY lifecycle: alt-screen, Ctrl+C, Posoco shutdown and restore OK")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            os.close(master)

if __name__ == "__main__":
    sys.exit(main())
