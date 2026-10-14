#!/usr/bin/env python3
"""Unit tests for scripts/lib/bundle_contract.py: what a signed bundle must still carry.

The checks run on a synthetic bundle skeleton with injected signature readers; the last
class reads real signatures from small binaries signed with codesign.
"""
from __future__ import annotations

import copy
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from lib import bundle_contract  # noqa: E402
from lib.bundle_contract import Signature  # noqa: E402

SANDBOX = "com.apple.security.app-sandbox"
READ_ONLY = "com.apple.security.temporary-exception.files.absolute-path.read-only"
# Stands in for Extension/WallpaperExtension.entitlements: the checks must follow whatever it says.
REPOSITORY_ENTITLEMENTS = {
    SANDBOX: True,
    "com.apple.security.network.client": True,
    READ_ONLY: ["/opt/homebrew/"],
}
HOST_INFO = {
    "CFBundleIdentifier": "app.wallpapermachine",
    "LSMinimumSystemVersion": "15.0",
    "NSAppleEventsUsageDescription": "Asks Music what is playing.",
    "NSAudioCaptureUsageDescription": "Captures system audio on request.",
    "CFBundleURLTypes": [{"CFBundleURLName": "app.wallpapermachine.automation", "CFBundleURLSchemes": ["wallpapermachine"]}],
}
EXTENSION_INFO = {
    "CFBundleIdentifier": "app.wallpapermachine.wallpaper-extension",
    "EXAppExtensionAttributes": {"EXExtensionPointIdentifier": "com.apple.wallpaper"},
}
AD_HOC = Signature(adhoc=True, team=None)


class SyntheticBundleTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.app = Path(scratch.name) / "WallpaperMachine.app"
        self.extension = self.app / "Contents/Extensions/WallpaperMachineExtension.appex"
        self.host_info = copy.deepcopy(HOST_INFO)
        self.extension_info = copy.deepcopy(EXTENSION_INFO)
        self.signatures = {self.app: AD_HOC, self.extension: AD_HOC}
        self.entitlements = {self.app: {}, self.extension: copy.deepcopy(REPOSITORY_ENTITLEMENTS)}
        self.minimum_system = "15.0"

    def write(self):
        for bundle, info in ((self.app, self.host_info), (self.extension, self.extension_info)):
            if info is not None:
                (bundle / "Contents").mkdir(parents=True, exist_ok=True)
                with open(bundle / "Contents/Info.plist", "wb") as handle:
                    plistlib.dump(info, handle)
        (self.app / "Contents/Extensions").mkdir(parents=True, exist_ok=True)

    def readers(self, **overrides):
        return {"entitlements": lambda path: self.entitlements.get(path, {}), "signature": self.signatures.get,
                "extension_entitlements": REPOSITORY_ENTITLEMENTS, "minimum_system": self.minimum_system, **overrides}

    def findings(self, **overrides):
        self.write()
        return bundle_contract.check_bundle(self.app, **self.readers(**overrides))

    def assertOneError(self, fragment, **overrides):
        errors, _ = self.findings(**overrides)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn(fragment, errors[0])

    def test_a_complete_bundle_has_no_findings(self):
        self.assertEqual(self.findings(), ([], []))

    def test_the_repositorys_own_entitlements_and_deployment_target_are_what_the_default_checks_read(self):
        with open(bundle_contract.EXTENSION_ENTITLEMENTS, "rb") as handle:
            self.entitlements[self.extension] = plistlib.load(handle)
        self.host_info["LSMinimumSystemVersion"] = bundle_contract.deployment_target()
        self.write()
        errors, _ = bundle_contract.check_bundle(
            self.app, entitlements=lambda path: self.entitlements.get(path, {}), signature=self.signatures.get)
        self.assertEqual(errors, [])

    # --- the extension's signature ------------------------------------------------

    def test_an_extension_signed_without_the_sandbox_fails(self):
        del self.entitlements[self.extension][SANDBOX]
        self.assertOneError(SANDBOX)

    def test_an_extension_signed_with_the_sandbox_turned_off_fails(self):
        self.entitlements[self.extension][SANDBOX] = False
        self.assertOneError(SANDBOX)

    def test_a_repository_entitlement_missing_from_the_signature_fails(self):
        del self.entitlements[self.extension]["com.apple.security.network.client"]
        self.assertOneError("lacks com.apple.security.network.client")

    def test_an_entitlement_signed_with_another_value_fails(self):
        self.entitlements[self.extension][READ_ONLY] = ["/usr/local/"]
        self.assertOneError(READ_ONLY)

    def test_an_entitlement_of_the_wrong_type_fails(self):
        self.entitlements[self.extension]["com.apple.security.network.client"] = 1
        self.assertOneError("com.apple.security.network.client")

    def test_an_added_entitlement_only_warns(self):
        self.entitlements[self.extension]["com.apple.security.get-task-allow"] = True
        errors, warnings = self.findings()
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)
        self.assertIn("com.apple.security.get-task-allow", warnings[0])

    def test_the_bundle_is_held_to_the_entitlements_file_it_is_given(self):
        self.assertOneError("com.apple.security.device.audio-input", extension_entitlements={
            **REPOSITORY_ENTITLEMENTS, "com.apple.security.device.audio-input": True})

    def test_an_unsigned_extension_fails_once(self):
        del self.signatures[self.extension]
        self.assertOneError("is not signed")

    def test_a_bundle_without_an_extension_fails(self):
        self.extension_info = None
        self.assertOneError("embeds no extension")

    # --- the extension's Info.plist -----------------------------------------------

    def test_an_extension_that_declares_another_extension_point_fails(self):
        self.extension_info["EXAppExtensionAttributes"]["EXExtensionPointIdentifier"] = "com.apple.widgetkit-extension"
        self.assertOneError("com.apple.wallpaper")

    def test_an_extension_without_extension_attributes_fails(self):
        del self.extension_info["EXAppExtensionAttributes"]
        self.assertOneError("com.apple.wallpaper")

    def test_an_extension_with_another_identifier_fails(self):
        self.extension_info["CFBundleIdentifier"] = "app.wallpapermachine.other"
        self.assertOneError("app.wallpapermachine.wallpaper-extension")

    # --- the host's Info.plist ----------------------------------------------------

    def test_a_missing_url_scheme_fails(self):
        self.host_info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["other"]}]
        self.assertOneError("wallpapermachine://")

    def test_an_absent_url_type_list_fails(self):
        del self.host_info["CFBundleURLTypes"]
        self.assertOneError("wallpapermachine://")

    def test_a_missing_usage_string_fails(self):
        del self.host_info["NSAudioCaptureUsageDescription"]
        self.assertOneError("NSAudioCaptureUsageDescription")

    def test_a_blank_usage_string_fails(self):
        self.host_info["NSAppleEventsUsageDescription"] = "  "
        self.assertOneError("NSAppleEventsUsageDescription")

    def test_a_minimum_system_below_the_deployment_target_fails(self):
        self.host_info["LSMinimumSystemVersion"] = "14.6"
        self.assertOneError("below the deployment target 15.0")

    def test_a_minimum_system_raised_by_packaging_passes(self):
        self.host_info["LSMinimumSystemVersion"] = "27.0"
        self.assertEqual(self.findings(), ([], []))

    def test_minimum_systems_compare_numerically(self):
        self.minimum_system = "15.2"
        self.host_info["LSMinimumSystemVersion"] = "15.10"
        self.assertEqual(self.findings(), ([], []))

    def test_a_host_with_another_identifier_fails(self):
        self.host_info["CFBundleIdentifier"] = "app.example.other"
        self.assertOneError("app.wallpapermachine")

    def test_a_sandboxed_host_fails(self):
        self.entitlements[self.app] = {SANDBOX: True}
        self.assertOneError("is sandboxed")

    def test_every_finding_is_reported_together(self):
        del self.host_info["NSAudioCaptureUsageDescription"]
        del self.entitlements[self.extension][SANDBOX]
        self.host_info["CFBundleURLTypes"] = []
        self.write()
        with self.assertRaises(bundle_contract.BundleContractError) as raised:
            bundle_contract.verify_bundle(self.app, **self.readers())
        for fragment in ("NSAudioCaptureUsageDescription", SANDBOX, "wallpapermachine://"):
            self.assertIn(fragment, str(raised.exception))

    # --- signing teams ------------------------------------------------------------

    def test_a_differing_team_identifier_fails(self):
        self.signatures[self.app] = Signature(adhoc=False, team="ABCDE12345")
        self.signatures[self.extension] = Signature(adhoc=False, team="ZZZZZ99999")
        self.assertOneError("ZZZZZ99999")

    def test_matching_team_identifiers_pass(self):
        self.signatures[self.app] = Signature(adhoc=False, team="ABCDE12345")
        self.signatures[self.extension] = Signature(adhoc=False, team="ABCDE12345")
        self.assertEqual(self.findings(), ([], []))

    def test_two_certificate_signatures_without_a_team_pass(self):
        # The project's self-signed release certificate has no team identifier.
        self.signatures[self.app] = Signature(adhoc=False, team=None)
        self.signatures[self.extension] = Signature(adhoc=False, team=None)
        self.assertEqual(self.findings(), ([], []))

    def test_an_ad_hoc_extension_in_a_certificate_signed_app_fails(self):
        self.signatures[self.app] = Signature(adhoc=False, team=None)
        self.assertOneError("not signed the same way")

    def test_an_unsigned_host_fails_without_reading_its_entitlements(self):
        del self.signatures[self.app]
        self.entitlements[self.app] = {SANDBOX: True}  # would be a second finding if it were read
        self.assertOneError("is not signed")

    # --- verify_bundle ------------------------------------------------------------

    def test_verifying_returns_the_warnings_of_a_passing_bundle(self):
        self.entitlements[self.extension]["com.apple.security.get-task-allow"] = True
        self.write()
        warnings = bundle_contract.verify_bundle(self.app, **self.readers())
        self.assertEqual(len(warnings), 1)


@unittest.skipUnless(sys.platform == "darwin", "signatures are read with codesign")
class CodesignReaderTests(unittest.TestCase):
    """The readers against binaries signed with the real tool."""

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)

    def binary(self, name, entitlements=None, sign=True):
        path = self.root / name
        shutil.copyfile("/usr/bin/true", path)  # system files carry a signature a copy keeps; it is replaced below
        path.chmod(0o755)
        subprocess.run(["codesign", "--remove-signature", path], check=True, capture_output=True)
        if sign:
            command = ["codesign", "--force", "--sign", "-"]
            if entitlements is not None:
                file = self.root / f"{name}.entitlements"
                file.write_bytes(plistlib.dumps(entitlements))
                command += ["--entitlements", file]
            subprocess.run([*command, path], check=True, capture_output=True)
        return path

    def test_signed_entitlements_are_read_back_with_their_types(self):
        entitlements = {SANDBOX: True, READ_ONLY: ["/opt/homebrew/"]}
        self.assertEqual(bundle_contract.read_entitlements(self.binary("with", entitlements)), entitlements)

    def test_a_signature_without_entitlements_reads_as_none(self):
        self.assertEqual(bundle_contract.read_entitlements(self.binary("without")), {})

    def test_an_unsigned_binary_reads_as_no_entitlements_and_no_signature(self):
        unsigned = self.binary("unsigned", sign=False)
        self.assertEqual(bundle_contract.read_entitlements(unsigned), {})
        self.assertIsNone(bundle_contract.read_signature(unsigned))

    def test_an_ad_hoc_signature_has_no_team(self):
        self.assertEqual(bundle_contract.read_signature(self.binary("adhoc")), Signature(adhoc=True, team=None))

    def test_a_missing_file_is_an_error_not_an_empty_answer(self):
        with self.assertRaises(bundle_contract.BundleContractError):
            bundle_contract.read_signature(self.root / "absent")
        with self.assertRaises(bundle_contract.BundleContractError):
            bundle_contract.read_entitlements(self.root / "absent")


@unittest.skipUnless(sys.platform == "darwin", "signatures are read with codesign")
class SignedBundleTests(unittest.TestCase):
    """A small app and extension signed the way scripts/package.py signs them, read with the default readers."""

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.app = Path(scratch.name) / "WallpaperMachine.app"
        self.extension = self.app / "Contents/Extensions/WallpaperMachineExtension.appex"
        for bundle, name, info in ((self.app, "WallpaperMachine", HOST_INFO), (self.extension, "WallpaperMachineExtension", EXTENSION_INFO)):
            (bundle / "Contents/MacOS").mkdir(parents=True)
            shutil.copyfile("/usr/bin/true", bundle / "Contents/MacOS" / name)
            (bundle / "Contents/MacOS" / name).chmod(0o755)
            with open(bundle / "Contents/Info.plist", "wb") as handle:
                plistlib.dump({**info, "CFBundleExecutable": name, "CFBundlePackageType": "APPL" if bundle == self.app else "XPC!"}, handle)
        self.entitlements = Path(scratch.name) / "extension.entitlements"
        self.entitlements.write_bytes(plistlib.dumps(REPOSITORY_ENTITLEMENTS))

    def sign(self, path, *options):
        subprocess.run(["codesign", "--force", "--sign", "-", *options, path], check=True, capture_output=True)

    def errors(self):
        return bundle_contract.check_bundle(self.app, extension_entitlements=REPOSITORY_ENTITLEMENTS, minimum_system="15.0").errors

    def test_a_bundle_signed_with_its_entitlements_passes(self):
        self.sign(self.extension, "--entitlements", self.entitlements)
        self.sign(self.app, "--options", "0")
        self.assertEqual(self.errors(), [])

    def test_resigning_the_extension_without_preserving_its_entitlements_fails(self):
        self.sign(self.extension, "--entitlements", self.entitlements)
        self.sign(self.extension)  # what dropping --preserve-metadata=entitlements does
        self.sign(self.app, "--options", "0")
        errors = self.errors()
        self.assertTrue(any(SANDBOX in error for error in errors), errors)
        self.assertTrue(any("com.apple.security.network.client" in error for error in errors), errors)

    def test_resigning_the_extension_with_preserved_entitlements_passes(self):
        self.sign(self.extension, "--entitlements", self.entitlements)
        self.sign(self.extension, "--preserve-metadata=entitlements")
        self.sign(self.app, "--options", "0")
        self.assertEqual(self.errors(), [])


if __name__ == "__main__":
    unittest.main()
