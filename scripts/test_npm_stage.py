#!/usr/bin/env python3
"""Tests for npm staging: single JS-only package shape and dist wiring."""

import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("npm_stage.py")
SPEC = importlib.util.spec_from_file_location("npm_stage", SCRIPT)
npm_stage = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(npm_stage)

BUNDLE = b"#!/usr/bin/env node\nconsole.log('cetas');\n"


class NpmStageTest(unittest.TestCase):
    def _write_dist_artifact(self, staging):
        with tarfile.open(staging / npm_stage.DIST_ARTIFACT, "w:gz") as tf:
            info = tarfile.TarInfo("dist/cetas.js")
            info.mode = 0o755
            info.size = len(BUNDLE)
            tf.addfile(info, io.BytesIO(BUNDLE))

    def test_single_js_package_shape(self):
        version = "1.2.3"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staging = root / "staging"
            out = root / "out"
            staging.mkdir()
            self._write_dist_artifact(staging)

            pkg_dir = npm_stage.stage(out, staging, version)

            manifest = json.loads((pkg_dir / "package.json").read_text())
            self.assertEqual(manifest["name"], "@posoco/cetas")
            self.assertEqual(manifest["version"], version)
            self.assertEqual(manifest["publishConfig"], {"access": "public"})
            self.assertEqual(manifest["type"], "module")
            # The bin is the bundle itself: no launcher shim, no payloads.
            self.assertEqual(manifest["bin"], {"cetas": "dist/cetas.js"})
            self.assertEqual(manifest["files"], ["dist"])
            self.assertEqual(manifest["engines"], {"node": ">=24"})
            self.assertIn("@earendil-works/pi-tui", manifest["dependencies"])
            self.assertNotIn("optionalDependencies", manifest)

            bundle = pkg_dir / "dist" / "cetas.js"
            self.assertEqual(bundle.read_bytes(), BUNDLE)
            self.assertTrue(bundle.read_bytes().startswith(b"#!/usr/bin/env node\n"))
            self.assertEqual(bundle.stat().st_mode & 0o111, 0o111)

    def test_missing_artifact_dies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(SystemExit):
                npm_stage.stage(root / "out", root, "1.2.3")


if __name__ == "__main__":
    unittest.main()
