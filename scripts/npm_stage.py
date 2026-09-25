#!/usr/bin/env python3
"""Stage npm packages for cetas from release artifacts (stdlib only).

Usage:
  npm_stage.py --staging DIR --out DIR --version X.Y.Z

Input: the flattened release artifacts (cetas-bun-<target>.tar.gz for unix
targets, cetas-bun-windows-x64.zip for Windows). Output: one publishable
directory per platform payload package plus the cetas meta package whose
bin shim execs the installed platform binary. The version comes from the
release tag; publishing is manual via .github/workflows/npm-publish.yml
(workflow_dispatch on the release tag) or a local npm publish with NPM_TOKEN.
"""
import argparse
import json
import re
import shutil
import sys
import tarfile
import zipfile
from pathlib import Path

SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
DESCRIPTION = "Bun-runtime host for cetas — provider-neutral posoco agent with pi-tui"
REPO_URL = "git+https://github.com/colmugx/cetas.git"
REPO_HOME = "https://github.com/colmugx/cetas"

# Keep in sync with the build matrix in .github/workflows/release.yml.
# Archive and binary names are release/product names (cetas-bun); only the
# npm package names carry the cetas- prefix.
TARGETS = {
    "darwin-arm64": {
        "os": "darwin",
        "cpu": "arm64",
        "archive": "cetas-bun-darwin-arm64.tar.gz",
        "binary": "cetas-bun",
    },
    "linux-x64": {
        "os": "linux",
        "cpu": "x64",
        "archive": "cetas-bun-linux-x64.tar.gz",
        "binary": "cetas-bun",
    },
    "windows-x64": {
        "os": "win32",
        "cpu": "x64",
        "archive": "cetas-bun-windows-x64.zip",
        "binary": "cetas-bun.exe",
    },
}

PLATFORM_README = """# cetas-{target}

Platform binary ({os}/{cpu}) for [cetas]({repo}) — this package is an
install target of cetas's optionalDependencies. Install the
`cetas` meta package instead.
"""

META_README = f"""# cetas

Bun-runtime host for cetas — a provider-neutral posoco agent with a pi-tui
terminal UI, distributed as a prebuilt native binary ({REPO_HOME}).

## Install

    npm install -g cetas

Supported platforms: darwin-arm64, linux-x64, windows-x64. Each installs via
an optional dependency carrying its binary; on other platforms only this
launcher installs and reports the supported list. The launcher itself runs
under Node.js (esbuild-style); the agent binary it execs is self-contained.
"""

SHIM = """#!/usr/bin/env node
// cetas launcher: exec the cetas-bun binary for this platform from the
// matching cetas-<os>-<arch> payload package. Runs under Node.js.
const { spawnSync } = require("node:child_process");

const OS = { darwin: "darwin", linux: "linux", win32: "windows" }[process.platform];
const supported = ["darwin-arm64", "linux-x64", "windows-x64"];
const target = OS ? `${OS}-${process.arch}` : null;

if (!supported.includes(target)) {
  console.error(
    `cetas: unsupported platform ${process.platform}-${process.arch} ` +
    `(supported: ${supported.join(", ")})`,
  );
  process.exit(1);
}

const pkg = `cetas-${target}`;
let bin;
try {
  bin = require.resolve(`${pkg}/cetas-bun${process.platform === "win32" ? ".exe" : ""}`);
} catch {
  console.error(
    `cetas: payload package ${pkg} is missing ` +
    `(skipped as an optional dependency? try: npm install ${pkg})`,
  );
  process.exit(1);
}

const result = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  console.error(`cetas: failed to launch ${bin}: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status ?? 1);
"""


def die(msg, code=1):
    sys.stderr.write(f"error: {msg}\n")
    sys.exit(code)


def write_json(path, doc):
    path.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")


def extract_binary(archive, binary, dest):
    """Pull the single binary entry out of the release archive into dest."""
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as zf:
            names = [n for n in zf.namelist() if not n.endswith("/") and Path(n).name == binary]
            if not names:
                die(f"{archive}: no '{binary}' entry")
            dest.write_bytes(zf.read(names[0]))
    else:
        with tarfile.open(archive) as tf:
            members = [m for m in tf.getmembers() if m.isfile() and Path(m.name).name == binary]
            if not members:
                die(f"{archive}: no '{binary}' entry")
            src = tf.extractfile(members[0])
            dest.write_bytes(src.read())
    dest.chmod(0o755)


def stage_platform(out, staging, target, meta, version):
    pkg_dir = out / f"cetas-{target}"
    pkg_dir.mkdir(parents=True)
    extract_binary(staging / meta["archive"], meta["binary"], pkg_dir / meta["binary"])
    write_json(
        pkg_dir / "package.json",
        {
            "name": f"cetas-{target}",
            "version": version,
            "description": f"cetas binary for {meta['os']}/{meta['cpu']}; install the cetas meta package instead",
            "license": "Apache-2.0",
            "repository": {"type": "git", "url": REPO_URL},
            "os": [meta["os"]],
            "cpu": [meta["cpu"]],
        },
    )
    (pkg_dir / "README.md").write_text(
        PLATFORM_README.format(target=target, os=meta["os"], cpu=meta["cpu"], repo=REPO_HOME)
    )
    return pkg_dir


def stage_meta(out, version):
    pkg_dir = out / "cetas"
    (pkg_dir / "bin").mkdir(parents=True)
    shim = pkg_dir / "bin" / "cetas.js"
    shim.write_text(SHIM)
    shim.chmod(0o755)
    write_json(
        pkg_dir / "package.json",
        {
            "name": "cetas",
            "version": version,
            "description": DESCRIPTION,
            "license": "Apache-2.0",
            "repository": {"type": "git", "url": REPO_URL},
            "bin": {"cetas": "bin/cetas.js"},
            "files": ["bin"],
            "optionalDependencies": {f"cetas-{t}": version for t in TARGETS},
        },
    )
    (pkg_dir / "README.md").write_text(META_README)
    return pkg_dir


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--staging", required=True, type=Path, help="dir with flattened release artifacts")
    ap.add_argument("--out", required=True, type=Path, help="dir to write publishable packages into")
    ap.add_argument("--version", required=True, help="release version (X.Y.Z, from the cetas-v tag)")
    args = ap.parse_args()

    if not SEMVER.match(args.version):
        die(f"bad version: {args.version}")
    for meta in TARGETS.values():
        archive = args.staging / meta["archive"]
        if not archive.is_file():
            die(f"missing artifact: {archive}")
    if args.out.exists():
        shutil.rmtree(args.out)

    for target, meta in TARGETS.items():
        pkg_dir = stage_platform(args.out, args.staging, target, meta, args.version)
        size = (pkg_dir / meta["binary"]).stat().st_size / 1024 / 1024
        print(f"✓ cetas-{target}  {size:.1f} MB")
    stage_meta(args.out, args.version)
    print("✓ cetas (meta)")


if __name__ == "__main__":
    main()
