#!/usr/bin/env python3
"""Unit tests for scripts/bump_version.py."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "bump_version.py"
SPEC = importlib.util.spec_from_file_location("bump_version", SCRIPT)
bump_version = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(bump_version)

SAMPLE_YML = """name: WallpaperMachine
targets:
  WallpaperMachine:
    settings:
      base:
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
  WallpaperMachineExtension:
    settings:
      base:
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
"""

SAMPLE_PBX = """
				CURRENT_PROJECT_VERSION = 1;
				MARKETING_VERSION = 0.1.0;
				CURRENT_PROJECT_VERSION = 1;
				MARKETING_VERSION = 0.1.0;
"""


class ParseTests(unittest.TestCase):
    def test_subject_patch(self):
        self.assertEqual(bump_version.parse_specs("release: patch\n"), ["patch"])

    def test_case_and_v_prefix(self):
        self.assertEqual(bump_version.parse_specs("Release: V1.2.3\n"), ["1.2.3"])

    def test_body_line_in_merge_commit(self):
        message = "Merge pull request #2 from user/branch\n\nrelease: minor\n"
        self.assertEqual(bump_version.parse_specs(message), ["minor"])

    def test_ignores_ordinary_commits(self):
        self.assertEqual(bump_version.parse_specs("fix: crash on import\n"), [])

    def test_ignores_bump_commit(self):
        self.assertEqual(bump_version.parse_specs("chore: bump version to 0.1.1\n"), [])

    def test_ignores_release_without_spec(self):
        self.assertEqual(bump_version.parse_specs("release the notes\n"), [])

    def test_resolve_highest_bump(self):
        self.assertEqual(bump_version.resolve_specs(["patch", "minor", "patch"]), "minor")

    def test_explicit_version_wins(self):
        self.assertEqual(bump_version.resolve_specs(["major", "1.4.0"]), "1.4.0")

    def test_no_specs(self):
        self.assertIsNone(bump_version.resolve_specs([]))


class BumpTests(unittest.TestCase):
    def test_patch_minor_major(self):
        self.assertEqual(bump_version.bump_marketing("0.1.0", "patch"), "0.1.1")
        self.assertEqual(bump_version.bump_marketing("0.1.9", "minor"), "0.2.0")
        self.assertEqual(bump_version.bump_marketing("0.9.1", "major"), "1.0.0")

    def test_explicit_same_or_higher(self):
        self.assertEqual(bump_version.bump_marketing("0.1.0", "0.1.0"), "0.1.0")
        self.assertEqual(bump_version.bump_marketing("0.1.0", "v2.0.0"), "2.0.0")

    def test_refuses_downgrade(self):
        with self.assertRaises(bump_version.VersionError):
            bump_version.bump_marketing("1.0.0", "0.9.0")

    def test_invalid_semver(self):
        with self.assertRaises(bump_version.VersionError):
            bump_version.bump_marketing("0.1.0", "1.2")

    def test_next_build(self):
        self.assertEqual(bump_version.next_build("1"), "2")
        with self.assertRaises(bump_version.VersionError):
            bump_version.next_build("build")


class FileUpdateTests(unittest.TestCase):
    def test_replaces_every_yml_entry(self):
        updated = bump_version.replace_project_yml(SAMPLE_YML, "0.2.0", "3")
        self.assertEqual(updated.count('MARKETING_VERSION: "0.2.0"'), 2)
        self.assertEqual(updated.count('CURRENT_PROJECT_VERSION: "3"'), 2)
        self.assertNotIn("0.1.0", updated)

    def test_replaces_every_pbx_entry(self):
        updated = bump_version.replace_pbxproj(SAMPLE_PBX, "0.2.0", "3")
        self.assertEqual(updated.count("MARKETING_VERSION = 0.2.0;"), 2)
        self.assertEqual(updated.count("CURRENT_PROJECT_VERSION = 3;"), 2)

    def test_plan_and_apply(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "WallpaperMachine.xcodeproj").mkdir()
            (root / "project.yml").write_text(SAMPLE_YML)
            (root / "WallpaperMachine.xcodeproj/project.pbxproj").write_text(SAMPLE_PBX)
            plan = bump_version.plan_bump(root, "minor")
            self.assertEqual(plan["new_marketing"], "0.2.0")
            self.assertEqual(plan["new_build"], "2")
            self.assertTrue(plan["changed"])
            self.assertEqual(plan["tag"], "v0.2.0")
            bump_version.apply_bump(root, "0.2.0", "2")
            yml = (root / "project.yml").read_text()
            self.assertIn('MARKETING_VERSION: "0.2.0"', yml)
            self.assertIn('CURRENT_PROJECT_VERSION: "2"', yml)
            self.assertIn("MARKETING_VERSION = 0.2.0;", (root / "WallpaperMachine.xcodeproj/project.pbxproj").read_text())

    def test_plan_skips_unchanged_explicit_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "project.yml").write_text(SAMPLE_YML)
            plan = bump_version.plan_bump(root, "0.1.0")
            self.assertFalse(plan["changed"])
            self.assertEqual(plan["new_build"], "1")

    def test_github_event_messages(self):
        event = {
            "head_commit": {"message": "Merge pull request #2 from user/branch\n"},
            "commits": [
                {"message": "Merge pull request #2 from user/branch\n"},
                {"message": "release: patch\n\nqueue downloads\n"},
            ],
        }
        messages = bump_version.collect_event_messages(event)
        self.assertEqual(bump_version.spec_from_messages(messages), "patch")

    def test_github_output_format(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "output"
            bump_version.write_github_output(path, {"changed": True, "new_marketing": "0.2.0", "tag": "v0.2.0"})
            text = path.read_text()
            self.assertIn("changed=true\n", text)
            self.assertIn("new_marketing=0.2.0\n", text)
            self.assertIn("tag=v0.2.0\n", text)


class HotfixTests(unittest.TestCase):
    def test_a_hotfix_is_the_next_patch_and_the_newest_version(self):
        bump_version.check_hotfix("1.6.5", "1.6.6", ["v1.6.4", "v1.6.5"])
        bump_version.check_hotfix("1.6.6", "1.6.7", ["v1.6.5", "v1.6.6"])
        refused = {
            "minor": ("1.6.5", "1.7.0", ["v1.6.5"]),
            "major": ("1.6.5", "2.0.0", ["v1.6.5"]),
            "same version": ("1.6.5", "1.6.5", ["v1.6.5"]),
            "older line": ("1.5.9", "1.5.10", ["v1.5.9", "v1.6.0"]),
            "taken": ("1.6.5", "1.6.6", ["v1.6.5", "v1.6.6"]),
            "behind the newest release": ("1.6.5", "1.6.7", ["v1.6.5", "v1.6.6"]),
            "ahead of the newest release": ("1.6.7", "1.6.8", ["v1.6.5", "v1.6.6"]),
        }
        for reason, (current, new, tags) in refused.items():
            with self.subTest(reason), self.assertRaises(bump_version.VersionError):
                bump_version.check_hotfix(current, new, tags)

    def test_hotfix_branch_refuses_a_minor_release_from_the_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "WallpaperMachine.xcodeproj").mkdir()
            (root / "project.yml").write_text(SAMPLE_YML)
            (root / "WallpaperMachine.xcodeproj/project.pbxproj").write_text(SAMPLE_PBX)
            for spec, status in (("minor", 1), ("patch", 0)):
                with self.subTest(spec), patch.object(bump_version.sys, "argv", [
                    "bump_version.py", "--spec", spec, "--branch", "hotfix/0.1.0", "--root", str(root),
                    "--output", str(root / "out")]):
                    self.assertEqual(bump_version.main(), status)
            self.assertIn('MARKETING_VERSION: "0.1.0"', (root / "project.yml").read_text(), "No --apply, no write")

    def test_commits_a_tag_contains_are_not_released_again(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
            git("init", "-q")
            git("config", "user.email", "test@example.com")
            git("config", "user.name", "Test")
            git("commit", "-q", "--allow-empty", "-m", "fix: the hotfix\n\nrelease: patch")
            released = git("rev-parse", "HEAD")
            git("tag", "v0.1.1")
            git("commit", "-q", "--allow-empty", "-m", "chore: merge hotfix 0.1.1 into main")
            merged = git("rev-parse", "HEAD")
            event = {
                "head_commit": {"id": merged, "message": "chore: merge hotfix 0.1.1 into main"},
                "commits": [{"id": released, "message": "fix: the hotfix\n\nrelease: patch"},
                            {"id": merged, "message": "chore: merge hotfix 0.1.1 into main"}],
            }
            messages = bump_version.collect_event_messages(event, lambda commit: bump_version.tagged_commit(root, commit))
            self.assertIsNone(bump_version.spec_from_messages(messages))
            self.assertFalse(bump_version.tagged_commit(root, merged))
            self.assertFalse(bump_version.tagged_commit(root, "0" * 40), "An unknown commit is not released")


class MergedHotfixTests(unittest.TestCase):
    def test_main_releases_only_once_the_newest_tag_is_merged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True)
            git("init", "-q", "-b", "main")
            git("config", "user.email", "test@example.com")
            git("config", "user.name", "Test")
            git("commit", "-q", "--allow-empty", "-m", "base")
            git("tag", "v0.1.0")
            git("switch", "-q", "-c", "hotfix/0.1.0")
            git("commit", "-q", "--allow-empty", "-m", "fix")
            git("tag", "v0.1.1")
            git("switch", "-q", "main")
            git("commit", "-q", "--allow-empty", "-m", "feature")
            with self.assertRaises(bump_version.VersionError):
                bump_version.check_contains_newest_release(root, bump_version.version_tags(root))
            git("merge", "-q", "--no-ff", "--no-edit", "v0.1.1")
            bump_version.check_contains_newest_release(root, bump_version.version_tags(root))
            bump_version.check_contains_newest_release(root, [])


class RepoFileTests(unittest.TestCase):
    def test_checked_in_project_yml_is_valid(self):
        root = Path(__file__).resolve().parents[2]
        marketing, build = bump_version.read_yml_versions((root / "project.yml").read_text())
        bump_version.parse_semver(marketing)
        self.assertGreaterEqual(int(build), 1)
        pbx = (root / "WallpaperMachine.xcodeproj/project.pbxproj").read_text()
        self.assertGreaterEqual(len(bump_version.PBX_MARKETING.findall(pbx)), 2)
        self.assertGreaterEqual(len(bump_version.PBX_BUILD.findall(pbx)), 2)


class CLITests(unittest.TestCase):
    def test_ci_uses_release_spec_env(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "WallpaperMachine.xcodeproj").mkdir()
            (root / "project.yml").write_text(SAMPLE_YML)
            (root / "WallpaperMachine.xcodeproj/project.pbxproj").write_text(SAMPLE_PBX)
            output = root / "github-output"
            env = {"RELEASE_SPEC": "patch", "GITHUB_OUTPUT": str(output), "GITHUB_REF_NAME": ""}
            with patch.dict(os.environ, env, clear=False), patch.object(
                bump_version.sys, "argv", ["bump_version.py", "--ci", "--apply", "--root", str(root)]
            ):
                self.assertEqual(bump_version.main(), 0)
            self.assertIn("0.1.1", (root / "project.yml").read_text())
            self.assertIn("changed=true", output.read_text())

    def test_ci_reads_event_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "WallpaperMachine.xcodeproj").mkdir()
            (root / "project.yml").write_text(SAMPLE_YML)
            (root / "WallpaperMachine.xcodeproj/project.pbxproj").write_text(SAMPLE_PBX)
            event = root / "event.json"
            event.write_text(json.dumps({"head_commit": {"message": "release: major\n"}}))
            output = root / "github-output"
            env = {"GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output), "RELEASE_SPEC": "",
                   "GITHUB_REF_NAME": ""}
            with patch.dict(os.environ, env, clear=False), patch.object(
                bump_version.sys, "argv", ["bump_version.py", "--ci", "--root", str(root)]
            ):
                self.assertEqual(bump_version.main(), 0)
            self.assertIn("new_marketing=1.0.0", output.read_text())
            self.assertIn('MARKETING_VERSION: "0.1.0"', (root / "project.yml").read_text())

    def test_no_spec_is_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "github-output"
            with patch.object(
                bump_version.sys,
                "argv",
                ["bump_version.py", "--message", "fix: nits", "--output", str(output), "--root", str(root)],
            ):
                self.assertEqual(bump_version.main(), 0)
            self.assertIn("changed=false", output.read_text())


if __name__ == "__main__":
    unittest.main()
