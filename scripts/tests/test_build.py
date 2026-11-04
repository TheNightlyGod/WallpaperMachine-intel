#!/usr/bin/env python3
"""Unit tests for scripts/build.py."""
from __future__ import annotations

import importlib.util
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


def compiled_icon(directory):
    """What `--compile-app-icon` leaves in `directory`."""
    directory.mkdir(parents=True)
    for name in build.APP_ICON_OUTPUTS:
        (directory / name).write_bytes(b"icon")
    (directory / build.APP_ICON_PLIST).write_bytes(build.plistlib.dumps({"CFBundleIconName": "AppIcon"}))
    return directory


class LateAppIconTests(unittest.TestCase):
    """The release build compiles without the icon, which another runner compiles meanwhile."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.app = self.root / "WallpaperMachine.app"
        self.calls = []
        for patch in (mock.patch.object(build, "build_environment", return_value={}),
                      mock.patch.object(build, "app_bundle", return_value=self.app),
                      mock.patch.object(build, "run", side_effect=lambda command, *_, **__: self.calls.append(command)),
                      mock.patch("builtins.print")):
            patch.start()
            self.addCleanup(patch.stop)

    def main(self, *arguments):
        with mock.patch.object(sys, "argv", ["build.py", "--swift-only", "--configuration", "Release", *arguments]):
            build.main()

    def test_a_build_without_the_icon_leaves_it_out_of_the_xcode_build(self):
        self.main("--no-app-icon")
        xcodebuild = next(command for command in self.calls if command[0] == "xcodebuild")
        self.assertIn("EXCLUDED_SOURCE_FILE_NAMES=AppIcon.icon", xcodebuild)
        self.assertNotIn("codesign", [command[0] for command in self.calls])

    def test_installing_the_icon_later_adds_it_to_the_built_app_without_building(self):
        (self.app / "Contents/Resources").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(build.plistlib.dumps({"CFBundleName": "WallpaperMachine"}))

        self.main("--install-app-icon", str(compiled_icon(self.root / "icon")))

        self.assertEqual([command[0] for command in self.calls], ["codesign"])
        self.assertTrue((self.app / "Contents/Resources/Assets.car").is_file())
        info = build.plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info, {"CFBundleName": "WallpaperMachine", "CFBundleIconName": "AppIcon"})

    def test_installing_the_icon_needs_a_built_app(self):
        with self.assertRaises(SystemExit):
            self.main("--install-app-icon", str(compiled_icon(self.root / "icon")))
        self.assertEqual(self.calls, [])

    def test_installing_needs_compiled_icon_output(self):
        (self.root / "empty").mkdir()
        with self.assertRaises(SystemExit):
            self.main("--install-app-icon", str(self.root / "empty"))
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
