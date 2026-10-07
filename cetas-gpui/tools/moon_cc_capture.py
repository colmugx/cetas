#!/usr/bin/env python3
"""Capture every C input Moon would give its final native compiler.

The resulting source set is compiled by Cargo into the GPUI executable.
Moon's own executable output is only a build-graph placeholder.
"""

import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import sys


def expand(args, cwd, seen=None):
    seen = set() if seen is None else seen
    out = []
    for arg in args:
        if not arg.startswith("@"):
            out.append(arg)
            continue
        path = (cwd / arg[1:]).resolve()
        if path in seen:
            raise RuntimeError(f"recursive response file: {path}")
        seen.add(path)
        out.extend(expand(shlex.split(path.read_text()), cwd, seen))
        seen.remove(path)
    return out


def main():
    cwd = Path.cwd().resolve()
    dest = Path(os.environ["CETAS_MOON_CAPTURE_DIR"]).resolve()
    dest.mkdir(parents=True, exist_ok=True)
    args = expand(sys.argv[1:], cwd)
    output = None
    sources = []
    i = 0
    while i < len(args):
        if args[i] == "-o" and i + 1 < len(args):
            output = args[i + 1]
            i += 2
            continue
        if args[i].endswith(".c"):
            sources.append(args[i])
        i += 1
    if not sources:
        raise RuntimeError("Moon compiler invocation contained no C sources")

    copied = []
    for source_arg in sources:
        source = (cwd / source_arg).resolve()
        # Preserve paths below _build; source stubs get a stable source/ prefix.
        try:
            relative = source.relative_to(cwd / "_build")
        except ValueError:
            relative = Path("source") / source.name
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        copied.append(relative.as_posix())

    with (dest / ".lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest = dest / "sources.txt"
        known = set(manifest.read_text().splitlines()) if manifest.exists() else set()
        known.update(copied)
        manifest.write_text("\n".join(sorted(known)) + "\n")
        with (dest / "capture.jsonl").open("a") as trace:
            trace.write(json.dumps({"cwd": str(cwd), "argv": sys.argv[1:], "expanded": args}) + "\n")

    if output:
        p = (cwd / output).resolve()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"cetas-gpui capture: {error}", file=sys.stderr)
        raise SystemExit(1)
