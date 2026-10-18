#!/usr/bin/env python3
"""Unit tests for scripts/lib/xcode.py: the quiet runner's filter and summary."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from lib import xcode  # noqa: E402

PASSING_RUN = """\
Command line invocation:
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project x.xcodeproj test
2026-09-19 18:01:14.073 xcodebuild[51232:5680671] [MT] DVTPlugInExtensionFaulting: Failed to fire fault for extension Xcode.Device.CoreDevice: Error Domain=DVTPlugInErrorDomain Code=2 "Loading a plug-in failed."
2026-09-19 18:01:17.349188+0800 WallpaperMachine[51359:5681081] [Connection] Unable to get synchronousRemoteObjectProxy, error: Error Domain=NSCocoaErrorDomain Code=4097
CompileSwift normal arm64 /repo/App/AppDelegate.swift
/repo/App/AppDelegate.swift:12:5: warning: variable 'x' was never used
Test Case '-[WallpaperMachineTests.AppThemeTests testDamagedSavedColor]' started.
Test Case '-[WallpaperMachineTests.AppThemeTests testDamagedSavedColor]' passed (0.002 seconds).
Test Suite 'AppThemeTests' passed at 2026-09-19 18:01:17.400.
\t Executed 3 tests, with 0 failures (0 unexpected) in 0.006 (0.007) seconds
** TEST SUCCEEDED **
"""

FAILING_RUN = """\
Test Case '-[WallpaperMachineTests.DownloaderTests testFoo]' started.
/repo/Tests/Unit/Workshop/DownloaderTests.swift:120: error: -[WallpaperMachineTests.DownloaderTests testFoo] : XCTAssertEqual failed: ("1") is not equal to ("2")
Test Case '-[WallpaperMachineTests.DownloaderTests testFoo]' failed (0.100 seconds).
\t Executed 2 tests, with 1 failure (0 unexpected) in 0.2 (0.3) seconds
Testing failed:
\tDownloaderTests.testFoo(): XCTAssertEqual failed: ("1") is not equal to ("2")
\tTesting cancelled because the build failed.
** TEST FAILED **
"""

BROKEN_BUILD = """\
CompileSwift normal arm64 /repo/App/Foo.swift
/repo/App/Foo.swift:7:9: error: cannot find 'bar' in scope
/repo/App/Foo.swift:7:9: error: cannot find 'bar' in scope
The following build commands failed:
\tSwiftCompile normal arm64 /repo/App/Foo.swift (in target 'WallpaperMachine' from project 'x')
(1 failure)
** BUILD FAILED **
"""


class FilterLines(unittest.TestCase):
    def filtered(self, text):
        return list(xcode.filter_lines(text.splitlines(keepends=True)))

    def test_passing_run_is_silent(self):
        self.assertEqual(self.filtered(PASSING_RUN), [])

    def test_failing_test_shows_assertion_and_verdict_once(self):
        lines = self.filtered(FAILING_RUN)
        self.assertIn("/repo/Tests/Unit/Workshop/DownloaderTests.swift:120: error: -[WallpaperMachineTests.DownloaderTests testFoo] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")", lines)
        self.assertIn("Test Case '-[WallpaperMachineTests.DownloaderTests testFoo]' failed (0.100 seconds).", lines)
        self.assertIn("** TEST FAILED **", lines)
        self.assertIn("\t Executed 2 tests, with 1 failure (0 unexpected) in 0.2 (0.3) seconds", lines)
        self.assertNotIn("Test Case '-[WallpaperMachineTests.DownloaderTests testFoo]' started.", lines)

    def test_failure_block_body_is_kept_and_duplicates_dropped(self):
        lines = self.filtered(BROKEN_BUILD)
        self.assertEqual(lines.count("/repo/App/Foo.swift:7:9: error: cannot find 'bar' in scope"), 1)
        self.assertIn("The following build commands failed:", lines)
        self.assertIn("\tSwiftCompile normal arm64 /repo/App/Foo.swift (in target 'WallpaperMachine' from project 'x')", lines)
        self.assertIn("(1 failure)", lines)
        self.assertIn("** BUILD FAILED **", lines)
        self.assertNotIn("CompileSwift normal arm64 /repo/App/Foo.swift", lines)

    def test_cargo_errors_are_kept(self):
        lines = self.filtered("   Compiling foo v0.1.0\nerror[E0425]: cannot find value `x`\n --> src/lib.rs:3:5\nerror: could not compile `foo`\n")
        self.assertEqual(lines, ["error[E0425]: cannot find value `x`", "error: could not compile `foo`"])

    def test_output_is_capped(self):
        text = "".join(f"/repo/F.swift:{index}:1: error: e{index}\n" for index in range(50))
        lines = list(xcode.filter_lines(text.splitlines(keepends=True), limit=20))
        self.assertEqual(len(lines), 21)
        self.assertTrue(lines[-1].startswith("..."))


class RunQuiet(unittest.TestCase):
    def test_echo_limit_still_drains_the_child_and_preserves_its_exit_and_side_effect(self):
        script = """import pathlib, sys
for index in range(1000):
    print(f'/a/B.swift:{index}:1: error: problem {index}', flush=True)
pathlib.Path(sys.argv[1]).write_text('finished')
print('final marker', flush=True)
sys.exit(7)
"""
        echoed = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            completed, log = xcode.run_quiet(
                [sys.executable, "-c", script, str(root / "done")], root / "run.log", echo=echoed.append)
            self.assertEqual(completed.returncode, 7)
            self.assertEqual((root / "done").read_text(), "finished")
            output = log.read_text()
        self.assertIn("problem 999", output)
        self.assertIn("final marker\n", output)
        self.assertEqual(len(echoed), xcode.MAX_ECHOED_LINES + 1)
        self.assertEqual(sum(line.startswith("...") for line in echoed), 1)

    def test_logs_everything_and_echoes_only_failures(self):
        script = "import sys; print('noise'); print('/a/B.swift:1:2: error: boom'); print('x warning: y'); sys.exit(3)"
        echoed = []
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "nested" / "run.log"
            completed, path = xcode.run_quiet([sys.executable, "-c", script], log, echo=echoed.append)
            self.assertEqual(completed.returncode, 3)
            self.assertEqual(path, log)
            text = log.read_text()
        self.assertIn("noise", text)
        self.assertIn("boom", text)
        self.assertEqual(echoed, ["/a/B.swift:1:2: error: boom", "  1 warning line(s) in the log"])


class Summarize(unittest.TestCase):
    def test_passing_summary_is_one_line(self):
        lines, failed = xcode.summarize({
            "passedTests": 491, "failedTests": 0, "skippedTests": 9, "totalTestCount": 500,
            "result": "Passed", "startTime": 100.0, "finishTime": 252.4, "testFailures": [], "runtimeWarnings": [],
        })
        self.assertEqual(lines, ["Passed: 491 passed, 0 failed, 9 skipped of 500 in 152s"])
        self.assertEqual(failed, 0)

    def test_failures_get_one_line_each(self):
        lines, failed = xcode.summarize({
            "passedTests": 1, "failedTests": 1, "skippedTests": 0, "totalTestCount": 2, "result": "Failed",
            "testFailures": [{"testIdentifier": "DownloaderTests/testFoo()", "failureText": "XCTAssertEqual failed:\n  (\"1\") is not equal to (\"2\")", "targetName": "T"}],
        })
        self.assertEqual(lines[0], "Failed: 1 passed, 1 failed, 0 skipped of 2")
        self.assertEqual(lines[1], "  FAIL DownloaderTests/testFoo(): XCTAssertEqual failed: (\"1\") is not equal to (\"2\")")
        self.assertEqual(failed, 1)

    def test_a_numbered_failure_is_still_named(self):
        lines, _ = xcode.summarize({
            "passedTests": 6, "failedTests": 1, "skippedTests": 0, "totalTestCount": 7, "result": "Failed",
            "testFailures": [{
                "testIdentifier": 3, "testName": "testBar()", "targetName": "T",
                "testIdentifierString": "PanelTests/testBar()",
                "failureText": "Test exceeded execution time allowance of 2 minutes",
            }],
        })
        self.assertEqual(lines[1], "  FAIL PanelTests/testBar(): Test exceeded execution time allowance of 2 minutes")


if __name__ == "__main__":
    unittest.main()
