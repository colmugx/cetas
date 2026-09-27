#!/usr/bin/env python3
"""Tests for npm staging package naming and launcher wiring."""

import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("npm_stage.py")
SPEC = importlib.util.spec_from_file_location("npm_stage", SCRIPT)
npm_stage = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(npm_stage)


class NpmStageTest(unittest.TestCase):
    def _write_release_artifacts(self, staging):
        payload = b"fake-cetas-binary\n"
        for meta in npm_stage.TARGETS.values():
            archive = staging / meta["archive"]
            if archive.suffix == ".zip":
                with zipfile.ZipFile(archive, "w") as zf:
                    zf.writestr(meta["binary"], payload)
            else:
                with tarfile.open(archive, "w:gz") as tf:
                    info = tarfile.TarInfo(meta["binary"])
                    info.mode = 0o755
                    info.size = len(payload)
                    tf.addfile(info, io.BytesIO(payload))

    def test_platform_packages_are_scoped_and_meta_links_them(self):
        version = "1.2.3"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staging = root / "staging"
            out = root / "out"
            staging.mkdir()
            out.mkdir()
            self._write_release_artifacts(staging)

            expected_optional = {}
            for target, platform in npm_stage.TARGETS.items():
                pkg_dir = npm_stage.stage_platform(out, staging, target, platform, version)
                manifest = json.loads((pkg_dir / "package.json").read_text())

                expected_name = f"@posoco/cetas-{target}"
                expected_optional[expected_name] = version
                self.assertEqual(manifest["name"], expected_name)
                self.assertEqual(manifest["version"], version)
                self.assertEqual(manifest["os"], [platform["os"]])
                self.assertEqual(manifest["cpu"], [platform["cpu"]])
                self.assertEqual(manifest["publishConfig"], {"access": "public"})

            meta_dir = npm_stage.stage_meta(out, version)
            meta = json.loads((meta_dir / "package.json").read_text())
            self.assertEqual(meta["name"], "@posoco/cetas")
            self.assertEqual(meta["optionalDependencies"], expected_optional)
            self.assertEqual(meta["publishConfig"], {"access": "public"})

            shim = (meta_dir / "bin" / "cetas.js").read_text()
            self.assertIn("const pkg = `@posoco/cetas-${target}`;", shim)
            self.assertNotIn("const pkg = `cetas-${target}`;", shim)


if __name__ == "__main__":
    unittest.main()
