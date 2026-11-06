#!/usr/bin/env python3
"""Capture MoonBit's generated C via options.link.native.cc.

Empty outputs exist only for Moon's build graph. Never link them.
Based on colmugx/ai-passport.mbt's moon_cc_capture.py.
"""
import json
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
        path = (cwd / arg[1:]).resolve()
        if path in seen:
            raise ValueError(f"recursive response file: {path}")
        seen.add(path)
        result.extend(expand(shlex.split(path.read_text()), cwd, seen))
        seen.remove(path)
    return result


def parse(args):
    sources, output, depfile = [], None, None
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("-o", "-MF"):
            if i + 1 >= len(args):
                raise ValueError(f"missing argument after {arg}")
            if arg == "-o":
                output = args[i + 1]
            else:
                depfile = args[i + 1]
            i += 2
            continue
        if arg.startswith("-o") and len(arg) > 2:
            output = arg[2:]
        elif arg.startswith("-MF") and len(arg) > 3:
            depfile = arg[3:]
        elif arg.endswith(".c"):
            sources.append(arg)
        i += 1
    return sources, output, depfile


def capture(args, cwd, destination):
    expanded = expand(args, cwd)
    sources, output, depfile = parse(expanded)
    if not sources:
        raise ValueError("Moon capture invoked without .c inputs")
    build_root = (cwd / "_build").resolve()
    destination.mkdir(parents=True, exist_ok=True)
    copied = []
    for arg in sources:
        source = (cwd / arg).resolve()
        if not source.is_relative_to(build_root):
            raise ValueError(f"C input outside Moon _build: {source}")
        if not source.is_file():
            raise FileNotFoundError(source)
        rel = source.relative_to(build_root)
        target = destination / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        copied.append(rel.as_posix())
    (destination / "sources.txt").write_text("\n".join(sorted(set(copied))) + "\n")
    (destination / "invocation.json").write_text(json.dumps({
        "argv": args, "expanded_argv": expanded, "cwd": str(cwd),
        "sources": copied, "output": output, "depfile": depfile,
    }, indent=2, sort_keys=True) + "\n")
    if output:
        p = (cwd / output).resolve()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"")
    if depfile:
        p = (cwd / depfile).resolve()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f"{output or 'capture'}: {' '.join(sources)}\n")


def main():
    destination = os.environ.get("MOON_CC_CAPTURE_DIR")
    if not destination:
        os.execvp("cc", ["cc", *sys.argv[1:]])
    capture(sys.argv[1:], Path.cwd().resolve(), Path(destination).resolve())


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"Cetas cc capture: {error}", file=sys.stderr)
        sys.exit(1)
