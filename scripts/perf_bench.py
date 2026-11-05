#!/usr/bin/env python3
"""Headless before/after measurements of renderer builds on real wallpapers.

Drives the renderer test binaries `scripts/check_renderer.py` builds
(`artifacts/renderer/bin/tests/` of any worktree) on the user's own wallpapers
with the user's own settings, read-only from
`~/Library/Application Support/WallpaperMachine`:

- `identity A B`: is B's picture byte-identical to A's? The poster harness hashes
  sampled frames at each display's size, backing scale and render scale; A runs
  twice, and frames that differ between A's two runs are excluded as
  nondeterministic (wall-clock scripts and particles).
- `cost A B`: what does B cost against A? The headless energy test runs the
  production scene wallpaper on every display's surface at once, A and B in
  alternating ABBA order as fresh processes, each its own resource coalition,
  with paired differences and a bootstrap confidence interval per metric.
- `aa A`: the noise floor: A against a copy of itself in another folder.
- `report DIR`: prints a run's table again and writes its flat CSV.

A condition is a binary set (`--bin LABEL=DIR`) or that set with extra
environment (`--variant LABEL=BIN_LABEL:ENV=VALUE,...`), so an optimization's
off-switch is measured in one binary. Each set is wrapped in scratch bundles
under `artifacts/perf-bench/bin/<label>/` (bundle id
`dev.wallpapermachine.perfbench.<label>.<binary>`), so every set keeps its own
compiled Metal cache and every probe can be launched as an app of its own.
Nothing here sets a wallpaper, touches the desktop, captures the screen, starts
audio or writes under the user's wallpaper library.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import random
import re
import shutil
import statistics
import subprocess
import sys
import time
import tomllib
from types import SimpleNamespace

from lib.glyphs import markers
from lib.paths import ARTIFACTS

MARK = markers()
PERF_ARTIFACTS = ARTIFACTS / "perf-bench"
USER_HOME = Path.home() / "Library/Application Support/WallpaperMachine"
ENERGY_BINARY = "unchanged_present_test"
SMOKE_BINARY = "metal_scene_draw_smoke"
BINARIES = (ENERGY_BINARY, SMOKE_BINARY)
ENERGY_TEST = "UnchangedPresent.LocalProjectEnergyIsMeasuredHeadlessly"
POSTER_TEST = "MetalSceneDraw.LocalProjectsDrawAPosterPicture"
LOCAL_TEST = "MetalSceneDraw.LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend"
BUNDLE_PREFIX = "dev.wallpapermachine.perfbench"
PRODUCTION_SURFACES = "3840x2160@2+3456x2234@2"
SCALING_MODES = ("none", "stretch", "fit", "fill", "fit_blurred")
LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,39}")
ENV_NAME = re.compile(r"[A-Z_][A-Z0-9_]*")
HASH_LINE = re.compile(r"^\[ HASH     \] (\S+) (\d+)x(\d+) frame=(\d+) sha256=([0-9a-f]{64})$", re.MULTILINE)
COST_LINE = re.compile(r"^\[ COST     \] (\S+) (\{.*\})$", re.MULTILINE)
MSAA = {"none": 0, "x2": 2, "x4": 4, "x8": 8}
LEVELS = {"disabled": 0, "low": 1, "medium": 2, "high": 3, "ultra": 4}
POST_PROCESSING = {"disabled": 0, "enabled": 2, "ultra": 4, "displayhdr": 5}
# A run is rejected when other processes kept the GPU busy for this share of
# the window (power_benchmark.GPU_CONTENTION_SHARE), or when its frame count
# strays this far from its condition's median.
CONTENTION_SHARE = 0.25
FRAME_TOLERANCE = 0.01
# The bootstrap interval of the median of three deltas is their range, which
# excludes zero for a quarter of pure-noise runs; five keep that to 1 in 16.
MIN_PAIRS = 5
BOOTSTRAP_RESAMPLES = 10_000
# Higher is better for these; every other metric is a cost.
THROUGHPUT_METRICS = ("frames_per_s", "presented_per_s")
# Work avoided rather than work done: more is neither a cost nor throughput.
AVOIDED_WORK_METRICS = ("presents_skipped_per_s",)
LSREGISTER = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                  "LaunchServices.framework/Support/lsregister")


class BenchError(RuntimeError):
    """A request the driver cannot carry out; printed without a traceback."""


# --- safety ------------------------------------------------------------------

def ensure_scratch(path: Path, home: Path | None = None) -> Path:
    """Refuse any write inside the user's wallpaper library; return the path resolved."""
    resolved = Path(path).resolve()
    protected = Path(home if home is not None else USER_HOME).resolve()
    if resolved == protected or protected in resolved.parents:
        raise BenchError(f"refusing to write inside the user's wallpaper library: {resolved}")
    return resolved


# --- parsing -------------------------------------------------------------------

def parse_surfaces(text: str) -> list[dict]:
    """`3840x2160@2+3456x2234@2`: the surfaces one run draws at once."""
    surfaces = []
    for item in text.split("+"):
        match = re.fullmatch(r"(\d+)x(\d+)@(\d+(?:\.\d+)?)", item.strip())
        if not match:
            raise BenchError(f"a surface is <width>x<height>@<scale>, not {item!r}")
        width, height, scale = int(match[1]), int(match[2]), float(match[3])
        if not (0 < width <= 16384 and 0 < height <= 16384 and 1.0 <= scale <= 4.0):
            raise BenchError(f"surface out of range: {item!r}")
        surfaces.append({"width": width, "height": height, "scale": scale})
    return surfaces


def surface_name(surface: dict) -> str:
    return f"{surface['width']}x{surface['height']}@{surface['scale']:g}"


def surfaces_name(surfaces: list[dict]) -> str:
    return "+".join(surface_name(surface) for surface in surfaces)


def parse_label(text: str, what: str) -> str:
    if not LABEL.fullmatch(text):
        raise BenchError(f"{what} label {text!r} must be letters, digits and '-' (bundle-id safe)")
    return text


def parse_bin(text: str) -> tuple[str, Path]:
    """`LABEL=DIR`: a check_renderer.py `artifacts/renderer/bin/tests` directory."""
    label, separator, directory = text.partition("=")
    if not separator or not directory:
        raise BenchError(f"--bin takes LABEL=DIR, not {text!r}")
    return parse_label(label, "--bin"), Path(directory).expanduser()


def parse_variant(text: str) -> tuple[str, str, dict[str, str]]:
    """`LABEL=BIN_LABEL:ENV=VALUE,...`: a binary set run with extra environment."""
    label, separator, rest = text.partition("=")
    build, colon, assignments = rest.partition(":")
    if not separator or not build:
        raise BenchError(f"--variant takes LABEL=BIN_LABEL:ENV=VALUE,..., not {text!r}")
    env = {}
    for assignment in filter(None, assignments.split(",")) if colon else ():
        name, equals, value = assignment.partition("=")
        if not equals or not ENV_NAME.fullmatch(name):
            raise BenchError(f"--variant environment is NAME=VALUE, not {assignment!r}")
        env[name] = value
    return parse_label(label, "--variant"), parse_label(build, "--variant binary"), env


def abba_order(first: str, second: str, pairs: int) -> list[str]:
    """A B B A A B B A ...: each adjacent pair holds one run of each, and neither
    condition always goes first, so a drift over the session cancels out."""
    order = []
    for index in range(pairs):
        order += [first, second] if index % 2 == 0 else [second, first]
    return order


def parse_hashes(text: str) -> dict[str, dict[int, str]]:
    """`[ HASH ]` lines of the poster harness: scene -> {draw: sha256}."""
    found: dict[str, dict[int, str]] = {}
    for scene, _width, _height, frame, digest in HASH_LINE.findall(text):
        found.setdefault(scene, {})[int(frame)] = digest
    return found


def parse_cost_lines(text: str) -> dict[str, dict]:
    """`[ COST ]` lines of the timed local-project run: scene -> its record."""
    return {scene: json.loads(record) for scene, record in COST_LINE.findall(text)}


def read_energy_record(path: Path) -> dict:
    """The schema-2 record `WE_TEST_ENERGY_OUTPUT` names; raises on anything else."""
    record = json.loads(Path(path).read_text())
    if not isinstance(record, dict) or record.get("schema") != 2:
        raise ValueError("not a schema-2 energy record")
    for section in ("surfaces", "window", "cpu", "gpu", "memory", "thermal"):
        if section not in record:
            raise ValueError(f"energy record has no {section}")
    if not record["window"].get("seconds"):
        raise ValueError("energy record has no window length")
    return record


def thermal_throttled(text: str | None) -> bool:
    """Whether `pmset -g therm` reports a warning level or a CPU speed limit."""
    for line in (text or "").splitlines():
        limit = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", line)
        if limit and int(limit[1]) < 100:
            return True
        if re.search(r"(thermal|performance) warning level", line, re.IGNORECASE) and \
                not re.search(r"\bNo (thermal|performance) warning level", line, re.IGNORECASE):
            return True
    return False


# --- settings (read-only) ------------------------------------------------------

def read_json(path: Path) -> dict:
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def user_config(home: Path) -> dict:
    """The quality the app applies, from `config.toml`, read without writing."""
    try:
        with (Path(home) / "config.toml").open("rb") as stream:
            config = tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError):
        config = {}
    quality = config.get("quality", {}) if isinstance(config.get("quality"), dict) else {}
    scene = quality.get("scene", {}) if isinstance(quality.get("scene"), dict) else {}
    render_scale = quality.get("render_scale", 1.0)
    try:
        render_scale = min(1.0, max(0.25, float(render_scale)))
    except (TypeError, ValueError):
        render_scale = 1.0
    cap = quality.get("frame_rate_cap")
    resolution = quality.get("scene_resolution", "display")
    return {
        "render_scale": render_scale,
        "frame_rate_cap": int(cap) if isinstance(cap, int) and cap > 0 else None,
        "resolution": resolution if resolution in ("display", "canvas") else "display",
        "quality": {
            "msaa": MSAA.get(scene.get("msaa"), 0),
            "shadows": LEVELS.get(scene.get("shadows"), 2),
            "volumetrics": LEVELS.get(scene.get("volumetrics"), 2),
            "reflection": scene.get("reflection", True) is not False,
            "post_processing": POST_PROCESSING.get(scene.get("post_processing"), 2),
        },
        # Recorded only: the harness runs these at the engine's defaults (off),
        # so a run under other values is flagged rather than silently unlike.
        "scene_optimization_enabled": quality.get("scene_optimization_enabled", True),
        "scene_on_demand_enabled": quality.get("scene_on_demand_enabled", False),
        "metalfx_upscaling_enabled": quality.get("metalfx_upscaling_enabled", False),
        "scene_video_plane_sampling": (config.get("experimental") or {}).get(
            "scene_video_plane_sampling", False),
        "scene_display_framing": (config.get("experimental") or {}).get(
            "scene_display_framing", False),
    }


def display_inventory() -> list[dict]:
    """Online displays: pixel size, backing scale, refresh, main flag and identity."""
    from power_benchmark import command_output

    raw = command_output(["system_profiler", "-json", "SPDisplaysDataType"])
    try:
        cards = json.loads(raw).get("SPDisplaysDataType", []) if raw else []
    except json.JSONDecodeError:
        return []
    return parse_display_inventory(cards)


def parse_display_inventory(cards: list) -> list[dict]:
    found = []
    for card in cards:
        for display in card.get("spdisplays_ndrvs", []):
            pixels = re.match(r"(\d+) x (\d+)", display.get("_spdisplays_pixels", ""))
            points = re.match(r"(\d+) x (\d+)(?: @ ([\d.]+)Hz)?", display.get("_spdisplays_resolution", ""))
            if not pixels:
                continue

            def hex_id(key):
                try:
                    return int(display.get(key, ""), 16)
                except ValueError:
                    return None

            width, height = int(pixels[1]), int(pixels[2])
            found.append({
                "name": display.get("_name"),
                "width": width, "height": height,
                "scale": round(width / int(points[1]), 2) if points and int(points[1]) else 1.0,
                "refresh_hz": float(points[3]) if points and points[3] else None,
                "main": display.get("spdisplays_main") == "spdisplays_yes",
                "vendor_id": hex_id("_spdisplays_display-vendor-id"),
                "model_id": hex_id("_spdisplays_display-product-id"),
                "serial_number": hex_id("_spdisplays_display-serial-number"),
            })
    # The app counts the main display first.
    return sorted(found, key=lambda entry: not entry["main"])


def monitor_matches(selector: dict, display: dict | None, index: int) -> bool:
    """Whether a saved per-display entry applies to a surface, as the app matches them:
    `primary` is the main display, which is the first surface (whichever displays are
    connected now), `identity` the connected display of the surface's size whose ids it
    names."""
    kind = selector.get("kind")
    if kind == "primary":
        return index == 0
    if kind == "identity" and display:
        keys = [key for key in ("vendor_id", "model_id", "serial_number") if selector.get(key) is not None]
        return bool(keys) and all(selector[key] == display.get(key) for key in keys)
    return False


def wallpaper_settings(home: Path, wallpaper: str, surfaces: list[dict], displays: list[dict],
                       config: dict, scaling_override: list[str] | None = None,
                       fps_override: int | None = None) -> dict:
    """What the app would run `wallpaper` with on these surfaces."""
    home = Path(home)
    project = home / "Library" / wallpaper / "project.json"
    saved = read_json(home / "wallpapers" / f"{wallpaper}.json")
    manifest = read_json(project)
    kind = str(manifest.get("type") or saved.get("type") or "unknown").lower()
    overrides = saved.get("property_overrides")
    monitors = [entry for entry in saved.get("monitors") or [] if isinstance(entry, dict)]
    per_surface = []
    for index, surface in enumerate(surfaces):
        display = next((entry for entry in displays
                        if (entry["width"], entry["height"]) == (surface["width"], surface["height"])), None)
        saved_entry = next((entry for entry in monitors
                            if monitor_matches(entry.get("selector") or {}, display, index)), None)
        scaling, source = "fill", "default"
        if saved_entry and str(saved_entry.get("scaling_mode", "")).lower() in SCALING_MODES:
            scaling, source = str(saved_entry["scaling_mode"]).lower(), f"saved {saved_entry['selector'].get('kind')}"
        if scaling_override:
            scaling = scaling_override[index if len(scaling_override) > 1 else 0]
            source = "override"
        refresh = int(round(display["refresh_hz"])) if display and display.get("refresh_hz") else 60
        frame_rate = saved_entry.get("frame_rate") if saved_entry else None
        fps = max(1, min(int(frame_rate), refresh)) if isinstance(frame_rate, int) else min(refresh, 60)
        if config.get("frame_rate_cap"):
            fps = min(fps, config["frame_rate_cap"])
        per_surface.append({
            **surface, "scaling": scaling, "scaling_source": source,
            "scaling_factor": (saved_entry or {}).get("scaling_factor", 1.0),
            "display": display["name"] if display else None, "fps": fps_override or fps,
        })
    notes = []
    if len({entry["fps"] for entry in per_surface}) > 1:
        notes.append("surfaces resolve different frame rates; the run uses the first surface's")
    if any(entry["scaling_factor"] not in (1, 1.0) for entry in per_surface):
        notes.append("a saved scaling factor other than 1 is not applied by the harness")
    for key in ("scene_on_demand_enabled", "metalfx_upscaling_enabled", "scene_video_plane_sampling"):
        if config.get(key):
            notes.append(f"{key} is on in the app; the harness runs it off")
    if config.get("scene_display_framing"):
        notes.append("scene_display_framing is on in the app; the harness runs it off "
                     "unless a --variant sets WALLPAPER_MACHINE_SDR_FRAMING=1")
    audio = saved.get("audio") or {}
    if audio.get("response_enabled") and not audio.get("muted"):
        notes.append("audio response is on in the app; the harness hears no system audio")
    return {
        "id": wallpaper,
        "type": kind,
        "project": str(project),
        "project_exists": project.is_file(),
        "properties": json.dumps(overrides, separators=(",", ":"), sort_keys=True)
        if isinstance(overrides, dict) and overrides else None,
        "surfaces": per_surface,
        "fps": per_surface[0]["fps"] if per_surface else 60,
        "notes": notes,
    }


def skip_reason(settings: dict) -> str | None:
    if not settings["project_exists"]:
        return "no project.json in the library"
    if settings["type"] == "video":
        return "plain video: drawn by the system player, not the scene engine; desktop procedure only"
    if settings["type"] == "web":
        return "web wallpaper: drawn by WebKit, not the scene engine; desktop procedure only"
    if settings["type"] != "scene":
        return f"type {settings['type']!r} is not a scene"
    return None


def quality_env(config: dict) -> dict[str, str]:
    quality = config["quality"]
    return {"WE_TEST_MSAA": str(quality["msaa"]), "WE_TEST_SHADOWS": str(quality["shadows"]),
            "WE_TEST_VOLUMETRICS": str(quality["volumetrics"]),
            "WE_TEST_REFLECTION": "1" if quality["reflection"] else "0",
            "WE_TEST_POSTPROCESSING": str(quality["post_processing"])}


# --- binaries ------------------------------------------------------------------

def sha256(path: Path) -> str:
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def bundle_identifier(label: str, binary: str) -> str:
    return f"{BUNDLE_PREFIX}.{label}.{binary.replace('_', '-')}"


def wrap_binaries(label: str, source: Path, root: Path, names=BINARIES) -> dict:
    """Wrap each test binary of `source` in a scratch bundle under `root/bin/<label>/`.

    An unchanged binary is left in place, so its folder's compiled Metal stays warm."""
    source = Path(source)
    wrapped = {}
    for name in names:
        executable = source / name
        if not executable.is_file():
            raise BenchError(f"{executable} does not exist; run scripts/check_renderer.py in that tree")
        bundle = ensure_scratch(Path(root) / "bin" / label / f"{name}.app")
        target = bundle / "Contents/MacOS" / name
        digest = sha256(executable)
        if not target.is_file() or sha256(target) != digest:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(executable, target)
            target.chmod(0o755)
        # A UI element, as the app is an accessory: LSBackgroundOnly would clamp every
        # thread to legacy QoS, user-interactive render threads included. App Nap is
        # off because the app's desktop windows keep it from napping.
        info = {"CFBundleIdentifier": bundle_identifier(label, name), "CFBundleExecutable": name,
                "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1", "LSUIElement": True, "NSAppSleepDisabled": True}
        plist = bundle / "Contents/Info.plist"
        if not plist.is_file() or plistlib.loads(plist.read_bytes()) != info:
            plist.write_bytes(plistlib.dumps(info))
        wrapped[name] = {"source": str(executable), "bundle": str(bundle), "executable": str(target),
                         "sha256": digest, "bundle_identifier": info["CFBundleIdentifier"]}
    return wrapped


def build_identity(source: Path) -> dict:
    """The tree a binary directory was built from, as far as it can be told."""
    from power_benchmark import command_output

    source = Path(source).resolve()
    identity = {"source": str(source)}
    parts = source.parts
    if parts[-4:] == ("artifacts", "renderer", "bin", "tests"):
        tree = source.parents[3]
        identity.update(tree=str(tree),
                        commit=command_output(["git", "-C", str(tree), "rev-parse", "HEAD"]),
                        tree_dirty=bool(command_output(["git", "-C", str(tree), "status", "--porcelain"])))
    return identity


def linked_libraries(executable: Path) -> list[str]:
    from power_benchmark import command_output

    listing = command_output(["otool", "-L", str(executable)]) or ""
    return [line.strip().split(" (")[0] for line in listing.splitlines()[1:] if "/opt/homebrew/" in line]


# --- launching -------------------------------------------------------------------

def foreground_process():
    """Clear inherited Darwin background policy in the child, as check_renderer.py does."""
    os.setpriority(os.PRIO_DARWIN_PROCESS, 0, 0)
    os.setpriority(os.PRIO_DARWIN_THREAD, 0, 0)


def base_environment() -> dict[str, str]:
    """The invoking environment without WE_TEST_* and WALLPAPER_MACHINE_* settings, which
    each run sets explicitly."""
    return {key: value for key, value in os.environ.items()
            if not key.startswith(("WE_TEST_", "WALLPAPER_MACHINE_"))}


def run_direct(executable: str, arguments: list[str], env: dict[str, str], log: Path,
               timeout: float) -> int | str:
    log = ensure_scratch(log)
    log.parent.mkdir(parents=True, exist_ok=True)
    command = ["/usr/sbin/taskpolicy", "-a", "-l", "0", "-t", "0", executable, *arguments]
    with log.open("w") as stream:
        try:
            return subprocess.run(command, env={**base_environment(), **env}, stdout=stream,
                                  stderr=subprocess.STDOUT, preexec_fn=foreground_process,
                                  timeout=timeout, check=False).returncode
        except subprocess.TimeoutExpired:
            return "timeout"


def open_command(bundle: str, arguments: list[str], env: dict[str, str], stdout: Path,
                 stderr: Path) -> list[str]:
    command = ["open", "-W", "-n", "-g", "--stdout", str(stdout), "--stderr", str(stderr)]
    for name, value in sorted(env.items()):
        command += ["--env", f"{name}={value}"]
    return [*command, bundle, "--args", *arguments]


def run_as_app(wrapped: dict, arguments: list[str], env: dict[str, str], log: Path,
               timeout: float) -> dict:
    """Launch a wrapped binary as an app of its own (its own coalition and app QoS);
    fall back to a direct, foreground exec when LaunchServices will not."""
    log = ensure_scratch(log)
    log.parent.mkdir(parents=True, exist_ok=True)
    errors = log.with_suffix(".stderr.log")
    try:
        launched = subprocess.run(open_command(wrapped["bundle"], arguments, env, log, errors),
                                  capture_output=True, text=True, timeout=timeout, check=False)
        status = launched.returncode
        reason = (launched.stderr or launched.stdout).strip()
    except subprocess.TimeoutExpired:
        subprocess.run(["pkill", "-f", wrapped["executable"]], check=False)
        return {"method": "open", "status": "timeout"}
    if status == 0 and log.is_file():
        return {"method": "open", "status": 0}
    direct = run_direct(wrapped["executable"], arguments, env, log, timeout)
    return {"method": "direct", "status": direct, "open_failure": reason or f"open exited {status}"}


def gtest_passed(log: Path) -> bool:
    try:
        text = Path(log).read_text(errors="replace")
    except OSError:
        return False
    return "[  PASSED  ]" in text and "[  FAILED  ]" not in text


def wait_until_cool(limit: float = 300.0, poll: float = 10.0) -> dict:
    """Wait for no thermal or performance warning, at most `limit` seconds."""
    from power_benchmark import command_output

    started = time.monotonic()
    while True:
        text = command_output(["pmset", "-g", "therm"])
        if not thermal_throttled(text) or time.monotonic() - started >= limit:
            return {"waited_s": round(time.monotonic() - started, 1), "throttled": thermal_throttled(text)}
        time.sleep(poll)


# --- statistics ------------------------------------------------------------------

def median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def iqr(values: list[float]) -> float | None:
    if not values:
        return None
    if len(values) < 2:
        return 0.0
    quartiles = statistics.quantiles(values, n=4, method="inclusive")
    return quartiles[2] - quartiles[0]


def bootstrap_ci(deltas: list[float], resamples: int = BOOTSTRAP_RESAMPLES, seed: int = 0) -> tuple[float, float] | None:
    """95 % interval of the median paired difference, by resampling the pairs."""
    if not deltas:
        return None
    generator = random.Random(seed)
    medians = sorted(statistics.median(generator.choices(deltas, k=len(deltas))) for _ in range(resamples))
    return medians[int(0.025 * (resamples - 1))], medians[int(0.975 * (resamples - 1))]


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = fraction * (len(ordered) - 1)
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def verdict(metric: str, deltas: list[float], ci: tuple[float, float] | None, floor: float | None) -> str:
    """A saving or regression only when the interval excludes zero and the change is
    larger than the A/A noise floor; a frame-rate change is throughput, not power."""
    if len(deltas) < MIN_PAIRS or ci is None:
        return "insufficient pairs"
    if ci[0] <= 0.0 <= ci[1]:
        return "no change"
    middle = statistics.median(deltas)
    if floor is not None and abs(middle) <= floor:
        return "within noise"
    if metric in THROUGHPUT_METRICS:
        word = "throughput up" if middle > 0 else "throughput down"
    elif metric in AVOIDED_WORK_METRICS:
        word = "more skipped" if middle > 0 else "fewer skipped"
    else:
        word = "saving" if middle < 0 else "regression"
    return word if floor is not None else word + " (no A/A floor)"


def summarize(metric: str, runs: list[dict], first: str, second: str, floor: float | None) -> dict:
    """Median and IQR per condition, and the paired difference second - first."""
    values = {label: [run["metrics"][metric] for run in runs
                      if run["condition"] == label and run["accepted"] and run["metrics"].get(metric) is not None]
              for label in (first, second)}
    deltas = []
    for pair in sorted({run["pair"] for run in runs}):
        members = {run["condition"]: run for run in runs if run["pair"] == pair}
        if all(label in members and members[label]["accepted"]
               and members[label]["metrics"].get(metric) is not None for label in (first, second)):
            deltas.append(members[second]["metrics"][metric] - members[first]["metrics"][metric])
    ci = bootstrap_ci(deltas)
    base = median(values[first])
    middle = median(deltas)
    return {
        **{label: {"median": median(values[label]), "iqr": iqr(values[label]), "n": len(values[label])}
           for label in (first, second)},
        "paired_delta": {"median": middle, "ci95": list(ci) if ci else None, "pairs": len(deltas),
                         "pct": round(100.0 * middle / base, 2) if middle is not None and base else None},
        "deltas": deltas,
        "verdict": verdict(metric, deltas, ci, floor),
    }


def energy_metrics(record: dict) -> dict[str, float | None]:
    """The per-run figures compared between conditions, from one schema-2 record."""
    seconds = record["window"]["seconds"]
    cpu, gpu, memory = record["cpu"], record["gpu"], record["memory"]

    def rate(value, scale=1.0):
        return None if value is None else value * scale / seconds

    metrics = {
        "cpu_mw": rate(cpu.get("energy_mj")),
        "cpu_p_mw": rate(cpu.get("p_energy_mj")),
        "cpu_ms_per_s": rate(cpu.get("seconds"), 1000.0),
        "idle_wakeups_per_s": cpu.get("idle_wakeups_per_s"),
        "interrupt_wakeups_per_s": cpu.get("interrupt_wakeups_per_s"),
        "gpu_own_busy_pct": rate(gpu.get("own_busy_s"), 100.0),
        "gpu_ms_per_frame": gpu.get("ms_per_frame"),
        "cb_ms_p95": gpu.get("cb_ms_p95"),
        "gpu_coalition_mw": None if gpu.get("coalition_shared") else rate(gpu.get("coalition_energy_mj")),
        "gpu_all_mw": rate(gpu.get("all_energy_mj")),
        "footprint_mb_peak": memory.get("footprint_mb_peak"),
        "footprint_mb_end": memory.get("footprint_mb_end"),
        "frames_per_s": rate(sum(surface["frames_completed"] for surface in record["surfaces"])),
        "presented_per_s": rate(sum(surface["frames_presented"] for surface in record["surfaces"])),
    }
    counters = [surface.get("counters") for surface in record["surfaces"]]
    if counters and all(counters):
        metrics["draws_executed_per_s"] = rate(sum(entry["draws_executed"] for entry in counters))
        metrics["presents_skipped_per_s"] = rate(sum(entry["presents_skipped_unchanged"] for entry in counters))
    return metrics


def reject_runs(runs: list[dict]) -> None:
    """Mark runs whose window is not comparable: a failed test or frames, a GPU
    contended by others, a hot machine, or a frame count off its condition's median."""
    for run in runs:
        record = run.get("record")
        reasons = list(run.get("reasons", []))
        # The thermal wait gave up: the window would be measured on a speed-limited CPU,
        # which the process's own thermal state does not always show.
        if (run.get("thermal_wait") or {}).get("throttled"):
            reasons.append("CPU still thermally limited after the cooling wait")
        if record is not None:
            if any(surface["failed_frames"] for surface in record["surfaces"]):
                reasons.append("failed frames")
            if any(surface["backend"] != "native" for surface in record["surfaces"]):
                reasons.append("scene held, not drawn")
            if (record["gpu"].get("other_busy_share") or 0.0) > CONTENTION_SHARE:
                reasons.append(f"GPU contended ({record['gpu']['other_busy_share']:.0%} by others)")
            if record["thermal"].get("after") not in ("nominal", None):
                reasons.append(f"thermal state {record['thermal']['after']}")
        run["reasons"] = reasons
        run["accepted"] = not reasons
    for label in {run["condition"] for run in runs}:
        frames = [run["metrics"]["frames_per_s"] for run in runs
                  if run["condition"] == label and run["accepted"] and run["metrics"].get("frames_per_s")]
        middle = median(frames)
        for run in runs:
            value = run["metrics"].get("frames_per_s")
            if run["condition"] == label and run["accepted"] and middle and value is not None \
                    and abs(value - middle) > FRAME_TOLERANCE * middle:
                run["reasons"].append(f"frame rate {value:.2f}/s is off its median {middle:.2f}/s")
                run["accepted"] = False


def noise_floor(results: dict) -> dict[str, dict[str, float]]:
    """95th percentile of |A - A'| per wallpaper and metric, from an `aa` run."""
    floors = {}
    for key, entry in results.items():
        floors[key] = {metric: percentile([abs(delta) for delta in summary["deltas"]], 0.95)
                       for metric, summary in entry["metrics"].items() if summary["deltas"]}
    return floors


def compare_ppm(first: bytes, second: bytes) -> dict:
    """Differing pixels and the largest channel difference of two binary PPMs."""
    def body(data: bytes):
        # P6, width, height and maxval are separated by whitespace runs, and exactly one
        # whitespace byte follows the maxval: pixel bytes may themselves be whitespace.
        fields, position = [], 0
        while len(fields) < 4:
            while data[position:position + 1].isspace():
                position += 1
            end = position
            while end < len(data) and not data[end:end + 1].isspace():
                end += 1
            fields.append(data[position:end])
            position = end
        return (int(fields[1]), int(fields[2])), data[position + 1:]

    (size_a, pixels_a), (size_b, pixels_b) = body(first), body(second)
    if size_a != size_b or len(pixels_a) != len(pixels_b):
        return {"same_size": False}
    differing = largest = 0
    for index in range(0, len(pixels_a), 3):
        a, b = pixels_a[index:index + 3], pixels_b[index:index + 3]
        if a != b:
            differing += 1
            largest = max(largest, *(abs(x - y) for x, y in zip(a, b)))
    return {"same_size": True, "differing_pixels": differing, "max_channel_diff": largest}


# --- the session -------------------------------------------------------------------

class Session:
    """One driver invocation: its conditions, wrapped binaries, settings and report."""

    def __init__(self, args, kind: str):
        self.args = args
        self.kind = kind
        self.home = Path(args.home).expanduser()
        self.root = ensure_scratch(PERF_ARTIFACTS, self.home)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.out = ensure_scratch(Path(args.out) if args.out else self.root / f"{stamp}-{kind}", self.home)
        self.out.mkdir(parents=True, exist_ok=True)
        self.assets = Path(args.assets).expanduser() if args.assets else self.home / "SceneAssets"
        self.builds = {}
        for text in args.bin or []:
            label, directory = parse_bin(text)
            self.builds[label] = {"dir": directory}
        self.conditions = {label: {"build": label, "env": {}} for label in self.builds}
        for text in args.variant or []:
            label, build, env = parse_variant(text)
            if build not in self.builds:
                raise BenchError(f"--variant {label} names no --bin {build}")
            if label in self.conditions:
                raise BenchError(f"condition {label} is defined twice")
            self.conditions[label] = {"build": build, "env": env}
        self.config = user_config(self.home)
        if args.render_scale is not None:
            self.config["render_scale"] = min(1.0, max(0.25, args.render_scale))
        if args.resolution:
            self.config["resolution"] = args.resolution
        self.displays = display_inventory()
        self.surfaces = parse_surfaces(args.surfaces)
        self.scaling = args.scaling.split(",") if args.scaling else None
        if self.scaling and (any(mode not in SCALING_MODES for mode in self.scaling)
                             or len(self.scaling) not in (1, len(self.surfaces))):
            raise BenchError(f"--scaling takes one of {', '.join(SCALING_MODES)}, once or per surface")
        self.report = {"schema": 1, "kind": kind, "created": stamp, "out": str(self.out),
                       "builds": {}, "conditions": self.conditions,
                       "settings": {"config": self.config, "displays": self.displays,
                                    "surfaces": surfaces_name(self.surfaces), "wallpapers": {}},
                       "skips": [], "rejected_runs": []}

    def require(self, *labels):
        for label in labels:
            if label not in self.conditions:
                raise BenchError(f"no condition {label}: give --bin {label}=DIR or --variant {label}=...")

    def wrap(self, label: str, names=BINARIES):
        build = self.builds[label]
        if "bins" not in build:
            build["bins"] = wrap_binaries(label, build["dir"], self.root, names)
            libraries = linked_libraries(Path(build["bins"][names[0]]["executable"]))
            self.report["builds"][label] = {**build_identity(build["dir"]), "bins": build["bins"],
                                            "homebrew_libraries": libraries}
        return build["bins"]

    def binary(self, condition: str, name: str) -> dict:
        return self.wrap(self.conditions[condition]["build"])[name]

    def wallpapers(self):
        for wallpaper in self.args.wallpaper:
            settings = wallpaper_settings(self.home, wallpaper, self.surfaces, self.displays, self.config,
                                          self.scaling, self.args.fps)
            self.report["settings"]["wallpapers"][wallpaper] = settings
            reason = skip_reason(settings)
            if reason:
                self.report["skips"].append({"id": wallpaper, "reason": reason})
                print(f"{MARK.warn} {wallpaper}: skipped, {reason}")
                continue
            for note in settings["notes"]:
                print(f"{MARK.warn} {wallpaper}: {note}")
            yield settings

    def write(self):
        from power_benchmark import manifest

        self.report.setdefault("manifest", manifest(SimpleNamespace(note=self.args.note, configuration="Release")))
        path = self.out / "report.json"
        path.write_text(json.dumps(self.report, indent=2))
        write_csv(self.report, self.out / "report.csv")
        print_report(self.report)
        print(f"{MARK.step} Report: {path}")
        return path


# --- identity ------------------------------------------------------------------------

def identity_env(session: Session, settings: dict, surface: dict, frames: int, hash_frames=None) -> dict:
    env = {
        "WE_TEST_COMPARE_PROJECTS": settings["project"], "WE_TEST_ASSETS": str(session.assets),
        "WE_TEST_RANDOM_SEED": "1", "WE_TEST_SETTLE_TEXT": "1", "WE_TEST_METAL_WARMUP_TICKS": "40",
        "WE_TEST_METAL_FRAMES": str(frames), "WE_TEST_METAL_FRAME_STEP": repr(1.0 / settings["fps"]),
        "WE_TEST_COMPARE_SURFACE": f"{surface['width']}x{surface['height']}",
        "WE_TEST_COMPARE_SCALE_FACTOR": f"{surface['scale']:g}",
        "WE_TEST_COMPARE_RESOLUTION": session.config["resolution"],
        "WE_TEST_COMPARE_SCALING": surface["scaling"],
        "WE_TEST_COMPARE_RENDER_SCALE": repr(session.config["render_scale"]),
        **quality_env(session.config),
    }
    if settings["properties"]:
        env["WE_TEST_PROPERTIES"] = settings["properties"]
    if hash_frames is not None:
        env["WE_TEST_COMPARE_HASH_FRAMES"] = json.dumps(sorted(hash_frames))
    else:
        env["WE_TEST_COMPARE_HASH_EVERY"] = str(session.args.hash_every)
    return env


def identity_run(session, condition, settings, surface, name, frames, hash_frames=None, output=None):
    env = {**identity_env(session, settings, surface, frames, hash_frames), **session.conditions[condition]["env"]}
    if output is not None:
        env["WE_TEST_OUTPUT"] = str(ensure_scratch(output, session.home))
    log = session.out / "logs" / f"{name}.log"
    status = run_direct(session.binary(condition, SMOKE_BINARY)["executable"],
                        [f"--gtest_filter={POSTER_TEST}"], env, log, 1800)
    text = log.read_text(errors="replace") if log.is_file() else ""
    hashes = parse_hashes(text).get(settings["id"], {})
    return {"status": status, "log": str(log), "hashes": hashes}


def run_identity(args) -> int:
    session = Session(args, "identity")
    first, second = args.first, args.second
    session.require(first, second)
    results = session.report.setdefault("identity", {})
    for settings in session.wallpapers():
        for surface in settings["surfaces"]:
            key = f"{settings['id']}@{surface_name(surface)}"
            stem = key.replace("@", "_")
            runs = [identity_run(session, first, settings, surface, f"{stem}-{first}-1", args.frames),
                    identity_run(session, first, settings, surface, f"{stem}-{first}-2", args.frames),
                    identity_run(session, second, settings, surface, f"{stem}-{second}", args.frames)]
            entry = judge_identity(*(run["hashes"] for run in runs))
            entry.update(runs=[{key: run[key] for key in ("status", "log")} for run in runs],
                         scaling=surface["scaling"])
            if entry["first_diff_frame"] is not None and not args.no_diff:
                entry["first_diff"] = diff_frame(session, first, second, settings, surface, stem,
                                                 entry["first_diff_frame"], args.frames)
            results[key] = entry
            print(f"{MARK.step} {key}: {entry['verdict']} ({len(entry['comparable_frames'])} comparable, "
                  f"{len(entry['nondeterministic_frames'])} nondeterministic)")
    session.write()
    if not results:
        print(f"{MARK.missing} No wallpaper was compared", file=sys.stderr)
        return 1
    return 0 if all(entry["verdict"] in ("identical", "nondeterministic") for entry in results.values()) else 1


def judge_identity(first_a: dict[int, str], first_b: dict[int, str], second: dict[int, str]) -> dict:
    """Compare B's frames with A's where A's two runs agree with each other."""
    frames = sorted(set(first_a) | set(first_b) | set(second))
    missing = [frame for frame in frames if frame not in first_a or frame not in first_b or frame not in second]
    nondeterministic = [frame for frame in frames if frame not in missing and first_a[frame] != first_b[frame]]
    comparable = [frame for frame in frames if frame not in missing and frame not in nondeterministic]
    differing = [frame for frame in comparable if second[frame] != first_a[frame]]
    if not frames or missing:
        result = "error"
    elif differing:
        result = "different"
    elif not comparable:
        result = "nondeterministic"
    else:
        result = "identical"
    return {"frames": frames, "missing_frames": missing, "base_self_equal": not nondeterministic,
            "nondeterministic_frames": nondeterministic, "comparable_frames": comparable,
            "differing_frames": differing, "equal": result == "identical",
            "first_diff_frame": differing[0] if differing else None, "verdict": result}


def diff_frame(session, first, second, settings, surface, stem, frame, frames) -> dict:
    """Draw the first differing frame again from both and count what differs; the
    pictures are deleted again (a 4K frame is 25 MB)."""
    scratch = session.out / "diff" / stem
    pictures = {}
    for condition in (first, second):
        directory = scratch / condition
        identity_run(session, condition, settings, surface, f"{stem}-{condition}-diff", frames, {frame}, directory)
        found = directory / f"{settings['id']}-frame-{frame}.ppm"
        pictures[condition] = found.read_bytes() if found.is_file() else None
    shutil.rmtree(scratch, ignore_errors=True)
    if not all(pictures.values()):
        return {"frame": frame, "error": "a build delivered no picture for the frame"}
    return {"frame": frame, **compare_ppm(pictures[first], pictures[second])}


# --- cost -------------------------------------------------------------------------------

def energy_env(session: Session, settings: dict, condition: str, record: Path, warm: bool) -> dict:
    args = session.args
    env = {
        "WE_TEST_ENERGY_PROJECT": settings["project"], "WE_TEST_ASSETS": str(session.assets),
        "WE_TEST_ENERGY_SURFACES": ",".join(surface_name(surface) for surface in settings["surfaces"]),
        "WE_TEST_ENERGY_SCALING": ",".join(surface["scaling"] for surface in settings["surfaces"]),
        "WE_TEST_ENERGY_RESOLUTION": session.config["resolution"],
        "WE_TEST_ENERGY_FPS": str(settings["fps"]),
        "WE_TEST_ENERGY_WARMUP": str(2 if warm else args.warmup),
        "WE_TEST_ENERGY_SECONDS": str(2 if warm else args.window),
        "WE_TEST_ENERGY_CACHE": str(ensure_scratch(session.root / "cache" / condition / settings["id"], session.home)),
        "WE_TEST_ENERGY_OUTPUT": str(ensure_scratch(record, session.home)),
        **quality_env(session.config),
    }
    if session.config["render_scale"] < 1.0:
        env["WE_TEST_ENERGY_RENDER_SCALE"] = repr(session.config["render_scale"])
    if settings["properties"]:
        env["WE_TEST_PROPERTIES"] = settings["properties"]
    if args.counters:
        env["WE_TEST_ENERGY_COUNTERS"] = "1"
    return {**env, **session.conditions[condition]["env"]}


def saturated_env(session: Session, settings: dict, surface: dict, condition: str) -> dict:
    env = {
        "WE_TEST_METAL_PROJECTS": settings["project"], "WE_TEST_ASSETS": str(session.assets),
        "WE_TEST_RANDOM_SEED": "1", "WE_TEST_METAL_FRAMES": str(session.args.saturated_frames),
        "WE_TEST_METAL_SURFACE": f"{surface['width']}x{surface['height']}",
        "WE_TEST_METAL_SCALE_FACTOR": f"{surface['scale']:g}",
        "WE_TEST_METAL_RESOLUTION": session.config["resolution"],
        "WE_TEST_METAL_RENDER_SCALE": repr(session.config["render_scale"]),
        "WE_TEST_METAL_TIMING": "1", **quality_env(session.config),
    }
    if settings["properties"]:
        env["WE_TEST_PROPERTIES"] = settings["properties"]
    return {**env, **session.conditions[condition]["env"]}


def cost_run(session: Session, settings: dict, condition: str, name: str, warm: bool = False) -> dict:
    """One fresh process of the energy test, plus the saturated GPU runs when asked."""
    record_path = session.out / "records" / f"{name}.json"
    record_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.unlink(missing_ok=True)
    timeout = 240 + (4 if warm else session.args.warmup + session.args.window)
    cool = {"waited_s": 0.0, "throttled": False} if warm else wait_until_cool()
    wrapped = session.binary(condition, ENERGY_BINARY)
    arguments = [f"--gtest_filter={ENERGY_TEST}"]
    env = energy_env(session, settings, condition, record_path, warm)
    log = session.out / "logs" / f"{name}.log"
    if session.args.launch == "app":
        launch = run_as_app(wrapped, arguments, env, log, timeout)
    else:
        launch = {"method": "direct", "status": run_direct(wrapped["executable"], arguments, env, log, timeout)}
    run = {"name": name, "condition": condition, "launch": launch, "thermal_wait": cool,
           "log": str(session.out / "logs" / f"{name}.log"), "record": None, "metrics": {}, "reasons": []}
    try:
        run["record"] = read_energy_record(record_path)
        run["metrics"] = energy_metrics(run["record"])
    except (OSError, ValueError) as error:
        run["reasons"].append(f"no energy record: {error}")
    if launch["status"] != 0 or not gtest_passed(run["log"]):
        run["reasons"].append(f"the energy test did not pass ({launch['method']}, status {launch['status']})")
    if session.args.saturated:
        for surface in settings["surfaces"]:
            log = session.out / "logs" / f"{name}-saturated-{surface_name(surface)}.log"
            status = run_direct(session.binary(condition, SMOKE_BINARY)["executable"],
                                [f"--gtest_filter={LOCAL_TEST}"],
                                saturated_env(session, settings, surface, condition), log, 600)
            text = log.read_text(errors="replace") if log.is_file() else ""
            cost = parse_cost_lines(text).get(settings["id"])
            if status != 0 or cost is None:
                run["reasons"].append(f"saturated run on {surface_name(surface)} failed (status {status})")
                continue
            suffix = "@" + surface_name(surface)
            for metric in ("gpu_ms_p50", "gpu_ms_p95", "gpu_ms_mean", "gpu_busy_ms_mean", "cpu_ms_mean",
                           "render_passes_per_draw", "blits_per_draw", "render_target_bytes"):
                run["metrics"][f"sat_{metric}{suffix}"] = cost.get(metric)
    return run


def run_cost_pair(session: Session, first: str, second: str, pairs: int, floors: dict) -> dict:
    results = session.report.setdefault("cost", {})
    for settings in session.wallpapers():
        key = f"{settings['id']}@{surfaces_name(settings['surfaces'])}"
        stem = key.replace("@", "_").replace("+", "_")
        print(f"{MARK.step} {key}: warming {first} and {second}")
        for condition in dict.fromkeys((first, second)):
            cost_run(session, settings, condition, f"{stem}-{condition}-warm", warm=True)
        order = abba_order(first, second, pairs)
        runs, last = [], None
        for index, condition in enumerate(order):
            if last is not None:
                time.sleep(max(0.0, session.args.cooldown - (time.monotonic() - last)))
            run = cost_run(session, settings, condition, f"{stem}-{index:02d}-{condition}")
            last = time.monotonic()
            run["pair"] = index // 2
            runs.append(run)
            print(f"{MARK.step} {key}: run {index + 1}/{len(order)} {condition} "
                  f"({run['launch']['method']}){'; ' + '; '.join(run['reasons']) if run['reasons'] else ''}")
        reject_runs(runs)
        metrics = sorted({metric for run in runs for metric in run["metrics"]})
        floor = floors.get(key, {})
        results[key] = {
            "order": "".join("A" if condition == first else "B" for condition in order),
            "first": first, "second": second,
            "runs": [{key_: run[key_] for key_ in ("name", "condition", "pair", "accepted", "reasons", "launch",
                                                     "log", "metrics", "record")} for run in runs],
            "metrics": {metric: summarize(metric, runs, first, second, floor.get(metric)) for metric in metrics},
        }
        session.report["rejected_runs"] += [{"key": key, "name": run["name"], "reasons": run["reasons"]}
                                            for run in runs if not run["accepted"]]
    return results


def run_cost(args) -> int:
    session = Session(args, "cost")
    session.require(args.first, args.second)
    floors = {}
    if args.noise_floor:
        floors = read_json(Path(args.noise_floor)).get("aa_noise_floor", {})
        session.report["noise_floor_source"] = str(Path(args.noise_floor).resolve())
    run_cost_pair(session, args.first, args.second, args.pairs, floors)
    session.write()
    return 0


def run_aa(args) -> int:
    session = Session(args, "aa")
    session.require(args.first)
    build = session.conditions[args.first]["build"]
    copy = parse_label(f"{args.first}-aa", "A/A copy")
    session.builds[copy] = {"dir": session.builds[build]["dir"]}
    session.conditions[copy] = {"build": copy, "env": dict(session.conditions[args.first]["env"])}
    results = run_cost_pair(session, args.first, copy, args.pairs, {})
    session.report["aa_noise_floor"] = noise_floor(results)
    session.write()
    return 0


# --- reporting -------------------------------------------------------------------------

def format_value(value) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.4g}"
    return str(value)


def report_rows(report: dict) -> list[dict]:
    rows = []
    for key, entry in report.get("cost", {}).items():
        wallpaper, _, surfaces = key.partition("@")
        for metric, summary in entry["metrics"].items():
            for label in (entry["first"], entry["second"]):
                delta = summary["paired_delta"] if label == entry["second"] else {}
                ci = delta.get("ci95") or [None, None]
                rows.append({"wallpaper": wallpaper, "surfaces": surfaces, "label": label, "metric": metric,
                             "median": summary[label]["median"], "iqr": summary[label]["iqr"],
                             "paired_delta": delta.get("median"), "ci95_low": ci[0], "ci95_high": ci[1],
                             "verdict": summary["verdict"] if label == entry["second"] else ""})
    for key, entry in report.get("identity", {}).items():
        wallpaper, _, surfaces = key.partition("@")
        rows.append({"wallpaper": wallpaper, "surfaces": surfaces, "label": "", "metric": "identity",
                     "median": None, "iqr": None, "paired_delta": None, "ci95_low": None, "ci95_high": None,
                     "verdict": entry["verdict"]})
    return rows


CSV_COLUMNS = ("wallpaper", "surfaces", "label", "metric", "median", "iqr", "paired_delta",
               "ci95_low", "ci95_high", "verdict")


def write_csv(report: dict, path: Path) -> None:
    with ensure_scratch(path).open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        writer.writerows(report_rows(report))


def print_report(report: dict) -> None:
    for key, entry in report.get("identity", {}).items():
        extra = ""
        if entry.get("first_diff"):
            diff = entry["first_diff"]
            extra = f"; frame {diff['frame']}: {diff.get('differing_pixels', '?')} pixels differ, " \
                    f"max channel {diff.get('max_channel_diff', '?')}"
        print(f"{MARK.step} identity {key}: {entry['verdict']}, frames {entry['comparable_frames']} "
              f"compared, {entry['nondeterministic_frames']} nondeterministic{extra}")
    for key, entry in report.get("cost", {}).items():
        first, second = entry["first"], entry["second"]
        print(f"{MARK.step} cost {key} ({entry['order']}):")
        print(f"    {'metric':<34} {first:>12} {second:>12} {'delta':>10} {'ci95':>22}  verdict")
        for metric, summary in entry["metrics"].items():
            ci = summary["paired_delta"]["ci95"]
            interval = f"[{format_value(ci[0])}, {format_value(ci[1])}]" if ci else "-"
            print(f"    {metric:<34} {format_value(summary[first]['median']):>12} "
                  f"{format_value(summary[second]['median']):>12} "
                  f"{format_value(summary['paired_delta']['median']):>10} {interval:>22}  {summary['verdict']}")
    for skip in report.get("skips", []):
        print(f"{MARK.warn} skipped {skip['id']}: {skip['reason']}")
    for run in report.get("rejected_runs", []):
        print(f"{MARK.warn} rejected {run['name']}: {'; '.join(run['reasons'])}")


def run_report(args) -> int:
    path = Path(args.path)
    path = path / "report.json" if path.is_dir() else path
    report = read_json(path)
    if not report:
        raise BenchError(f"{path} holds no report")
    print_report(report)
    write_csv(report, path.with_suffix(".csv"))
    print(f"{MARK.step} CSV: {path.with_suffix('.csv')}")
    return 0


def run_clean(_args) -> int:
    """Delete the wrapped bundles and the scratch bundle ids' Metal caches."""
    from power_benchmark import command_output

    bins = PERF_ARTIFACTS / "bin"
    for bundle in sorted(bins.glob("*/*.app")) if bins.is_dir() else []:
        if LSREGISTER.is_file():
            subprocess.run([str(LSREGISTER), "-u", str(bundle)], capture_output=True, check=False)
    shutil.rmtree(bins, ignore_errors=True)
    shutil.rmtree(PERF_ARTIFACTS / "cache", ignore_errors=True)
    cache = command_output(["getconf", "DARWIN_USER_CACHE_DIR"])
    removed = []
    if cache:
        for folder in Path(cache).glob(f"{BUNDLE_PREFIX}.*"):
            shutil.rmtree(folder, ignore_errors=True)
            removed.append(folder.name)
    print(f"{MARK.step} Removed {bins}, the scene caches and {len(removed)} Metal cache folder(s)")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    def common(command):
        command.add_argument("--bin", action="append", metavar="LABEL=DIR",
                             help="A check_renderer.py artifacts/renderer/bin/tests directory; repeatable")
        command.add_argument("--variant", action="append", metavar="LABEL=BIN_LABEL:ENV=VALUE,...",
                             help="A --bin set run with extra environment (an off-switch); repeatable")
        command.add_argument("--wallpaper", action="append", required=True, metavar="ID",
                             help="Workshop id in the user's library; repeatable")
        command.add_argument("--surfaces", default=PRODUCTION_SURFACES,
                             help=f"Surfaces drawn at once, '+'-separated (default {PRODUCTION_SURFACES})")
        command.add_argument("--scaling", help="Scaling mode, once or per surface (default: the saved one)")
        command.add_argument("--render-scale", type=float, help="Override config.toml's render scale")
        command.add_argument("--fps", type=int, help="Override the resolved frame rate")
        command.add_argument("--resolution", choices=("display", "canvas"), help="Override the 2D scene resolution")
        command.add_argument("--home", default=str(USER_HOME), help="Where settings and wallpapers are read from")
        command.add_argument("--assets", help="SceneAssets directory (default: <home>/SceneAssets)")
        command.add_argument("--out", help="Run directory (default: artifacts/perf-bench/<time>-<kind>)")
        command.add_argument("--note", default="", help="Free text recorded in the manifest")

    def paced(command):
        command.add_argument("--pairs", type=int, default=5, help="Measured pairs, ABBA order (default 5)")
        command.add_argument("--warmup", type=float, default=8.0, help="Seconds after the first frame (default 8)")
        command.add_argument("--window", type=float, default=30.0, help="Measured seconds (default 30)")
        command.add_argument("--cooldown", type=float, default=20.0, help="Seconds between runs (default 20)")
        command.add_argument("--counters", action="store_true", help="Also count renderer work (both conditions)")
        command.add_argument("--launch", choices=("app", "direct"), default="app",
                             help="app: each probe an app of its own (own coalition; default); direct: a "
                                  "foreground child of this process (shares this terminal's coalition)")
        command.add_argument("--saturated", action="store_true",
                             help="Also time back-to-back draws on the GPU per surface")
        command.add_argument("--saturated-frames", type=int, default=240, help="Draws per saturated run")

    identity = commands.add_parser("identity", help="Are B's pictures byte-identical to A's?")
    identity.add_argument("first", metavar="A")
    identity.add_argument("second", metavar="B")
    common(identity)
    identity.add_argument("--frames", type=int, default=600, help="Draws per run (default 600)")
    identity.add_argument("--hash-every", type=int, default=60, help="Hash every k-th draw (default 60)")
    identity.add_argument("--no-diff", action="store_true", help="Do not count the differing pixels")
    identity.set_defaults(handler=run_identity)

    cost = commands.add_parser("cost", help="What does B cost against A?")
    cost.add_argument("first", metavar="A")
    cost.add_argument("second", metavar="B")
    common(cost)
    paced(cost)
    cost.add_argument("--noise-floor", help="report.json of an aa run, for the verdicts")
    cost.set_defaults(handler=run_cost)

    aa = commands.add_parser("aa", help="The noise floor: A against a copy of itself")
    aa.add_argument("first", metavar="A")
    common(aa)
    paced(aa)
    aa.set_defaults(handler=run_aa)

    report = commands.add_parser("report", help="Print a run's table and write its CSV")
    report.add_argument("path", help="A run directory or its report.json")
    report.set_defaults(handler=run_report)

    clean = commands.add_parser("clean", help="Delete wrapped bundles, scene caches and their Metal caches")
    clean.set_defaults(handler=run_clean)

    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except BenchError as error:
        print(f"{MARK.missing} {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
