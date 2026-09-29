#!/usr/bin/env python3
"""Prepare the temporary cetas-memoh development workspace.

posoco-extension modules used by cetas-memoh are not yet published to the
Moon registry. Pin their source revision locally until they are publishable.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / ".deps"
EXTENSION = DEPS / "posoco-extension"
REV_FILE = ROOT / "EXTENSION_REV"
WORK_FILE = ROOT / "moon.work"
REMOTE = "https://github.com/colmugx/posoco-extension.git"
MEMBER = re.compile(r'^\s*"\./([^"]+)"')


def run(*args: str, cwd: Path | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def main() -> None:
    rev = REV_FILE.read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", rev):
        raise SystemExit(f"invalid EXTENSION_REV: {rev!r}")

    DEPS.mkdir(exist_ok=True)
    if not (EXTENSION / ".git").exists():
        run("git", "clone", "--filter=blob:none", REMOTE, str(EXTENSION))
    run("git", "fetch", "--depth=1", "origin", rev, cwd=EXTENSION)
    run("git", "checkout", "--detach", rev, cwd=EXTENSION)

    source = (EXTENSION / "moon.work").read_text().splitlines()
    members = []
    for line in source:
        match = MEMBER.match(line)
        if match:
            members.append(
                f'  "./.deps/posoco-extension/{match.group(1)}",'
            )
    if not members:
        raise SystemExit("posoco-extension/moon.work contained no members")

    WORK_FILE.write_text(
        "members = [\n"
        '  ".",\n'
        + "\n".join(members)
        + "\n]\n"
    )
    print(f"prepared cetas-memoh workspace with posoco-extension {rev}")


if __name__ == "__main__":
    main()
