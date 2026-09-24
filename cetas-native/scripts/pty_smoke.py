#!/usr/bin/env python3
"""Run the MoonBit smoke executable behind a minimal terminal protocol harness.

A PTY alone is not a terminal emulator. Crossterm asks the terminal for the
cursor position with CSI 6 n while Ratatui initializes an inline viewport.
GitHub Actions has no emulator attached to a raw PTY, so this harness answers
that query and provides a deterministic 80x24 window.
"""

import errno
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

QUERY_CURSOR_POSITION = b"\x1b[6n"
CURSOR_POSITION_RESPONSE = b"\x1b[24;1R"
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
    tail = b""
    status = None

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

                scan = tail + data
                queries = scan.count(QUERY_CURSOR_POSITION)
                for _ in range(queries):
                    os.write(fd, CURSOR_POSITION_RESPONSE)
                tail = scan[-(len(QUERY_CURSOR_POSITION) - 1) :]
            else:
                tail = b""

        waited_pid, raw_status = os.waitpid(pid, os.WNOHANG)
        if waited_pid == pid:
            status = raw_status

    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
