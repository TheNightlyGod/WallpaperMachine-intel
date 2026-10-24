#!/usr/bin/env python3
"""Unit tests for the manifest and measurement parsers in scripts/power_benchmark.py."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("power_benchmark", SCRIPTS / "power_benchmark.py")
power_benchmark = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(power_benchmark)


class MainTests(unittest.TestCase):
    def test_manifest_write_uses_workspace_dirty_state(self):
        for dirty in (False, True):
            with self.subTest(dirty=dirty), tempfile.TemporaryDirectory() as directory:
                document = {"schema_version": 2, "workspace": {"dirty": dirty},
                            "build": {"status": "unknown", "processes": {}}, "conditions": []}
                with mock.patch.object(sys, "argv", ["power_benchmark.py"]), \
                     mock.patch.object(power_benchmark, "manifest", return_value=document), \
                     mock.patch.object(power_benchmark, "POWER_ARTIFACTS", Path(directory)), \
                     mock.patch("builtins.print") as output:
                    self.assertEqual(power_benchmark.main(), 0)
                artifacts = list(Path(directory).glob("*.json"))
                self.assertEqual(len(artifacts), 1)
                self.assertEqual(json.loads(artifacts[0].read_text()), document)
                warnings = [call for call in output.call_args_list if "Working tree is dirty" in str(call)]
                self.assertEqual(len(warnings), int(dirty))


class CommandOutputTests(unittest.TestCase):
    def test_a_failing_inspection_reports_nothing_rather_than_an_empty_string(self):
        self.assertIsNone(power_benchmark.command_output([sys.executable, "-c", "raise SystemExit(3)"]))

    def test_a_missing_tool_does_not_raise(self):
        self.assertIsNone(power_benchmark.command_output(["mwe-tool-that-does-not-exist"]))

    def test_output_is_stripped(self):
        self.assertEqual(
            power_benchmark.command_output([sys.executable, "-c", "print('  value  ')"]),
            "value")


class ParserTests(unittest.TestCase):
    def test_malformed_hardware_json_yields_an_empty_section(self):
        original = power_benchmark.command_output
        power_benchmark.command_output = lambda command: "{not json"
        try:
            self.assertEqual(power_benchmark.hardware(), {})
            self.assertEqual(power_benchmark.displays(), [])
        finally:
            power_benchmark.command_output = original

    def test_displays_are_flattened_across_graphics_cards(self):
        payload = json.dumps({"SPDisplaysDataType": [
            {"spdisplays_ndrvs": [
                {"_name": "Built-in", "_spdisplays_pixels": "3456 x 2234", "ignored": "x"},
                {"_name": "External", "_spdisplays_pixels": "6880 x 2880"},
            ]},
            {"spdisplays_ndrvs": [{"_name": "Third", "_spdisplays_pixels": "1920 x 1080"}]},
        ]})
        original = power_benchmark.command_output
        power_benchmark.command_output = lambda command: payload
        try:
            found = power_benchmark.displays()
        finally:
            power_benchmark.command_output = original
        self.assertEqual([entry["_name"] for entry in found], ["Built-in", "External", "Third"])
        self.assertNotIn("ignored", found[0], "only geometry fields are recorded")

    def test_vendored_revisions_are_keyed_by_the_directory_they_ship_from(self):
        revisions = power_benchmark.provenance()
        self.assertIn("ThirdParty/naga", revisions)
        self.assertIn("ThirdParty/mediaremote-adapter", revisions)
        self.assertTrue(all(revisions.values()), "a recorded entry must carry its pinned revision")
        for first_party in ("App", "Renderer", "Renderer/Engine"):
            self.assertNotIn(first_party, revisions, "first-party directories pin no vendored revision")

    def test_a_card_without_displays_contributes_nothing(self):
        original = power_benchmark.command_output
        power_benchmark.command_output = lambda command: json.dumps(
            {"SPDisplaysDataType": [{"_name": "Headless"}]})
        try:
            self.assertEqual(power_benchmark.displays(), [])
        finally:
            power_benchmark.command_output = original


class ManifestTests(unittest.TestCase):
    def manifest(self):
        return power_benchmark.manifest(
            argparse.Namespace(configuration="Release", note="test"))

    def test_every_condition_starts_unmeasured(self):
        document = self.manifest()
        self.assertFalse(document["measured"])
        self.assertIsNone(document["measurement_tool"])
        self.assertTrue(document["conditions"])
        self.assertTrue(all(not entry["measured"] for entry in document["conditions"]))

    def test_the_baseline_and_load_matrix_is_complete(self):
        ids = [entry["id"] for entry in self.manifest()["conditions"]]
        self.assertEqual(ids, ["B0", "B1", "B2", "T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8"])

    def test_the_manifest_is_json_serializable(self):
        json.loads(json.dumps(self.manifest()))


class ProcessBuildIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.contents = self.root / "Old.app/Contents"
        (self.contents / "MacOS").mkdir(parents=True)
        self.executable = self.contents / "MacOS/WallpaperMachine"
        self.executable.write_bytes(b"old running binary")
        (self.contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "app.wallpapermachine", "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "7",
        }))
        self.stamp = {"executable": str(self.executable), "launched_at": "fixture launch",
                      "started_epoch": time.time() + 60}

    def identity(self):
        with mock.patch.object(power_benchmark, "process_stamp", return_value=self.stamp), \
                mock.patch.object(power_benchmark, "command_output", return_value="arm64"):
            return power_benchmark.process_build_identity(42)

    def test_old_process_is_not_labelled_with_the_current_worktree_commit_or_version(self):
        (self.root / "project.yml").write_text('MARKETING_VERSION: "2.0.0"\n')
        with mock.patch.object(power_benchmark, "ROOT", self.root), \
                mock.patch.object(power_benchmark, "command_output", side_effect=lambda command: "new-head" if command[-1] == "HEAD" else ""):
            workspace = power_benchmark.workspace_identity("Release")
        identity = self.identity()
        self.assertEqual(workspace["commit"], "new-head")
        self.assertEqual(workspace["marketing_version"], "2.0.0")
        self.assertEqual(identity["status"], "identified")
        self.assertEqual(identity["marketing_version"], "1.0.0")
        self.assertEqual(identity["binary_architectures"], ["arm64"])
        self.assertEqual(identity["executable_sha256"], power_benchmark.hashlib.sha256(b"old running binary").hexdigest())
        self.assertIsNone(identity["source_revision"])
        self.assertIsNone(identity["configuration"])
        self.assertIsNone(identity["loaded_renderer_libraries"])

    def test_missing_process_and_a_rebuilt_bundle_are_unknown(self):
        with mock.patch.object(power_benchmark, "process_stamp", return_value=None):
            self.assertEqual(power_benchmark.process_build_identity(42)["status"], "unknown")
        self.stamp["started_epoch"] = 0
        identity = self.identity()
        self.assertEqual(identity["status"], "unknown")
        self.assertNotIn("marketing_version", identity)
        self.assertNotIn("executable_sha256", identity)

    def test_replacing_the_executable_during_the_window_invalidates_attribution(self):
        identity = self.identity()
        self.executable.write_bytes(b"replacement binary")
        with mock.patch.object(power_benchmark, "process_stamp", return_value=self.stamp):
            verified = power_benchmark.verify_process_build(identity)
        self.assertEqual(verified["status"], "unknown")
        self.assertNotIn("executable_sha256", verified)

    def test_attachment_keeps_process_identity_separate_from_the_workspace(self):
        identity = self.identity()
        document = {"workspace": {"commit": "new-head"}, "conditions": [{"id": "T1", "measured": False}]}
        sample = {"process_builds": {"app": [identity], "extension": []}, "tools": ["fixture"],
                  "elapsed_seconds": 1, "processes": {}, "coalitions": {}, "system_power": {}, "package_power": {}}
        power_benchmark.attach_measurement(document, "T1", 1, sample)
        self.assertEqual(document["workspace"]["commit"], "new-head")
        self.assertEqual(document["build"]["processes"]["app"][0]["marketing_version"], "1.0.0")
        self.assertTrue(document["conditions"][0]["measured"])


GPU_CLIENTS = """\
+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x1000010bd, !registered, !matched, active>
    {
      "AppUsage" = ()
      "IOUserClientCreator" = "pid 443, WindowServer"
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x1000010bf, !registered, !matched, active>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=18,"accumulatedGPUTime"=1000},\
{"API"="Metal","lastSubmittedTime"=0,"accumulatedGPUTime"=500})
      "IOUserClientCreator" = "pid 443, WindowServer"
      "CommandQueueCount" = 2
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100001226, !registered, !matched, active>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=20,"accumulatedGPUTime"=7})
      "IOUserClientCreator" = "pid 29493, WallpaperMachine"
    }
"""

POWERMETRICS_SAMPLES = """\
*** Sampled system activity (Wed Sep 23 10:00:00 2026 +0800) (1003.21ms elapsed) ***

**** Processor usage ****

E-Cluster Power: 90 mW
CPU Power: 1000 mW
GPU Power: 400 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1400 mW

**** GPU usage ****

GPU HW active residency:  60.00%
GPU Power: 400 mW

*** Sampled system activity (Wed Sep 23 10:00:01 2026 +0800) (1001.02ms elapsed) ***

**** Processor usage ****

E-Cluster Power: 110 mW
CPU Power: 2000 mW
GPU Power: 600 mW
ANE Power: 10 mW
Combined Power (CPU + GPU + ANE): 2610 mW

**** GPU usage ****

GPU Power: 600 mW
"""


class MeasurementParserTests(unittest.TestCase):
    def test_cpu_time_accepts_unbounded_minutes_hours_and_days(self):
        self.assertAlmostEqual(power_benchmark.parse_cpu_time("419:00.62"), 25140.62)
        self.assertAlmostEqual(power_benchmark.parse_cpu_time("1:02:03.04"), 3723.04)
        self.assertAlmostEqual(power_benchmark.parse_cpu_time("2-01:00:00.00"), 176400.0)

    def test_cpu_time_rejects_anything_else(self):
        for text in ("", "12", "cpu", "1:2:3:4", "-1:00"):
            self.assertIsNone(power_benchmark.parse_cpu_time(text), text)

    def test_gpu_time_is_summed_over_every_client_of_a_process(self):
        self.assertEqual(power_benchmark.parse_gpu_times(GPU_CLIENTS), {443: 1500, 29493: 7})

    def test_package_power_is_the_mean_over_samples(self):
        power = power_benchmark.parse_powermetrics(POWERMETRICS_SAMPLES)
        self.assertTrue(power["measured"])
        self.assertEqual(power["samples"], 2)
        self.assertEqual((power["cpu_mw"], power["gpu_mw"], power["ane_mw"], power["combined_mw"]),
                         (1500.0, 500.0, 5.0, 2005.0))

    def test_output_without_samples_is_not_a_measurement(self):
        power = power_benchmark.parse_powermetrics("powermetrics must be invoked as the superuser")
        self.assertFalse(power["measured"])

    def test_system_power_is_the_mean_of_the_readings_taken_in_the_window(self):
        before = {"AccumulatedSystemLoad": 1_000_000, "SystemLoadAccumulatorCount": 100,
                  "AccumulatedSystemPowerIn": 5_000, "SystemPowerInAccumulatorCount": 7}
        after = {"AccumulatedSystemLoad": 1_000_000 + 3 * 20_000 + 2 * 23_000,
                 "SystemLoadAccumulatorCount": 105,
                 "AccumulatedSystemPowerIn": 5_000, "SystemPowerInAccumulatorCount": 7}
        power = power_benchmark.system_power(before, after)
        self.assertTrue(power["measured"])
        self.assertEqual((power["load_mw"], power["samples"]), (21_200, 5))
        self.assertIsNone(power["power_in_mw"], "an adapter that delivered nothing has no mean")

    def test_system_power_without_new_readings_or_a_battery_is_not_a_measurement(self):
        snapshot = {"AccumulatedSystemLoad": 10, "SystemLoadAccumulatorCount": 1}
        self.assertFalse(power_benchmark.system_power(snapshot, dict(snapshot))["measured"])
        self.assertFalse(power_benchmark.system_power(None, snapshot)["measured"])

    def test_battery_telemetry_is_read_from_the_plist_ioreg_prints(self):
        telemetry = {"SystemLoad": 21_503, "AccumulatedSystemLoad": 6_226_785_686,
                     "SystemLoadAccumulatorCount": 225_876}
        text = plistlib.dumps([{"PowerTelemetryData": telemetry, "Voltage": 12_316}]).decode()
        self.assertEqual(power_benchmark.parse_power_telemetry(text), telemetry)
        self.assertIsNone(power_benchmark.parse_power_telemetry("not a plist"))
        self.assertIsNone(power_benchmark.parse_power_telemetry(plistlib.dumps([]).decode()))


class CoalitionTests(unittest.TestCase):
    def snapshot(self, counters, roles=None):
        return {"roles": roles or {"app": [10], "window_server": [20]}, "counters": counters}

    def test_list_entries_are_read_as_ids_every_sixteen_bytes(self):
        # Each entry is a uint64 id followed by two uint32 words (type, task count).
        words = [101, 0x0000_0003_0000_0000, 202, 0x0000_0001_0000_0000, 999, 999]
        self.assertEqual(power_benchmark.coalition_ids_from_entries(words, 32), [101, 202])
        self.assertEqual(power_benchmark.coalition_ids_from_entries(words, 0), [])

    def test_each_role_and_all_coalitions_are_reported_in_milliwatts(self):
        before = self.snapshot({10: (0, 0, 0), 20: (0, 0, 0), 30: (0, 0, 0)})
        after = self.snapshot({10: (2_000_000_000, 10_000_000_000, 1_000_000_000),
                               20: (1_000_000_000, 1_000_000_000, 200_000_000),
                               30: (500_000_000, 0, 0)})
        usage = power_benchmark.coalition_usage(before, after, 2.0)
        self.assertTrue(usage["measured"])
        self.assertEqual(usage["roles"]["app"],
                         {"coalitions": [10], "cpu_mw": 1000, "gpu_mw": 5000, "gpu_busy_percent": 50.0})
        self.assertEqual(usage["roles"]["window_server"]["gpu_mw"], 500)
        self.assertEqual((usage["all"]["cpu_mw"], usage["all"]["gpu_mw"]), (1750, 5500))
        self.assertEqual(usage["other_gpu_busy_percent"], 10.0, "the app's own GPU time is not contention")
        self.assertFalse(usage["gpu_contended"])

    def test_other_coalitions_busy_for_a_quarter_of_the_window_mark_it_contended(self):
        before = self.snapshot({10: (0, 0, 0), 30: (0, 0, 0)})
        after = self.snapshot({10: (0, 0, 0), 30: (0, 0, 500_000_000)})
        self.assertTrue(power_benchmark.coalition_usage(before, after, 2.0)["gpu_contended"])

    def test_a_coalition_that_ended_or_went_backwards_is_left_out(self):
        before = self.snapshot({10: (5, 5, 5), 20: (0, 0, 0)})
        after = self.snapshot({10: (1, 1, 1)})
        usage = power_benchmark.coalition_usage(before, after, 1.0)
        self.assertEqual(usage["roles"]["window_server"], {"coalitions": [20]},
                         "a role whose coalition disappeared reports no figure")
        self.assertEqual(usage["all"]["cpu_mw"], 0)

    def test_a_role_sharing_the_app_coalition_is_not_charged_its_energy_again(self):
        reader = SimpleNamespace(coalition_of={1: 10, 2: 10, 3: 40}.get,
                                 coalition_ids=lambda: [10, 40],
                                 counters=lambda coalition: (1, 1, 1))
        snapshot = power_benchmark.coalition_snapshot(reader, {"app": [1], "web_content": [2, 3]})
        self.assertEqual(snapshot["roles"], {"app": [10], "web_content": [40]})

    def test_without_accounting_nothing_is_measured(self):
        self.assertFalse(power_benchmark.coalition_usage(None, None, 1.0)["measured"])
        self.assertFalse(power_benchmark.coalition_snapshot(None, {"app": [1]}))

    def test_a_listing_that_fails_at_the_end_is_unavailable_not_zero(self):
        before = self.snapshot({10: (0, 0, 0)})
        failing = SimpleNamespace(coalition_of={1: 10}.get, coalition_ids=lambda: None,
                                  counters=lambda coalition: (1, 1, 1))
        after = power_benchmark.coalition_snapshot(failing, {"app": [1]})
        self.assertIsNone(after, "a failed listing is no snapshot at all")
        self.assertFalse(power_benchmark.coalition_usage(before, after, 1.0)["measured"])
        self.assertFalse(power_benchmark.coalition_usage(before, self.snapshot({}), 1.0)["measured"],
                         "an empty final snapshot must not read as zero power")
        self.assertFalse(
            power_benchmark.coalition_usage(before, self.snapshot({20: (5, 5, 5)}), 1.0)["measured"],
            "no coalition read at both ends leaves nothing to measure")

    @unittest.skipUnless(sys.platform == "darwin", "resource coalitions are a Darwin feature")
    def test_this_process_has_a_readable_coalition(self):
        reader = power_benchmark.CoalitionReader.open()
        if reader is None:
            self.skipTest("libsystem does not export the coalition calls")
        coalition = reader.coalition_of(os.getpid())
        self.assertIsNotNone(coalition)
        self.assertIn(coalition, reader.coalition_ids())
        cpu_before = reader.counters(coalition)[0]
        deadline = time.monotonic() + 0.2
        while time.monotonic() < deadline:
            sum(range(10_000))
        cpu_after = reader.counters(coalition)[0]
        if cpu_before == 0 and cpu_after == 0:
            # GitHub's macOS runners are virtual machines whose kernel has no energy
            # model: the field exists, is readable, and stays 0 for every coalition.
            self.skipTest("the kernel charges no CPU energy to coalitions on this machine")
        self.assertGreater(cpu_after, cpu_before,
                           "CPU work must move the CPU energy field; a moved field reads flat")


class MeasureWindowTests(unittest.TestCase):
    def test_a_refused_powermetrics_still_measures_the_whole_window(self):
        # sudo rejecting the password returns at once. Taking the second
        # samples then would turn a 60-second measurement into a rate over a
        # fraction of a second.
        clock = SimpleNamespace(now=5_000.0, slept=[])

        def sleep(seconds):
            clock.slept.append(seconds)
            clock.now += seconds

        def refused(seconds, password):
            clock.now += 0.2
            return {"measured": False, "reason": "sudo: 1 incorrect password attempt"}

        cpu = iter([{7: 10.0}, {7: 40.0}])
        with mock.patch.object(power_benchmark, "time",
                               SimpleNamespace(monotonic=lambda: clock.now, sleep=sleep)), \
                mock.patch.object(power_benchmark, "role_pids", lambda: {"app": [7]}), \
                mock.patch.object(power_benchmark, "process_build_identity", lambda pid: {"pid": pid, "status": "unknown"}), \
                mock.patch.object(power_benchmark, "cpu_seconds", lambda pids: next(cpu)), \
                mock.patch.object(power_benchmark, "gpu_times", lambda: None), \
                mock.patch.object(power_benchmark, "coalition_snapshot", lambda reader, roles: None), \
                mock.patch.object(power_benchmark, "power_telemetry", lambda: None), \
                mock.patch.object(power_benchmark, "package_power", refused):
            measurement = power_benchmark.measure(60, True, "wrong")
        self.assertAlmostEqual(measurement["elapsed_seconds"], 60.0)
        self.assertAlmostEqual(sum(clock.slept), 59.8)
        self.assertEqual(measurement["processes"]["app"]["cpu_percent"], 50.0)
        self.assertFalse(measurement["package_power"]["measured"])
        self.assertIn("incorrect password", measurement["package_power"]["reason"])


class InvocationTests(unittest.TestCase):
    def test_print_only_writes_no_artifact_and_emits_the_manifest(self):
        before = set(power_benchmark.POWER_ARTIFACTS.glob("*.json")) \
            if power_benchmark.POWER_ARTIFACTS.is_dir() else set()
        completed = subprocess.run(
            [sys.executable, str(SCRIPTS / "power_benchmark.py"), "--print-only"],
            capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = json.loads(completed.stdout)
        self.assertFalse(document["measured"])
        after = set(power_benchmark.POWER_ARTIFACTS.glob("*.json")) \
            if power_benchmark.POWER_ARTIFACTS.is_dir() else set()
        self.assertEqual(before, after)

    def test_measuring_needs_a_condition(self):
        completed = subprocess.run(
            [sys.executable, str(SCRIPTS / "power_benchmark.py"), "--measure", "1"],
            capture_output=True, text=True, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("--condition", completed.stderr)


if __name__ == "__main__":
    unittest.main()
