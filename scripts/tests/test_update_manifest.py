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
        self.image = self.root / "WallpaperMachine-1.4.0-arm64.dmg"
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
                         "https://github.com/owner/app/releases/download/v1.4.0/WallpaperMachine-1.4.0-arm64.dmg")
        self.assertEqual(asset["size"], self.image.stat().st_size)
        self.assertEqual(asset["digest"], "sha256:" + hashlib.sha256(self.image.read_bytes()).hexdigest())

    def test_verified_metadata_is_digest_bound_and_additive(self):
        metadata = self.root / "metadata.json"
        facts = {"version": "1.4.0", "image": self.image.name,
                 "size": self.image.stat().st_size, "sha256": hashlib.sha256(self.image.read_bytes()).hexdigest(),
                 "bundle_identifier": "app.wallpapermachine", "minimum_system_version": "15.0", "architectures": ["arm64"]}
        metadata.write_text(json.dumps(facts))
        content = update_manifest.manifest("v1.4.0", "owner/app", self.notes, self.image, metadata=metadata)
        self.assertEqual(content["minimum_system_version"], "15.0")
        self.assertEqual(content["architectures"], ["arm64"])
        self.assertEqual(content["tag_name"], "v1.4.0")
        for key, bad in [("sha256", "wrong"), ("version", "1.4.1"), ("minimum_system_version", "new"),
                         ("architectures", ["x86_64"]), ("bundle_identifier", "foreign.app")]:
            with self.subTest(key=key):
                metadata.write_text(json.dumps({**facts, key: bad}))
                with self.assertRaises(update_manifest.ManifestError):
                    update_manifest.manifest("v1.4.0", "owner/app", self.notes, self.image, metadata=metadata)

    def test_without_a_changelog_the_manifest_has_no_changelog_field(self):
        content = json.loads(self.run_main(str(self.image)).read_text(encoding="utf-8"))
        self.assertNotIn("changelog", content)

    def changelog(self, count, newest=(1, 4, 0)):
        """A changelog of `count` versions counting down from `newest`, the oldest in the old heading form."""
        versions = [".".join(map(str, newest))] + [f"0.{minor}.0" for minor in range(count - 1, 0, -1)]
        sections = []
        for index, version in enumerate(versions):
            if index == count - 1:
                sections.append(f"## {version} — 2026-01-01\n\n### English\n\n- 旧版 {version}\n\n")
            else:
                sections.append(f"## [{version}](https://github.com/owner/app/compare/v0.0.0...v{version}) (2026-01-02)"
                                f"\n\n### English\n\n#### Bug Fixes\n\n- Fix {version} ([abc1234](https://x/commit/abc1234))\n\n")
        path = self.root / "CHANGELOG.md"
        path.write_text("# Changelog\n\nPreamble with a ## inside a line.\n\n" + "".join(sections), encoding="utf-8")
        return path, sections

    def test_the_changelog_carries_the_newest_sections_verbatim(self):
        path, sections = self.changelog(3)
        content = json.loads(self.run_main("--changelog", str(path), str(self.image)).read_text(encoding="utf-8"))
        self.assertEqual(content["changelog"], "".join(sections).rstrip("\n") + "\n")
        self.assertTrue(content["changelog"].startswith("## [1.4.0](https://github.com/owner/app/compare/"))
        self.assertNotIn("Preamble", content["changelog"])
        self.assertIn("## 0.1.0 — 2026-01-01", content["changelog"], "The older heading form is carried as written")

    def test_the_changelog_keeps_only_the_newest_twenty_sections(self):
        path, sections = self.changelog(update_manifest.CHANGELOG_SECTIONS + 5)
        carried = update_manifest.manifest("v1.4.0", "owner/app", self.notes, self.image, path)["changelog"]
        self.assertEqual(carried.count("\n## "), update_manifest.CHANGELOG_SECTIONS - 1)
        self.assertEqual(carried, "".join(sections[:update_manifest.CHANGELOG_SECTIONS]).rstrip("\n") + "\n")

    def test_a_changelog_without_the_release_is_refused(self):
        path, _ = self.changelog(2, newest=(1, 3, 9))
        with self.assertRaisesRegex(update_manifest.ManifestError, "does not start with the section for v1.4.0"):
            update_manifest.manifest("v1.4.0", "owner/app", self.notes, self.image, path)
        # A release whose section is not the newest: the app would drop the history.
        newer, _ = self.changelog(3, newest=(1, 5, 0))
        with self.assertRaisesRegex(update_manifest.ManifestError, "does not start with the section for v0.2.0"):
            update_manifest.changelog_sections(newer, "v0.2.0")
        empty = self.root / "empty.md"
        empty.write_text("# Changelog\n", encoding="utf-8")
        with self.assertRaisesRegex(update_manifest.ManifestError, "no ## version sections"):
            update_manifest.manifest("v1.4.0", "owner/app", self.notes, self.image, empty)
        with self.assertRaisesRegex(update_manifest.ManifestError, "Not a file"):
            self.run_main("--changelog", str(self.root / "missing.md"), str(self.image))

    def test_image_of_another_version_is_refused(self):
        other = self.root / "WallpaperMachine-1.3.9-arm64.dmg"
        other.write_bytes(b"older")
        with self.assertRaisesRegex(update_manifest.ManifestError, "WallpaperMachine-1.4.0-arm64.dmg"):
            update_manifest.manifest("v1.4.0", "owner/app", self.notes, other)

    def test_malformed_tag_and_repository_are_refused(self):
        for tag in ("1.4.0", "v1.4", "v1.4.0-beta"):
            with self.subTest(tag=tag), self.assertRaises(update_manifest.ManifestError):
                update_manifest.manifest(tag, "owner/app", self.notes, self.image)
        with self.assertRaises(update_manifest.ManifestError):
            update_manifest.manifest("v1.4.0", "https://github.com/owner/app", self.notes, self.image)


if __name__ == "__main__":
    unittest.main()
