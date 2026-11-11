"""Offline checks for the independent Homebrew/Scoop publishing workflow."""
import json
import tempfile
import unittest
from pathlib import Path

from scripts import package_managers as pm


class PackageManagersTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.tap = self.base / "tap/Formula/cetas.rb"
        self.bucket = self.base / "bucket/bucket/cetas.json"
        self.checksums = self.base / "SHA256SUMS"
        self.meta = self.base / "release.json"
        self.shas = {
            file: f"{i + 1:064x}" for i, file in enumerate(pm.FILES)
        }
        self.checksums.write_text(
            "\n".join(f"{sha}  {file}" for file, sha in self.shas.items()) + "\n",
            encoding="utf-8",
        )
        self.meta.write_text(json.dumps({
            "isDraft": False,
            "isPrerelease": False,
            "assets": [{"name": file} for file in (*pm.FILES, "SHA256SUMS")],
        }), encoding="utf-8")

    def test_independent_assets_still_used(self):
        pm.generate("cetas-v0.11.2", self.checksums, self.meta, self.tap, self.bucket)
        formula = self.tap.read_text(encoding="utf-8")
        manifest = json.loads(self.bucket.read_text(encoding="utf-8"))
        for asset in pm.FILES[:-1]:
            self.assertIn(asset, formula)
            self.assertIn(self.shas[asset], formula)
        self.assertEqual(manifest["architecture"]["64bit"]["hash"], self.shas["cetas-windows-x64.zip"])
        self.assertEqual(manifest["bin"], ["cetas.exe", "cetas-acp.exe", "cetas-run.exe"])
        self.assertIn("resource(\"acp\").stage", formula)
        self.assertIn("resource(\"run\").stage", formula)
        self.assertNotIn("cetas-windows-x64.zip", formula)
        self.assertEqual(manifest["version"], "0.11.2")

    def test_idempotent(self):
        pm.generate("cetas-v0.11.2", self.checksums, self.meta, self.tap, self.bucket)
        first = (self.tap.read_bytes(), self.bucket.read_bytes())
        pm.generate("cetas-v0.11.2", self.checksums, self.meta, self.tap, self.bucket)
        self.assertEqual(first, (self.tap.read_bytes(), self.bucket.read_bytes()))

    def test_refuses_downgrade_without_mutating(self):
        pm.generate("cetas-v0.11.2", self.checksums, self.meta, self.tap, self.bucket)
        first = (self.tap.read_bytes(), self.bucket.read_bytes())
        with self.assertRaisesRegex(ValueError, "downgrade"):
            pm.generate("cetas-v0.11.1", self.checksums, self.meta, self.tap, self.bucket)
        self.assertEqual(first, (self.tap.read_bytes(), self.bucket.read_bytes()))

    def test_missing_checksum_fails(self):
        self.checksums.write_text("a" * 64 + "  cetas-windows-x64.zip\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "lacks checksums"):
            pm.generate("cetas-v0.11.2", self.checksums, self.meta, self.tap, self.bucket)
        self.assertFalse(self.tap.exists())

    def test_missing_release_asset_fails(self):
        self.meta.write_text(json.dumps({"assets": [], "isDraft": False, "isPrerelease": False}))
        with self.assertRaisesRegex(ValueError, "assets missing"):
            pm.generate("cetas-v0.11.2", self.checksums, self.meta, self.tap, self.bucket)

    def test_prerelease_fails(self):
        data = json.loads(self.meta.read_text())
        data["isPrerelease"] = True
        self.meta.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "draft/prerelease"):
            pm.generate("cetas-v0.11.2", self.checksums, self.meta, self.tap, self.bucket)

    def test_rejects_invalid_version(self):
        for tag in ("cetas-v0.11.2-rc1", "cetas-memoh-v0.11.2", "cetas-vlatest"):
            with self.assertRaises(ValueError):
                pm.parse_tag(tag)


if __name__ == "__main__":
    unittest.main()
