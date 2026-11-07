#!/usr/bin/env python3
"""Unit tests for scripts/power_ab.py: the plan, the seeded homes, the config and the quits.

Nothing here launches or quits an app, touches the desktop or reads the user's library:
every side effect is replaced, and the source library is a temporary fixture.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
from pathlib import Path
import signal
import sys
import tempfile
import tomllib
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("power_ab", SCRIPTS / "power_ab.py")
power_ab = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
# Its dataclasses resolve their string annotations through sys.modules.
sys.modules[SPEC.name] = power_ab
SPEC.loader.exec_module(power_ab)

WALLPAPER = "3784370784"
USER_CONFIG = """schema_version = 1
monitor_settings = []

[general]
last_selected_wallpaper = "111"

[power]
on_battery = "keep_running"

[ui.selector_window]
x = 200
y = 200
width = 1100
height = 720

[experimental]
scene_video_plane_sampling = false

[quality]
render_scale = 0.75
frame_rate_cap = 60
scene_resolution = "display"

[quality.battery]
render_scale = 0.75
target_fps = 30

[quality.scene]
msaa = "none"
post_processing = "enabled"

[primary_display]
kind = "identity"
uuid = "PRIMARY-UUID"
vendor_id = 4268

[[monitors]]
kind = "primary"
enabled = true
mode = "independent"
wallpaper = "111"

[[monitors]]
kind = "identity"
uuid = "PRIMARY-UUID"
enabled = true
mode = "independent"
wallpaper = "111"

[[monitors]]
kind = "identity"
uuid = "EXTERNAL-UUID"
enabled = false
mode = "independent"
wallpaper = "222"

[diagnostics]
verbose_logging = true
"""


def source_home(root: Path, *, assets=True, saved=True) -> Path:
    source = root / "source"
    (source / "Library" / WALLPAPER).mkdir(parents=True)
    (source / "Library" / WALLPAPER / "project.json").write_text('{"type": "scene"}')
    if assets:
        (source / "SceneAssets").mkdir()
    if saved:
        (source / "wallpapers").mkdir()
        (source / "wallpapers" / f"{WALLPAPER}.json").write_text('{"property_overrides": {}}')
    (source / "config.toml").write_text(USER_CONFIG)
    return source


class ScheduleTests(unittest.TestCase):
    def test_every_pair_sits_between_baselines_and_alternates_its_order(self):
        self.assertEqual(power_ab.schedule(3), ["B0", "A", "B", "B0", "B", "A", "B0", "A", "B", "B0"])
        self.assertEqual(power_ab.schedule(1, "old", "new"), ["B0", "old", "new", "B0"])


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.user = tomllib.loads(USER_CONFIG)

    def test_every_display_plays_the_wallpaper_by_default(self):
        config = power_ab.bench_config(self.user, WALLPAPER, None)
        self.assertEqual([monitor["wallpaper"] for monitor in config["monitors"]], [WALLPAPER] * 3)
        self.assertTrue(all(monitor["enabled"] for monitor in config["monitors"]),
                        "a covered display that was switched off would show nothing")

    def test_only_the_displays_asked_for_play_it(self):
        config = power_ab.bench_config(self.user, WALLPAPER, ["EXTERNAL-UUID"])
        self.assertEqual([monitor["wallpaper"] for monitor in config["monitors"]], ["", "", WALLPAPER])
        primary = power_ab.bench_config(self.user, WALLPAPER, ["PRIMARY-UUID"])
        self.assertEqual([monitor["wallpaper"] for monitor in primary["monitors"]], [WALLPAPER, WALLPAPER, ""],
                         "the primary entry follows the primary display's identity")
        self.assertFalse(primary["monitors"][2]["enabled"], "an uncovered entry is left as the user had it")

    def test_rendering_and_display_settings_are_the_users_and_nothing_else(self):
        config = power_ab.bench_config(self.user, WALLPAPER, None)
        self.assertEqual(config["quality"], self.user["quality"])
        self.assertEqual(config["power"], self.user["power"])
        self.assertEqual(config["experimental"], self.user["experimental"])
        self.assertEqual(config["primary_display"], self.user["primary_display"])
        for left_out in ("general", "ui", "diagnostics"):
            self.assertNotIn(left_out, config)
        self.assertEqual(self.user["monitors"][0]["wallpaper"], "111", "the user's own config is not modified")

    def test_a_display_set_no_entry_covers_is_refused(self):
        with self.assertRaises(power_ab.Refused):
            power_ab.bench_config(self.user, WALLPAPER, ["UNKNOWN-UUID"])

    def test_the_written_config_reads_back_as_generated(self):
        config = power_ab.bench_config(self.user, WALLPAPER, ["EXTERNAL-UUID"])
        config["quality"]["odd key"] = 'quote " and \\ backslash'
        config["monitor_settings"] = [1, 2]
        self.assertEqual(tomllib.loads(power_ab.toml_dumps(config)), config)


class SeedingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_every_write_lands_in_the_home_and_nothing_under_the_source(self):
        source = source_home(self.root)
        home = self.root / "tmp/A/home"
        commands = power_ab.seed_commands(source, home, WALLPAPER) + power_ab.suite_commands(self.root / "tmp/A/prefs/defaults")
        written = [Path(path) for command in commands for path in power_ab.written_paths(command)]
        self.assertTrue(written)
        for path in written:
            self.assertTrue(path.is_relative_to(self.root / "tmp"), path)
            self.assertFalse(path.is_relative_to(source), path)
        copies = [command for command in commands if command[0] == "cp"]
        self.assertEqual(len(copies), 3)
        self.assertTrue(all(command[1] == "-c" for command in copies), "copies are APFS clones")
        self.assertIn(["touch", str(home / "Library/.starter-installed")], commands)

    def test_absent_assets_and_saved_settings_are_not_copied(self):
        source = source_home(self.root, assets=False, saved=False)
        commands = power_ab.seed_commands(source, self.root / "home", WALLPAPER)
        self.assertEqual([command for command in commands if command[0] == "cp"],
                         [["cp", "-c", "-R", str(source / "Library" / WALLPAPER),
                           str(self.root / "home/Library" / WALLPAPER)]])

    def test_the_suite_marks_the_welcome_seen_and_writes_no_desktop_picture(self):
        suite = self.root / "prefs/defaults"
        values = {command[3]: command[4:] for command in power_ab.suite_commands(suite)}
        self.assertEqual(values, {
            "WallpaperMachine.welcomeSeen": ["-bool", "true"],
            "WallpaperMachine.appLanguage": ["-string", "en"],
            "WallpaperMachine.writeDesktopPicture": ["-bool", "false"],
        })
        self.assertTrue(all(command[2] == str(suite) for command in power_ab.suite_commands(suite)),
                        "an absolute-path suite, never a named domain in ~/Library/Preferences")


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = source_home(self.root)
        self.arms = [power_ab.Arm("A", self.root / "old/WallpaperMachine.app"),
                     power_ab.Arm("B", self.root / "old/WallpaperMachine.app",
                                  {"WALLPAPER_MACHINE_PRESENT_FEEDBACK": "0"})]
        self.layout = power_ab.Layout(self.root / "tmp", self.root / "results")

    def run_with(self, **overrides):
        values = dict(arms=self.arms, wallpaper=WALLPAPER, display_uuids=None, condition="T3", pairs=2,
                      settle=120, window=60, source=self.source, password_file=None, password_stdin=False,
                      suspend_vm=False, note="")
        values.update(overrides)
        return power_ab.Run(**values)

    @staticmethod
    def environment(command):
        return dict(command[index + 1].split("=", 1) for index, part in enumerate(command) if part == "--env")

    def test_measured_launches_open_their_diagnostics_window_where_the_measurement_starts(self):
        plan = self.run_with().plan(self.layout)
        steps = plan["steps"]
        self.assertEqual([step["label"] for step in steps], ["A", "B", "B0", "A", "B", "B0", "B", "A", "B0"])
        warm = steps[0]
        self.assertEqual(warm["step"], "warm")
        self.assertNotIn("window", warm)
        self.assertNotIn("WALLPAPER_MACHINE_DIAGNOSTICS", self.environment(warm["launch"]))
        measured = steps[3]
        self.assertEqual(measured["launch"][:5], ["open", "-n", "-g", "-a", str(self.arms[0].app)])
        env = self.environment(measured["launch"])
        self.assertEqual(env["WALLPAPER_MACHINE_HOME"], str(self.layout.home(self.arms[0])))
        self.assertEqual(env["WALLPAPER_MACHINE_DEFAULTS_SUITE"], str(self.layout.suite(self.arms[0])))
        self.assertEqual(env["WALLPAPER_MACHINE_PANEL_AT_LAUNCH"], "0")
        self.assertEqual((env["WALLPAPER_MACHINE_DIAGNOSTICS"], env["WALLPAPER_MACHINE_DIAGNOSTICS_DELAY"]),
                         ("60", "120"))
        self.assertEqual(measured["wait_seconds"], 120)
        window = measured["window"]
        self.assertEqual(window[window.index("--app-pid") + 1], "<pid>")
        self.assertEqual(window[window.index("--home") + 1], str(self.layout.home(self.arms[0])))
        self.assertEqual(window[window.index("--measure") + 1], "60")
        self.assertNotIn("--powermetrics", window, "no password source, no powermetrics")

    def test_an_arm_setting_reaches_only_that_arms_launches(self):
        steps = self.run_with().plan(self.layout)["steps"]
        for step in steps:
            if "launch" not in step:
                continue
            env = self.environment(step["launch"])
            self.assertEqual("WALLPAPER_MACHINE_PRESENT_FEEDBACK" in env, step["label"] == "B")

    def test_baseline_windows_measure_with_the_app_quit(self):
        steps = self.run_with(password_stdin=True).plan(self.layout)["steps"]
        baselines = [step for step in steps if step["label"] == "B0"]
        self.assertEqual(len(baselines), 3)
        for step in baselines:
            self.assertNotIn("launch", step)
            self.assertNotIn("--app-pid", step["window"])
            self.assertEqual(step["window"][step["window"].index("--condition") + 1], "B0")
            self.assertIn("--sudo-password-stdin", step["window"])

    def test_every_seeded_write_is_inside_the_temporary_folder(self):
        plan = self.run_with().plan(self.layout)
        for commands in plan["seeding"].values():
            for command in commands:
                for path in power_ab.written_paths(command):
                    self.assertTrue(Path(path).is_relative_to(self.layout.root), path)


class ArgumentTests(unittest.TestCase):
    def parse(self, *argv):
        parser = power_ab.argparse.ArgumentParser()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            power_ab.parse_arms(parser, *argv)

    def test_arms_are_two_distinct_labels_with_their_own_settings(self):
        self.parse([["A", "/x.app"]], None)
        self.parse([["A", "/x.app"], ["A", "/y.app"]], None)
        self.parse([["A", "/x.app"], ["B0", "/y.app"]], None)
        self.parse([["A", "/x.app"], ["B", "/y.app"]], [["C", "KEY=1"]])
        self.parse([["A", "/x.app"], ["B", "/y.app"]], [["B", "WALLPAPER_MACHINE_HOME=/elsewhere"]])
        self.parse([["A", "/x.app"], ["B", "/y.app"]], [["B", "no-equals"]])
        parser = power_ab.argparse.ArgumentParser()
        arms = power_ab.parse_arms(parser, [["A", "/x.app"], ["B", "/x.app"]], [["B", "SWITCH=0"]])
        self.assertEqual([(arm.label, arm.env) for arm in arms], [("A", {}), ("B", {"SWITCH": "0"})])


class DryRunTests(unittest.TestCase):
    def test_a_dry_run_executes_nothing_and_never_shows_the_password(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = source_home(root)
            password = root / "password"
            password.write_text("hunter2-secret\n")
            app = root / "A/WallpaperMachine.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/WallpaperMachine").write_text("")
            refuse = mock.Mock(side_effect=AssertionError("a dry run executed something"))
            stdout = io.StringIO()
            with mock.patch.object(power_ab.subprocess, "run", refuse), \
                    mock.patch.object(power_ab.subprocess, "Popen", refuse), \
                    mock.patch.object(power_ab.os, "kill", refuse), \
                    mock.patch.object(power_ab.tempfile, "mkdtemp", refuse), \
                    mock.patch.object(power_ab, "RESULTS", root / "results"), \
                    contextlib.redirect_stdout(stdout):
                status = power_ab.main([
                    "--dry-run", "--arm", "A", str(app), "--arm", "B", str(app),
                    "--arm-env", "B", "WALLPAPER_MACHINE_FEEDBACK_COPIES=1",
                    "--wallpaper", WALLPAPER, "--source-home", str(source),
                    "--sudo-password-file", str(password), "--pairs", "1"])
            self.assertEqual(status, 0)
            refuse.assert_not_called()
            text = stdout.getvalue()
            self.assertNotIn("hunter2", text)
            self.assertFalse((root / "results").exists(), "a dry run writes no results")
            self.assertIn(f'wallpaper = "{WALLPAPER}"', text)
            self.assertIn("WALLPAPER_MACHINE_FEEDBACK_COPIES=1", text)
            self.assertIn("--app-pid '<pid>'", text)


class RestoreTests(unittest.TestCase):
    def interrupted_run(self, root: Path, exits: bool):
        """Ctrl-C while the user's app is still closing; it finishes closing during the
        clean-up when `exits`. Returns the signals sent, the waits and the commands run."""
        source = source_home(root)
        app = root / "A/WallpaperMachine.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/WallpaperMachine").write_text("")
        user = root / "Applications/WallpaperMachine.app"
        (user / "Contents/MacOS").mkdir(parents=True)
        user_executable = user / "Contents/MacOS/WallpaperMachine"
        user_executable.write_text("")
        alive = {"user": True}
        signals, waits, commands = [], [], []

        def wait_for_exit(pid, stamp, **_):
            waits.append(pid)
            if len(waits) == 1:
                raise KeyboardInterrupt  # while the app puts the desktop picture back
            alive["user"] = not exits
            return exits

        with mock.patch.object(power_ab, "preconditions", return_value=[]), \
                mock.patch.object(power_ab, "running_apps",
                                  lambda: {99: user_executable} if alive["user"] else {}), \
                mock.patch.object(power_ab.os, "kill", lambda pid, sig: signals.append((pid, sig))), \
                mock.patch.object(power_ab, "wait_for_exit", wait_for_exit), \
                mock.patch.object(power_ab, "start_stamp", return_value="launched once"), \
                mock.patch.object(power_ab, "SIGNALLED", set()), \
                mock.patch.object(power_ab.subprocess, "run",
                                  lambda command, **_: commands.append(command)), \
                mock.patch.object(power_ab.tempfile, "mkdtemp", return_value=str(root / "tmp")), \
                mock.patch.object(power_ab, "RESULTS", root / "results"), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            (root / "tmp").mkdir()
            with self.assertRaises(KeyboardInterrupt):
                power_ab.main(["--arm", "A", str(app), "--arm", "B", str(app),
                               "--arm-env", "B", "WALLPAPER_MACHINE_FEEDBACK_COPIES=1",
                               "--wallpaper", WALLPAPER, "--source-home", str(source), "--pairs", "1"])
        self.assertFalse((root / "tmp").exists(), "the temporary homes are deleted")
        reopened = [command for command in commands if command[:3] == ["open", "-g", "-a"]]
        return signals, waits, reopened, user

    def test_an_interruption_while_the_users_app_closes_reopens_it_once_it_has_gone(self):
        with tempfile.TemporaryDirectory() as directory:
            signals, waits, reopened, user = self.interrupted_run(Path(directory), exits=True)
        self.assertEqual(signals, [(99, signal.SIGTERM)], "one signal, and no second one in the clean-up")
        self.assertEqual(waits, [99, 99], "the clean-up waits for it to finish closing")
        self.assertEqual(len(reopened), 1)
        self.assertEqual(Path(reopened[0][3]).resolve(), user.resolve())

    def test_an_app_that_never_finishes_closing_is_neither_signalled_again_nor_reopened(self):
        with tempfile.TemporaryDirectory() as directory:
            signals, waits, reopened, _ = self.interrupted_run(Path(directory), exits=False)
        self.assertEqual(signals, [(99, signal.SIGTERM)])
        self.assertEqual(reopened, [], "a second copy would start beside the one still running")


class CleanUpTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.arm_app = self.root / "A/WallpaperMachine.app"
        (self.arm_app / "Contents/MacOS").mkdir(parents=True)
        self.arm_executable = self.arm_app / "Contents/MacOS/WallpaperMachine"
        self.arm_executable.write_text("")
        self.run_ = power_ab.Run(arms=[power_ab.Arm("A", self.arm_app), power_ab.Arm("B", self.arm_app)],
                                 wallpaper=WALLPAPER, display_uuids=None, condition="T3", pairs=1, settle=1,
                                 window=1, source=self.root, password_file=None, password_stdin=False,
                                 suspend_vm=False, note="")
        (self.root / "tmp").mkdir()
        self.layout = power_ab.Layout(self.root / "tmp", self.root / "results")

    def test_an_arms_copy_is_quit_once_and_one_already_signalled_is_only_waited_for(self):
        quits, waits = [], []
        listing = {7: self.arm_executable, 8: self.arm_executable}
        with mock.patch.object(power_ab, "running_apps", lambda: dict(listing)), \
                mock.patch.object(power_ab, "SIGNALLED", {8}), \
                mock.patch.object(power_ab, "quit_app", lambda pid, **_: quits.append(pid)), \
                mock.patch.object(power_ab, "wait_for_exit", lambda pid, stamp, **_: waits.append(pid) or True), \
                mock.patch.object(power_ab, "start_stamp", return_value="once"), \
                mock.patch.object(power_ab.subprocess, "run", lambda command, **_: None), \
                contextlib.redirect_stdout(io.StringIO()):
            power_ab.clean_up(self.run_, self.layout, None, None, None)
        self.assertEqual(quits, [7], "the copy not yet signalled gets its one signal")
        self.assertEqual(waits, [8], "the copy already signalled is only waited for")
        self.assertFalse((self.root / "tmp").exists())

    def test_the_homes_are_deleted_even_when_waiting_for_a_copy_fails(self):
        def wait_for_exit(pid, stamp, **_):
            raise KeyboardInterrupt
        with mock.patch.object(power_ab, "running_apps", lambda: {9: self.arm_executable}), \
                mock.patch.object(power_ab, "SIGNALLED", {9}), \
                mock.patch.object(power_ab, "wait_for_exit", wait_for_exit), \
                mock.patch.object(power_ab, "start_stamp", return_value="once"), \
                mock.patch.object(power_ab.subprocess, "run", lambda command, **_: None), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(KeyboardInterrupt):
                power_ab.clean_up(self.run_, self.layout, None, None, None)
        self.assertFalse((self.root / "tmp").exists(), "the temporary homes are deleted whatever happened")

    def test_the_clean_up_ignores_further_interrupts_and_restores_the_handlers(self):
        seen = []
        with mock.patch.object(power_ab, "clean_up",
                               lambda *args: seen.append(power_ab.signal.getsignal(power_ab.signal.SIGINT))), \
                mock.patch.object(power_ab, "preconditions", return_value=[]), \
                mock.patch.object(power_ab, "running_apps", return_value={}), \
                mock.patch.object(power_ab, "execute", return_value=0), \
                mock.patch.object(power_ab.tempfile, "mkdtemp", return_value=str(self.root / "tmp")), \
                mock.patch.object(power_ab, "RESULTS", self.root / "results"), \
                contextlib.redirect_stdout(io.StringIO()):
            before = power_ab.signal.getsignal(power_ab.signal.SIGINT)
            power_ab.main(["--arm", "A", str(self.arm_app), "--arm", "B", str(self.arm_app),
                           "--arm-env", "B", "WALLPAPER_MACHINE_FEEDBACK_COPIES=1",
                           "--wallpaper", WALLPAPER, "--source-home", str(source_home(self.root / "src")),
                           "--pairs", "1"])
            after = power_ab.signal.getsignal(power_ab.signal.SIGINT)
        self.assertEqual(seen, [power_ab.signal.SIG_IGN])
        self.assertEqual(after, before)


class PreconditionTests(unittest.TestCase):
    def outputs(self, power_source):
        listing = {"pmset -g ps": power_source, "pmset -g": "", "pmset -g therm": ""}
        return lambda command: listing.get(" ".join(command), "")

    def test_battery_power_is_refused_unless_allowed(self):
        with mock.patch.object(power_ab, "output", self.outputs("Now drawing from 'Battery Power'")), \
                mock.patch.object(power_ab.shutil, "which", return_value=None), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(any("AC power" in problem for problem in power_ab.preconditions(False)))
            self.assertEqual(power_ab.preconditions(False, allow_battery=True), [])

    def test_ac_power_needs_no_permission(self):
        with mock.patch.object(power_ab, "output", self.outputs("Now drawing from 'AC Power'")), \
                mock.patch.object(power_ab.shutil, "which", return_value=None), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(power_ab.preconditions(False), [])


class QuitTests(unittest.TestCase):
    def test_a_quit_sends_one_sigterm_and_waits_for_the_exit(self):
        signals = []
        alive = iter([True, True, False])

        def kill(pid, sig):
            signals.append(sig)
            if sig == 0 and not next(alive):
                raise ProcessLookupError

        clock = mock.Mock(side_effect=[0.0] + [1.0] * 10)
        with mock.patch.object(power_ab.os, "kill", kill), \
                mock.patch.object(power_ab, "start_stamp", return_value="Tue Nov  3 10:00:00 2026"):
            power_ab.quit_app(42, clock=clock, sleep=lambda seconds: None)
        self.assertEqual(signals.count(signal.SIGTERM), 1)
        self.assertEqual(signals[0], signal.SIGTERM)

    def test_an_app_that_does_not_exit_gets_no_second_signal(self):
        signals = []
        ticks = iter(range(1000))
        with mock.patch.object(power_ab.os, "kill", lambda pid, sig: signals.append(sig)), \
                mock.patch.object(power_ab, "start_stamp", return_value="same"):
            with self.assertRaises(RuntimeError):
                power_ab.quit_app(42, clock=lambda: float(next(ticks)), sleep=lambda seconds: None)
        self.assertEqual(signals.count(signal.SIGTERM), 1)
        self.assertNotIn(signal.SIGKILL, signals)

    def test_a_reused_pid_counts_as_exited(self):
        stamps = iter(["launched first", "launched later"])
        with mock.patch.object(power_ab.os, "kill", lambda pid, sig: None), \
                mock.patch.object(power_ab, "start_stamp", lambda pid: next(stamps)):
            power_ab.quit_app(42, clock=lambda: 0.0, sleep=lambda seconds: None)

    def test_the_launched_copy_is_the_new_process_of_that_arms_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "real.app/Contents/MacOS").mkdir(parents=True)
            (root / "real.app/Contents/MacOS/WallpaperMachine").write_text("")
            (root / "linked.app").symlink_to(root / "real.app")
            arm = power_ab.Arm("A", root / "linked.app")
            found = {10: root / "real.app/Contents/MacOS/WallpaperMachine",
                     11: root / "real.app/Contents/MacOS/WallpaperMachine",
                     12: Path("/Applications/WallpaperMachine.app/Contents/MacOS/WallpaperMachine")}
            with mock.patch.object(power_ab, "running_apps", return_value=found):
                self.assertEqual(power_ab.resolve_pid(arm, {10}, clock=lambda: 0.0, sleep=lambda s: None), 11)
                with self.assertRaises(RuntimeError):
                    power_ab.resolve_pid(arm, set(), clock=lambda: 0.0, sleep=lambda s: None)

    def test_the_app_bundle_is_found_from_its_executable(self):
        self.assertEqual(power_ab.app_bundle(Path("/Applications/WallpaperMachine.app/Contents/MacOS/WallpaperMachine")),
                         Path("/Applications/WallpaperMachine.app"))
        self.assertIsNone(power_ab.app_bundle(Path("/usr/local/bin/WallpaperMachine")))


class PasswordTests(unittest.TestCase):
    def test_the_first_line_of_the_file_is_the_password(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "password"
            path.write_text("s3cret\nignored\n")
            self.assertEqual(power_ab.read_password(path), "s3cret")


class SummaryTests(unittest.TestCase):
    @staticmethod
    def window(label, **metrics):
        return {"label": label, "metrics": metrics}

    def test_each_window_is_compared_with_the_baselines_around_its_pair(self):
        windows = [
            self.window("B0", window_server_gpu_mw=40, package_mw=1000),
            self.window("A", app_gpu_mw=3000, window_server_gpu_mw=340, package_mw=4000),
            self.window("B", app_gpu_mw=2500, window_server_gpu_mw=300, package_mw=3500),
            self.window("B0", window_server_gpu_mw=60, package_mw=1200),
            self.window("B", app_gpu_mw=2600, window_server_gpu_mw=310, package_mw=3700),
            self.window("A", app_gpu_mw=3100, window_server_gpu_mw=360, package_mw=4200),
            self.window("B0", window_server_gpu_mw=40, package_mw=1000),
        ]
        summary = power_ab.summarize(windows)
        self.assertEqual(windows[1]["incremental"], {"window_server_gpu_mw": 290.0, "package_mw": 2900.0,
                                                     "app_gpu_mw": 3000})
        self.assertEqual(windows[5]["incremental"]["package_mw"], 3100.0)
        self.assertEqual(summary["per_arm"]["A"]["package_mw"]["values"], [2900.0, 3100.0])
        self.assertEqual(summary["paired"]["package_mw"]["values"], [-500.0, -500.0])
        self.assertEqual(summary["paired"]["app_gpu_mw"]["difference"], "B - A")

    def test_the_figures_of_one_window_are_read_from_its_document(self):
        document = {"measurement": {
            "coalitions": {"measured": True, "gpu_contended": False,
                           "roles": {"app": {"cpu_mw": 50, "gpu_mw": 3000}, "window_server": {"cpu_mw": 9, "gpu_mw": 300}},
                           "all": {"cpu_mw": 900, "gpu_mw": 3500}},
            "package_power": {"measured": True, "combined_mw": 4200.0},
            "system_power": {"measured": False, "reason": "none"},
            "diagnostics": {"measured": True, "surfaces": [{"surface": "scene/1/handle1/gen1",
                                                            "draws_per_second": 60.0}]},
        }}
        metrics = power_ab.window_metrics(document)
        self.assertEqual(metrics["app_gpu_mw"], 3000)
        self.assertEqual(metrics["window_server_gpu_mw"], 300)
        self.assertEqual(metrics["package_mw"], 4200.0)
        self.assertNotIn("system_load_mw", metrics)
        self.assertEqual(metrics["surfaces"], {"scene/1/handle1/gen1": {"draws_per_second": 60.0}})


if __name__ == "__main__":
    unittest.main()
