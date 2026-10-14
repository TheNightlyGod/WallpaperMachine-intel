#!/usr/bin/env python3
"""Unit tests for scripts/lib/dmg.py: the Finder layout records and a real image round trip."""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from lib import bundle_contract, dmg  # noqa: E402

VERSION = "1.2.3"
ALIAS_FIXED = ">h28pI2shI64pII4s4shhI2s10s"
ALIAS_TAG_POSIX_PATH = 18


def read_ds_store(data):
    """`(filename, code, type, value)` of every record, in stored order: the file is read
    the way Finder reads it, header -> root block -> DSDB superblock -> leaf."""
    root, = struct.unpack_from(">I", data, 8)
    count, = struct.unpack_from(">I", data, 4 + root)
    offsets = struct.unpack_from(f">{count}I", data, 4 + root + 8)
    toc = 4 + root + 8 + 4 * (-(-count // 256) * 256)
    length = data[toc + 4]
    assert data[toc + 5:toc + 5 + length] == b"DSDB"
    superblock, = struct.unpack_from(">I", data, toc + 5 + length)
    leaf_block = struct.unpack_from(">I", data, 4 + (offsets[superblock] & ~0x1F))[0]
    position = 4 + (offsets[leaf_block] & ~0x1F)
    pointer, entries = struct.unpack_from(">II", data, position)
    assert pointer == 0, "the tree must be a single leaf"
    position += 8
    records = []
    for _ in range(entries):
        units, = struct.unpack_from(">I", data, position)
        name = data[position + 4:position + 4 + 2 * units].decode("utf-16-be")
        position += 4 + 2 * units
        code, kind = data[position:position + 4], data[position + 4:position + 8]
        position += 8
        if kind == b"blob":
            size, = struct.unpack_from(">I", data, position)
            value = data[position + 4:position + 4 + size]
            position += 4 + size
        elif kind == b"long":
            value, = struct.unpack_from(">I", data, position)
            position += 4
        elif kind == b"type":
            value = data[position:position + 4]
            position += 4
        else:
            raise AssertionError(f"unexpected record type {kind!r}")
        records.append((name, code, kind, value))
    return records


def alias_target(record):
    """`(catalog node ID, POSIX path within the volume)` a version 2 alias points at."""
    cnid, = struct.unpack_from(">I", record, 8 + struct.calcsize(">h28pI2shI64p"))
    position = 8 + struct.calcsize(ALIAS_FIXED)
    while True:
        tag, length = struct.unpack_from(">hh", record, position)
        if tag == -1:
            raise AssertionError("alias carries no POSIX path")
        if tag == ALIAS_TAG_POSIX_PATH:
            return cnid, record[position + 4:position + 4 + length].decode()
        position += 4 + length + (length & 1)


def png(path, width, height):
    rows = b"".join(b"\x00" + b"\xf4\xf6\xfa" * width for _ in range(height))

    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class LayoutRecordTests(unittest.TestCase):
    def test_records_are_stored_in_finders_lookup_order(self):
        records = [
            ("b.txt", b"Iloc", b"blob", dmg.icon_location((1, 2))),
            (".", b"vSrn", b"long", 1),
            ("A.app", b"Iloc", b"blob", dmg.icon_location((3, 4))),
            (".", b"bwsp", b"blob", b"x"),
        ]
        stored = [(name, code) for name, code, _, _ in read_ds_store(dmg.ds_store(records))]
        self.assertEqual(stored, [(".", b"bwsp"), (".", b"vSrn"), ("A.app", b"Iloc"), ("b.txt", b"Iloc")])

    def test_records_that_outgrow_one_page_are_refused(self):
        with self.assertRaises(dmg.DiskImageError):
            dmg.ds_store([(".", b"bwsp", b"blob", bytes(dmg.PAGE_SIZE))])


# Finder reads these formats and no test can run Finder, so the writers are held to the
# bytes of the implementation Finder is known to accept: ds_store 1.3.3 and mac_alias
# 2.2.3, which dmgbuild 1.6.7 uses. Each constant below is those packages' output for
# the inputs next to it, zlib-compressed and base64-encoded. They were produced once in
# a throwaway virtualenv; regenerate them the same way if an input changes, never by hand.
VOLUME, MOUNT = "WallpaperMachine 1.2.3", "/Volumes/WallpaperMachine 1.2.3"
MAC_EPOCH = datetime(1904, 1, 1, tzinfo=timezone.utc)
VOLUME_DATE = (datetime(2026, 9, 26, 8, 0, 0, 250000, tzinfo=timezone.utc) - MAC_EPOCH).total_seconds()
CREATION_DATE = (datetime(2026, 9, 26, 8, 0, 1, 500000, tzinfo=timezone.utc) - MAC_EPOCH).total_seconds()
# mac_alias Alias(volume=VolumeInfo(VOLUME, <volume date>, b"H+", fixed disk), target=TargetInfo(file,
# ".background.tiff", folder CNID 2, CNID 18, <creation date>)) with the folder name, POSIX paths and
# carbon path Alias.for_file derives.
ROOT_ALIAS = """
eNqVkD8TwUAQxX9RqQhm0jIaBXMZdCqlRkt9+SeZRJIJ6dW+o9bXYBNUofB2bu7tzdu9twtgXGmBtddJkuvcL7ba
DaPUH83VQi2pcL/N2Exr2jKVo934UGRl6qlzFAT8jb70Mz7JQ/BF88uOSfvlZw29Nzcu4ovJ94pV02+HsfRROGhc
Yg4UZJSkePJ6JiKQ6Aq32IsmkcjlzvFFua2rQlGlko+Yi24hZ0mfnt38bcDQ3mVJefRP9o+hqg08AZuWUnw=
"""
# The same for "Resources/Art/background.tiff": folder CNID 21, CNID 22, CNID path [21, 20].
NESTED_ALIAS = """
eNqVkDFTwkAQhb9oY2VEJaWml0kGmLFIpR0NjYXUR7hAhphkjqT3h/jXbPkb+gJiwWDh7uzc27m3+94sgPfBGQQz
UxS1qa2bmnSVlzYcRqNoTBfbzwGThx3s+3OTrpeuastF1ORZxv8j0D7v0HwpTnDOn10DV1zs1Z+g94O9d1nuMH3V
rbw/nraevNhN1brUbhK0LeHY+SUhPnMMKWuWOCpaShZENORkSl84YCZOoaz11lgxp7uplVil+pCheCPVmGvu4l/l
WMLxse4N9/FrVbRv+v/j6t1NvgHz1VZy
"""
# ds_store DSStore.open(path, "w+") after inserting each of `golden_records()` as a DSStoreEntry.
DS_STORE = """
eNrtmctu00AUhs+4SbFEC06pKlhhgWgXVM6lIQsWKI26oIuKRRBBAlFsx0msuraVqyCKlB1Sn4fHABawYIXEitcI
x/Yk6S1C7ED9P2vyj0+OZ/4ZW3J0QkSi0qvniVSaN22FPz4Q6dcpQZG6zE3w9wQAAACA/56lRNToff+A3/ur2BIA
rhwitVfdqyQ/8hcncStLHScqZFyRmjqVq53ql6WOExUyrkhNSVWlalJ1qWWp40SlSaFMzUtVpcqZhS61jBsMAAAA
AAAAAAAAAK4syX/7hjXohJYXWHzWtELP7XRzua9CWUq9qraCQdWtO5bZfl1z/XowqAQ9v95RD7Xbw2GxkNvWC6Xc
aFsflkrcLxZzo5G6emdzKxl/Wq6j9LmJk3qj4dp9r/sudFzb788i0oqSnlr5FllJLx9q65ZpHzXbkYP9Y7Pp7Hqu
2XkzDz7noV66duBX3ffOs4w4iT2cRLXGjZrpeaEZOu0D0265vqPnjYKxE5v59WObnj6Mu4pmzIczum6j8febusbj
zWqpE+aSnEV2tKgOGvkpE2VkX4yjIuvW5Vc8vuj3Bt3jcQyyyCSbjqhJbQqoRz7VOdollxp83OT+BtU4x+MjZA3J
4cyD+KoWZ/l8rlOe8wrcdmiNMtmLs92iu9kXgdc7djrZBYuKdkBT7pffysWrPPkmPaIn4pP4koSU6YZdO7tP4nvy
WPSrbd8L/CYldecV2mW7IRt32awZLypgw519L7Dlk6xx6k/Wz5PJ7Cas/3HBRhwPz45DH8+NAwAAAAAAAAAAAAAA
AAAAAAAA/wy/AeVPvGc=
"""


def expected(encoded):
    return zlib.decompress(base64.b64decode("".join(encoded.split())))


def golden_records():
    return [
        ("WallpaperMachine.app", b"Iloc", b"blob", dmg.icon_location((180, 205))),
        (".", b"vSrn", b"long", 1),
        ("Applications", b"Iloc", b"blob", dmg.icon_location((480, 205))),
        (".", b"icvl", b"type", b"icnv"),
        (".", b"bwsp", b"blob", plistlib.dumps({"ShowSidebar": False, "WindowBounds": "{{420, 260}, {660, 440}}"},
                                              fmt=plistlib.FMT_BINARY)),
        (".", b"icvp", b"blob", plistlib.dumps({"backgroundType": 2, "backgroundImageAlias": expected(ROOT_ALIAS),
                                               "iconSize": 128.0}, fmt=plistlib.FMT_BINARY)),
    ]


class ReferenceBytesTests(unittest.TestCase):
    def test_the_ds_store_is_the_reference_writers_byte_for_byte(self):
        self.assertEqual(dmg.ds_store(golden_records()), expected(DS_STORE))

    def test_an_alias_at_the_volume_root_is_the_reference_writers_byte_for_byte(self):
        self.assertEqual(dmg.encode_alias(VOLUME, VOLUME_DATE, MOUNT, 2, 18, CREATION_DATE, ".background.tiff"),
                         expected(ROOT_ALIAS))

    def test_an_alias_in_a_folder_is_the_reference_writers_byte_for_byte(self):
        self.assertEqual(dmg.encode_alias(VOLUME, VOLUME_DATE, MOUNT, 21, 22, CREATION_DATE,
                                          "Resources/Art/background.tiff", [21, 20]),
                         expected(NESTED_ALIAS))


class BuildInputTests(unittest.TestCase):
    def test_a_background_without_its_retina_twin_is_refused_before_any_work(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            png(root / "background.png", 4, 3)
            (root / "WallpaperMachine.app").mkdir()
            with self.assertRaisesRegex(dmg.DiskImageError, "background@2x.png"):
                dmg.build(root / "WallpaperMachine.app", root / "out.dmg", "Test", background=root / "background.png")
            self.assertFalse((root / "out.dmg").exists())

    def test_a_retina_twin_of_the_wrong_size_is_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            png(root / "background.png", 4, 3)
            png(root / "background@2x.png", 8, 5)
            with self.assertRaisesRegex(dmg.DiskImageError, "not twice"):
                dmg.check_inputs(background=root / "background.png")


@unittest.skipUnless(sys.platform == "darwin", "disk images need hdiutil")
class DiskImageRoundTripTests(unittest.TestCase):
    """Build an image of a small signed bundle, then open it the way a user's Mac does."""

    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        root = Path(cls.scratch.name)
        app = root / "input" / dmg.APPLICATION
        (app / "Contents/MacOS").mkdir(parents=True)
        with open(app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": dmg.BUNDLE_IDENTIFIER, "CFBundleExecutable": "WallpaperMachine",
                           "CFBundlePackageType": "APPL", "CFBundleShortVersionString": VERSION}, handle)
        executable = app / "Contents/MacOS/WallpaperMachine"
        shutil.copyfile("/usr/bin/true", executable)  # system files carry flags a copy may not keep
        executable.chmod(0o755)
        subprocess.run(["codesign", "--force", "--sign", "-", app], check=True, capture_output=True)
        # What a synced checkout's File Provider adds to the signed bundle in build/; the
        # copy in the image must shed it or `codesign --strict` fails there.
        subprocess.run(["xattr", "-wx", "com.apple.FinderInfo", (bytes(8) + b"\x04\x00" + bytes(22)).hex(), app],
                       check=True, capture_output=True)
        png(root / "background.png", 66, 44)
        png(root / "background@2x.png", 132, 88)
        shutil.copyfile("/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns",
                     root / "volume.icns")
        cls.image = dmg.build(app, root / dmg.image_name(VERSION), dmg.volume_name(VERSION),
                              icon=root / "volume.icns", background=root / "background.png")

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def mounted(self):
        mount = Path(self.scratch.name) / "volume"
        mount.mkdir(exist_ok=True)
        subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, self.image],
                       check=True, capture_output=True)
        self.addCleanup(subprocess.run, ["hdiutil", "detach", "-force", mount], capture_output=True)
        return mount

    @staticmethod
    def accept(app):
        """A contract that passes: the test bundle is a bare executable, not the real app."""
        return []

    def test_the_image_verifies_for_its_version_only(self):
        dmg.verify(self.image, VERSION, contract=self.accept)
        with self.assertRaisesRegex(dmg.DiskImageError, "not 9.9.9"):
            dmg.verify(self.image, "9.9.9", contract=self.accept)

    def test_the_contract_runs_on_the_app_inside_the_mounted_image(self):
        seen = []

        def contract(app):
            app = Path(app)
            seen.append((app.name, app.parent != Path(self.scratch.name) / "input", os.path.ismount(app.parent),
                         (app / "Contents/Info.plist").is_file()))
            return ["the signature adds an entitlement"]

        self.assertEqual(dmg.verify(self.image, VERSION, contract=contract), ["the signature adds an entitlement"])
        self.assertEqual(seen, [(dmg.APPLICATION, True, True, True)])

    def test_a_contract_failure_in_the_image_fails_verification_and_detaches_it(self):
        def contract(app):
            raise bundle_contract.BundleContractError("the extension lost its sandbox")

        with self.assertRaisesRegex(dmg.DiskImageError, f"{dmg.image_name(VERSION)}: the extension lost its sandbox"):
            dmg.verify(self.image, VERSION, contract=contract)
        self.assertNotIn(str(self.image), self.attached_images())

    def test_by_default_the_image_must_satisfy_the_real_bundle_contract(self):
        with self.assertRaisesRegex(dmg.DiskImageError, "embeds no extension"):
            dmg.verify(self.image, VERSION)

    @staticmethod
    def attached_images():
        listing = plistlib.loads(subprocess.run(["hdiutil", "info", "-plist"], check=True, capture_output=True).stdout)
        return [entry.get("image-path") for entry in listing.get("images", [])]

    def test_verification_leaves_nothing_attached(self):
        dmg.verify(self.image, VERSION, contract=self.accept)
        self.assertNotIn(str(self.image), self.attached_images())

    def test_the_window_places_the_app_beside_applications_over_the_background(self):
        mount = self.mounted()
        records = {(name, code): value for name, code, _, value in read_ds_store((mount / ".DS_Store").read_bytes())}
        self.assertEqual(struct.unpack(">II", records[(dmg.APPLICATION, b"Iloc")][:8]), dmg.APP_ICON_CENTER)
        self.assertEqual(struct.unpack(">II", records[(dmg.APPLICATIONS_LINK, b"Iloc")][:8]), dmg.APPLICATIONS_ICON_CENTER)
        window = plistlib.loads(records[(".", b"bwsp")])
        self.assertFalse(window["ShowToolbar"] or window["ShowSidebar"] or window["ShowStatusBar"])
        icons = plistlib.loads(records[(".", b"icvp")])
        self.assertEqual(icons["backgroundType"], 2)
        self.assertEqual(alias_target(icons["backgroundImageAlias"]),
                         (os.lstat(mount / ".background.tiff").st_ino, "/.background.tiff"))
        self.assertNotIn((".", b"pBBk"), records)  # macOS 26.2 drops the background when present

    def test_the_volume_carries_its_icon_and_the_applications_link(self):
        mount = self.mounted()
        self.assertEqual(os.readlink(mount / dmg.APPLICATIONS_LINK), "/Applications")
        self.assertTrue((mount / ".VolumeIcon.icns").is_file())
        finder_info = subprocess.run(["xattr", "-px", "com.apple.FinderInfo", mount], check=True,
                                     capture_output=True, text=True).stdout
        self.assertTrue(int("".join(finder_info.split())[16:20], 16) & 0x0400, "kHasCustomIcon")
        self.assertFalse((mount / ".Trashes").exists())


if __name__ == "__main__":
    unittest.main()
