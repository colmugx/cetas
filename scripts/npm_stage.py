#!/usr/bin/env python3
"""Stage the npm package for cetas from the release dist artifact (stdlib only).

Usage:
  npm_stage.py --staging DIR --out DIR --version X.Y.Z

Input: the flattened release artifact `cetas-js-dist.tar.gz` (the
platform-independent node bundle built by release.yml's cetas-js-dist job).
Output: one publishable directory — @posoco/cetas, a JS-only package whose
`cetas` bin runs the bundled dist/cetas.js under plain Node.js (>= 24). No
platform payloads, no optionalDependencies. The version comes from the
release tag; publishing is manual via .github/workflows/npm-publish.yml
(workflow_dispatch on the release tag) or a local npm publish with NPM_TOKEN.
"""
import argparse
import io
import json
import re
import shutil
import sys
import tarfile
from pathlib import Path

SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
DESCRIPTION = "Cetas terminal host — provider-neutral Posoco agent (JS bundle for Node.js)"
REPO_URL = "git+https://github.com/colmugx/cetas.git"
REPO_HOME = "https://github.com/colmugx/cetas"
DIST_ARTIFACT = "cetas-js-dist.tar.gz"

# Keep in sync with cetas-js/package.json dependencies. pi-tui ships native
# .node prebuilds inside the package, so one dependency serves every platform.
PI_TUI_RANGE = "^0.85.1"

README = f"""# cetas

Cetas terminal host — a provider-neutral Posoco agent, distributed as a
single minified JS bundle that runs under plain Node.js ({REPO_HOME}).

## Install

    npm install -g @posoco/cetas

Requires Node.js >= 24 (engines is enforced). Every platform is served by
the same package: the bash/PowerShell tool swap detects the platform at
runtime and pi-tui's native addons load from its npm install.

The GitHub Release channel ships a self-contained bun-compiled binary
(cetas-bun-*) for users without Node.

The host checks this registry once a day for a newer release and prints a
one-line notice; set `CETAS_NO_UPDATE_CHECK=1` to disable.
"""


def die(msg, code=1):
    sys.stderr.write(f"error: {msg}\n")
    sys.exit(code)


def write_json(path, doc):
    path.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")


def extract_dist(archive, dest):
    """Pull dist/cetas.js (or a bare cetas.js) out of the dist artifact."""
    if not archive.is_file():
        die(f"missing artifact: {archive}")
    with tarfile.open(archive) as tf:
        members = [
            m
            for m in tf.getmembers()
            if m.isfile() and Path(m.name).name == "cetas.js"
        ]
        if not members:
            die(f"{archive}: no 'cetas.js' entry")
        src = tf.extractfile(members[0])
        dest.write_bytes(src.read())
    dest.chmod(0o755)


def stage(out, staging, version):
    pkg_dir = out / "cetas"
    (pkg_dir / "dist").mkdir(parents=True)
    extract_dist(staging / DIST_ARTIFACT, pkg_dir / "dist" / "cetas.js")
    license_src = Path(__file__).resolve().parent.parent / "LICENSE"
    if not license_src.is_file():
        die(f"missing LICENSE next to the repo root: {license_src}")
    shutil.copy(license_src, pkg_dir / "LICENSE")
    write_json(
        pkg_dir / "package.json",
        {
            "name": "@posoco/cetas",
            "version": version,
            "description": DESCRIPTION,
            "license": "Apache-2.0",
            "repository": {"type": "git", "url": REPO_URL},
            "publishConfig": {"access": "public"},
            "type": "module",
            "bin": {"cetas": "dist/cetas.js"},
            "files": ["dist"],
            "engines": {"node": ">=24"},
            "dependencies": {"@earendil-works/pi-tui": PI_TUI_RANGE},
        },
    )
    (pkg_dir / "README.md").write_text(README)
    return pkg_dir


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--staging", required=True, type=Path, help="dir with the flattened release artifacts")
    ap.add_argument("--out", required=True, type=Path, help="dir to write the publishable package into")
    ap.add_argument("--version", required=True, help="release version (X.Y.Z, from the cetas-v tag)")
    args = ap.parse_args()

    if not SEMVER.match(args.version):
        die(f"bad version: {args.version}")
    artifact = args.staging / DIST_ARTIFACT
    if not artifact.is_file():
        die(f"missing artifact: {artifact}")
    if args.out.exists():
        shutil.rmtree(args.out)

    pkg_dir = stage(args.out, args.staging, args.version)
    size = (pkg_dir / "dist" / "cetas.js").stat().st_size / 1024 / 1024
    print(f"✓ @posoco/cetas (JS bundle)  {size:.1f} MB")


if __name__ == "__main__":
    main()
