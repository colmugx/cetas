#!/usr/bin/env python3
"""Offline first-run API-key smoke using a disposable home and test credential.

This exercises the REAL MoonBit provider login path, file credential store,
Agent recomposition and process restart. It does not make an LLM request or
use a real API key.
"""
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

from pty_bootstrap_smoke import BINARY, ROOT

DUMMY_KEY = "sk-cetas-native-alpha-offline-fixture"


def launch(home):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 108, 0, 0))
    def acquire_tty():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    env = dict(os.environ, CETAS_HOME=str(home), TERM="xterm-256color", NO_COLOR="1")
    proc = subprocess.Popen([str(BINARY)], cwd=ROOT, stdin=slave,
                            stdout=slave, stderr=slave, env=env,
                            preexec_fn=acquire_tty)
    os.close(slave)
    return proc, master


def read_until(proc, master, output, condition, *, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition(bytes(output)):
            return
        if proc.poll() is not None:
            raise AssertionError(f"offline bootstrap exited early: {output[-2400:]!r}")
        ready, _, _ = select.select([master], [], [], .10)
        if ready:
            try:
                output.extend(os.read(master, 65536))
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
        if b"\x1b[?1049h" in output and not getattr(proc, "_probed", False):
            os.write(master, b"\x1b[?2026;2$y\x1b[?2027;2$y\x1b[?0u")
            os.killpg(proc.pid, signal.SIGWINCH)
            proc._probed = True
    raise TimeoutError(f"offline bootstrap condition not reached: {output[-3000:]!r}")


def clean_exit(proc, master, output):
    os.write(master, b"\x03")
    deadline = time.monotonic() + 20
    while proc.poll() is None and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], .10)
        if ready:
            try:
                output.extend(os.read(master, 65536))
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
    if proc.poll() is None:
        raise TimeoutError("Ctrl+C did not drain native bootstrap")
    if proc.returncode != 0 or b"\x1b[?1049l" not in output:
        raise AssertionError(f"terminal was not restored: {output[-1500:]!r}")


def one_run(home, *, setup):
    proc, master = launch(home)
    output = bytearray()
    try:
        read_until(proc, master, output, lambda b: b"\x1b[?1049h" in b)
        if setup:
            read_until(proc, master, output,
                       lambda b: b"First-run setup" in b and b"openai" in b)
            # Core's static factory order is DeepSeek, Kimi, OpenAI. Choose
            # the third provider rather than relying on the cursor default.
            os.write(master, b"\x1b[B\x1b[B\r")
            # OpenAI exposes BOTH OAuth and API key in Posoco. Choose the
            # first method explicitly; sending a key to this picker would
            # otherwise be interpreted as selection keystrokes.
            read_until(proc, master, output,
                       lambda b: b"api_key" in b and b"oauth" in b)
            os.write(master, b"\r")
            read_until(proc, master, output,
                       lambda b: b"OpenAI API key" in b)
            os.write(master, DUMMY_KEY.encode() + b"\r")
        read_until(
            proc, master, output,
            # Bubble Tea can redraw only the changed session ID via a cursor
            # move rather than painting the full "session: ID" line again.
            lambda b: re.search(rb"cetas-[0-9]{8,}", b) is not None and b" ready  |" in b,
            timeout=45,
        )
        if DUMMY_KEY.encode() in output:
            raise AssertionError("test credential leaked into terminal output")
        clean_exit(proc, master, output)
        return bytes(output)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        os.close(master)


def main():
    if not BINARY.is_file():
        raise FileNotFoundError(BINARY)
    with tempfile.TemporaryDirectory(prefix="cetas-alpha-offline-login-") as base:
        home = Path(base)
        one_run(home, setup=True)
        credential = home / ".cetas" / "credentials" / "openai.json"
        if not credential.is_file():
            raise AssertionError("provider login did not persist the tagged credential")
        # Restart with the SAME isolated home: no first-run picker this time.
        output = one_run(home, setup=False)
        if b"First-run setup" in output:
            raise AssertionError("restart unexpectedly entered provider setup")
        print("Offline first-run login: credential persisted; Agent recomposed and restarted OK")


if __name__ == "__main__":
    main()
