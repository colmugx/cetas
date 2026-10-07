#!/usr/bin/env python3
"""Capture MoonBit's final native C link while real compile steps still run.

Intermediate cc -c invocations go to the system compiler. The final C-backend
link is recorded for Cargo and replaced with an empty Moon build-graph output.
"""

import json
import os
from pathlib import Path
import shlex
import shutil
import sys


def expand_response_files(args, cwd, seen=None):
    seen = set() if seen is None else seen
    expanded = []
    for arg in args:
        if not arg.startswith("@"):
            expanded.append(arg)
            continue
        path = (cwd / arg[1:]).resolve()
        if path in seen:
            raise ValueError(f"recursive response file: {path}")
        seen.add(path)
        expanded.extend(expand_response_files(shlex.split(path.read_text()), cwd, seen))
        seen.remove(path)
    return expanded


def output_path(args):
    for i, arg in enumerate(args):
        if arg == "-o" and i + 1 < len(args):
            return args[i + 1]
        if arg.startswith("-o") and len(arg) > 2:
            return arg[2:]
    return None


def depfile_path(args):
    for i, arg in enumerate(args):
        if arg == "-MF" and i + 1 < len(args):
            return args[i + 1]
        if arg.startswith("-MF") and len(arg) > 3:
            return arg[3:]
    return None


def compile_only(args):
    if "-c" in args:
        return True
    out = output_path(args)
    return bool(out and out.endswith((".o", ".obj")))


def main():
    capture = os.environ.get("MOON_CC_CAPTURE_DIR")
    if not capture:
        os.execvp("cc", ["cc", *sys.argv[1:]])

    cwd = Path.cwd().resolve()
    raw = sys.argv[1:]
    expanded = expand_response_files(raw, cwd)

    if compile_only(expanded):
        os.execvp("cc", ["cc", *raw])

    sources = [arg for arg in expanded if arg.endswith((".c", ".m"))]
    if not sources:
        os.execvp("cc", ["cc", *raw])

    destination = Path(capture).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    copied = []
    absolute_sources = []
    for index, source_arg in enumerate(sources):
        source = (cwd / source_arg).resolve()
        if not source.is_file():
            raise FileNotFoundError(source)
        target = destination / f"{index:03d}-{source.name}"
        shutil.copyfile(source, target)
        copied.append({"original": str(source), "copied": target.name})
        absolute_sources.append(str(source))

    normalized = []
    for arg in expanded:
        if arg in sources:
            normalized.append(str((cwd / arg).resolve()))
        else:
            normalized.append(arg)

    record = {
        "argv": raw,
        "expanded_argv": normalized,
        "cwd": str(cwd),
        "sources": copied,
        "output": output_path(expanded),
    }
    (destination / "final-link.json").write_text(json.dumps(record, indent=2))

    out = output_path(expanded)
    if out:
        path = (cwd / out).resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"")

    dep = depfile_path(expanded)
    if dep:
        path = (cwd / dep).resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"{out or 'moon-link'}:\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"moon_cc_capture: {error}", file=sys.stderr)
        raise SystemExit(1)
