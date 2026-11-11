#!/usr/bin/env python3
"""Unit tests for scripts/package.py: the minimum macOS a packaged bundle can claim, how warnings are shown, and how it signs."""
from __future__ import annotations

import argparse
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import check_licenses  # noqa: E402
import notices  # noqa: E402
import package  # noqa: E402


class RaisedMinimumTests(unittest.TestCase):
    def test_libraries_at_or_below_the_target_keep_it(self):
        floor, newer = package.raised_minimum("15.0", {"liblz4.1.dylib": "14.0", "libqjs.0.dylib": "15.0"})
        self.assertEqual(floor, "15.0")
        self.assertEqual(newer, {})

    def test_the_newest_library_sets_the_floor(self):
        floor, newer = package.raised_minimum("15.0", {"libqjs.0.dylib": "26.0", "libfreetype.6.dylib": "27.0", "liblz4.1.dylib": "14.0"})
        self.assertEqual(floor, "27.0")
        self.assertEqual(newer, {"libqjs.0.dylib": "26.0", "libfreetype.6.dylib": "27.0"})

    def test_versions_compare_numerically(self):
        floor, newer = package.raised_minimum("15.0", {"libfreetype.6.dylib": "15.10"})
        self.assertEqual(floor, "15.10")
        self.assertEqual(list(newer), ["libfreetype.6.dylib"])


def otool_listing(file, *loads):
    """`otool -L` output: the header line, then one load command per line."""
    return "\n".join([f"{file}:", *(f"\t{load}" for load in loads)]) + "\n"


class SystemLibraryTests(unittest.TestCase):
    """Which system libraries the bundle may load unconditionally on its oldest macOS."""

    prefix = Path("/opt/homebrew")
    app = Path("/build/WallpaperMachine.app/Contents/MacOS/WallpaperMachine")
    library = prefix / "opt/sample/lib/libsample.6.dylib"

    def unavailable(self, listings):
        with mock.patch.object(package, "output", lambda args: listings[Path(args[-1])]):
            return package.unavailable_system_libraries([self.app], [self.library], self.prefix)

    def test_a_bundled_library_that_loads_a_newer_system_library_stops_packaging(self):
        listings = {
            self.app: otool_listing(self.app, f"{self.library} (compatibility version 27.0.0, current version 27.7.0)"),
            self.library: otool_listing(
                self.library,
                f"{self.library} (compatibility version 27.0.0, current version 27.7.0)",
                "/usr/lib/libz.1.dylib (compatibility version 1.0.0, current version 1.2.12)",
                "/usr/lib/libhvf.dylib (compatibility version 0.0.0, current version 0.0.0)",
                "/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)"),
        }
        self.assertEqual(self.unavailable(listings), ["libsample.6.dylib: /usr/lib/libhvf.dylib"])

    def test_a_weak_load_may_name_a_library_the_oldest_macos_lacks(self):
        listings = {
            self.app: otool_listing(self.app),
            self.library: otool_listing(
                self.library, "/usr/lib/libhvf.dylib (compatibility version 0.0.0, current version 0.0.0, weak)"),
        }
        self.assertEqual(self.unavailable(listings), [])

    def test_only_the_apps_own_executables_may_load_frameworks_and_the_swift_runtime(self):
        frameworks = ["/System/Library/Frameworks/Metal.framework/Versions/A/Metal (compatibility version 1.0.0, current version 370.64.2)",
                      "/usr/lib/swift/libswiftCore.dylib (compatibility version 1.0.0, current version 6.2.0)",
                      "@rpath/libsample.6.dylib (compatibility version 27.0.0, current version 27.7.0)"]
        listings = {self.app: otool_listing(self.app, *frameworks), self.library: otool_listing(self.library, *frameworks)}
        self.assertEqual(self.unavailable(listings), [
            "libsample.6.dylib: /System/Library/Frameworks/Metal.framework/Versions/A/Metal",
            "libsample.6.dylib: /usr/lib/swift/libswiftCore.dylib",
        ])

    def test_the_app_may_not_load_an_unlisted_library_from_usr_lib_either(self):
        listings = {
            self.app: otool_listing(self.app, "/usr/lib/libhvf.dylib (compatibility version 0.0.0, current version 0.0.0)"),
            self.library: otool_listing(self.library),
        }
        self.assertEqual(self.unavailable(listings), ["WallpaperMachine: /usr/lib/libhvf.dylib"])


class ResolveLibrariesTests(unittest.TestCase):
    """The Homebrew closure the app bundles, read from fake load commands."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        root = Path(self.scratch.name).resolve()
        self.prefix = root / "homebrew"
        self.app = root / "build/WallpaperMachine.app/Contents/MacOS/WallpaperMachine"
        self.freetype = self.prefix / "opt/freetype/lib/libfreetype.6.dylib"
        self.decoder = self.prefix / "opt/brotli/lib/libbrotlidec.1.dylib"
        self.common = self.prefix / "opt/brotli/lib/libbrotlicommon.1.dylib"
        for file in (self.app, self.freetype, self.decoder, self.common):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"")
        self.loads = {
            self.app: [str(self.freetype), "@rpath/libswiftCore.dylib"],
            self.freetype: [str(self.decoder)],
            # brotli's decoder loads its sibling through @rpath and its own @loader_path rpath.
            self.decoder: ["@rpath/libbrotlicommon.1.dylib"],
            self.common: [],
        }
        self.rpaths = {self.decoder: ["@loader_path/../lib"]}

    def tearDown(self):
        self.scratch.cleanup()

    def resolve(self):
        with mock.patch.object(package, "dependencies", lambda file: self.loads[Path(file).resolve()]), \
             mock.patch.object(package, "rpaths", lambda file: self.rpaths.get(Path(file).resolve(), [])):
            return package.resolve_libraries([self.app], [], self.prefix)

    def test_a_keg_library_loaded_through_its_own_rpath_is_bundled(self):
        libraries = self.resolve()
        self.assertEqual(sorted(libraries), ["libbrotlicommon.1.dylib", "libbrotlidec.1.dylib", "libfreetype.6.dylib"])
        self.assertEqual(libraries["libbrotlicommon.1.dylib"], self.common.resolve())

    def test_an_app_already_relocated_by_an_earlier_run_is_refused(self):
        self.loads[self.app] = ["@rpath/libfreetype.6.dylib"]
        with self.assertRaisesRegex(package.PackagingError, "fresh, unrelocated"):
            self.resolve()

    def test_an_rpath_that_leaves_the_homebrew_prefix_is_not_followed(self):
        outside = Path(self.scratch.name).resolve() / "elsewhere/lib"
        outside.mkdir(parents=True)
        (outside / "libbrotlicommon.1.dylib").write_bytes(b"")
        self.rpaths[self.decoder] = [str(outside)]
        with self.assertRaisesRegex(package.PackagingError, "libbrotlicommon"):
            self.resolve()


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


def noticeset(*, missing=()):
    found = [notices.Notice("cfg-if", "1.0.4", "MIT", ("MIT",), "cargo registry", (("LICENSE-MIT", "MIT text"),))]
    absent = [notices.Notice(name, "1.0.0", "MIT", ("MIT",), "cargo registry", (), ("MIT",)) for name in missing]
    result = notices.NoticeSet(found + absent)
    result.text = "THIRD-PARTY NOTICES\n"
    return result


class ThirdPartyNoticesTests(unittest.TestCase):
    def generate(self, require=False, **patch):
        patch = patch or {"return_value": noticeset()}
        with mock.patch.object(notices, "generate", **patch) as generate, \
                mock.patch.object(check_licenses, "cargo_environment", return_value={}), \
                contextlib.redirect_stdout(io.StringIO()) as stdout:
            text = package.third_party_notices(Path("/nonexistent/WallpaperMachine.app"), require)
        return text, stdout.getvalue(), generate

    def test_the_generated_text_is_returned_for_the_bundle(self):
        text, stdout, generate = self.generate()
        self.assertEqual(text, "THIRD-PARTY NOTICES\n")
        self.assertIn("1 components, 1 with license text, 0 without", stdout)
        self.assertEqual(generate.call_args.args[0].app, Path("/nonexistent/WallpaperMachine.app"))

    def test_a_tool_failure_stops_packaging(self):
        with self.assertRaisesRegex(package.PackagingError, "could not be generated: cargo tree failed"):
            self.generate(side_effect=check_licenses.ToolError("cargo tree failed"))

    def test_an_empty_closure_stops_packaging(self):
        with self.assertRaisesRegex(package.PackagingError, "closure is empty"):
            self.generate(return_value=notices.NoticeSet([]))

    def test_a_missing_license_text_is_named_and_does_not_stop_packaging_by_default(self):
        text, stdout, _ = self.generate(return_value=noticeset(missing=["objc2", "uniffi"]))
        self.assertEqual(text, "THIRD-PARTY NOTICES\n")
        self.assertIn("LICENSE TEXT NOT FOUND for 2 of 3 components: objc2 1.0.0, uniffi 1.0.0", stdout)

    def test_a_missing_license_text_stops_packaging_when_required(self):
        with self.assertRaisesRegex(package.PackagingError, "LICENSE TEXT NOT FOUND for 1 of 2 components: objc2 1.0.0"):
            self.generate(True, return_value=noticeset(missing=["objc2"]))


class WriteLicensesTests(unittest.TestCase):
    def test_the_notices_file_lands_in_resources_and_replaces_an_older_one(self):
        with tempfile.TemporaryDirectory() as directory:
            resources = Path(directory)
            (resources / "THIRD-PARTY-NOTICES.txt").write_text("old")
            package.write_licenses(resources, {}, "new notices\n")
            self.assertEqual((resources / "THIRD-PARTY-NOTICES.txt").read_text(), "new notices\n")
            self.assertTrue((resources / "LICENSING.md").is_file())


# What `security find-identity -v -p codesigning` prints: valid identities only, so an
# untrusted self-signed certificate is not among them.
IDENTITIES = """  1) B3AD765B2043BDF58E95C0C7376B4B6505BB8EDA "Apple Development: someone@example.com (C5762C9UB8)"
  2) A26B5696707B23C51F8EB8501A941787F8F9A7CB "Developer ID Application: Example Maintainer (ABCDE12345)"
     2 valid identities found
"""
# After a renewal: the old certificate and the new one share their name.
RENEWED = """  1) A26B5696707B23C51F8EB8501A941787F8F9A7CB "Developer ID Application: Example Maintainer (ABCDE12345)"
  2) 0F1E2D3C4B5A69788796A5B4C3D2E1F00F1E2D3C "Developer ID Application: Example Maintainer (ABCDE12345)"
     2 valid identities found
"""


class SigningTests(unittest.TestCase):
    def signing(self, identity, listing=IDENTITIES):
        return package.signing_for(identity, listing)

    def test_a_developer_id_is_signed_for_notarization(self):
        for identity in ("Developer ID Application", "Developer ID Application: Example Maintainer (ABCDE12345)",
                         "a26b5696707b23c51f8eb8501a941787f8f9a7cb"):
            signing = self.signing(identity)
            self.assertTrue(signing.developer_id, identity)
            self.assertEqual(signing.options(), ["--timestamp", "--options", "runtime"])

    def test_an_identity_that_is_not_listed_runs_without_the_hardened_runtime(self):
        signing = self.signing("WallpaperMachine Code Signing")
        self.assertFalse(signing.developer_id)
        self.assertNotIn("runtime", signing.options())

    def test_an_identity_matching_several_certificates_stops_packaging_and_lists_them(self):
        with self.assertRaises(package.PackagingError) as raised:
            self.signing("Developer ID Application", RENEWED)
        self.assertIn("A26B5696707B23C51F8EB8501A941787F8F9A7CB", str(raised.exception))
        self.assertIn("0F1E2D3C4B5A69788796A5B4C3D2E1F00F1E2D3C", str(raised.exception))
        with self.assertRaises(package.PackagingError):
            self.signing("(")

    def test_a_sha1_picks_one_of_two_certificates_with_the_same_name(self):
        self.assertTrue(self.signing("0F1E2D3C4B5A69788796A5B4C3D2E1F00F1E2D3C", RENEWED).developer_id)

    def test_an_unknown_identity_is_not_a_developer_id(self):
        self.assertFalse(self.signing("Developer ID Installer").developer_id)

    def test_ad_hoc_needs_no_keychain(self):
        signing = package.signing_for("-", listing="unreadable")
        self.assertEqual((signing.identity, signing.developer_id), ("-", False))
        self.assertNotIn("runtime", signing.options())

    def test_notarizing_without_a_developer_id_stops_before_the_bundle_is_read(self):
        args = argparse.Namespace(sign_identity="-", notarize="WallpaperMachine Notary", notary_keychain=None,
                                  configuration="Release")
        with mock.patch.object(package, "app_bundle") as app_bundle, \
                self.assertRaisesRegex(package.PackagingError, "Developer ID"):
            package.package(args)
        app_bundle.assert_not_called()


class ImageContractTests(unittest.TestCase):
    def test_a_notarized_image_must_carry_the_ticket_on_its_app(self):
        with mock.patch.object(package.notary, "check_stapled") as stapled, \
                mock.patch.object(package.bundle_contract, "verify_bundle", return_value=["warning"]) as contract:
            self.assertEqual(package.image_contract(True)(Path("/Volumes/x/WallpaperMachine.app")), ["warning"])
        stapled.assert_called_once()
        contract.assert_called_once()

    def test_an_image_that_was_not_notarized_is_held_to_the_bundle_contract_only(self):
        self.assertIs(package.image_contract(False), package.bundle_contract.verify_bundle)


if __name__ == "__main__":
    unittest.main()
