#!/usr/bin/env python3
"""Exercise real Bubble Tea keyboard decoding and approval/question UI in a PTY.

The Go helper uses the production model's Update and View and scripted
EventHub messages. The real MoonBit/Posoco approval policy is covered by
separate MoonBit tests; this test isolates the terminal input boundary.
"""
import errno
import fcntl
import json
import os
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "cetas-native"


def run_pty(trace_path: Path) -> bytes:
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 108, 0, 0))
    env = dict(os.environ, CETAS_PTY_UI_HELPER="1",
               CETAS_PTY_UI_TRACE=str(trace_path),
               TERM="xterm-256color", NO_COLOR="1")
    def acquire_tty():
        # The Go test opens /dev/tty through Bubble Tea. A PTY slave passed
        # as stdin is not enough on macOS: make it the controlling terminal.
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    proc = subprocess.Popen(
        ["go", "test", "-run", "^TestInteractivePTYApprovals$", "-count=1",
         "-v", "."],
        cwd=NATIVE, stdin=slave, stdout=slave, stderr=slave, env=env,
        preexec_fn=acquire_tty,
    )
    os.close(slave)
    output = bytearray()

    def until(marker: bytes, timeout: float = 40) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker in output:
                return
            if proc.poll() is not None:
                raise AssertionError(
                    f"PTY helper exited before {marker!r}: {output[-2500:]!r}"
                )
            readable, _, _ = select.select([master], [], [], .10)
            if readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        chunk = b""
                    else:
                        raise
                output.extend(chunk)
        raise TimeoutError(f"PTY did not render {marker!r}: {output[-2500:]!r}")

    try:
        until(b"Approve shell command?")
        # Two Down arrows select "Allow all shell commands", index 2.
        os.write(master, b"\x1b[B\x1b[B\r")
        until(b"CJK question: enter a response")
        os.write(master, "你好 Cetas".encode() + b"\r")
        until(b"PTY secret input")
        # Secret input must never be echoed in the full terminal transcript.
        os.write(master, b"credential-canary-123")
        # Observe at least one redraw before cancelling the secret.
        until("••••".encode())
        os.write(master, b"\x1b")
        until(b"Cancel this approval?")
        os.write(master, b"\x1b")
        until(b"Pending shutdown question")
        os.write(master, b"\x03")
        deadline = time.monotonic() + 25
        while proc.poll() is None and time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], .10)
            if readable:
                try:
                    output.extend(os.read(master, 65536))
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
        if proc.poll() is None:
            raise TimeoutError("PTY Ctrl+C failed to terminate Bubble Tea")
        if proc.returncode != 0:
            raise AssertionError(f"PTY helper failed: {output[-3500:]!r}")
        if b"credential-canary-123" in output or b"NEVER-PREFILL-ME" in output:
            raise AssertionError("secret credential leaked into PTY output")
        if b"\x1b[?1049h" not in output or b"\x1b[?1049l" not in output:
            raise AssertionError("Bubble Tea did not enter and restore alternate screen")
        replies = json.loads(trace_path.read_text())
        if [r["request_id"] for r in replies] != ["u-1", "u-2", "u-3", "u-4"]:
            raise AssertionError(f"wrong request order: {replies!r}")
        if replies[0].get("selected") != 2:
            raise AssertionError("shell approval did not select tool-wide grant")
        if replies[1].get("text") != "你好 Cetas":
            raise AssertionError("CJK question answer was damaged")
        if not replies[2].get("cancelled") or not replies[3].get("cancelled"):
            raise AssertionError("secret/question Esc did not cancel")
        print("PTY UI: approval, CJK, secret masking, cancellation, FIFO, stale dismissal and restore OK")
        return bytes(output)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        os.close(master)


def main():
    with tempfile.TemporaryDirectory(prefix="cetas-pty-ui-") as home:
        run_pty(Path(home) / "responses.json")


if __name__ == "__main__":
    main()
