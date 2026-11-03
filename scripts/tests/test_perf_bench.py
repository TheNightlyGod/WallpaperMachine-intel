#!/usr/bin/env python3
"""Behavior tests for scripts/perf_bench.py: settings, launch, records, statistics, verdicts."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("perf_bench", SCRIPTS / "perf_bench.py")
perf_bench = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(perf_bench)

# The production surfaces as system_profiler reports them: a 4K display at 2x
# that is the main one, and the built-in panel.
DISPLAY_CARDS = [{"spdisplays_ndrvs": [
    {"_name": "Panel A", "_spdisplays_pixels": "3840 x 2160", "_spdisplays_resolution": "1920 x 1080 @ 120.00Hz",
     "spdisplays_main": "spdisplays_yes", "_spdisplays_display-vendor-id": "10ac",
     "_spdisplays_display-product-id": "436a", "_spdisplays_display-serial-number": "4143534c"},
    {"_name": "Panel B", "_spdisplays_pixels": "3456 x 2234", "_spdisplays_resolution": "1728 x 1117 @ 120.00Hz",
     "_spdisplays_display-vendor-id": "610", "_spdisplays_display-product-id": "a05f",
     "_spdisplays_display-serial-number": "fd626d62"},
]}]

# One recorded schema-2 run of the energy test (two surfaces, 0.75, 60 fps),
# with the project path replaced.
RECORD = {
    "schema": 2, "test": "UnchangedPresent.LocalProjectEnergyIsMeasuredHeadlessly",
    "project": "/library/3626305963/project.json",
    "settings": {"render_scale": 0.75, "fps": 60, "resolution": "display", "properties": None,
                 "quality": {"msaa": 0, "shadows": 2, "volumetrics": 2, "reflection": True,
                             "post_processing": 2}, "counters": True, "scene_optimization": True},
    "surfaces": [
        {"width": 3840, "height": 2160, "scale": 2, "scaling": "fill", "backend": "native",
         "frames_completed": 300, "frames_presented": 300, "failed_frames": 0,
         "counters": {"timer_wakeups": 300, "draw_requests": 300, "draw_ticks_suppressed": 0,
                      "draws_executed": 300, "render_submissions": 0, "present_requests": 300,
                      "presents_skipped_unchanged": 0, "gpu_completions": 0}},
        {"width": 3456, "height": 2234, "scale": 2, "scaling": "fill", "backend": "native",
         "frames_completed": 301, "frames_presented": 301, "failed_frames": 0,
         "counters": {"timer_wakeups": 301, "draw_requests": 301, "draw_ticks_suppressed": 0,
                      "draws_executed": 301, "render_submissions": 0, "present_requests": 301,
                      "presents_skipped_unchanged": 0, "gpu_completions": 0}},
    ],
    "window": {"warmup_s": 3, "seconds": 5.003419417},
    "cpu": {"seconds": 0.910654, "user_s": 0.464020416667, "system_s": 0.4466335, "p_s": 0.443727166667,
            "energy_mj": 2146.20287, "p_energy_mj": 1349.856214, "idle_wakeups": 0, "interrupt_wakeups": 647,
            "idle_wakeups_per_s": 0, "interrupt_wakeups_per_s": 129.311565967, "instructions": 4192326521,
            "cycles": 3814968477, "qos_ms": {"default": 0, "maintenance": 0, "background": 0,
                                            "utility": 0.0103333333333, "legacy": 439.220875,
                                            "user_initiated": 28.027125, "user_interactive": 443.395583333}},
    "gpu": {"own_busy_s": 3.39363883, "cb_count": 600, "frames_completed": 601, "ms_per_frame": 5.64665362729,
            "cb_per_frame": 0.998336106489, "cb_ms_p50": 6, "cb_ms_p95": 6.8, "cb_ms_p99": 7,
            "coalition_id": 46793, "coalition_shared": True, "coalition_energy_mj": 23693.062971,
            "coalition_cpu_energy_mj": 239659.640179, "coalition_busy_s": 3.975488934,
            "all_energy_mj": 23697.143735, "all_busy_s": 3.976225009, "other_busy_s": 0.000736075,
            "other_busy_share": 0.00014711439091, "coalitions_counted": 834},
    "memory": {"footprint_mb_end": 798.485588074, "footprint_mb_peak": 1037.04808807},
    "thermal": {"before": "nominal", "after": "nominal"},
}


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def library_home(root: Path) -> Path:
    """A wallpaper library laid out as the app keeps it, with the user's settings."""
    home = root / "WallpaperMachine"
    write(home / "config.toml", """schema_version = 1
[quality]
render_scale = 0.75
frame_rate_cap = 60
scene_resolution = "display"
metalfx_upscaling_enabled = false
[quality.scene]
msaa = "none"
shadows = "medium"
volumetrics = "high"
reflection = true
post_processing = "ultra"
""")
    write(home / "Library/111/project.json", json.dumps({"type": "scene", "file": "scene.json"}))
    write(home / "Library/222/project.json", json.dumps({"type": "Video", "file": "clip.mp4"}))
    write(home / "Library/333/project.json", json.dumps({"type": "web", "file": "index.html"}))
    write(home / "wallpapers/111.json", json.dumps({
        "schema_version": 1, "type": "scene",
        "monitors": [
            {"selector": {"kind": "primary"}, "scaling_mode": "fit_blurred", "scaling_factor": 1.0},
            {"selector": {"kind": "identity", "uuid": "X", "vendor_id": 1552, "model_id": 41055,
                          "serial_number": 4251086178}, "scaling_mode": "fit", "scaling_factor": 1.0},
        ],
        "property_overrides": {"numberoficons": 1.0, "newproperty": False},
    }))
    return home


def snapshot(root: Path) -> dict:
    return {str(path): path.stat().st_mtime_ns for path in root.rglob("*")}


class ParsingTests(unittest.TestCase):
    def test_surfaces_are_width_height_and_backing_scale(self):
        surfaces = perf_bench.parse_surfaces(perf_bench.PRODUCTION_SURFACES)
        self.assertEqual(surfaces, [{"width": 3840, "height": 2160, "scale": 2.0},
                                    {"width": 3456, "height": 2234, "scale": 2.0}])
        self.assertEqual(perf_bench.surfaces_name(surfaces), perf_bench.PRODUCTION_SURFACES)
        for bad in ("3840x2160", "3840x2160@0.5", "0x2160@2", "3840x2160@2+"):
            with self.subTest(bad=bad), self.assertRaises(perf_bench.BenchError):
                perf_bench.parse_surfaces(bad)

    def test_a_variant_is_a_binary_set_with_extra_environment(self):
        self.assertEqual(perf_bench.parse_variant("off=new:WALLPAPER_MACHINE_X=0,WE_TEST_Y=a b"),
                         ("off", "new", {"WALLPAPER_MACHINE_X": "0", "WE_TEST_Y": "a b"}))
        self.assertEqual(perf_bench.parse_variant("same=new"), ("same", "new", {}))
        for bad in ("off", "off=new:lower=1", "off=new:X", "o_ff=new:X=1", "off=:X=1"):
            with self.subTest(bad=bad), self.assertRaises(perf_bench.BenchError):
                perf_bench.parse_variant(bad)
        self.assertEqual(perf_bench.parse_bin("base=~/x/tests"), ("base", Path.home() / "x/tests"))
        with self.assertRaises(perf_bench.BenchError):
            perf_bench.parse_bin("base.1=/tmp")

    def test_abba_order_puts_each_condition_first_in_turn(self):
        self.assertEqual(perf_bench.abba_order("A", "B", 4), list("ABBAABBA"))
        self.assertEqual(perf_bench.abba_order("A", "B", 1), list("AB"))
        order = perf_bench.abba_order("A", "B", 5)
        for index in range(5):
            self.assertEqual(sorted(order[2 * index:2 * index + 2]), ["A", "B"])

    def test_hash_and_cost_lines_are_read_from_a_log(self):
        log = ("[ HASH     ] 111 3840x2160 frame=59 sha256=" + "a" * 64 + "\n"
               "noise\n[ HASH     ] 111 3840x2160 frame=119 sha256=" + "b" * 64 + "\n"
               '[ COST     ] 111 {"draws":119,"gpu_ms_p50":5.5}\n')
        self.assertEqual(perf_bench.parse_hashes(log), {"111": {59: "a" * 64, 119: "b" * 64}})
        self.assertEqual(perf_bench.parse_cost_lines(log), {"111": {"draws": 119, "gpu_ms_p50": 5.5}})

    def test_thermal_warnings_and_speed_limits_count_as_throttled(self):
        quiet = ("Note: No thermal warning level has been recorded\n"
                 "Note: No performance warning level has been recorded\n")
        self.assertFalse(perf_bench.thermal_throttled(quiet))
        self.assertFalse(perf_bench.thermal_throttled(None))
        self.assertTrue(perf_bench.thermal_throttled("Thermal warning level set to 2\n"))
        self.assertTrue(perf_bench.thermal_throttled("CPU_Scheduler_Limit = 100\nCPU_Speed_Limit = 72\n"))
        self.assertFalse(perf_bench.thermal_throttled("CPU_Speed_Limit = 100\n"))


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.home = library_home(Path(self.directory.name))
        self.displays = perf_bench.parse_display_inventory(DISPLAY_CARDS)
        self.surfaces = perf_bench.parse_surfaces(perf_bench.PRODUCTION_SURFACES)

    def tearDown(self):
        self.directory.cleanup()

    def test_quality_comes_from_config_toml(self):
        config = perf_bench.user_config(self.home)
        self.assertEqual(config["render_scale"], 0.75)
        self.assertEqual(config["frame_rate_cap"], 60)
        self.assertEqual(config["resolution"], "display")
        self.assertEqual(config["quality"], {"msaa": 0, "shadows": 2, "volumetrics": 3, "reflection": True,
                                             "post_processing": 4})
        self.assertEqual(perf_bench.quality_env(config)["WE_TEST_POSTPROCESSING"], "4")
        empty = perf_bench.user_config(Path(self.directory.name) / "nowhere")
        self.assertEqual((empty["render_scale"], empty["resolution"], empty["quality"]["msaa"]), (1.0, "display", 0))

    def test_an_experimental_switch_on_in_the_app_is_recorded_and_flagged(self):
        config = perf_bench.user_config(self.home)
        self.assertFalse(config["scene_display_framing"])
        settings = perf_bench.wallpaper_settings(self.home, "111", self.surfaces, self.displays, config)
        self.assertFalse(any("scene_display_framing" in note for note in settings["notes"]))
        with (self.home / "config.toml").open("a") as stream:
            stream.write("[experimental]\nscene_display_framing = true\n")
        config = perf_bench.user_config(self.home)
        self.assertTrue(config["scene_display_framing"])
        settings = perf_bench.wallpaper_settings(self.home, "111", self.surfaces, self.displays, config)
        self.assertTrue(any("scene_display_framing" in note and "WALLPAPER_MACHINE_SDR_FRAMING=1" in note
                            for note in settings["notes"]))
        # The note says the harness runs it off: no inherited switch reaches a probe.
        with mock.patch.dict(os.environ, {"WALLPAPER_MACHINE_SDR_FRAMING": "1"}):
            self.assertNotIn("WALLPAPER_MACHINE_SDR_FRAMING", perf_bench.base_environment())

    def test_displays_are_read_with_their_identity_and_main_first(self):
        self.assertEqual([(d["width"], d["scale"], d["main"]) for d in self.displays],
                         [(3840, 2.0, True), (3456, 2.0, False)])
        self.assertEqual((self.displays[1]["vendor_id"], self.displays[1]["model_id"],
                          self.displays[1]["serial_number"]), (1552, 41055, 4251086178))
        self.assertEqual(self.displays[0]["refresh_hz"], 120.0)

    def test_saved_scaling_properties_and_frame_rate_apply_per_surface(self):
        config = perf_bench.user_config(self.home)
        settings = perf_bench.wallpaper_settings(self.home, "111", self.surfaces, self.displays, config)
        self.assertIsNone(perf_bench.skip_reason(settings))
        self.assertEqual([surface["scaling"] for surface in settings["surfaces"]], ["fit_blurred", "fit"])
        self.assertEqual(json.loads(settings["properties"]), {"newproperty": False, "numberoficons": 1.0})
        self.assertEqual(settings["fps"], 60)
        overridden = perf_bench.wallpaper_settings(self.home, "111", self.surfaces, self.displays, config,
                                                   ["stretch"], 30)
        self.assertEqual([surface["scaling"] for surface in overridden["surfaces"]], ["stretch", "stretch"])
        self.assertEqual(overridden["fps"], 30)

    def test_the_first_surface_is_the_primary_display_whichever_displays_are_connected(self):
        # Only the built-in panel connected: it is the main display now, but the
        # second surface still takes the entry saved for its identity.
        config = perf_bench.user_config(self.home)
        panel_only = [dict(self.displays[1], main=True)]
        settings = perf_bench.wallpaper_settings(self.home, "111", self.surfaces, panel_only, config)
        self.assertEqual([surface["scaling"] for surface in settings["surfaces"]], ["fit_blurred", "fit"])
        self.assertEqual([surface["display"] for surface in settings["surfaces"]], [None, "Panel B"])
        nothing = perf_bench.wallpaper_settings(self.home, "111", self.surfaces, [], config)
        self.assertEqual([surface["scaling"] for surface in nothing["surfaces"]], ["fit_blurred", "fill"])

    def test_a_wallpaper_with_no_saved_settings_fills_every_display(self):
        config = perf_bench.user_config(self.home)
        write(self.home / "Library/444/project.json", json.dumps({"type": "scene"}))
        settings = perf_bench.wallpaper_settings(self.home, "444", self.surfaces, self.displays, config)
        self.assertEqual([surface["scaling"] for surface in settings["surfaces"]], ["fill", "fill"])
        self.assertIsNone(settings["properties"])

    def test_video_web_and_missing_wallpapers_are_skipped_with_a_reason(self):
        config = perf_bench.user_config(self.home)
        reasons = {wallpaper: perf_bench.skip_reason(perf_bench.wallpaper_settings(
            self.home, wallpaper, self.surfaces, self.displays, config)) for wallpaper in ("222", "333", "999")}
        self.assertIn("video", reasons["222"])
        self.assertIn("web", reasons["333"])
        self.assertIn("no project.json", reasons["999"])

    def test_reading_settings_writes_nothing_in_the_library(self):
        before = snapshot(self.home)
        config = perf_bench.user_config(self.home)
        for wallpaper in ("111", "222", "333", "999"):
            perf_bench.wallpaper_settings(self.home, wallpaper, self.surfaces, self.displays, config)
        self.assertEqual(snapshot(self.home), before)


class ScratchTests(unittest.TestCase):
    def test_no_write_lands_in_the_users_library(self):
        with tempfile.TemporaryDirectory() as directory:
            home = library_home(Path(directory))
            for inside in (home, home / "Library/111/x.json", home / "wallpapers/../SceneAssets/cache"):
                with self.subTest(inside=inside), self.assertRaises(perf_bench.BenchError):
                    perf_bench.ensure_scratch(inside, home)
            self.assertEqual(perf_bench.ensure_scratch(Path(directory) / "elsewhere", home),
                             (Path(directory) / "elsewhere").resolve())
            # Wrapping into a scratch root inside the library is refused before anything is written.
            source = Path(directory) / "tests"
            write(source / perf_bench.ENERGY_BINARY, "#!/bin/sh\n")
            before = snapshot(home)
            with mock.patch.object(perf_bench, "USER_HOME", home), self.assertRaises(perf_bench.BenchError):
                perf_bench.wrap_binaries("base", source, home / "perf", names=(perf_bench.ENERGY_BINARY,))
            self.assertEqual(snapshot(home), before)

    def test_binaries_are_wrapped_in_scratch_bundles_and_left_alone_when_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root, source = Path(directory) / "perf", Path(directory) / "tests"
            for name in perf_bench.BINARIES:
                write(source / name, f"#!/bin/sh\necho {name}\n")
            with mock.patch.object(perf_bench, "USER_HOME", Path(directory) / "home"):
                wrapped = perf_bench.wrap_binaries("base-1", source, root)
                stamps = {name: Path(entry["executable"]).stat().st_mtime_ns for name, entry in wrapped.items()}
                again = perf_bench.wrap_binaries("base-1", source, root)
            for name, entry in again.items():
                info = plistlib.loads((Path(entry["bundle"]) / "Contents/Info.plist").read_bytes())
                self.assertTrue(info["CFBundleIdentifier"].startswith("dev.wallpapermachine.perfbench.base-1."))
                self.assertNotIn("app.wallpapermachine", info["CFBundleIdentifier"])
                self.assertNotIn("_", info["CFBundleIdentifier"])
                self.assertTrue(info["LSUIElement"])
                self.assertNotIn("LSBackgroundOnly", info)
                self.assertTrue(os.access(entry["executable"], os.X_OK))
                self.assertEqual(Path(entry["executable"]).stat().st_mtime_ns, stamps[name])
            with self.assertRaises(perf_bench.BenchError):
                perf_bench.wrap_binaries("base-1", Path(directory) / "missing", root)

    def test_an_app_launch_passes_the_environment_and_arguments_through_open(self):
        command = perf_bench.open_command("/b/x.app", ["--gtest_filter=T"], {"WE_TEST_B": "2", "WE_TEST_A": "1"},
                                          Path("/o.log"), Path("/e.log"))
        self.assertEqual(command[:4], ["open", "-W", "-n", "-g"])
        self.assertEqual(command[command.index("/b/x.app"):], ["/b/x.app", "--args", "--gtest_filter=T"])
        self.assertEqual([command[i + 1] for i, word in enumerate(command) if word == "--env"],
                         ["WE_TEST_A=1", "WE_TEST_B=2"])

    def test_a_refused_app_launch_falls_back_to_a_direct_foreground_run(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "run.log"
            refused = mock.Mock(returncode=1, stdout="", stderr="LSOpenURLsWithRole() failed")
            with mock.patch.object(perf_bench, "USER_HOME", Path(directory) / "home"), \
                 mock.patch.object(perf_bench.subprocess, "run", return_value=refused), \
                 mock.patch.object(perf_bench, "run_direct", return_value=0) as direct:
                launch = perf_bench.run_as_app({"bundle": "/b.app", "executable": "/b.app/x"}, [], {}, log, 10)
            self.assertEqual(launch["method"], "direct")
            self.assertIn("LSOpenURLsWithRole", launch["open_failure"])
            direct.assert_called_once()


class RecordTests(unittest.TestCase):
    def test_a_recorded_schema_2_run_yields_rates_per_second(self):
        with tempfile.TemporaryDirectory() as directory:
            path = write(Path(directory) / "record.json", json.dumps(RECORD))
            record = perf_bench.read_energy_record(path)
        metrics = perf_bench.energy_metrics(record)
        seconds = RECORD["window"]["seconds"]
        self.assertAlmostEqual(metrics["cpu_mw"], 2146.20287 / seconds)
        self.assertAlmostEqual(metrics["cpu_ms_per_s"], 910.654 / seconds)
        self.assertAlmostEqual(metrics["frames_per_s"], 601 / seconds)
        self.assertAlmostEqual(metrics["gpu_ms_per_frame"], 5.64665362729)
        self.assertAlmostEqual(metrics["draws_executed_per_s"], 601 / seconds)
        # Started from a terminal, the coalition is the terminal's: no own GPU energy.
        self.assertIsNone(metrics["gpu_coalition_mw"])
        own = json.loads(json.dumps(RECORD))
        own["gpu"]["coalition_shared"] = False
        self.assertAlmostEqual(perf_bench.energy_metrics(own)["gpu_coalition_mw"], 23693.062971 / seconds)

    def test_anything_but_a_schema_2_record_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            for document in ({"schema": 1}, {**RECORD, "schema": 3}, [], {k: v for k, v in RECORD.items() if k != "gpu"}):
                path = write(Path(directory) / "record.json", json.dumps(document))
                with self.subTest(document=str(document)[:40]), self.assertRaises(ValueError):
                    perf_bench.read_energy_record(path)


def run(condition, pair, value, accepted=True, frames=60.0, **extra):
    return {"condition": condition, "pair": pair, "accepted": accepted, "reasons": [],
            "metrics": {"gpu_ms_per_frame": value, "frames_per_s": frames}, **extra}


class StatisticsTests(unittest.TestCase):
    def test_the_bootstrap_interval_is_reproducible_and_brackets_the_median(self):
        deltas = [-0.31, -0.28, -0.35, -0.30, -0.26]
        first, second = perf_bench.bootstrap_ci(deltas), perf_bench.bootstrap_ci(deltas)
        self.assertEqual(first, second)
        self.assertLessEqual(first[0], -0.30)
        self.assertGreaterEqual(first[1], -0.30)
        self.assertLess(first[1], 0.0)
        self.assertEqual(perf_bench.bootstrap_ci([0.5, 0.5, 0.5]), (0.5, 0.5))
        self.assertIsNone(perf_bench.bootstrap_ci([]))

    def test_verdicts_need_pairs_an_interval_clear_of_zero_and_a_change_above_the_floor(self):
        verdict = perf_bench.verdict
        self.assertEqual(verdict("gpu_ms_per_frame", [-1.0, -1.0], (-1.0, -1.0), 0.1), "insufficient pairs")
        # Three deltas of one sign bound an interval clear of zero by chance a quarter of the time.
        self.assertEqual(verdict("gpu_ms_per_frame", [-1.0, -0.9, -1.1], (-1.1, -0.9), 0.1), "insufficient pairs")
        self.assertEqual(verdict("gpu_ms_per_frame", [-1.0, 0.5, 0.2, 0.1, -0.3], (-1.0, 0.5), 0.1), "no change")
        self.assertEqual(verdict("gpu_ms_per_frame", [-0.05, -0.04, -0.06, -0.05, -0.05], (-0.06, -0.04), 0.1),
                         "within noise")
        self.assertEqual(verdict("gpu_ms_per_frame", [-1.0, -0.9, -1.1, -1.0, -1.0], (-1.1, -0.9), 0.1), "saving")
        self.assertEqual(verdict("cpu_mw", [5.0, 6.0, 7.0, 6.0, 6.0], (5.0, 7.0), 1.0), "regression")
        self.assertEqual(verdict("frames_per_s", [-3.0, -2.0, -4.0, -3.0, -3.0], (-4.0, -2.0), 0.5), "throughput down")
        self.assertEqual(verdict("cpu_mw", [-5.0, -6.0, -7.0, -6.0, -6.0], (-7.0, -5.0), None), "saving (no A/A floor)")
        # Skipping more unchanged presents is work avoided, not a cost that went up.
        self.assertEqual(verdict("presents_skipped_per_s", [20.0, 21.0, 19.0, 20.0, 20.0], (19.0, 21.0), 1.0),
                         "more skipped")

    @mock.patch.object(perf_bench, "MIN_PAIRS", 3)
    def test_a_rejected_run_drops_its_whole_pair(self):
        runs = [run("A", 0, 5.0), run("B", 0, 4.0), run("B", 1, 4.1), run("A", 1, 5.2, accepted=False),
                run("A", 2, 5.1), run("B", 2, 4.0), run("B", 3, 4.2), run("A", 3, 5.0)]
        summary = perf_bench.summarize("gpu_ms_per_frame", runs, "A", "B", 0.1)
        self.assertEqual(summary["paired_delta"]["pairs"], 3)
        for found, expected in zip(sorted(summary["deltas"]), [-1.1, -1.0, -0.8]):
            self.assertAlmostEqual(found, expected)
        self.assertEqual(summary["A"]["n"], 3)
        self.assertEqual(summary["B"]["median"], 4.05)
        self.assertEqual(summary["verdict"], "saving")
        self.assertAlmostEqual(summary["paired_delta"]["pct"], -100 * 1.0 / 5.0)

    def test_runs_are_rejected_for_contention_failures_heat_and_a_stray_frame_rate(self):
        def recorded(**changes):
            record = json.loads(json.dumps(RECORD))
            for path, value in changes.items():
                section, key = path.split("__")
                record[section][key] = value
            return record

        failed = json.loads(json.dumps(RECORD))
        failed["surfaces"][1]["failed_frames"] = 2
        runs = [
            run("A", 0, 5.0, record=recorded()),
            run("A", 1, 5.0, record=recorded(gpu__other_busy_share=0.4)),
            run("A", 2, 5.0, record=recorded(thermal__after="serious")),
            run("A", 3, 5.0, record=failed),
            run("A", 4, 5.0, frames=58.0, record=recorded()),
            run("A", 5, 5.0, frames=60.1, record=recorded()),
            run("A", 6, 5.0, record=None, reasons=["no energy record"]),
            run("A", 7, 5.0, record=recorded(), thermal_wait={"waited_s": 300.0, "throttled": True}),
        ]
        perf_bench.reject_runs(runs)
        self.assertEqual([entry["accepted"] for entry in runs],
                         [True, False, False, False, False, True, False, False])
        self.assertIn("thermally limited", runs[7]["reasons"][0])
        self.assertIn("contended", runs[1]["reasons"][0])
        self.assertIn("thermal", runs[2]["reasons"][0])
        self.assertIn("failed frames", runs[3]["reasons"][0])
        self.assertIn("frame rate", runs[4]["reasons"][0])

    def test_the_noise_floor_is_the_95th_percentile_of_absolute_aa_differences(self):
        results = {"111@x": {"metrics": {"cpu_mw": {"deltas": [1.0, -2.0, 3.0, -4.0, 5.0]},
                                         "empty": {"deltas": []}}}}
        floor = perf_bench.noise_floor(results)
        self.assertAlmostEqual(floor["111@x"]["cpu_mw"], 4.8)
        self.assertNotIn("empty", floor["111@x"])


class IdentityTests(unittest.TestCase):
    def test_frames_that_differ_between_two_base_runs_are_excluded(self):
        base_a = {59: "a", 119: "b", 179: "c"}
        base_b = {59: "a", 119: "X", 179: "c"}
        same = perf_bench.judge_identity(base_a, base_b, {59: "a", 119: "Y", 179: "c"})
        self.assertEqual(same["verdict"], "identical")
        self.assertEqual(same["nondeterministic_frames"], [119])
        self.assertEqual(same["comparable_frames"], [59, 179])
        self.assertFalse(same["base_self_equal"])
        changed = perf_bench.judge_identity(base_a, base_a, {59: "a", 119: "b", 179: "d"})
        self.assertEqual((changed["verdict"], changed["first_diff_frame"]), ("different", 179))
        self.assertEqual(perf_bench.judge_identity(base_a, {59: "z", 119: "y", 179: "x"}, base_a)["verdict"],
                         "nondeterministic")
        self.assertEqual(perf_bench.judge_identity(base_a, base_a, {59: "a"})["verdict"], "error")
        self.assertEqual(perf_bench.judge_identity({}, {}, {})["verdict"], "error")

    def test_pictures_are_compared_pixel_by_pixel(self):
        header = b"P6\n2 2\n255\n"
        first = header + bytes([0, 0, 0, 10, 10, 10, 20, 20, 20, 30, 30, 30])
        second = header + bytes([0, 0, 0, 10, 13, 10, 20, 20, 20, 30, 30, 37])
        self.assertEqual(perf_bench.compare_ppm(first, second),
                         {"same_size": True, "differing_pixels": 2, "max_channel_diff": 7})
        self.assertEqual(perf_bench.compare_ppm(first, b"P6\n1 1\n255\n\0\0\0"), {"same_size": False})

    def test_pixel_bytes_that_are_whitespace_stay_pixels(self):
        # A newline (10) and a space (32) open the pixel data; a header split on runs of
        # whitespace would swallow them and misalign every pixel after.
        header = b"P6\n2 1\n255\n"
        first = header + bytes([10, 32, 9, 1, 2, 3])
        second = header + bytes([10, 33, 9, 1, 2, 3])
        self.assertEqual(perf_bench.compare_ppm(first, second),
                         {"same_size": True, "differing_pixels": 1, "max_channel_diff": 1})


class ReportTests(unittest.TestCase):
    @mock.patch.object(perf_bench, "MIN_PAIRS", 3)
    def test_the_csv_has_one_row_per_condition_and_metric_and_the_delta_on_the_candidate(self):
        runs = [run("A", 0, 5.0), run("B", 0, 4.0), run("B", 1, 4.0), run("A", 1, 5.0),
                run("A", 2, 5.0), run("B", 2, 4.0)]
        report = {"cost": {"111@3840x2160@2": {
            "first": "A", "second": "B", "order": "ABBAAB",
            "metrics": {"gpu_ms_per_frame": perf_bench.summarize("gpu_ms_per_frame", runs, "A", "B", None)}}},
            "identity": {"111@3840x2160@2": {"verdict": "identical"}}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.csv"
            with mock.patch.object(perf_bench, "USER_HOME", Path(directory) / "home"):
                perf_bench.write_csv(report, path)
            lines = path.read_text().splitlines()
        self.assertEqual(lines[0], ",".join(perf_bench.CSV_COLUMNS))
        self.assertEqual(lines[1], "111,3840x2160@2,A,gpu_ms_per_frame,5.0,0.0,,,,")
        self.assertEqual(lines[2], "111,3840x2160@2,B,gpu_ms_per_frame,4.0,0.0,-1.0,-1.0,-1.0,saving (no A/A floor)")
        self.assertEqual(lines[3], "111,3840x2160@2,,identity,,,,,,identical")


if __name__ == "__main__":
    unittest.main()
