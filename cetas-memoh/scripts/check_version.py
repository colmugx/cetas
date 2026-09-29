#!/usr/bin/env python3
"""Verify cetas-memoh's independent version surfaces."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
MOON = re.compile(r'(?m)^version\s*=\s*"([^"]+)"')
MAIN = re.compile(r'const\s+CETAS_MEMOH_VERSION\s*=\s*"([^"]+)"')
INSTALL = re.compile(r'(?m)^DEFAULT_VERSION="([^"]+)"')


def read_match(path: Path, pattern: re.Pattern[str]) -> str:
    match = pattern.search(path.read_text())
    if match is None:
        raise SystemExit(f"missing version declaration: {path.relative_to(ROOT)}")
    return match.group(1)


def main() -> None:
    expected = (ROOT / "VERSION").read_text().strip()
    if not SEMVER.fullmatch(expected):
        raise SystemExit(f"invalid cetas-memoh/VERSION: {expected!r}")
    surfaces = {
        "moon.mod": read_match(ROOT / "moon.mod", MOON),
        "main/main.mbt": read_match(ROOT / "main/main.mbt", MAIN),
        "install.sh": read_match(ROOT / "install.sh", INSTALL),
    }
    bad = {name: value for name, value in surfaces.items() if value != expected}
    for name, value in surfaces.items():
        status = "ok" if value == expected else f"expected {expected}"
        print(f"{name}: {value} ({status})")
    if bad:
        raise SystemExit("cetas-memoh version surfaces are out of sync")
    print(f"cetas-memoh version: {expected}")


if __name__ == "__main__":
    main()
