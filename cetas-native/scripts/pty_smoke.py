#!/usr/bin/env python3
"""Run the MoonBit smoke executable behind a minimal terminal protocol harness.

A PTY alone is not a terminal emulator. Crossterm asks the terminal for the
cursor position with CSI 6 n while Ratatui initializes an inline viewport.
GitHub Actions has no emulator attached to a raw PTY, so this harness answers
that query, provides a deterministic 80x24 window, and injects terminal input
after the resumed terminal enables focus reporting.
"""

import errno
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

QUERY_CURSOR_POSITION = b"\x1b[6n"
CURSOR_POSITION_RESPONSE = b"\x1b[24;1R"
ENABLE_FOCUS = b"\x1b[?1004h"
FOCUS_IN = b"\x1b[I"
BRACKETED_PASTE = b"\x1b[200~cetas-paste\x1b[201~"
KEY_Q = b"q"
TIMEOUT_SECONDS = 60


def main() -> int:
    pid, fd = pty.fork()

    if pid == 0:
        os.environ.setdefault("TERM", "xterm-256color")
        os.execvp(
            "moon",
            ["moon", "run", "src", "--target", "native", "--release"],
        )

    fcntl.ioctl(
        fd,
        termios.TIOCSWINSZ,
        struct.pack("HHHH", 24, 80, 0, 0),
    )

    deadline = time.monotonic() + TIMEOUT_SECONDS
    scan_tail = b""
    status = None
    focus_enable_count = 0
    input_injected = False

    while status is None:
        if time.monotonic() >= deadline:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
            print("PTY smoke timed out", file=sys.stderr)
            return 124

        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(fd, 4096)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                data = b""

            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()

                scan = scan_tail + data

                queries = scan.count(QUERY_CURSOR_POSITION)
                for _ in range(queries):
                    os.write(fd, CURSOR_POSITION_RESPONSE)

                new_focus_enables = scan.count(ENABLE_FOCUS)
                focus_enable_count += new_focus_enables

                # First enable is the initial open. The second is resume.
                # Inject only after resume so the smoke can prove that event
                # modes are restored as part of the terminal lifecycle.
                if focus_enable_count >= 2 and not input_injected:
                    input_injected = True
                    os.write(fd, FOCUS_IN)
                    os.write(fd, BRACKETED_PASTE)
                    os.write(fd, KEY_Q)
                    # Crossterm's Unix resize source is SIGWINCH. Keep the
                    # width changes from 80 to 81 so Crossterm receives a real Resize
                    # event; the MoonBit smoke asserts the resized viewport.
                    fcntl.ioctl(
                        fd,
                        termios.TIOCSWINSZ,
                        struct.pack("HHHH", 24, 81, 0, 0),
                    )
                    os.kill(pid, signal.SIGWINCH)

                keep = max(len(QUERY_CURSOR_POSITION), len(ENABLE_FOCUS)) - 1
                scan_tail = scan[-keep:]
            else:
                scan_tail = b""

        waited_pid, raw_status = os.waitpid(pid, os.WNOHANG)
        if waited_pid == pid:
            status = raw_status

    if not input_injected:
        print("PTY smoke never observed resumed focus reporting", file=sys.stderr)
        return 125

    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
