#!/usr/bin/env python3
"""Run non-interactive native tests; desktop automation requires --ui.

Order: the Python script tests in `scripts/tests/`, then `xcodegen generate`, then
the Swift test bundle. Result bundles and the full xcodebuild log land in
`artifacts/tests/` and are disposable; `scripts/clean.py` removes them. The terminal
only gets compile errors, failing tests and a one-line verdict; pass `--verbose` for
the raw stream. See docs/testing/README.md.

`--only` narrows the native run to test classes or methods
(`--only LibraryStoreTests --only WorkshopSearchTests/testPagination`) for quick
iteration on a small change; the full gate is still the default and the final word.

Opt-in layers are off by default and are requested through the environment:
`WALLPAPER_MACHINE_MEDIA_TESTS=1` (real video decoding) and
`WALLPAPER_MACHINE_NETWORK_TESTS=1` (live Steam pages and temporary native SteamCMD install).
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import os
import shutil
import subprocess
import sys

from lib.glyphs import markers
from lib.paths import BUILD, ROOT, TEST_ARTIFACTS, XCODEPROJ
from lib.xcode import run_quiet, test_summary

MARK = markers()
SCRIPT_TESTS = sorted((ROOT / "scripts/tests").glob("test_*.py"))
NATIVE_TARGET = "WallpaperMachineTests"
UI_TARGET = "WallpaperMachineUITests"

# Opt-in test layers. xcodebuild does not hand its own environment to the hosted test
# process; `TEST_RUNNER_`-prefixed variables are forwarded with the prefix stripped,
# which is what makes these reach the tests that gate themselves on them.
OPT_IN_VARIABLES = ("WALLPAPER_MACHINE_MEDIA_TESTS", "WALLPAPER_MACHINE_NETWORK_TESTS")

# Xcode's thread performance checker runs inside the test host, and its report of a
# priority inversion is symbolicated on the main thread; under the gate's load that
# has held tests past their time allowance. AppKit raises one itself: the first time
# a focused text field with unchecked text is removed, the main thread waits for its
# data detectors to load. Only the inversion reports are turned off.
TEST_HOST_VARIABLES = {"PERFC_DISABLE_PRIORITY_INVERSIONS": "1"}

# Result bundles are tens of megabytes each and only the newest ones are ever read.
KEPT_RESULT_BUNDLES = 5


def test_identifiers(target, only):
    """`-only-testing:` identifiers for a target, given `Class` or `Class/method` names."""
    identifiers = []
    for entry in only or ():
        name = entry.strip().strip("/")
        if not name:
            continue
        if name.startswith(target + "/"):
            name = name[len(target) + 1:]
        identifiers.append(f"{target}/{name}")
    return identifiers or [target]


def test_host_environment(environ):
    """`environ` with the test host's own variables and the opt-in layers forwarded to it."""
    env = dict(environ)
    for name, value in TEST_HOST_VARIABLES.items():
        env["TEST_RUNNER_" + name] = value
    for name in OPT_IN_VARIABLES:
        if name in env:
            env["TEST_RUNNER_" + name] = env[name]
    return env


def xcodebuild_command(scheme, target, result, only=None, parallel=True):
    command = [
        "xcodebuild", "-project", XCODEPROJ.name,
        "-scheme", scheme, "-configuration", "Debug", "-derivedDataPath", str(BUILD),
        "-destination", "platform=macOS,arch=arm64", "-resultBundlePath", str(result),
    ]
    command += ["-only-testing:" + identifier for identifier in test_identifiers(target, only)]
    # Test classes run in parallel worker processes. Every suite already isolates its
    # state through `WALLPAPER_MACHINE_HOME`, temporary directories and per-test
    # `UserDefaults` suites, so workers do not share a home, a preferences domain or a
    # staging tree. Most of the wall clock is spent waiting on debounce intervals and
    # child-process reaping, which overlaps well.
    command += ["-parallel-testing-enabled", "YES" if parallel else "NO"]
    # A real CDN install includes downloads and system security assessments. Keep the
    # routine gate bounded tightly; only the explicitly opted-in layer gets more time.
    allowance = "660" if os.environ.get("WALLPAPER_MACHINE_NETWORK_TESTS") == "1" else "90"
    command += ["-maximum-test-execution-time-allowance", allowance, "-test-timeouts-enabled", "YES", "test"]
    return command


def prune_result_bundles(keep=KEPT_RESULT_BUNDLES, directory=TEST_ARTIFACTS):
    """Keep the newest timestamped bundles and logs across native and UI runs."""
    bundles = sorted((entry for entry in directory.glob("*.xcresult") if entry.is_dir()),
                     key=lambda entry: (entry.stem.partition("-")[2], entry.name), reverse=True)
    for stale in bundles[keep:]:
        shutil.rmtree(stale, ignore_errors=True)
        stale.with_suffix(".log").unlink(missing_ok=True)
    return bundles[keep:]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ui", action="store_true", help="Run desktop UI tests instead (takes over the desktop).")
    parser.add_argument(
        "--only", action="append", metavar="CLASS[/METHOD]",
        help="Run only this native test class or method (repeatable). Skips the Python script tests.",
    )
    parser.add_argument(
        "--serial", action="store_true",
        help="Run test classes one at a time instead of in parallel (for diagnosing interference).",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Echo the whole xcodebuild stream instead of only failures; the log gets it either way.",
    )
    args = parser.parse_args()
    scheme = "WallpaperMachineUI" if args.ui else "WallpaperMachine"
    target = UI_TARGET if args.ui else NATIVE_TARGET
    if args.ui:
        print(f"{MARK.warn} Desktop automation explicitly enabled: do not use the mouse or keyboard during this run.", flush=True)
    if args.only:
        print(f"{MARK.warn} Targeted run ({', '.join(args.only)}): not a substitute for the full gate.", flush=True)
    else:
        # Every module isolates itself in temporary directories, so they run side by
        # side; the gate waits for the slowest one instead of their sum. unittest
        # reports on stderr; the scripts under test chatter on stdout. Keep both
        # unless something failed, and print one line per module in a fixed order.
        with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            runs = list(pool.map(lambda module: subprocess.run(
                [sys.executable, str(module)], cwd=ROOT, capture_output=True, text=True, errors="replace"),
                SCRIPT_TESTS))
        failed_modules = []
        for module, script_tests in zip(SCRIPT_TESTS, runs):
            if script_tests.returncode != 0 or args.verbose:
                sys.stdout.write(script_tests.stdout)
                sys.stdout.write(script_tests.stderr)
            if script_tests.returncode != 0:
                print(f"{MARK.missing} {module.relative_to(ROOT)} failed", flush=True)
                failed_modules.append(script_tests.returncode)
                continue
            ran = next((line for line in script_tests.stderr.splitlines() if line.startswith("Ran ")), "ran")
            print(f"{MARK.ok} {module.relative_to(ROOT)}: {ran}", flush=True)
        if failed_modules:
            return failed_modules[0]
    if not (shutil.which("xcodegen") and shutil.which("xcodebuild")):
        print(f"{MARK.ok} All unit tests passed. (Skipping Xcode integration tests: xcodegen/xcodebuild not present)")
        return 0
    # `--use-cache` leaves the project untouched when project.yml has not changed,
    # so Xcode's incremental build state survives between runs.
    subprocess.run(["xcodegen", "generate", "--use-cache", "--quiet"], cwd=ROOT, check=True)
    TEST_ARTIFACTS.mkdir(parents=True, exist_ok=True)
    prefix = "UI-" if args.ui else "Tests-"
    result = TEST_ARTIFACTS / (prefix + datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".xcresult")
    # UI tests drive one desktop and cannot share it with a second worker.
    command = xcodebuild_command(scheme, target, result, args.only, parallel=not (args.serial or args.ui))
    env = test_host_environment(os.environ)
    completed, log = run_quiet(command, result.with_suffix(".log"), cwd=ROOT, env=env, verbose=args.verbose)
    failed = None
    if (result / "Info.plist").exists():
        lines, failed = test_summary(result, cwd=ROOT)
        for line in lines:
            print(line, flush=True)
    status = MARK.ok if completed.returncode == 0 and not failed else MARK.missing
    print(f"{status} Test evidence: {result} (log: {log.name})", flush=True)
    prune_result_bundles()
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
