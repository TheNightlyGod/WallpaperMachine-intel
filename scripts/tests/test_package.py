#!/usr/bin/env python3
"""Unit tests for scripts/package.py: the minimum macOS a packaged bundle can claim and how warnings are shown."""
from __future__ import annotations

import contextlib
import io
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import package  # noqa: E402


class RaisedMinimumTests(unittest.TestCase):
    def test_libraries_at_or_below_the_target_keep_it(self):
        floor, newer = package.raised_minimum("15.0", {"liblz4.1.dylib": "14.0", "libqjs.0.dylib": "15.0"})
        self.assertEqual(floor, "15.0")
        self.assertEqual(newer, {})

    def test_the_newest_library_sets_the_floor(self):
        floor, newer = package.raised_minimum("15.0", {"libqjs.0.dylib": "26.0", "libavcodec.62.dylib": "27.0", "liblz4.1.dylib": "14.0"})
        self.assertEqual(floor, "27.0")
        self.assertEqual(newer, {"libqjs.0.dylib": "26.0", "libavcodec.62.dylib": "27.0"})

    def test_versions_compare_numerically(self):
        floor, newer = package.raised_minimum("15.0", {"libvulkan.1.dylib": "15.10"})
        self.assertEqual(floor, "15.10")
        self.assertEqual(list(newer), ["libvulkan.1.dylib"])


class ReportTests(unittest.TestCase):
    def test_a_warning_seen_by_both_the_bundle_and_the_image_check_prints_once(self):
        reported = set()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            package.report(["extension adds get-task-allow"], reported)
            package.report(["extension adds get-task-allow", "image adds another key"], reported)
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].endswith("extension adds get-task-allow"))
        self.assertTrue(lines[1].endswith("image adds another key"))


if __name__ == "__main__":
    unittest.main()
