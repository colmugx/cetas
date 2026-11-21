#!/usr/bin/env python3
"""Select only the shared and Memoh modules in this CI checkout.

Cetas-Go's opt-in HawDB native adapter is unrelated to Memoh's standalone
build. MoonBit resolves the whole moon.work graph even for -p checks, so
remove the Cetas-Go module and its HawDB adapter from Memoh's *ephemeral*
workspace. The source tree, session formats, and runtime backends stay intact.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "moon.work"
original = path.read_text(encoding="utf-8")
updated = original
for member in (
    '  "./cetas-go",\n',
    '  "./extension/posoco-ext-hawdb-session",\n',
):
    if updated.count(member) != 1:
        raise SystemExit(f"Missing or ambiguous moon.work member: {member.strip()}")
    updated = updated.replace(member, "", 1)
path.write_text(updated, encoding="utf-8")
