#!/usr/bin/env python3
"""Run shared observer-event parity fixtures through the native shell."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys

MODULE_ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURE_ROOT = MODULE_ROOT / "parity" / "fixtures"


def run_fixture(events_path: pathlib.Path) -> bool:
    expected_path = events_path.with_name(
        events_path.name.replace(".events.jsonl", ".expected.json")
    )
    if not expected_path.exists():
        print(f"missing expected snapshot for {events_path.name}", file=sys.stderr)
        return False

    proc = subprocess.run(
        ["moon", "run", "src/parity", "--target", "native", "--release"],
        cwd=MODULE_ROOT,
        input=events_path.read_text(encoding="utf-8"),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    if proc.returncode != 0:
        print(f"{events_path.name}: native runner exited {proc.returncode}", file=sys.stderr)
        if proc.stdout:
            print(proc.stdout, file=sys.stderr)
        if proc.stderr:
            print(proc.stderr, file=sys.stderr)
        return False

    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    if not lines:
        print(f"{events_path.name}: native runner produced no snapshot", file=sys.stderr)
        return False

    try:
        actual = json.loads(lines[-1])
        expected = json.loads(expected_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"{events_path.name}: invalid snapshot JSON: {exc}", file=sys.stderr)
        print(proc.stdout, file=sys.stderr)
        return False

    if actual != expected:
        print(f"{events_path.name}: snapshot mismatch", file=sys.stderr)
        print("expected:", json.dumps(expected, indent=2, ensure_ascii=False), file=sys.stderr)
        print("actual:", json.dumps(actual, indent=2, ensure_ascii=False), file=sys.stderr)
        return False

    print(f"{events_path.name}: ok")
    return True


def main() -> int:
    fixtures = sorted(FIXTURE_ROOT.glob("*.events.jsonl"))
    if not fixtures:
        print("no parity fixtures found", file=sys.stderr)
        return 2

    return 0 if all(run_fixture(path) for path in fixtures) else 1


if __name__ == "__main__":
    raise SystemExit(main())
