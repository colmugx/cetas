#!/usr/bin/env python3
"""Build macOS arm64 archive of MoonBit C output + MoonBit C runtime.

Temporarily injects Moon's custom cc; always restores moon.pkg.
No prebuilt binaries enter version control.
"""
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
MOON = ROOT.parent  # Cetas root workspace, with source-pinned external/cetas
PKG = MOON / "cetas-native/native_bridge/moon.pkg"
BUILD = ROOT / "build"
CAPTURE = BUILD / "captured"
TOOLCHAIN = BUILD / "capture-toolchain"
OBJECTS = BUILD / "objects"
ARCHIVE = ROOT / "go_bridge/lib/libcetas_moon.a"
RUNTIME_SOURCES = ("runtime.c", "backtrace.c", "env.c", "sync_io.c", "utf.c")


def run(cmd, **kwargs):
    print("+", " ".join(str(s) for s in cmd), flush=True)
    subprocess.run([str(s) for s in cmd], check=True, **kwargs)


def capture_c():
    TOOLCHAIN.mkdir(parents=True, exist_ok=True)
    driver = TOOLCHAIN / "cc"
    shutil.copy2(ROOT / "tools/capture_cc.py", driver)
    driver.chmod(0o755)
    archiver = shutil.which("ar")
    if not archiver:
        raise RuntimeError("ar not found")
    ar_link = TOOLCHAIN / "ar"
    ar_link.unlink(missing_ok=True)
    ar_link.symlink_to(Path(archiver).resolve())
    original = PKG.read_bytes()
    if b"link:" in original:
        raise RuntimeError("moon.pkg already has a link override")
    extra = ('\noptions(\n  link: {\n    "native": { "cc": ' +
             json.dumps(str(driver)) + ' },\n  },\n)\n').encode()
    if CAPTURE.exists():
        shutil.rmtree(CAPTURE)
    # Force compiler invocation even when Moon has a cached successful build.
    native_build = MOON / "_build/native"
    if native_build.exists():
        shutil.rmtree(native_build)
    PKG.write_bytes(original + extra)
    env = dict(os.environ, MOONBIT_NEW_NATIVE="0", MOON_CC_CAPTURE_DIR=str(CAPTURE))
    try:
        run(["moon", "build", "cetas-native/native_bridge", "--target", "native", "--release"],
            cwd=MOON, env=env)
    finally:
        PKG.write_bytes(original)
    manifest = CAPTURE / "sources.txt"
    if not manifest.is_file():
        raise RuntimeError("Moon did not invoke the capture compiler")
    sources = [CAPTURE / s for s in manifest.read_text().splitlines() if s]
    if not sources or not all(s.is_file() for s in sources):
        raise RuntimeError("incomplete captured C sources")
    return sources


def dependency_native_sources():
    """Compile native-stub units from the full source-pinned Moon workspace.

    Moon's generated C is monolithic; foreign C units in dependency packages
    are not. Traverse both registry modules and the nested Cetas submodule.
    For macOS skip Linux/Windows backend units using explicit filenames.
    """
    roots = [
        MOON / "_mooncakes",
        MOON / ".mooncakes",
        MOON,
    ]
    excluded = {
        "iocp.c", "io_windows.c", "signal_windows.c",
        "watch_inotify.c", "watch_windows.c", "process_windows.c",
        "windows.c", "windows_subsystem.c",
    }
    if sys.platform == "darwin":
        excluded.add("epoll.c")
        excluded.add("watch_inotify.c")
    else:
        excluded.add("kqueue.c")
        excluded.add("watch_kqueue.c")
    seen = set()
    files = []
    for root in roots:
        if not root.exists():
            continue
        for pkg in root.rglob("moon.pkg"):
            rel = pkg.relative_to(root)
            if ("test" in rel.parts or "tests" in rel.parts or "_build" in rel.parts
                or "external_loop_test" in rel.parts
                or "moonbit-community" in rel.parts and "proton" in rel.parts):
                continue
            match = re.search(r'"native-stub"\s*:\s*\[([^]]+)\]', pkg.read_text(), re.S)
            if match is None:
                continue
            for name in re.findall(r'"([^"]+\.c)"', match.group(1)):
                if name in excluded:
                    continue
                src = (pkg.parent / name).resolve()
                if not src.is_file():
                    raise RuntimeError(f"native C unit missing: {src}")
                if src not in seen:
                    files.append(src)
                    seen.add(src)
    if not files:
        raise RuntimeError("no MoonBit dependency native C units found")
    print(f"Compiling {len(files)} workspace native C stubs", flush=True)
    return files


def compile_archive(sources):
    moon_home = Path(os.environ.get("MOON_HOME", Path.home() / ".moon")).resolve()
    runtime = moon_home / "lib/runtime"
    include = moon_home / "include"
    if not runtime.is_dir() or not include.is_dir():
        raise RuntimeError(f"MoonBit C runtime/headers absent under {moon_home}")
    runtime_sources = sorted(runtime.glob("*.c"))
    if not runtime_sources:
        raise RuntimeError("MoonBit C runtime sources missing; check MoonBit installation")
    print("Linking MoonBit runtime C sources:", ", ".join(src.name for src in runtime_sources), flush=True)
    missing = [str(p) for p in runtime_sources if not p.is_file()]
    if missing:
        raise RuntimeError(f"MoonBit runtime sources missing: {missing}")
    cc, ar = shutil.which("clang") or shutil.which("cc"), shutil.which("ar")
    if not cc or not ar:
        raise RuntimeError("clang and ar are required")
    if OBJECTS.exists():
        shutil.rmtree(OBJECTS)
    OBJECTS.mkdir(parents=True)
    objects = []
    for i, src in enumerate([*sources, *runtime_sources, *dependency_native_sources()]):
        obj = OBJECTS / f"unit-{i:04d}.o"
        run([cc, "-std=gnu11", "-O2", "-fPIC", "-pthread",
             "-Wno-missing-braces", "-Wno-parentheses", "-I", include,
             "-I", runtime, "-c", src, "-o", obj])
        objects.append(obj)
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    ARCHIVE.unlink(missing_ok=True)
    run([ar, "rcs", ARCHIVE, *objects])
    symbols = subprocess.run(["nm", "-g", str(ARCHIVE)],
                             capture_output=True, text=True, check=True).stdout
    for sym in ("cetas_infra_run", "moonbit_init",
                "moonbit_runtime_init"):
        if sym not in symbols:
            raise RuntimeError(f"static archive missing {sym}")
    return objects


def main():
    if sys.platform not in ("darwin", "linux") or platform.machine() not in ("arm64", "aarch64", "x86_64"):
        raise RuntimeError("Cetas native static build supports Darwin/Linux arm64/x64")
    BUILD.mkdir(parents=True, exist_ok=True)
    sources = capture_c()
    objects = compile_archive(sources)
    (BUILD / "build-info.json").write_text(json.dumps({
        "platform": "darwin/arm64",
        "sources": [str(s.relative_to(CAPTURE)) for s in sources],
        "objects": len(objects),
    }, indent=2) + "\n")
    print(f"Static MoonBit archive: {ARCHIVE}, from {len(sources)} captured C files")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as e:
        print(f"Cetas static build failed: {e}", file=sys.stderr)
        sys.exit(1)
