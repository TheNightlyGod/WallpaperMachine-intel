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
CHECKS = (
    ("core", ("-p", "wallpaper-core", "--lib")),
    ("bridge", ("-p", "wallpaper-bridge", "--lib")),
    ("core-integration", ("-p", "wallpaper-core", "--test", "audio_response_controller",
                          "--test", "core_audio_api", "--test", "project_override_json",
                          "--test", "wallpaper_background")),
    ("shader", ("-p", "shader", "--features", "ffi")),
)
OPT_INS = ("WE_RUN_MACOS_WINDOW_TESTS", "WALLPAPER_MACHINE_MEDIA_TESTS", "WALLPAPER_MACHINE_NETWORK_TESTS")
CORE_EXCLUSIONS = {
    "tests::general::platform::case_wallpaper_window": "requires an explicitly authorized desktop run",
    "tests::general::platform::case_wallpaper_window_update_display": "requires an explicitly authorized desktop run",
    "tests::general::platform::case_wallpaper_window_layer_swap_revert": "requires an explicitly authorized desktop run",
    "tests::general::platform::case_wallpaper_window_layer_swap_finish": "requires an explicitly authorized desktop run",
    "tests::general::platform::case_wallpaper_window_announces_layers": "requires an explicitly authorized desktop run",
    "tests::general::project_smoke::case_3177024520": "requires an external wallpaper asset corpus",
    "tests::general::project_smoke::case_3470764447": "requires an external wallpaper asset corpus",
    "tests::general::resource_smoke::case_3177024520": "requires an external wallpaper asset corpus",
    "tests::general::resource_smoke::case_3470764447": "requires an external wallpaper asset corpus",
}


def run_checks(output, environment, runner=run_quiet):
    output.mkdir(parents=True, exist_ok=True)
    report = {"desktop_automation": False, "audio_hardware": False,
              "disabled_opt_ins": list(OPT_INS), "explicit_exclusions": CORE_EXCLUSIONS,
              "results": []}
    for test, reason in CORE_EXCLUSIONS.items():
        print(f"{MARK.warn} Excluded {test}: {reason}")
    with tempfile.TemporaryDirectory(prefix="wallpaper-rust-tests-") as home:
        env = dict(environment)
        for variable in OPT_INS:
            env.pop(variable, None)
        env["WALLPAPER_MACHINE_HOME"] = home
        for name, arguments in CHECKS:
            command = ["cargo", "test", "--release", "--locked", *arguments, "--", "--nocapture"]
            if name == "core":
                for test in CORE_EXCLUSIONS:
                    command += ["--skip", test]
            log = output / f"{name}.log"
            try:
                completed, _ = runner(command, log, cwd=RENDERER, env=env)
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
    args = parser.parse_args(argv)
    output = args.output or ARTIFACTS / "rust" / datetime.now().strftime("checks-%Y%m%d-%H%M%S-%f")
    return run_checks(output, cargo_environment())


if __name__ == "__main__":
    raise SystemExit(main())
