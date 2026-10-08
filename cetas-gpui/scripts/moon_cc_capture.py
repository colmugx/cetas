#!/usr/bin/env python3
"""Capture MoonBit C compiler inputs for the GPUI same-process build.

This replaces options.link.native.cc only for the build command. It never
builds a separate core executable: Cargo compiles these generated .c files.
Adapted from colmugx/ai-passport.mbt's moon_cc_capture.py.
"""
import fcntl
import os
from pathlib import Path
import shlex
import shutil
import sys


def expand(args, cwd, seen=None):
    seen = set() if seen is None else seen
    result = []
    for arg in args:
        if not arg.startswith("@"):
            result.append(arg)
            continue
        response = (cwd / arg[1:]).resolve()
        if response in seen:
            raise ValueError("recursive response file: " + str(response))
        seen.add(response)
        result += expand(shlex.split(response.read_text()), cwd, seen)
        seen.remove(response)
    return result


def main():
    dest = os.environ.get("MOON_CC_CAPTURE_DIR")
    if not dest:
        os.execvp("cc", ["cc", *sys.argv[1:]])
    dest = Path(dest).resolve()
    dest.mkdir(parents=True, exist_ok=True)
    cwd = Path.cwd().resolve()
    args = expand(sys.argv[1:], cwd)
    sources = []
    output = None
    depfile = None
    for i, arg in enumerate(args):
        if arg == "-o" and i + 1 < len(args):
            output = args[i + 1]
        if arg == "-MF" and i + 1 < len(args):
            depfile = args[i + 1]
        if arg.endswith(".c"):
            sources.append(arg)
    if not sources or not output:
        raise ValueError("expected C sources and -o from Moon's compiler driver")
    build_root = (cwd / "_build").resolve()
    copied = []
    for raw in sources:
        source = (cwd / raw).resolve()
        try:
            rel = source.relative_to(build_root)
        except ValueError as error:
            raise ValueError("source is outside Moon _build: " + str(source)) from error
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        copied.append(rel.as_posix())
    with (dest / ".manifest.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest = dest / "sources.txt"
        existing = set(manifest.read_text().splitlines()) if manifest.exists() else set()
        existing.update(copied)
        manifest.write_text("\n".join(sorted(existing)) + "\n")
    # Satisfy Moon's internal build graph. The placeholder is never linked.
    out = (cwd / output).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(b"")
    if depfile:
        dep = (cwd / depfile).resolve()
        dep.parent.mkdir(parents=True, exist_ok=True)
        dep.write_text(f"{output}: {' '.join(sources)}\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        print("cetas-moon-capture: " + str(error), file=sys.stderr)
        sys.exit(1)
