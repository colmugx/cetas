#!/usr/bin/env python3
"""Generate Homebrew/Scoop metadata from an existing Cetas GitHub release.

This script never builds binaries or modifies release assets. It keeps the
three independent native Unix archives and uses the existing Windows bundle.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPO = "colmugx/cetas"
TAG_RE = re.compile(r"^cetas-v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
SHA_RE = re.compile(r"^([a-fA-F0-9]{64})[ \t]+\*?([A-Za-z0-9._-]+)$")
UNIX_TARGETS = ("darwin-arm64", "linux-x64")
FILES = tuple(
    f"{name}-{target}.tar.gz"
    for target in UNIX_TARGETS
    for name in ("cetas", "cetas-acp", "cetas-run")
) + ("cetas-windows-x64.zip",)


def parse_tag(tag: str) -> tuple[str, tuple[int, int, int]]:
    match = TAG_RE.fullmatch(tag)
    if not match:
        raise ValueError(f"expected stable release tag cetas-vX.Y.Z, got {tag!r}")
    numbers = tuple(int(part) for part in match.groups())
    return ".".join(str(part) for part in numbers), numbers


def read_checksums(path: Path) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = SHA_RE.fullmatch(line.strip())
        if not match:
            raise ValueError(f"malformed SHA256SUMS entry: {line!r}")
        digest, name = match.groups()
        if name in checksums:
            raise ValueError(f"duplicate SHA256SUMS entry: {name}")
        checksums[name] = digest.lower()
    missing = sorted(set(FILES) - checksums.keys())
    if missing:
        raise ValueError(f"release lacks checksums for: {', '.join(missing)}")
    return checksums


def validate_release_metadata(path: Path) -> None:
    release = json.loads(path.read_text(encoding="utf-8"))
    if release.get("isDraft") or release.get("isPrerelease"):
        raise ValueError("draft/prerelease cannot be published to stable package managers")
    asset_names = {asset["name"] for asset in release["assets"]}
    missing = sorted(set(FILES + ("SHA256SUMS",)) - asset_names)
    if missing:
        raise ValueError(f"release assets missing: {', '.join(missing)}")


def asset_url(version: str, asset: str) -> str:
    return f"https://github.com/{REPO}/releases/download/cetas-v{version}/{asset}"


def formula(version: str, sha: dict[str, str]) -> str:
    lines = [
        "class Cetas < Formula",
        '  desc "Native Cetas terminal AI agent"',
        f'  homepage "https://github.com/{REPO}"',
        f'  version "{version}"',
        '  license "Apache-2.0"',
        "",
    ]
    for os_name, arch_name, target in (
        ("macos", "arm", "darwin-arm64"),
        ("linux", "intel", "linux-x64"),
    ):
        main = f"cetas-{target}.tar.gz"
        lines.extend((
            f"  on_{os_name} do",
            f"    on_{arch_name} do",
            f'      url "{asset_url(version, main)}"',
            f'      sha256 "{sha[main]}"',
            "",
        ))
        for name in ("acp", "run"):
            asset = f"cetas-{name}-{target}.tar.gz"
            lines.extend((
                f'      resource "{name}" do',
                f'        url "{asset_url(version, asset)}"',
                f'        sha256 "{sha[asset]}"',
                "      end",
                "",
            ))
        lines.extend(("    end", "  end", ""))
    lines.extend((
        "  def install",
        '    bin.install "cetas"',
        '    resource("acp").stage { bin.install "cetas-acp" }',
        '    resource("run").stage { bin.install "cetas-run" }',
        "  end",
        "",
        "  test do",
        '    assert_match "cetas #{version}", shell_output("#{bin}/cetas --version")',
        '    assert_match "cetas-acp", shell_output("#{bin}/cetas acp --version")',
        '    assert_match "cetas-run", shell_output("#{bin}/cetas run --version")',
        "  end",
        "end",
        "",
    ))
    return "\n".join(lines)


def scoop(version: str, sha: dict[str, str]) -> str:
    asset = "cetas-windows-x64.zip"
    payload = {
        "version": version,
        "description": "Native Cetas terminal AI agent",
        "homepage": f"https://github.com/{REPO}",
        "license": "Apache-2.0",
        "architecture": {
            "64bit": {
                "url": asset_url(version, asset),
                "hash": sha[asset],
            },
        },
        # Scoop shims point to the real executable inside its versioned dir.
        # cetas_moon.dll remains adjacent to cetas.exe in that directory.
        "bin": ["cetas.exe", "cetas-acp.exe", "cetas-run.exe"],
        "checkver": {
            "url": f"https://api.github.com/repos/{REPO}/releases?per_page=30",
            "regex": r'"tag_name"\s*:\s*"cetas-v([0-9]+\.[0-9]+\.[0-9]+)"',
        },
        "autoupdate": {
            "architecture": {
                "64bit": {
                    "url": f"https://github.com/{REPO}/releases/download/cetas-v$version/{asset}",
                },
            },
        },
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def existing_version(path: Path, kind: str) -> tuple[int, int, int] | None:
    if not path.exists():
        return None
    content = path.read_text(encoding="utf-8")
    if kind == "homebrew":
        match = re.search(r'^\s*version "(\d+\.\d+\.\d+)"\s*$', content, re.M)
        if match is None:
            raise ValueError(f"cannot determine existing Homebrew version in {path}")
        raw_version = match.group(1)
    else:
        raw_version = json.loads(content)["version"]
    _, numbers = parse_tag(f"cetas-v{raw_version}")
    return numbers


def generate(tag: str, checksums: Path, metadata: Path, tap: Path, bucket: Path) -> None:
    version, numeric_version = parse_tag(tag)
    validate_release_metadata(metadata)
    digests = read_checksums(checksums)
    for path, kind in ((tap, "homebrew"), (bucket, "scoop")):
        old = existing_version(path, kind)
        if old is not None and old > numeric_version:
            raise ValueError(f"refusing to downgrade {kind}: {old} > {numeric_version}")

    # Validate both target manifests before making either filesystem change.
    outputs = ((tap, formula(version, digests)), (bucket, scoop(version, digests)))
    for path, text in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print(f"{path}: {version}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--checksums", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--homebrew", type=Path, required=True)
    parser.add_argument("--scoop", type=Path, required=True)
    args = parser.parse_args()
    generate(args.tag, args.checksums, args.metadata, args.homebrew, args.scoop)


if __name__ == "__main__":
    main()
