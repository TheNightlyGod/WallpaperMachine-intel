#!/usr/bin/env python3
"""Desktop power A/B of two arms: two copies of the app, or one copy with two settings.

An authorized desktop run only (docs/testing/power-benchmark.md#desktop-ab-runs): it
quits the running WallpaperMachine, plays one wallpaper with each arm on the real
displays and samples power with scripts/power_benchmark.py. Run `--dry-run` first: it
prints every command, path and the generated config.toml and executes nothing.

Each arm runs in a home of its own under a temporary folder, seeded with APFS clones
(`cp -c`) of the wallpaper's library folder and SceneAssets and a copy of its saved
settings, with a config.toml generated from the user's quality, power and display
sections so the wallpaper plays on the displays asked for, and a path-backed defaults
suite that marks the welcome as seen, keeps the panel's language English and writes no
desktop picture. The user's library, preferences and desktop picture are never written.

Order: one warm launch per arm (unmeasured), then B0, A, B, B0, B, A, B0, ... for
`--pairs` pairs. A measured launch keeps the control panel closed, opens the diagnostics
window `--settle` seconds after launch for `--window` seconds, and is measured over the
same span with `--app-pid` and `--home`. Every quit is one SIGTERM and a wait for the
exit, never a second signal. The sudo password for powermetrics is read once (from
`--sudo-password-file` or stdin), kept in memory and passed only to sudo's stdin. At
the end the app that was running is opened again from where it was found, and the
temporary folder is deleted. Results: artifacts/power-ab/<timestamp>/.
"""
from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass, field
from datetime import datetime
import getpass
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import tomllib

from lib.glyphs import markers
from lib.paths import ARTIFACTS, ROOT
import power_benchmark

MARK = markers()
POWER_BENCHMARK = ROOT / "scripts/power_benchmark.py"
RESULTS = ARTIFACTS / "power-ab"
SOURCE_HOME = Path.home() / "Library/Application Support/WallpaperMachine"
EXECUTABLE = "WallpaperMachine"
BASELINE = "B0"
# What the harness sets for every launch; an arm may not override it.
HARNESS_ENVIRONMENT = ("WALLPAPER_MACHINE_HOME", "WALLPAPER_MACHINE_DEFAULTS_SUITE",
                       "WALLPAPER_MACHINE_PANEL_AT_LAUNCH", "WALLPAPER_MACHINE_DIAGNOSTICS",
                       "WALLPAPER_MACHINE_DIAGNOSTICS_DELAY")
# Sections of the user's config.toml that decide how a wallpaper renders and when it
# pauses. Window geometry, the last selection and logging stay at their defaults.
COPIED_SECTIONS = ("quality", "power", "experimental", "primary_display", "monitor_settings")
SUITE_VALUES = (
    ("WallpaperMachine.welcomeSeen", "-bool", "true"),
    ("WallpaperMachine.appLanguage", "-string", "en"),
    # On by default; it would rewrite the user's real desktop picture.
    ("WallpaperMachine.writeDesktopPicture", "-bool", "false"),
)
QUIT_TIMEOUT = 90.0
# `open` can fail with -600 for a few seconds after the app exits.
AFTER_QUIT = 5.0
LABEL = re.compile(r"[A-Za-z][A-Za-z0-9_-]*")
ENV_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class Refused(Exception):
    """A precondition does not hold; nothing was changed."""


@dataclass
class Arm:
    label: str
    app: Path
    env: dict[str, str] = field(default_factory=dict)

    @property
    def executable(self) -> Path:
        return self.app / "Contents/MacOS" / EXECUTABLE


@dataclass
class Layout:
    """Where one run keeps its files: the disposable homes and its results."""

    root: Path
    results: Path

    def home(self, arm: Arm) -> Path:
        return self.root / arm.label / "home"

    def suite(self, arm: Arm) -> Path:
        # A path-backed suite keeps its plist in this folder, so deleting the folder
        # leaves nothing in ~/Library/Preferences (Tests/Unit/Support/TemporaryDefaults.swift).
        return self.root / arm.label / "prefs" / "defaults"


# --- the generated config -------------------------------------------------------------

def covers(monitor: dict, display_uuids: list[str] | None, primary_uuid: str | None) -> bool:
    """Whether a `[[monitors]]` entry names a display the run plays the wallpaper on."""
    if display_uuids is None:
        return True
    if monitor.get("kind") == "primary":
        return primary_uuid is not None and primary_uuid in display_uuids
    return monitor.get("uuid") in display_uuids


def bench_config(user: dict, wallpaper: str, display_uuids: list[str] | None) -> dict:
    """The user's rendering and display settings with `wallpaper` on the covered displays."""
    config: dict = {"schema_version": user.get("schema_version", 1)}
    for section in COPIED_SECTIONS:
        if section in user:
            config[section] = copy.deepcopy(user[section])
    primary_uuid = (user.get("primary_display") or {}).get("uuid")
    monitors = []
    for monitor in user.get("monitors", []):
        entry = copy.deepcopy(monitor)
        covered = covers(entry, display_uuids, primary_uuid)
        entry["wallpaper"] = wallpaper if covered else ""
        if covered:
            entry["enabled"] = True
        monitors.append(entry)
    if not any(entry["wallpaper"] for entry in monitors):
        raise Refused("no [[monitors]] entry of the user's config.toml covers the displays asked for")
    config["monitors"] = monitors
    return config


def toml_key(key: str) -> str:
    return key if re.fullmatch(r"[A-Za-z0-9_-]+", key) else json.dumps(key)


def toml_value(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        # JSON's escapes are a subset of a TOML basic string's.
        return json.dumps(value)
    if isinstance(value, list) and not any(isinstance(item, dict) for item in value):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    raise TypeError(f"cannot write {type(value).__name__} to TOML")


def toml_dumps(data: dict, prefix: str = "") -> str:
    """TOML for the tables, arrays of tables and plain values a config.toml holds."""
    lines, tables, arrays = [], [], []
    for key, value in data.items():
        if isinstance(value, dict):
            tables.append((key, value))
        elif isinstance(value, list) and value and all(isinstance(item, dict) for item in value):
            arrays.append((key, value))
        else:
            lines.append(f"{toml_key(key)} = {toml_value(value)}")
    text = "\n".join(lines) + ("\n" if lines else "")
    for key, value in tables:
        name = prefix + toml_key(key)
        text += f"\n[{name}]\n" + toml_dumps(value, name + ".")
    for key, entries in arrays:
        name = prefix + toml_key(key)
        for entry in entries:
            text += f"\n[[{name}]]\n" + toml_dumps(entry, name + ".")
    return text


# --- the plan -------------------------------------------------------------------------

def schedule(pairs: int, first: str = "A", second: str = "B") -> list[str]:
    """B0, A, B, B0, B, A, B0, ...: every pair between two baselines, alternating order."""
    order = [BASELINE]
    for index in range(pairs):
        order += [first, second] if index % 2 == 0 else [second, first]
        order.append(BASELINE)
    return order


def seed_commands(source: Path, home: Path, wallpaper: str) -> list[list[str]]:
    """Clones of what one wallpaper needs, under `home`; nothing is written under `source`."""
    commands = [["mkdir", "-p", str(home / "Library"), str(home / "wallpapers")],
                ["cp", "-c", "-R", str(source / "Library" / wallpaper), str(home / "Library" / wallpaper)]]
    if (source / "SceneAssets").is_dir():
        commands.append(["cp", "-c", "-R", str(source / "SceneAssets"), str(home / "SceneAssets")])
    saved = source / "wallpapers" / f"{wallpaper}.json"
    if saved.is_file():
        commands.append(["cp", "-c", str(saved), str(home / "wallpapers" / saved.name)])
    # The starter wallpaper is installed into an empty library once, unless marked done.
    commands.append(["touch", str(home / "Library/.starter-installed")])
    return commands


def suite_commands(suite: Path) -> list[list[str]]:
    return [["defaults", "write", str(suite), key, kind, value] for key, kind, value in SUITE_VALUES]


def written_paths(command: list[str]) -> list[str]:
    """The paths a seeding or suite command writes."""
    if command[0] == "mkdir":
        return command[2:]
    if command[0] in ("cp", "touch"):
        return command[-1:]
    if command[:2] == ["defaults", "write"]:
        return [command[2]]
    raise ValueError(f"unknown seeding command {command[0]}")


def launch_environment(arm: Arm, layout: Layout, settle: int, window: int | None) -> dict[str, str]:
    env = {"WALLPAPER_MACHINE_HOME": str(layout.home(arm)),
           "WALLPAPER_MACHINE_DEFAULTS_SUITE": str(layout.suite(arm)),
           "WALLPAPER_MACHINE_PANEL_AT_LAUNCH": "0",
           **arm.env}
    if window is not None:
        env["WALLPAPER_MACHINE_DIAGNOSTICS"] = str(window)
        env["WALLPAPER_MACHINE_DIAGNOSTICS_DELAY"] = str(settle)
    return env


def launch_command(arm: Arm, env: dict[str, str]) -> list[str]:
    # -n: a new instance even beside another copy; -g: not brought to the front; -a with
    # the path: LaunchServices must not pick another copy with the same bundle id.
    command = ["open", "-n", "-g", "-a", str(arm.app)]
    for key, value in env.items():
        command += ["--env", f"{key}={value}"]
    return command


def window_command(condition: str, seconds: int, output: Path, *, powermetrics: bool,
                   app_pid: int | str | None = None, home: Path | None = None, note: str = "") -> list[str]:
    command = [sys.executable, str(POWER_BENCHMARK), "--measure", str(seconds), "--condition", condition,
               "--output", str(output), "--note", note]
    if powermetrics:
        command += ["--powermetrics", "--sudo-password-stdin"]
    if app_pid is not None:
        command += ["--app-pid", str(app_pid)]
    if home is not None:
        command += ["--home", str(home)]
    return command


# --- the host -------------------------------------------------------------------------

def output(command: list[str]) -> str | None:
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return completed.stdout if completed.returncode == 0 else None


def running_apps() -> dict[int, Path]:
    """Every running WallpaperMachine by PID, with its executable."""
    found = {}
    for line in (output(["ps", "-axwwo", "pid=,comm="]) or "").splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and os.path.basename(fields[1]) == EXECUTABLE:
            found[int(fields[0])] = Path(fields[1])
    return found


def start_stamp(pid: int) -> str | None:
    stamp = output(["ps", "-p", str(pid), "-o", "lstart="])
    return stamp.strip() if stamp else None


def app_bundle(executable: Path) -> Path | None:
    return executable.parents[2] if executable.parent.name == "MacOS" and len(executable.parents) > 2 else None


def preconditions(suspend_vm: bool, allow_battery: bool = False) -> list[str]:
    """Problems that make a desktop window meaningless; suspends running VMs when asked."""
    problems = []
    source = output(["pmset", "-g", "ps"]) or ""
    if "AC Power" not in source:
        if allow_battery:
            # Both arms and every baseline then run on the battery; each window records it.
            print(f"{MARK.warn} on battery power: every window of this run measures on it")
        else:
            problems.append("not on AC power (pass --allow-battery to measure on battery)")
    if re.search(r"^\s*lowpowermode\s+1\b", output(["pmset", "-g"]) or "", re.MULTILINE):
        problems.append("Low Power Mode is on")
    therm = output(["pmset", "-g", "therm"]) or ""
    limit = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", therm)
    if limit and int(limit.group(1)) < 100:
        problems.append(f"the CPU is thermally limited to {limit.group(1)} %")
    print(f"{MARK.step} thermal: {' '.join(therm.split()) or 'unknown'}")
    if shutil.which("prlctl"):
        listing = output(["prlctl", "list", "--all", "--no-header", "--output", "name,status"]) or ""
        running = [line.rsplit(None, 1)[0] for line in listing.splitlines()
                   if line.strip() and line.split()[-1] == "running"]
        print(f"{MARK.step} Parallels: {', '.join(running) + ' running' if running else 'no VM running'}")
        for name in running:
            if not suspend_vm:
                problems.append(f"the Parallels VM {name!r} is running (pass --suspend-vm to suspend it)")
            elif subprocess.run(["prlctl", "suspend", name], check=False).returncode != 0:
                problems.append(f"the Parallels VM {name!r} could not be suspended")
    if output(["pgrep", "-x", "Google Chrome"]):
        print(f"{MARK.warn} Chrome is open: it composites on its own; quit it for clean windows")
    return problems


# Every PID this run has sent its one SIGTERM; the clean-up only waits for these.
SIGNALLED: set[int] = set()


def wait_for_exit(pid: int, stamp: str | None, clock=time.monotonic, sleep=time.sleep) -> bool:
    """Waits up to QUIT_TIMEOUT for `pid` to exit, sending nothing; True once it has
    (or its PID now belongs to another process)."""
    deadline = clock() + QUIT_TIMEOUT
    while clock() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        if start_stamp(pid) != stamp:
            return True  # exited, and the PID already belongs to another process
        sleep(0.5)
    return False


def quit_app(pid: int, clock=time.monotonic, sleep=time.sleep) -> None:
    """One SIGTERM and a wait for the exit. A second signal would end the app at once,
    perhaps before it put the desktop picture back, so it is never sent."""
    stamp = start_stamp(pid)
    # Recorded before the signal, so an interruption in between cannot lead to a second one.
    SIGNALLED.add(pid)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        SIGNALLED.discard(pid)
        return
    if not wait_for_exit(pid, stamp, clock=clock, sleep=sleep):
        raise RuntimeError(f"WallpaperMachine {pid} did not exit within {QUIT_TIMEOUT:.0f} s; "
                           "no second signal was sent")
    sleep(AFTER_QUIT)


def _interrupted(number, frame) -> None:
    """SIGTERM or SIGHUP to this script: unwind through the clean-up, which reopens the
    user's app and deletes the temporary homes, as Ctrl-C does."""
    raise KeyboardInterrupt(f"signal {number}")


def resolve_pid(arm: Arm, before: set[int], clock=time.monotonic, sleep=time.sleep) -> int:
    """The copy `open` just started: a new process running the arm's executable."""
    deadline = clock() + 30
    while clock() < deadline:
        started = [pid for pid, executable in running_apps().items()
                   if pid not in before and executable.resolve() == arm.executable.resolve()]
        if len(started) == 1:
            return started[0]
        if len(started) > 1:
            raise RuntimeError(f"several new copies of {arm.app} started: {started}")
        sleep(0.5)
    raise RuntimeError(f"{arm.app} did not start")


def read_password(path: Path | None) -> str:
    if path is not None:
        lines = path.read_text().splitlines()
        return lines[0] if lines else ""
    if sys.stdin.isatty():
        return getpass.getpass("sudo password for powermetrics: ")
    return sys.stdin.readline().rstrip("\r\n")


# --- results --------------------------------------------------------------------------

def window_metrics(document: dict) -> dict:
    """The figures one window contributes to the comparison."""
    measurement = document.get("measurement", {})
    coalitions = measurement.get("coalitions", {})
    roles = coalitions.get("roles", {}) if coalitions.get("measured") else {}
    metrics = {}
    for role in ("app", "window_server"):
        for kind in ("cpu_mw", "gpu_mw"):
            if kind in roles.get(role, {}):
                metrics[f"{role}_{kind}"] = roles[role][kind]
    if coalitions.get("measured"):
        metrics["all_cpu_mw"] = coalitions["all"]["cpu_mw"]
        metrics["all_gpu_mw"] = coalitions["all"]["gpu_mw"]
        metrics["gpu_contended"] = coalitions["gpu_contended"]
    package = measurement.get("package_power", {})
    if package.get("measured"):
        metrics["package_mw"] = package["combined_mw"]
    system = measurement.get("system_power", {})
    if system.get("measured"):
        metrics["system_load_mw"] = system["load_mw"]
    diagnostics = measurement.get("diagnostics", {})
    if diagnostics.get("measured"):
        metrics["surfaces"] = {surface.get("surface"): {key: surface[key] for key in (
            "draws_per_second", "present_requests_per_second", "presented_frames_per_second")
            if key in surface} for surface in diagnostics["surfaces"]}
    return metrics


# Whole-machine figures a baseline window also has: compared as the window minus the
# mean of the baselines on either side of its pair. The app's own coalition is not.
BASELINED = ("window_server_cpu_mw", "window_server_gpu_mw", "all_cpu_mw", "all_gpu_mw",
             "package_mw", "system_load_mw")


def summarize(windows: list[dict]) -> dict:
    """Incremental figures per arm window and the paired difference of each pair."""
    baselines = [index for index, window in enumerate(windows) if window["label"] == BASELINE]
    arms = [window for window in windows if window["label"] != BASELINE]
    for index, window in enumerate(windows):
        if window["label"] == BASELINE:
            continue
        before = max((b for b in baselines if b < index), default=None)
        after = min((b for b in baselines if b > index), default=None)
        around = [windows[b]["metrics"] for b in (before, after) if b is not None]
        incremental = {}
        for key in BASELINED:
            values = [metrics[key] for metrics in around if key in metrics]
            if key in window["metrics"] and values:
                incremental[key] = round(window["metrics"][key] - statistics.fmean(values), 1)
        for key in ("app_cpu_mw", "app_gpu_mw"):
            if key in window["metrics"]:
                incremental[key] = window["metrics"][key]
        window["incremental"] = incremental
    labels = sorted({window["label"] for window in arms}, key=[w["label"] for w in arms].index)
    per_arm = {}
    for label in labels:
        runs = [window["incremental"] for window in arms if window["label"] == label]
        keys = sorted({key for run in runs for key in run})
        per_arm[label] = {key: {"values": [run[key] for run in runs if key in run],
                                "median": statistics.median([run[key] for run in runs if key in run])}
                          for key in keys}
    paired = {}
    if len(labels) == 2:
        first, second = labels
        pairs = [arms[i:i + 2] for i in range(0, len(arms) - 1, 2)]
        for key in sorted({key for window in arms for key in window["incremental"]}):
            deltas = []
            for pair in pairs:
                by_label = {window["label"]: window["incremental"] for window in pair}
                if key in by_label.get(first, {}) and key in by_label.get(second, {}):
                    deltas.append(round(by_label[second][key] - by_label[first][key], 1))
            if deltas:
                paired[key] = {"difference": f"{second} - {first}", "values": deltas,
                               "median": statistics.median(deltas)}
    return {"per_arm": per_arm, "paired": paired}


# --- the run --------------------------------------------------------------------------

@dataclass
class Run:
    arms: list[Arm]
    wallpaper: str
    display_uuids: list[str] | None
    condition: str
    pairs: int
    settle: int
    window: int
    source: Path
    password_file: Path | None
    password_stdin: bool
    suspend_vm: bool
    note: str

    @property
    def powermetrics(self) -> bool:
        return self.password_file is not None or self.password_stdin

    def config_text(self) -> str:
        path = self.source / "config.toml"
        try:
            user = tomllib.loads(path.read_text())
        except (OSError, tomllib.TOMLDecodeError) as error:
            raise Refused(f"cannot read {path}: {error}") from error
        return toml_dumps(bench_config(user, self.wallpaper, self.display_uuids))

    def check_inputs(self, dry_run: bool) -> None:
        if not (self.source / "Library" / self.wallpaper / "project.json").is_file():
            raise Refused(f"{self.wallpaper} is not in {self.source / 'Library'}")
        for arm in self.arms:
            if not arm.executable.is_file():
                message = f"{arm.label}: {arm.executable} does not exist"
                if not dry_run:
                    raise Refused(message)
                print(f"{MARK.warn} {message}")

    def by_label(self, label: str) -> Arm:
        return next(arm for arm in self.arms if arm.label == label)

    def plan(self, layout: Layout) -> dict:
        """Every step the run takes, with its exact commands; `<pid>` is resolved at run time."""
        seeding = {arm.label: seed_commands(self.source, layout.home(arm), self.wallpaper)
                   + suite_commands(layout.suite(arm)) for arm in self.arms}
        steps = [{"step": "warm", "label": arm.label,
                  "launch": launch_command(arm, launch_environment(arm, layout, self.settle, None)),
                  "wait_seconds": self.settle} for arm in self.arms]
        for index, label in enumerate(schedule(self.pairs, self.arms[0].label, self.arms[1].label)):
            result = layout.results / f"window-{index:02d}-{label}.json"
            if label == BASELINE:
                steps.append({"step": "window", "label": label, "window": window_command(
                    BASELINE, self.window, result, powermetrics=self.powermetrics,
                    note=f"{BASELINE} app quit")})
                continue
            arm = self.by_label(label)
            steps.append({"step": "window", "label": label,
                          "launch": launch_command(arm, launch_environment(arm, layout, self.settle, self.window)),
                          "wait_seconds": self.settle,
                          "window": window_command(
                              self.condition, self.window, result, powermetrics=self.powermetrics,
                              app_pid="<pid>", home=layout.home(arm),
                              note=f"{label} {self.wallpaper} {self.note}".strip())})
        return {"seeding": seeding, "steps": steps}


def print_plan(run: Run, layout: Layout, config: str) -> None:
    print(f"{MARK.step} Dry run: nothing below is executed.")
    print("preconditions: pmset -g ps (AC power), pmset -g (lowpowermode 0), pmset -g therm, "
          + ("prlctl list --all" + (" then prlctl suspend <running VM>" if run.suspend_vm else
                                    "; refuse while a VM runs") if shutil.which("prlctl") else "no prlctl"))
    if run.powermetrics:
        where = run.password_file if run.password_file else "stdin"
        print(f"sudo password: read once from {where}, checked with `sudo -S -p '' -v`, "
              "then given only to sudo's stdin")
    else:
        print("no sudo password: package power is not sampled")
    print("quit: the running WallpaperMachine (found with ps), one SIGTERM, wait for exit, wait 5 s")
    print(f"temporary folder: {layout.root}")
    print(f"results: {layout.results}")
    plan = run.plan(layout)
    for label, commands in plan["seeding"].items():
        print(f"\n# seed {label}")
        for command in commands:
            print("  " + shlex.join(command))
        print(f"  write {layout.home(run.by_label(label)) / 'config.toml'}")
    print("\n# config.toml (both arms)\n" + config)
    for step in plan["steps"]:
        print(f"# {step['step']} {step['label']}")
        if "launch" in step:
            print("  " + shlex.join(step["launch"]))
            print(f"  resolve <pid> by {run.by_label(step['label']).executable}; wait until launch + "
                  f"{step['wait_seconds']} s")
        if "window" in step:
            stdin = " (sudo password on stdin)" if run.powermetrics else ""
            print("  " + shlex.join(step["window"]) + stdin)
        if "launch" in step:
            print("  quit <pid>: one SIGTERM, wait for exit, wait 5 s")
    print("\n# finally")
    print("  quit any copy this run started that still runs (one SIGTERM each)")
    print("  open -g -a <the app that was running> --env WALLPAPER_MACHINE_PANEL_AT_LAUNCH=0")
    print(f"  defaults delete <each suite>; rm -rf {layout.root}")


def execute(run: Run, layout: Layout, config: str, password: str | None) -> int:
    root = layout.root
    plan = run.plan(layout)
    for label, commands in plan["seeding"].items():
        for command in commands:
            for path in written_paths(command):
                if not Path(path).resolve().is_relative_to(root.resolve()):
                    raise RuntimeError(f"refusing to write outside the temporary folder: {path}")
            subprocess.run(command, check=True)
        (layout.home(run.by_label(label)) / "config.toml").write_text(config)
    layout.results.mkdir(parents=True, exist_ok=True)
    (layout.results / "config.toml").write_text(config)
    (layout.results / "plan.json").write_text(json.dumps(plan, indent=2, default=str))
    stdin = (password + "\n") if password is not None else None
    windows = []
    for step in plan["steps"]:
        if running_apps():
            raise RuntimeError(f"a WallpaperMachine is running before the {step['label']} step: "
                               f"{sorted(running_apps())}")
        pid = None
        if "launch" in step:
            arm = run.by_label(step["label"])
            started = time.monotonic()
            subprocess.run(step["launch"], check=True)
            pid = resolve_pid(arm, set())
            print(f"{MARK.step} {step['step']} {arm.label}: PID {pid}", flush=True)
            time.sleep(max(0.0, started + step["wait_seconds"] - time.monotonic()))
        try:
            if "window" in step:
                command = [str(pid) if part == "<pid>" else part for part in step["window"]]
                completed = subprocess.run(command, input=stdin, text=True, check=False)
                result = Path(command[command.index("--output") + 1])
                if completed.returncode != 0 or not result.is_file():
                    raise RuntimeError(f"the {step['label']} window was not measured "
                                       f"(power_benchmark exit {completed.returncode})")
                document = json.loads(result.read_text())
                appeared = (document.get("measurement", {}).get("app_guard", {})
                            .get("appeared_during_window") or [])
                if appeared:
                    raise RuntimeError(f"another WallpaperMachine started during the {step['label']} "
                                       f"window ({appeared}); the window is not comparable")
                windows.append({"label": step["label"], "result": str(result),
                                "metrics": window_metrics(document)})
        finally:
            if pid is not None:
                quit_app(pid)
    summary = {"wallpaper": run.wallpaper, "displays": run.display_uuids or "all",
               "condition": run.condition, "order": [w["label"] for w in windows],
               "windows": windows, **summarize(windows)}
    (layout.results / "summary.json").write_text(json.dumps(summary, indent=2))
    print(f"{MARK.ok} Summary: {layout.results / 'summary.json'}")
    for key, paired in summary["paired"].items():
        print(f"{MARK.step} {key}: {paired['difference']} median {paired['median']} {paired['values']}")
    return 0


def parse_arms(parser, values, environments) -> list[Arm]:
    arms = []
    for label, app in values or []:
        if not LABEL.fullmatch(label) or label == BASELINE:
            parser.error(f"arm label {label!r} must be a word other than {BASELINE}")
        if any(arm.label == label for arm in arms):
            parser.error(f"arm {label} is given twice")
        arms.append(Arm(label, Path(app).expanduser().resolve()))
    if len(arms) != 2:
        parser.error("give exactly two arms: --arm A APP --arm B APP")
    for label, assignment in environments or []:
        key, separator, value = assignment.partition("=")
        arm = next((arm for arm in arms if arm.label == label), None)
        if arm is None:
            parser.error(f"--arm-env names no arm {label}")
        if not separator or not ENV_KEY.fullmatch(key):
            parser.error(f"--arm-env expects KEY=VALUE, got {assignment!r}")
        if key in HARNESS_ENVIRONMENT:
            parser.error(f"{key} is set by this script for every launch")
        arm.env[key] = value
    return arms


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--arm", nargs=2, action="append", metavar=("LABEL", "APP"),
                        help="An arm: a label and a WallpaperMachine.app; give two. The same app twice "
                             "compares settings given with --arm-env.")
    parser.add_argument("--arm-env", nargs=2, action="append", metavar=("LABEL", "KEY=VALUE"),
                        help="Environment for one arm's launches, such as an A/B switch; repeatable.")
    parser.add_argument("--wallpaper", required=True, help="Workshop id in the source library.")
    parser.add_argument("--display-uuid", action="append", metavar="UUID",
                        help="Play only on this display (its config.toml uuid); repeatable. Default: all.")
    parser.add_argument("--condition", default="T3", help="Condition id of the arm windows (default T3).")
    parser.add_argument("--pairs", type=int, default=3, help="A/B pairs, alternating order (default 3).")
    parser.add_argument("--settle", type=int, default=120, help="Seconds from launch to window (default 120).")
    parser.add_argument("--window", type=int, default=60, help="Seconds per window (default 60).")
    parser.add_argument("--source-home", type=Path, default=SOURCE_HOME,
                        help="App-support folder the wallpaper and settings are cloned from (read only).")
    password = parser.add_mutually_exclusive_group()
    password.add_argument("--sudo-password-file", type=Path, metavar="FILE",
                          help="First line is the sudo password for powermetrics.")
    password.add_argument("--sudo-password-stdin", action="store_true",
                          help="Read the sudo password for powermetrics from stdin.")
    parser.add_argument("--suspend-vm", action="store_true", help="Suspend a running Parallels VM first.")
    parser.add_argument("--allow-battery", action="store_true",
                        help="Measure on battery power instead of refusing; the whole run must stay on it.")
    parser.add_argument("--note", default="", help="Free text added to every window's note.")
    parser.add_argument("--dry-run", action="store_true", help="Print the plan; execute nothing.")
    args = parser.parse_args(argv)
    arms = parse_arms(parser, args.arm, args.arm_env)
    if args.pairs < 1 or args.settle < 1 or args.window < 1:
        parser.error("--pairs, --settle and --window must be positive")
    if args.condition not in power_benchmark.CONDITIONS or args.condition == BASELINE:
        parser.error(f"--condition must be one of {', '.join(c for c in power_benchmark.CONDITIONS if c != BASELINE)}")
    run = Run(arms=arms, wallpaper=args.wallpaper, display_uuids=args.display_uuid,
              condition=args.condition, pairs=args.pairs, settle=args.settle, window=args.window,
              source=args.source_home.expanduser(), password_file=args.sudo_password_file,
              password_stdin=args.sudo_password_stdin, suspend_vm=args.suspend_vm, note=args.note)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    try:
        run.check_inputs(args.dry_run)
        config = run.config_text()
    except Refused as error:
        print(f"{MARK.missing} {error}", file=sys.stderr)
        return 2
    if args.dry_run:
        layout = Layout(Path(tempfile.gettempdir()) / "wallpapermachine-power-ab-XXXXXX", RESULTS / stamp)
        print_plan(run, layout, config)
        return 0

    problems = preconditions(args.suspend_vm, args.allow_battery)
    secret = read_password(args.sudo_password_file) if run.powermetrics else None
    if secret is not None:
        checked = subprocess.run(["sudo", "-S", "-p", "", "-v"], input=secret + "\n", text=True,
                                 capture_output=True, check=False)
        if checked.returncode != 0:
            problems.append("sudo did not accept the password")
    found = running_apps()
    if len(found) > 1:
        problems.append(f"several WallpaperMachine copies are running ({sorted(found)}); "
                        "quit all but the one to restore")
    temporary = Path(tempfile.gettempdir())
    if os.stat(temporary).st_dev != os.stat(run.source).st_dev:
        problems.append(f"{temporary} is on another volume than {run.source}: clones would be copies")
    if problems:
        for problem in problems:
            print(f"{MARK.missing} {problem}", file=sys.stderr)
        return 2

    previous = {number: signal.signal(number, _interrupted) for number in (signal.SIGTERM, signal.SIGHUP)}
    layout = None
    user_app = None
    user_pid = None
    user_stamp = None
    try:
        layout = Layout(Path(tempfile.mkdtemp(prefix="wallpapermachine-power-ab-")), RESULTS / stamp)
        if found:
            user_pid, executable = next(iter(found.items()))
            # Known before the signal: an interruption while it quits still reopens it.
            user_app = app_bundle(executable)
            user_stamp = start_stamp(user_pid)
            print(f"{MARK.step} quitting WallpaperMachine {user_pid} ({user_app})", flush=True)
            quit_app(user_pid)
        return execute(run, layout, config, secret)
    finally:
        # The clean-up itself is not interruptible: a second Ctrl-C or signal while it waits
        # for a closing app would leave the user's app closed and the homes behind.
        interrupt = signal.getsignal(signal.SIGINT)
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        print(f"{MARK.step} cleaning up; interrupts are ignored until it finishes", flush=True)
        try:
            clean_up(run, layout, user_app, user_pid, user_stamp)
        finally:
            signal.signal(signal.SIGINT, interrupt)
            for number, handler in previous.items():
                signal.signal(number, handler)


def clean_up(run: Run, layout: Layout | None, user_app: Path | None, user_pid: int | None,
             user_stamp: str | None) -> None:
    """Quits what this run started, reopens the user's app once its copy has gone, and
    deletes the temporary homes, each step whether or not the one before it worked."""
    try:
        for pid, executable in running_apps().items():
            if pid == user_pid or pid in SIGNALLED:
                # It has had its one signal and may still be closing: wait, never signal again.
                if not wait_for_exit(pid, user_stamp if pid == user_pid else start_stamp(pid)):
                    print(f"{MARK.warn} WallpaperMachine {pid} has not exited; no second signal was sent",
                          file=sys.stderr)
                continue
            if any(executable.resolve() == arm.executable.resolve() for arm in run.arms):
                try:
                    quit_app(pid)
                except RuntimeError as error:
                    print(f"{MARK.warn} {error}", file=sys.stderr)
    finally:
        try:
            if user_app is not None:
                if user_pid in running_apps():
                    print(f"{MARK.warn} {user_app} is still running and was not reopened", file=sys.stderr)
                else:
                    subprocess.run(["open", "-g", "-a", str(user_app), "--env",
                                    "WALLPAPER_MACHINE_PANEL_AT_LAUNCH=0"], check=False)
                    print(f"{MARK.step} reopened {user_app}")
        finally:
            if layout is not None:
                for arm in run.arms:
                    subprocess.run(["defaults", "delete", str(layout.suite(arm))], capture_output=True,
                                   check=False)
                shutil.rmtree(layout.root, ignore_errors=True)
                print(f"{MARK.step} removed {layout.root}")


if __name__ == "__main__":
    raise SystemExit(main())
