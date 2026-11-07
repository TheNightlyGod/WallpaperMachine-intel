#!/usr/bin/env python3
"""Unit tests for scripts/publish_release.py."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("publish_release", SCRIPTS / "publish_release.py")
publish_release = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(publish_release)

def release_fixture(root, tag):
    image = root / f"WallpaperMachine-{tag[1:]}-arm64.dmg"
    image.write_bytes(b"signed image fixture")
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    checksum = root / (image.name + ".sha256")
    checksum.write_text(f"{digest}  {image.name}\n")
    notes = root / "notes.md"
    notes.write_text("Release notes\n")
    manifest = root / "WallpaperMachine-update.json"
    manifest.write_text(json.dumps({
        "tag_name": tag, "prerelease": False, "body": notes.read_text(),
        "minimum_system_version": "15.0", "architectures": ["arm64"],
        "bundle_identifier": "app.wallpapermachine",
        "assets": [{"name": image.name, "size": image.stat().st_size, "digest": "sha256:" + digest,
                    "browser_download_url": f"https://github.com/owner/repo/releases/download/{tag}/{image.name}"}],
    }))
    return str(notes), [str(image), str(checksum), str(manifest)]


def publish_fixture(github, tag="v0.6.0"):
    with tempfile.TemporaryDirectory() as directory:
        notes, assets = release_fixture(Path(directory), tag)
        return publish_release.publish(tag, notes, assets, run=github)


def completed(stdout="", returncode=0):
    return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr="")


class FakeGitHub:
    def __init__(self, draft=None, published=(), prereleases=(), drafted=(), fail_on=None):
        self.draft = draft
        self.published = list(published)
        self.prereleases = list(prereleases)
        self.drafted = list(drafted)
        self.fail_on = fail_on
        self.calls: list[list[str]] = []
        self.uploaded = []

    def __call__(self, command, check=True):
        self.calls.append(command)
        verb = command[2] if len(command) > 2 else ""
        if verb == "view":
            if "assets,isDraft,tagName" in command:
                return completed(json.dumps({"assets": self.uploaded, "isDraft": True, "tagName": command[3]}))
            if self.draft is None:
                return completed(returncode=1)
            return completed("true\n" if self.draft else "false\n")
        if verb == "list":
            entries = [{"tagName": tag, "isDraft": False, "isPrerelease": False} for tag in self.published]
            entries += [{"tagName": tag, "isDraft": False, "isPrerelease": True} for tag in self.prereleases]
            entries += [{"tagName": tag, "isDraft": True, "isPrerelease": False} for tag in self.drafted]
            return completed(json.dumps(entries))
        if self.fail_on and self.fail_on in command:
            raise publish_release.PublishError(f"{verb} failed")
        if verb == "upload":
            self.uploaded = [{"name": Path(path).name, "size": Path(path).stat().st_size,
                              "digest": "sha256:" + hashlib.sha256(Path(path).read_bytes()).hexdigest()}
                             for path in command[4:] if not path.startswith("--")]
        return completed()

    @property
    def mutations(self):
        return [command for command in self.calls if command[2] not in ("view", "list")]


class PlanTests(unittest.TestCase):
    def test_no_release_is_created(self):
        self.assertEqual(publish_release.plan(None), publish_release.CREATE)

    def test_a_draft_is_resumed(self):
        self.assertEqual(publish_release.plan(True), publish_release.RESUME)

    def test_a_published_release_is_refused(self):
        self.assertEqual(publish_release.plan(False), publish_release.REFUSE)


class PublishTests(unittest.TestCase):
    def publish(self, github, tag="v0.6.0"):
        return publish_fixture(github, tag)

    def test_a_new_tag_is_drafted_uploaded_then_published(self):
        github = FakeGitHub(draft=None)
        action, latest = self.publish(github)
        self.assertEqual(action, publish_release.CREATE)
        self.assertTrue(latest)
        self.assertEqual([command[1:4] for command in github.mutations],
                         [["release", "create", "v0.6.0"],
                          ["release", "upload", "v0.6.0"],
                          ["release", "edit", "v0.6.0"]])
        self.assertIn("--draft", github.mutations[0])
        self.assertIn("--draft=false", github.mutations[2])

    def test_an_interrupted_run_finishes_its_own_draft(self):
        github = FakeGitHub(draft=True)
        action, _ = self.publish(github)
        self.assertEqual(action, publish_release.RESUME)
        self.assertEqual(github.mutations[0][1:3], ["release", "edit"])
        self.assertNotIn("--draft", github.mutations[0])

    def test_a_published_release_is_never_touched(self):
        github = FakeGitHub(draft=False, published=["v0.6.0"])
        with self.assertRaises(publish_release.PublishError):
            self.publish(github)
        self.assertEqual(github.mutations, [], "A live release must not be edited, cleared or clobbered")

    def test_a_failed_upload_leaves_the_release_a_draft(self):
        github = FakeGitHub(draft=None, fail_on="upload")
        with self.assertRaises(publish_release.PublishError):
            self.publish(github)
        cleared = [command for command in github.mutations if "--draft=false" in command]
        self.assertEqual(cleared, [], "Nothing may publish a release whose upload failed")


class AssetContractTests(unittest.TestCase):
    def test_missing_manifest_or_wrong_digest_never_mutates_github(self):
        with tempfile.TemporaryDirectory() as directory:
            notes, assets = release_fixture(Path(directory), "v0.6.0")
            github = FakeGitHub()
            with self.assertRaises(publish_release.PublishError):
                publish_release.publish("v0.6.0", notes, assets[:2], run=github)
            Path(assets[0]).write_bytes(b"changed")
            with self.assertRaises(publish_release.PublishError):
                publish_release.publish("v0.6.0", notes, assets, run=github)
            self.assertEqual(github.mutations, [])

    def test_uploaded_mismatch_is_never_promoted(self):
        class MissingAsset(FakeGitHub):
            def __call__(self, command, check=True):
                if "assets,isDraft,tagName" in command:
                    self.uploaded.pop()
                return super().__call__(command, check)
        github = MissingAsset()
        with self.assertRaises(publish_release.PublishError):
            publish_fixture(github)
        self.assertFalse(any("--draft=false" in command for command in github.mutations))

    def test_dry_run_never_uploads_or_promotes(self):
        with tempfile.TemporaryDirectory() as directory:
            notes, assets = release_fixture(Path(directory), "v0.6.0")
            github = FakeGitHub()
            publish_release.publish("v0.6.0", notes, assets, run=github, dry_run=True)
            self.assertEqual(github.mutations, [])


class LatestTests(unittest.TestCase):
    def test_a_newer_release_published_during_upload_is_observed_before_promotion(self):
        class InterleavedGitHub(FakeGitHub):
            def __call__(self, command, check=True):
                result = super().__call__(command, check)
                if command[2] == "upload":
                    self.published.append("v0.7.0")
                return result

        github = InterleavedGitHub(published=["v0.5.0"])
        _, latest = publish_fixture(github, "v0.6.0")
        self.assertFalse(latest)
        self.assertIn("--latest=false", github.mutations[-1])

    def test_newer_finishing_after_an_older_upload_still_becomes_latest(self):
        class InterleavedGitHub(FakeGitHub):
            def __call__(self, command, check=True):
                result = super().__call__(command, check)
                if command[2] == "upload":
                    self.published.append("v0.6.0")
                return result

        github = InterleavedGitHub(published=["v0.5.0"])
        _, latest = publish_fixture(github, "v0.7.0")
        self.assertTrue(latest)
        self.assertIn("--latest", github.mutations[-1])

    def test_failed_final_version_lookup_never_publishes_the_uploaded_draft(self):
        class UnavailableGitHub(FakeGitHub):
            def __call__(self, command, check=True):
                if command[2] == "list":
                    raise publish_release.PublishError("list failed")
                return super().__call__(command, check)

        github = UnavailableGitHub()
        with self.assertRaises(publish_release.PublishError):
            publish_fixture(github, "v0.7.0")
        self.assertFalse(any("--draft=false" in command for command in github.mutations))

    def test_the_first_release_claims_latest(self):
        self.assertTrue(publish_release.promotes_to_latest("v0.6.0", []))

    def test_a_newer_version_claims_latest(self):
        self.assertTrue(publish_release.promotes_to_latest("v0.6.0", [(0, 5, 0), (0, 4, 0)]))

    def test_an_older_build_finishing_last_does_not_steal_latest(self):
        # v0.7.0 built faster and published first; v0.6.0 must not demote it.
        github = FakeGitHub(draft=None, published=["v0.7.0"])
        _, latest = publish_fixture(github, "v0.6.0")
        self.assertFalse(latest)
        self.assertIn("--latest=false", github.mutations[-1])

    def test_the_newer_build_finishing_last_does_claim_latest(self):
        github = FakeGitHub(draft=None, published=["v0.6.0"])
        _, latest = publish_fixture(github, "v0.7.0")
        self.assertTrue(latest)
        self.assertIn("--latest", github.mutations[-1])

    def test_a_greater_prerelease_or_draft_does_not_block_latest(self):
        github = FakeGitHub(draft=None, published=["v0.5.0"], prereleases=["v0.9.0"], drafted=["v0.8.0"])
        _, latest = publish_fixture(github, "v0.6.0")
        self.assertTrue(latest, "Only a public, non-prerelease version is what the updater reads")
        self.assertIn("--latest", github.mutations[-1])

    def test_a_tag_that_is_not_a_version_is_refused(self):
        with self.assertRaises(publish_release.PublishError):
            publish_release.promotes_to_latest("nightly", [])


if __name__ == "__main__":
    unittest.main()
