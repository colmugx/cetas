#!/usr/bin/env python3
"""Resolve native Cetas and HawDB against the current source checkout."""

from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
HAWDB = ROOT / "_hawdb_checkout" / "bindings" / "moonbit"
ADAPTER = ROOT / "extension" / "posoco-ext-hawdb-session"
WORK = ROOT / "moon.work"


def native_version() -> str:
    text = (HAWDB / "moon.mod").read_text(encoding="utf-8")
    match = re.search(r'(?m)^version\s*=\s*"([^"]+)"\s*$', text)
    if not match:
        raise SystemExit("Missing upstream HawDB module version")
    return match.group(1)


def main() -> None:
    if not HAWDB.is_dir():
        raise SystemExit("Missing current HawDB source checkout at _hawdb_checkout")

    work = WORK.read_text(encoding="utf-8").splitlines()
    member = '  "./_hawdb_checkout/bindings/moonbit",'
    if not work or work[0] != "members = [":
        raise SystemExit("Unexpected moon.work")
    if member not in work:
        work.insert(1, member)
        WORK.write_text("\n".join(work) + "\n", encoding="utf-8")

    manifest = ADAPTER / "moon.mod"
    text = manifest.read_text(encoding="utf-8")
    update, count = re.subn(
        r'("nowledge-co/hawdb@)[^"]+(")',
        lambda match: match.group(1) + native_version() + match.group(2),
        text,
    )
    if count != 1:
        raise SystemExit("Expected one HawDB module import")
    manifest.write_text(update, encoding="utf-8")

    hawdb_pkg = HAWDB / "moon.pkg"
    hawdb_pkg_text = hawdb_pkg.read_text(encoding="utf-8")
    if "warnings =" not in hawdb_pkg_text:
        hawdb_pkg.write_text(
            hawdb_pkg_text + '\n' + 'warnings = "-78-27"' + '\n',
            encoding="utf-8",
        )

    pkg = ADAPTER / "moon.pkg"
    current = pkg.read_text(encoding="utf-8")
    lib = "hawdb_moonbit.lib" if sys.platform == "win32" else "libhawdb_moonbit.a"
    archive = HAWDB / "native" / "target" / "release" / lib
    flags = archive.resolve().as_posix()
    if sys.platform == "win32":
        flags += " ws2_32.lib userenv.lib bcrypt.lib advapi32.lib ntdll.lib shell32.lib secur32.lib crypt32.lib iphlpapi.lib ole32.lib"
    else:
        flags += " -ldl -lpthread -lm"
        if sys.platform == "darwin":
            flags += " -framework CoreFoundation -framework IOKit"
    updated, count = re.subn(
        r'(?m)^(\s*"cc-link-flags":\s*)"[^"\n]*"(,\s*)$',
        lambda match: match.group(1) + json.dumps(flags) + match.group(2),
        current,
    )
    if count != 1:
        raise SystemExit("Expected one native linker flag set")
    pkg.write_text(updated, encoding="utf-8")
    print("HAWDB_MAIN_VERSION=" + native_version())


if __name__ == "__main__":
    main()
