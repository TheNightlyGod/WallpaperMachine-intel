#!/usr/bin/env python3
"""Exercise the vendored stream state with synthetic notifications and held replies."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "ThirdParty/mediaremote-adapter"


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "Objective-C fixture requires the macOS SDK")
class MediaRemoteStreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.binary = Path(cls.temporary.name) / "stream-test"
        command = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Werror",
                   "-I", str(ADAPTER / "src"), "-I", str(ADAPTER / "include"),
                   str(Path(__file__).parent / "fixtures/mediaremote_stream_test.m"),
                   str(ADAPTER / "src/adapter/keys.m"), str(ADAPTER / "src/utility/Debounce.m"),
                   "-framework", "Foundation", "-framework", "AppKit", "-o", str(cls.binary)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def check_stream(self, *arguments):
        result = subprocess.run([str(self.binary), *arguments], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["failures"], 0)
        self.assertGreater(report["payloads"], 0)
        self.assertFalse(report["real_media_access"])

    def test_playing_notification_supplies_pid_and_late_metadata_is_ignored(self):
        self.check_stream()

    def test_late_application_lookup_cannot_restore_the_previous_player(self):
        self.check_stream("application-race")

    def test_same_player_notification_refreshes_metadata_after_superseding_old_requests(self):
        self.check_stream("same-player")

    def test_empty_playback_notification_preserves_startup_and_track_lookups(self):
        self.check_stream("missing-playback")


if __name__ == "__main__":
    unittest.main()
