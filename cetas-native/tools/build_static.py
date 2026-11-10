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
    # Inject into the *existing* options form: moon.pkg permits only one
    # options declaration, while foreign_library is a separate pkgtype.
    insertion = ('options(\n  link: {\n    "native": { "cc": ' +
                 json.dumps(str(driver)) + ' },\n  },\n').encode()
    if original.count(b"options(") != 1:
        raise RuntimeError("expected one native_bridge options declaration")
    injected = original.replace(b"options(\n", insertion, 1)
    if CAPTURE.exists():
        shutil.rmtree(CAPTURE)
    PKG.write_bytes(injected)
    env = dict(os.environ, MOONBIT_NEW_NATIVE="0", MOON_CC_CAPTURE_DIR=str(CAPTURE))
    try:
        run(["moon", "build", "cetas-native/native_bridge", "--target", "native", "--release"],
            cwd=MOON, env=env)
    finally:
        PKG.write_bytes(original)
    manifest = CAPTURE / "sources.txt"
    if sys.platform == "win32" and not manifest.is_file():
        # Moon uses the MSVC compiler driver on Windows and does not honor
        # options.link.native.cc for this package. Its generated monolithic C
        # file is still available under the normal build output. Capture that
        # exact file directly rather than claiming a custom compiler ran.
        generated = (
            MOON / "_build/native/release/build"
            / "colmugx/cetas-native/native_bridge/native_bridge.c"
        )
        if not generated.is_file():
            raise RuntimeError(f"Moon generated native C missing: {generated}")
        relative = generated.relative_to(MOON / "_build")
        target = CAPTURE / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(generated, target)
        manifest.write_text(relative.as_posix() + "\n")
    if not manifest.is_file():
        raise RuntimeError("Moon did not invoke the capture compiler")
    sources = [CAPTURE / s for s in manifest.read_text().splitlines() if s]
    if not sources or not all(s.is_file() for s in sources):
        raise RuntimeError("incomplete captured C sources")
    return sources


def workspace_roots():
    """Package roots that belong to the build graph.

    `moon.work` is authoritative: it names every member module of the root
    workspace and of the nested `extension` submodule. The registry vendor
    directories at the workspace root hold the pinned external dependencies.
    Walking the whole tree instead also picks up docs, agent skill templates
    and per-extension vendor copies, none of which are part of any build.
    """
    manifests = [MOON / "moon.work"]
    manifests += sorted(MOON.glob("*/moon.work"))
    manifests = [w for w in manifests if w.is_file()]
    if not manifests:
        raise RuntimeError("no moon.work found at the workspace root")
    roots = []
    for manifest in manifests:
        base = manifest.parent
        primary = base == MOON
        for member in re.findall(r'"([^"]+)"', manifest.read_text()):
            path = (base / member).resolve()
            if path.is_dir():
                roots.append(path)
            elif primary:
                raise RuntimeError(f"moon.work member missing: {path}")
            else:
                print(f"Skipping absent workspace member: {path}", flush=True)
    for vendored in ("_mooncakes", ".mooncakes"):
        path = MOON / vendored
        if path.is_dir():
            roots.append(path)
    if not roots:
        raise RuntimeError("no MoonBit workspace members found")
    return roots


def dependency_native_sources():
    """Compile native-stub units from the build graph's own packages.

    Moon's generated C is monolithic; foreign C units in dependency packages
    are not. Only workspace members and the root registry contribute units:
    vendored copies nested in submodules belong to other builds, and Moon
    never compiles the packages under `.agents/`, `docs/` or `_build/`.
    For macOS skip Linux/Windows backend units using explicit filenames.
    """
    roots = workspace_roots()
    skip_parts = {"_build", "_mooncakes", ".mooncakes"}
    # Moon's own stubs are guarded per target, but a foreign unit for the wrong
    # platform often includes a header that only exists there. Exclude the
    # other platform's units explicitly instead of letting the compiler find
    # the first missing header.
    if sys.platform == "win32":
        excluded = {
            "epoll.c", "kqueue.c", "watch_kqueue.c", "watch_inotify.c",
            "io_unix.c", "unix.c", "process_unix.c", "signal_unix.c",
        }
    else:
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
        for pkg in root.rglob("moon.pkg"):
            rel = pkg.relative_to(root)
            if (skip_parts & set(rel.parts)
                or any(p in ("test", "tests") or p.startswith("test_") or p.endswith("_test")
                       for p in rel.parts)
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
    windows = sys.platform == "win32"
    cc = shutil.which("clang") or shutil.which("cc")
    ar = shutil.which("llvm-ar") if windows else shutil.which("ar")
    nm = shutil.which("llvm-nm") if windows else shutil.which("nm")
    if not cc or not ar or not nm:
        raise RuntimeError("clang, llvm-ar/ar and llvm-nm/nm are required")
    if OBJECTS.exists():
        shutil.rmtree(OBJECTS)
    OBJECTS.mkdir(parents=True)
    objects = []
    # Windows objects are COFF and the toolchain is LLVM's: -fPIC and -pthread
    # mean nothing to the MSVC ABI, and llvm-ar/llvm-nm come with clang.
    flags = ["-std=gnu11", "-O2", "-Wno-missing-braces", "-Wno-parentheses",
             "-I", include, "-I", runtime]
    if not windows:
        flags[2:2] = ["-fPIC", "-pthread"]
    for i, src in enumerate([*sources, *runtime_sources, *dependency_native_sources()]):
        obj = OBJECTS / f"unit-{i:04d}.o"
        run([cc, *flags, "-c", src, "-o", obj])
        objects.append(obj)
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    ARCHIVE.unlink(missing_ok=True)
    run([ar, "rcs", ARCHIVE, *objects])
    symbols = subprocess.run([nm, "-g", str(ARCHIVE)],
                             capture_output=True, text=True, check=True).stdout
    for sym in ("cetas_infra_run", "moonbit_init",
                "moonbit_runtime_init"):
        if sym not in symbols:
            raise RuntimeError(f"static archive missing {sym}")
    return objects


def main():
    if sys.platform not in ("darwin", "linux", "win32") or platform.machine().lower() not in (
        "arm64", "aarch64", "x86_64", "amd64",
    ):
        raise RuntimeError("Cetas native static build supports Darwin/Linux/Windows arm64/x64")
    BUILD.mkdir(parents=True, exist_ok=True)
    sources = capture_c()
    objects = compile_archive(sources)
    (BUILD / "build-info.json").write_text(json.dumps({
        "platform": f"{sys.platform}/{platform.machine().lower()}",
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
