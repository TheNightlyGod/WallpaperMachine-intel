#!/usr/bin/env python3
"""Unit tests for scripts/build.py."""
from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("build", SCRIPTS / "build.py")
build = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(build)

IDENTITY = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]


def commit_repository(path, message):
    """Initialise a Git repository at `path` with one commit; return its short commit."""
    path.mkdir(parents=True, exist_ok=True)
    git = ["git", *IDENTITY, "-C", str(path)]
    subprocess.run([*git, "init", "--quiet"], check=True)
    subprocess.run([*git, "commit", "--quiet", "--allow-empty", "-m", message], check=True)
    return subprocess.check_output([*git, "rev-parse", "--short", "HEAD"], text=True).strip()


class RepositoryCommitTests(unittest.TestCase):
    def test_reports_the_repository_not_a_nested_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            application = commit_repository(root, "application source")
            nested = commit_repository(root / "ThirdParty/vendored", "pinned vendored revision")
            self.assertNotEqual(application, nested)
            self.assertEqual(build.repository_commit(root), application)


class XcodeSettingTests(unittest.TestCase):
    def xcodebuild_arguments(self, *arguments):
        calls = []
        with mock.patch.object(sys, "argv", ["build.py", "--swift-only", *arguments]), \
                mock.patch.object(shutil, "which", return_value="/usr/bin/xcodebuild"), \
                mock.patch.object(subprocess, "check_output", return_value="Xcode 16"), \
                mock.patch.object(build, "build_environment", return_value={}), \
                mock.patch.object(build, "run", side_effect=lambda command, *_, **__: calls.append(command)), \
                mock.patch("builtins.print"):
            build.main()
        return next(command for command in calls if command[0] == "xcodebuild")

    def test_passes_each_setting_to_xcodebuild(self):
        command = self.xcodebuild_arguments(
            "--xcode-setting", "SWIFT_USE_INTEGRATED_DRIVER=NO", "--xcode-setting", "CODE_SIGNING_ALLOWED=NO")
        self.assertEqual(command[-2:], ["SWIFT_USE_INTEGRATED_DRIVER=NO", "CODE_SIGNING_ALLOWED=NO"])

    def test_rejects_a_setting_without_a_value(self):
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            self.xcodebuild_arguments("--xcode-setting", "SWIFT_USE_INTEGRATED_DRIVER")


if __name__ == "__main__":
    unittest.main()
