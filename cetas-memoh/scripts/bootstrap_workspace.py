#!/usr/bin/env python3
"""Prepare the temporary standalone cetas-memoh workspace."""

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

# Minimal source-module closure required by cetas-memoh. Do not import the
# extension repository's full moon.work: unrelated modules must not participate
# in Memoh CI/release.
MEMBERS = (
    "posoco-devkit",
    "posoco-ext-acp",
    "posoco-ext-memoh",
    "posoco-ext-mcp",
    "posoco-ext-llm",
    "posoco-ext-credentials",
    "posoco-ext-oauth",
    "posoco-ext-workspace",
    "posoco-ext-permission",
    "posoco-ext-skills",
    "posoco-ext-askquestion",
    "posoco-ext-ratelimit",
    "posoco-ext-lazytools",
    "posoco-ext-deepseek",
    "posoco-ext-kimi",
    "posoco-ext-openai",
    "posoco-ext-openai-compatible",
    "posoco-ext-opencode-zen",
    "posoco-ext-openrouter",
    "posoco-ext-zai",
    "posoco-ext-zai-coding-plan",
    "posoco-kit-chat-completions",
    "posoco-kit-compact-evict",
    "posoco-kit-compact-summary",
    "posoco-kit-responses",
)


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

    missing = [name for name in MEMBERS if not (EXTENSION / name / "moon.mod").is_file()]
    if missing:
        raise SystemExit("missing pinned extension modules: " + ", ".join(missing))

    members = ['  ".",']
    members.extend(
        f'  "./.deps/posoco-extension/{name}",'
        for name in MEMBERS
    )
    WORK_FILE.write_text("members = [\n" + "\n".join(members) + "\n]\n")
    print(
        "prepared cetas-memoh workspace with posoco-extension "
        f"{rev} ({len(MEMBERS)} modules)"
    )


if __name__ == "__main__":
    main()
