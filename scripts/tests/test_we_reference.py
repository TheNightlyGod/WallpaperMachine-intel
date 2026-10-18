#!/usr/bin/env python3
"""Unit tests for the capture queue, scene clock and image handling in scripts/we_reference.py."""
from __future__ import annotations

from http.server import ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("we_reference", SCRIPTS / "we_reference.py")
we_reference = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(we_reference)


def wallpaper(root: Path, name: str) -> Path:
    folder = root / name
    (folder / "materials").mkdir(parents=True)
    (folder / "project.json").write_text('{"type": "scene"}')
    (folder / "materials/a b.json").write_text("{}")
    (folder / ".DS_Store").write_text("x")
    (folder / "config.toml").write_text("x")
    return folder


class CaptureServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        (root / "secret.txt").write_text("outside")
        self.shots = root / "shots"
        self.run = we_reference.CaptureRun([wallpaper(root, "111"), wallpaper(root, "222")], self.shots, delays=(8, 7))
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), we_reference.handler(self.run, "http://vm-host", root / "log"))
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.temp.cleanup()

    def request(self, path, data=None, method="GET"):
        try:
            with urllib.request.urlopen(urllib.request.Request(self.base + path, data=data, method=method)) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, b""

    def test_the_worker_is_handed_each_wallpaper_once_and_told_when_the_queue_is_empty(self):
        status, script = self.request("/worker.ps1")
        self.assertEqual(status, 200)
        self.assertIn(b"'http://vm-host'", script)
        first = json.loads(self.request("/next")[1])
        self.assertEqual(first["id"], "111")
        self.assertEqual(first["shots"], [8, 7])
        self.assertEqual(first["files"], [{"path": "materials/a b.json", "size": 2}, {"path": "project.json", "size": 17}])
        self.assertEqual(json.loads(self.request("/next")[1])["id"], "222")
        self.assertEqual(json.loads(self.request("/next")[1]), {"done": True})
        self.assertTrue(self.run.drained.is_set())

    def test_only_files_inside_a_queued_wallpaper_are_served(self):
        self.assertEqual(self.request("/file/111/materials/a%20b.json"), (200, b"{}"))
        self.assertEqual(self.request("/file/111/..%2Fsecret.txt")[0], 404)
        self.assertEqual(self.request("/file/111/../secret.txt")[0], 404)
        self.assertEqual(self.request("/file/333/project.json")[0], 404)

    def test_shots_and_screen_geometry_are_recorded_until_every_wallpaper_is_settled(self):
        self.assertEqual(self.request("/shot/111/1?opened=1000&taken=16000", b"png1", "PUT")[0], 200)
        self.assertEqual(self.request("/shot/111/0?opened=1000&taken=9000", b"png0", "PUT")[0], 200)
        self.assertEqual(self.request("/shot/333/0", b"png", "PUT")[0], 403)
        self.assertFalse(self.run.wait(0))
        self.request("/done/111", json.dumps({"screen": [3456, 2024], "work": [0, 0, 3456, 1928]}).encode(), "POST")
        self.request("/fail/222", b"download failed", "POST")
        self.assertTrue(self.run.wait(0))
        self.assertEqual((self.shots / "111-0.png").read_bytes(), b"png0")
        meta = json.loads((self.shots / "111.json").read_text())
        self.assertEqual(we_reference.scene_times(meta), [8.0, 15.0])
        self.assertEqual(meta["work"], [0, 0, 3456, 1928])
        self.assertEqual(self.run.failed, {"222": "download failed"})

    def test_a_worker_without_wallpaper_engine_ends_the_run(self):
        self.request("/abort", b"wallpaper64.exe not found", "POST")
        self.assertTrue(self.run.wait(0))
        self.assertEqual(self.run.aborted, "wallpaper64.exe not found")


class MainCheckoutTests(unittest.TestCase):
    def test_a_worktree_shares_the_frames_of_the_checkout_it_was_made_from(self):
        from lib.paths import main_checkout

        with tempfile.TemporaryDirectory() as directory:
            main, linked = Path(directory, "main").resolve(), Path(directory, "linked").resolve()
            git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", str(main)]
            main.mkdir()
            subprocess.run(git + ["init", "-q"], check=True)
            subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "start"], check=True)
            subprocess.run(git + ["worktree", "add", "-q", "--detach", str(linked)], check=True)
            self.assertEqual(main_checkout(main), main)
            self.assertEqual(main_checkout(linked), main)
            self.assertEqual(main_checkout(Path(directory)), Path(directory))


class SceneClockTests(unittest.TestCase):
    def test_a_capture_without_times_uses_the_workers_shot_delays(self):
        self.assertEqual(we_reference.scene_times({}), [8.0, 15.0])

    def test_the_render_clock_reads_the_time_of_day_wallpaper_engine_opened_the_wallpaper(self):
        now = 1_800_000_000
        saved = os.environ.get("TZ")
        try:
            for gmtoff in (8 * 3600, -5 * 3600, 0):
                for opened in (now, now - 3600 - 17, now - 3 * 86400 + 600):
                    with self.subTest(gmtoff=gmtoff, opened=opened):
                        os.environ["TZ"] = we_reference.reference_tz(opened * 1000, now, gmtoff)
                        time.tzset()
                        expected = time.gmtime(opened + gmtoff)
                        self.assertEqual(time.localtime(now)[3:6], expected[3:6])
        finally:
            if saved is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = saved
            time.tzset()


class ImageTests(unittest.TestCase):
    def test_a_bmp_round_trips_rows_whose_width_needs_padding(self):
        rgb = bytes(range(5 * 3 * 3))
        self.assertEqual(we_reference.read_bmp(we_reference.bmp(5, 3, rgb)), (5, 3, rgb))

    def test_the_work_area_leaves_the_taskbar_out(self):
        width, height = 64, 48
        # Grey wallpaper over the top 36 rows, a red taskbar under it.
        rgb = bytes([90, 90, 90] * width * 36 + [255, 0, 0] * width * 12)
        with tempfile.TemporaryDirectory() as directory:
            raw, png = Path(directory) / "frame.bmp", Path(directory) / "frame.png"
            raw.write_bytes(we_reference.bmp(width, height, rgb))
            subprocess.run(["sips", "-s", "format", "png", str(raw), "--out", str(png)], check=True, capture_output=True)
            area = we_reference.load(png, [width, height], [0, 0, width, 36], 16, 12)
        self.assertEqual(len(area), 16 * 12 * 3)
        # Resampling may blend the taskbar into the last row; every row above it is wallpaper.
        above = area[:16 * 11 * 3]
        self.assertTrue(all(abs(a - b) <= 8 for a, b in zip(above, [90, 90, 90] * 16 * 11)))

    def test_identical_pictures_measure_no_difference(self):
        picture = bytes([10, 200, 30, 40, 50, 60] * 8)
        result = we_reference.metrics(picture, picture)
        self.assertEqual((result["mean_abs"], result["off48"], result["corr"]), (0.0, 0.0, 1.0))


if __name__ == "__main__":
    unittest.main()
