#!/usr/bin/env python3
"""Unit tests for scripts/test.py's command construction."""
from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("test_runner", SCRIPTS / "test.py")
runner = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(runner)


class TestIdentifiers(unittest.TestCase):
    def test_default_is_the_whole_target(self):
        self.assertEqual(runner.test_identifiers("T", None), ["T"])
        self.assertEqual(runner.test_identifiers("T", []), ["T"])
        self.assertEqual(runner.test_identifiers("T", ["", "  "]), ["T"])

    def test_classes_and_methods_are_prefixed_once(self):
        self.assertEqual(
            runner.test_identifiers("T", ["A", "B/testX", "T/C", "/D/"]),
            ["T/A", "T/B/testX", "T/C", "T/D"],
        )


class TestXcodebuildCommand(unittest.TestCase):
    def only_testing(self, only):
        command = runner.xcodebuild_command("S", "T", Path("/tmp/r.xcresult"), only)
        return [part for part in command if part.startswith("-only-testing:")]

    def test_full_run_targets_the_bundle(self):
        self.assertEqual(self.only_testing(None), ["-only-testing:T"])

    def test_targeted_run_lists_each_entry(self):
        self.assertEqual(self.only_testing(["A", "B/testX"]), ["-only-testing:T/A", "-only-testing:T/B/testX"])

    def test_action_stays_last(self):
        self.assertEqual(runner.xcodebuild_command("S", "T", Path("/tmp/r.xcresult"), ["A"])[-1], "test")

    def flag(self, name, **kwargs):
        command = runner.xcodebuild_command("S", "T", Path("/tmp/r.xcresult"), **kwargs)
        return command[command.index(name) + 1]

    def test_only_network_opt_in_extends_the_execution_budget(self):
        for enabled, expected in [("", "90"), ("0", "90"), ("1", "660")]:
            with self.subTest(enabled=enabled), patch.dict(runner.os.environ, {"WALLPAPER_MACHINE_NETWORK_TESTS": enabled}):
                self.assertEqual(self.flag("-maximum-test-execution-time-allowance"), expected)

    def test_parallel_testing_is_on_by_default_and_can_be_turned_off(self):
        self.assertEqual(self.flag("-parallel-testing-enabled"), "YES")
        self.assertEqual(self.flag("-parallel-testing-enabled", parallel=False), "NO")


class PruneResultBundles(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def bundles(self, count):
        for index in range(count):
            (self.directory / f"Tests-{index:03d}.xcresult").mkdir()

    def remaining(self):
        return sorted(entry.name for entry in self.directory.iterdir())

    def test_keeps_the_newest_and_deletes_the_rest(self):
        self.bundles(5)
        runner.prune_result_bundles(keep=2, directory=self.directory)
        self.assertEqual(self.remaining(), ["Tests-003.xcresult", "Tests-004.xcresult"])

    def test_keeps_everything_when_under_the_limit(self):
        self.bundles(2)
        self.assertEqual(runner.prune_result_bundles(keep=5, directory=self.directory), [])
        self.assertEqual(len(self.remaining()), 2)

    def test_leaves_other_files_alone(self):
        self.bundles(3)
        (self.directory / "notes.txt").write_text("keep me")
        runner.prune_result_bundles(keep=1, directory=self.directory)
        self.assertEqual(self.remaining(), ["Tests-002.xcresult", "notes.txt"])

    def test_mixed_ui_and_native_prefixes_keep_the_five_latest_timestamps_and_logs(self):
        names = ([f"UI-2020010{day}-120000" for day in range(1, 6)]
                 + ["Tests-20261003-080000", "UI-20261003-080000-123456", "Tests-20261003-080001"])
        for name in names:
            (self.directory / f"{name}.xcresult").mkdir()
            (self.directory / f"{name}.log").write_text(name)
        stale = runner.prune_result_bundles(directory=self.directory)
        self.assertEqual({entry.stem for entry in stale}, set(names[:3]))
        self.assertEqual(set(self.remaining()), {
            name + suffix for name in names[3:] for suffix in (".xcresult", ".log")
        })


class OptInVariables(unittest.TestCase):
    def test_both_opt_in_layers_are_forwarded(self):
        self.assertEqual(
            set(runner.OPT_IN_VARIABLES),
            {"WALLPAPER_MACHINE_MEDIA_TESTS", "WALLPAPER_MACHINE_NETWORK_TESTS"},
        )

    def test_a_set_layer_reaches_the_test_host_and_an_unset_one_does_not(self):
        env = runner.test_host_environment({"WALLPAPER_MACHINE_MEDIA_TESTS": "1"})
        self.assertEqual(env["TEST_RUNNER_WALLPAPER_MACHINE_MEDIA_TESTS"], "1")
        self.assertNotIn("TEST_RUNNER_WALLPAPER_MACHINE_NETWORK_TESTS", env)


if __name__ == "__main__":
    unittest.main()
