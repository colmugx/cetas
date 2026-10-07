#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "cetas-gpui"
PKG = APP / "core" / "moon.pkg"
CAPTURE = APP / "generated" / "moonbit"
TOOLCHAIN = APP / "generated" / "toolchain"
CAPTURE_SOURCE = APP / "tools" / "moon_cc_capture.py"


def run(cmd, cwd, env):
    print("+", " ".join(map(str, cmd)), flush=True)
    subprocess.run(list(map(str, cmd)), cwd=cwd, env=env, check=True)


def prepare_capture_toolchain():
    if TOOLCHAIN.exists():
        shutil.rmtree(TOOLCHAIN)
    TOOLCHAIN.mkdir(parents=True)
    cc = TOOLCHAIN / "cc"
    shutil.copy2(CAPTURE_SOURCE, cc)
    cc.chmod(0o755)
    ar = shutil.which("ar")
    if not ar:
        raise SystemExit("system archiver 'ar' is required")
    (TOOLCHAIN / "ar").symlink_to(Path(ar).resolve())
    return cc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", default=None)
    args = parser.parse_args()

    if CAPTURE.exists():
        shutil.rmtree(CAPTURE)
    CAPTURE.mkdir(parents=True)
    capture_cc = prepare_capture_toolchain()

    original = PKG.read_text()
    patched = original.replace("__CETAS_GPUI_CC__", str(capture_cc))
    if patched == original:
        raise SystemExit("capture compiler placeholder missing")
    PKG.write_text(patched)

    env = os.environ.copy()
    env["MOONBIT_NEW_NATIVE"] = "0"
    env["CETAS_MOON_CAPTURE_DIR"] = str(CAPTURE)
    try:
        run(
            ["python3", "../scripts/prepare-recipe.py", "--flavor", "public", "--frontend", "all", "--platform", "unix"],
            APP,
            env,
        )
        shutil.copy2(ROOT / "cetas-web" / "server" / "recipe.generated.mbt", APP / "core" / "recipe.generated.mbt")
        run(["moon", "update"], APP, env)
        run(["moon", "build", "core", "--target", "native", "--release"], APP, env)
    finally:
        PKG.write_text(original)

    if not (CAPTURE / "sources.txt").exists():
        raise SystemExit("Moon build completed without captured C sources")

    cmd = ["cargo", "build", "--release"]
    if args.target:
        cmd += ["--target", args.target]
    run(cmd, APP, env)


if __name__ == "__main__":
    main()
