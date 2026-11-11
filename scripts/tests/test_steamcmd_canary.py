#!/usr/bin/env python3
"""Unit tests for scripts/steamcmd_canary.py. Nothing here reaches Valve or runs SteamCMD."""
from __future__ import annotations

import hashlib
import importlib.util
import stat
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("steamcmd_canary", SCRIPTS / "steamcmd_canary.py")
canary = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(canary)


def package(name: str, data: bytes, extra: str = "") -> str:
    sha1 = hashlib.sha1(data).hexdigest()
    sha256 = hashlib.sha256(data).hexdigest()
    return (f'\t"{name}"\n\t{{\n\t\t"file"\t\t"{name}.zip.{sha1}"\n\t\t"size"\t\t"{len(data)}"\n'
            f'\t\t"sha2"\t\t"{sha256}"\n{extra}\t}}\n')


# The shape Valve publishes: the osx block, then its signature blocks at the top level.
MANIFEST = (
    '"osx"\n{\n\t"version"\t\t"1792617903"\n\t"ostype"\t\t"macos1015"\n'
    + package("steamcmd_osx", b"executable", '\t\t"IsBootstrapperPackage"\t\t"1"\n')
    + package("steamcmd_bins_osx", b"libraries", '\t\t"zipvz"\t\t"steamcmd_bins_osx.zip.vz.00_1"\n')
    + '}\n"kvsign2"\n{\n\t"osx"\t\t"53d0"\n}\n"kvsignatures"\n{\n\t"osx"\t\t"1c2d"\n}\n'
)


class ManifestTests(unittest.TestCase):
    def test_reads_valves_manifest_with_its_signature_blocks(self) -> None:
        manifest = canary.parse_manifest(MANIFEST)
        self.assertEqual(manifest.version, "1792617903")
        self.assertEqual(manifest.published.isoformat(), "2026-10-21")
        self.assertEqual([p.name for p in manifest.packages], ["steamcmd_osx", "steamcmd_bins_osx"])
        self.assertEqual(manifest.packages[0].sha1, hashlib.sha1(b"executable").hexdigest())

    def test_refuses_what_the_app_would_refuse(self) -> None:
        broken = {
            "no osx block": MANIFEST.replace('"osx"\n{', '"linux"\n{', 1),
            "escaped string": MANIFEST.replace('"macos1015"', '"mac\\"os"'),
            "missing package": MANIFEST.replace("steamcmd_bins_osx", "steamcmd_other_osx"),
            "renamed file": MANIFEST.replace('"steamcmd_osx.zip.', '"other.zip.', 1),
            "version": MANIFEST.replace('"1792617903"', '"v1"'),
            "unclosed": MANIFEST.rstrip()[:-1],
        }
        for reason, text in broken.items():
            with self.subTest(reason), self.assertRaises(canary.CanaryError):
                canary.parse_manifest(text)

    def test_checksums_and_size_must_match(self) -> None:
        bins = canary.parse_manifest(MANIFEST).packages[1]
        canary.verify(bins, b"libraries")
        for data in (b"librarieS", b"libraries!"):
            with self.subTest(data), self.assertRaises(canary.CanaryError):
                canary.verify(bins, data)


class ExtractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.folder = Path(tempfile.mkdtemp(prefix="steamcmd-canary-test-"))
        self.runtime = self.folder / "runtime"
        self.runtime.mkdir()

    def tearDown(self) -> None:
        import shutil
        shutil.rmtree(self.folder)

    def archive(self, entries: list[tuple[str, bytes, bool]]) -> Path:
        path = self.folder / f"package-{len(list(self.folder.iterdir()))}.zip"
        # A duplicate entry is one of the cases under test; zipfile warns about writing it.
        with warnings.catch_warnings(), zipfile.ZipFile(path, "w") as bundle:
            warnings.simplefilter("ignore")
            for name, data, link in entries:
                info = zipfile.ZipInfo(name)
                if link:
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                bundle.writestr(info, data)
        return path

    def test_backslash_paths_links_and_executables(self) -> None:
        canary.extract(self.archive([
            ("steamcmd", b"\xcf\xfa\xed\xfe rest", False),
            ("public\\steambootstrapper_english.txt", b"text", False),
            ("Frameworks\\Breakpad.framework\\Versions\\A\\Breakpad", b"\xca\xfe\xba\xbe", False),
            ("Frameworks\\Breakpad.framework\\Versions\\Current", b"A", True),
            ("Frameworks\\Breakpad.framework\\Breakpad", b"Versions/Current/Breakpad", True),
        ]), self.runtime)
        self.assertEqual((self.runtime / "public/steambootstrapper_english.txt").read_bytes(), b"text")
        self.assertEqual(stat.S_IMODE((self.runtime / "steamcmd").stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((self.runtime / "public/steambootstrapper_english.txt").stat().st_mode), 0o644)
        framework = self.runtime / "Frameworks/Breakpad.framework"
        self.assertTrue((framework / "Breakpad").is_symlink())
        self.assertEqual((framework / "Breakpad").read_bytes(), b"\xca\xfe\xba\xbe")

    def test_nothing_lands_outside_the_folder_or_twice(self) -> None:
        unsafe = {
            "parent": [("..\\escape", b"x", False)],
            "absolute": [("/tmp/escape", b"x", False)],
            "absolute link": [("link", b"/etc", True)],
            "escaping link": [("Frameworks\\link", b"../../outside", True)],
            "duplicate": [("steamcmd", b"a", False), ("steamcmd", b"b", False)],
        }
        for reason, entries in unsafe.items():
            with self.subTest(reason), self.assertRaises(canary.CanaryError):
                canary.extract(self.archive(entries), self.runtime)
        self.assertFalse((self.folder / "escape").exists())
        self.assertFalse((self.folder / "outside").exists())


class IssueTests(unittest.TestCase):
    manifest = canary.parse_manifest(MANIFEST)

    def test_a_new_version_opens_one_issue_and_a_known_one_none(self) -> None:
        actions = canary.issue_actions(self.manifest, True, "Waiting for user info...OK", {})
        self.assertEqual([(a.title, a.number) for a in actions], [("SteamCMD 1792617903 released 2026-10-21", None)])
        self.assertIn("signs in anonymously", actions[0].body)
        known = {"SteamCMD 1792617903 released 2026-10-21": (7, "CLOSED")}
        self.assertEqual(canary.issue_actions(self.manifest, True, "", known), [])

    def test_a_failed_sign_in_comments_on_an_open_report_or_opens_one(self) -> None:
        known = {"SteamCMD 1792617903 released 2026-10-21": (7, "OPEN")}
        opened = canary.issue_actions(self.manifest, False, "FAILED (Timeout)", known)
        self.assertEqual([(a.title, a.number) for a in opened], [(canary.FAILING_TITLE, None)])
        self.assertIn("FAILED (Timeout)", opened[0].body)
        known[canary.FAILING_TITLE] = (9, "OPEN")
        commented = canary.issue_actions(self.manifest, False, "FAILED (Timeout)", known)
        self.assertEqual([(a.title, a.number) for a in commented], [(canary.FAILING_TITLE, 9)])
        known[canary.FAILING_TITLE] = (9, "CLOSED")
        reopened = canary.issue_actions(self.manifest, False, "", known)
        self.assertEqual([(a.title, a.number) for a in reopened], [(canary.FAILING_TITLE, None)])

    def test_an_open_issue_wins_over_a_closed_one_with_the_same_title(self) -> None:
        listed = [{"title": canary.FAILING_TITLE, "number": 12, "state": "OPEN"},
                  {"title": canary.FAILING_TITLE, "number": 9, "state": "CLOSED"}]
        for order in (listed, list(reversed(listed))):
            titles = canary.titles_from(order)
            actions = canary.issue_actions(self.manifest, False, "", titles)
            self.assertIn((canary.FAILING_TITLE, 12), [(a.title, a.number) for a in actions])

    def test_output_is_cut_to_its_last_lines(self) -> None:
        output = "\r\n".join(f"line {i}" for i in range(100))
        kept = canary.tail(output).splitlines()
        self.assertEqual(len(kept), canary.OUTPUT_LINES)
        self.assertEqual(kept[-1], "line 99")


if __name__ == "__main__":
    unittest.main()
