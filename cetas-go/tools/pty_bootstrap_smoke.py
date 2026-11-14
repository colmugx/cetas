#!/usr/bin/env python3
"""Real first-run PTY smoke: empty CETAS_HOME must reach Provider picker.

No secrets or network access are required. The real MoonBit bootstrap
resolves auth capabilities; the UI must remain alive and restore its TTY.
"""
import errno
import fcntl
import signal
import struct
import termios
import os
import pty
import select
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "_build" / "cetas-go"


def wait_until(proc, master, output, needle, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if needle in output:
            return
        if proc.poll() is not None:
            raise AssertionError(
                f"first-run process exited before {needle!r}: {output[-1800:]!r}"
            )
        ready, _, _ = select.select([master], [], [], 0.10)
        if ready:
            try:
                output.extend(os.read(master, 65536))
            except OSError as e:
                if e.errno != errno.EIO:
                    raise
        if b"\x1b[?1049h" in output and not getattr(proc, "_probed", False):
            # A headless PTY does not implement Bubble Tea's capability
            # queries. Reply as an unsupported xterm and force a resize so
            # the renderer can make its first visible frame.
            os.write(master, b"\x1b[?2026;2$y\x1b[?2027;2$y\x1b[?0u")
            os.killpg(proc.pid, signal.SIGWINCH)
            proc._probed = True
    raise TimeoutError(f"first-run picker not rendered: {output[-2500:]!r}")


def main():
    if not BINARY.is_file():
        raise FileNotFoundError(BINARY)
    with tempfile.TemporaryDirectory(prefix="cetas-first-run-") as isolated:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 108, 0, 0))
        def acquire_tty():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        env = dict(os.environ, CETAS_HOME=isolated, TERM="xterm-256color",
                   NO_COLOR="1")
        proc = subprocess.Popen([str(BINARY)], cwd=ROOT, stdin=slave,
                                stdout=slave, stderr=slave, env=env,
                                preexec_fn=acquire_tty)
        os.close(slave)
        output = bytearray()
        try:
            wait_until(proc, master, output, b"\x1b[?1049h")
            wait_until(proc, master, output, b"First-run setup")
            wait_until(proc, master, output, b"openai")
            if b"startup failed" in output:
                raise AssertionError("empty-home startup was rejected")
            os.write(master, b"\x03")
            deadline = time.monotonic() + 20
            while proc.poll() is None and time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.15)
                if ready:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError as e:
                        if e.errno != errno.EIO:
                            raise
            if proc.poll() is None:
                raise TimeoutError("Ctrl+C failed to stop first-run setup")
            if proc.returncode != 0 or b"\x1b[?1049l" not in output:
                raise AssertionError(
                    f"first-run terminal failed restoration: {output[-2000:]!r}"
                )
            print("Fresh-home bootstrap: real provider picker and terminal restoration OK")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            os.close(master)


if __name__ == "__main__":
    main()
