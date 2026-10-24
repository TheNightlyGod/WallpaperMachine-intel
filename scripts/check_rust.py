#!/usr/bin/env python3
"""Run the device-free Rust release checks with isolated state and explicit skips."""
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import tempfile

from build import cargo_environment
from lib.glyphs import markers
from lib.paths import ARTIFACTS, RENDERER
from lib.xcode import run_quiet, skipped_test_lines

MARK = markers()
# (name, cargo arguments, workspace directory). Cargo runs inside the workspace it tests:
# rustup resolves rust-toolchain.toml from the working directory.
CHECKS = (
    ("core", ("-p", "wallpaper-core", "--lib"), RENDERER),
    ("bridge", ("-p", "wallpaper-bridge", "--lib"), RENDERER),
    ("core-integration", ("-p", "wallpaper-core", "--test", "core_audio_api",
                          "--test", "project_override_json",
                          "--test", "wallpaper_background",
                          "--test", "first_frame_scaling",
                          "--test", "audio_response_capture_lifecycle",
                          "--test", "scene_audio_volume_validation"), RENDERER),
    ("shader", ("-p", "wm-shader", "--features", "ffi"), RENDERER),
)
OPT_INS = ("WE_RUN_MACOS_WINDOW_TESTS", "WALLPAPER_MACHINE_MEDIA_TESTS", "WALLPAPER_MACHINE_NETWORK_TESTS")
_DESKTOP_RUN = "requires an explicitly authorized desktop run"
CORE_EXCLUSIONS = {
    "tests::general::desktop_window::a_window_opens_with_a_layer_and_closes_without_one": _DESKTOP_RUN,
    "tests::general::desktop_window::updating_the_display_reshapes_window_view_and_layer": _DESKTOP_RUN,
    "tests::general::desktop_window::reverting_a_layer_swap_restores_the_layer_and_the_geometry": _DESKTOP_RUN,
    "tests::general::desktop_window::finishing_a_layer_swap_keeps_the_new_layer": _DESKTOP_RUN,
    "tests::general::desktop_window::every_installed_layer_is_announced_once_in_install_order": _DESKTOP_RUN,
}


def run_checks(output, environment, runner=run_quiet, *, observer_uniform_layout=False):
    output.mkdir(parents=True, exist_ok=True)
    report = {"desktop_automation": False, "audio_hardware": False,
              "disabled_opt_ins": list(OPT_INS), "explicit_exclusions": CORE_EXCLUSIONS,
              "results": []}
    for test, reason in CORE_EXCLUSIONS.items():
        print(f"{MARK.warn} Excluded {test}: {reason}")
    checks = CHECKS
    if observer_uniform_layout:
        checks += (("shader-observer", ("-p", "wm-shader", "--features", "ffi,observer-uniform-layout"), RENDERER),)
    with tempfile.TemporaryDirectory(prefix="wallpaper-rust-tests-") as home:
        env = dict(environment)
        for variable in OPT_INS:
            env.pop(variable, None)
        env["WALLPAPER_MACHINE_HOME"] = home
        for name, arguments, directory in checks:
            command = ["cargo", "test", "--release", "--locked", *arguments, "--", "--nocapture"]
            if name == "core":
                for test in CORE_EXCLUSIONS:
                    command += ["--skip", test]
            log = output / f"{name}.log"
            try:
                completed, _ = runner(command, log, cwd=directory, env=env)
                status = completed.returncode
            except OSError as error:
                status = 1
                log.write_text(str(error) + "\n")
            lines = log.read_text(errors="replace").splitlines()
            skips = skipped_test_lines(lines)
            summaries = [line.strip() for line in lines if line.startswith("test result:")]
            report["results"].append({"name": name, "command": command, "exit": status,
                                      "log": str(log), "skips": skips, "test_summaries": summaries})
            print(f"{MARK.ok if status == 0 else MARK.missing} Rust {name}: exit {status}; log: {log}", flush=True)
            for line in summaries:
                print(f"  {line}", flush=True)
            for line in skips:
                print(f"{MARK.warn} {line}", flush=True)
            (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{MARK.warn} Desktop/media/network opt-ins are disabled; any listed asset skips are unverified coverage.")
    return int(any(result["exit"] != 0 for result in report["results"]))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Directory for full logs and the machine-readable verdict.")
    parser.add_argument("--observer-uniform-layout", action="store_true",
                        help="Also check opt-in compiler-origin uniform layout diagnostics; no native capture.")
    args = parser.parse_args(argv)
    output = args.output or ARTIFACTS / "rust" / datetime.now().strftime("checks-%Y%m%d-%H%M%S-%f")
    return run_checks(output, cargo_environment(), observer_uniform_layout=args.observer_uniform_layout)


if __name__ == "__main__":
    raise SystemExit(main())
