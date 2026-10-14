#!/usr/bin/env python3
"""Unit tests for scripts/update_manifest.py."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("update_manifest", SCRIPTS / "update_manifest.py")
update_manifest = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(update_manifest)


class UpdateManifestTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.image = self.root / update_manifest.image_name("1.4.0")
        self.image.write_bytes(b"disk image bytes" * 1000)
        self.notes = self.root / "notes.md"
        self.notes.write_text("### Fixed\n\n- 更新检查不再用完 GitHub 额度\n", encoding="utf-8")

    def tearDown(self):
        self.directory.cleanup()

    def run_main(self, *arguments):
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            update_manifest.main(["--tag", "v1.4.0", "--repository", "owner/app", "--notes", str(self.notes), *arguments])
        return Path(out.getvalue().strip())

    def test_manifest_describes_the_published_image(self):
        written = self.run_main(str(self.image))
        self.assertEqual(written, self.root / "WallpaperMachine-update.json")
        content = json.loads(written.read_text(encoding="utf-8"))
        self.assertEqual(content["tag_name"], "v1.4.0")
        self.assertFalse(content["prerelease"])
        self.assertEqual(content["html_url"], "https://github.com/owner/app/releases/tag/v1.4.0")
        self.assertEqual(content["body"], self.notes.read_text(encoding="utf-8"))
        [asset] = content["assets"]
        self.assertEqual(asset["name"], self.image.name)
        self.assertEqual(asset["browser_download_url"],
                         f"https://github.com/owner/app/releases/download/v1.4.0/{self.image.name}")
        self.assertEqual(asset["size"], self.image.stat().st_size)
        self.assertEqual(asset["digest"], "sha256:" + hashlib.sha256(self.image.read_bytes()).hexdigest())

    def test_image_of_another_version_is_refused(self):
        other = self.root / update_manifest.image_name("1.3.9")
        other.write_bytes(b"older")
        with self.assertRaisesRegex(update_manifest.ManifestError, self.image.name):
            update_manifest.manifest("v1.4.0", "owner/app", self.notes, other)

    def test_malformed_tag_and_repository_are_refused(self):
        for tag in ("1.4.0", "v1.4", "v1.4.0-beta"):
            with self.subTest(tag=tag), self.assertRaises(update_manifest.ManifestError):
                update_manifest.manifest(tag, "owner/app", self.notes, self.image)
        with self.assertRaises(update_manifest.ManifestError):
            update_manifest.manifest("v1.4.0", "https://github.com/owner/app", self.notes, self.image)


if __name__ == "__main__":
    unittest.main()
