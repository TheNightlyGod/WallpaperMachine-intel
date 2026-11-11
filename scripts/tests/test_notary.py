#!/usr/bin/env python3
"""Unit tests for scripts/lib/notary.py: submitting, stapling and assessing, with Apple's tools replaced."""
from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from lib import notary  # noqa: E402

CREDENTIALS = notary.Credentials("WallpaperMachine Notary")
ACCEPTED = json.dumps({"id": "1111-2222", "status": "Accepted", "message": "Processing complete"})
INVALID = json.dumps({"id": "3333-4444", "status": "Invalid", "message": "Processing complete"})
LOG = json.dumps({"status": "Invalid", "issues": [
    {"severity": "error", "path": "WallpaperMachine.zip/WallpaperMachine.app/Contents/Frameworks/libfoo.dylib",
     "message": "The binary is not signed with a valid Developer ID certificate."}]})
ASSESSED = "accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example (ABCDE12345)"
LOST = (68, "", "error is Error Domain=NSURLErrorDomain Code=-1005 \"The network connection was lost.\"\n"
                "The staple and validate action failed! Error 68.")
STAPLED = (0, "The staple and validate action worked!", "")


class Tools:
    """Records each command and answers by the tool and action it names; a list answers in turn, then repeats its last."""

    def __init__(self, **answers):
        self.commands = []
        self.answers = {"submit": (0, ACCEPTED, ""), "log": (0, LOG, ""), "staple": STAPLED,
                        "validate": (0, "The validate action worked!", ""), "spctl": (0, "", ASSESSED), "ditto": (0, "", ""),
                        **answers}

    def __call__(self, command):
        command = list(map(str, command))
        self.commands.append(command)
        key = Path(command[0]).name if command[0] != "xcrun" else command[2]
        answer = self.answers[key]
        if isinstance(answer, list):
            answer = answer.pop(0) if len(answer) > 1 else answer[0]
        code, stdout, stderr = answer
        return subprocess.CompletedProcess(command, code, stdout, stderr)

    def named(self, key):
        return [command for command in self.commands
                if (command[0] == "xcrun" and command[2] == key) or Path(command[0]).name == key]


class SubmitTests(unittest.TestCase):
    def test_an_accepted_submission_returns_its_id_and_waits_with_the_profile(self):
        tools = Tools()
        self.assertEqual(notary.submit(Path("/tmp/WallpaperMachine.zip"), CREDENTIALS, tools), "1111-2222")
        command = tools.named("submit")[0]
        self.assertIn("--wait", command)
        self.assertEqual(command[command.index("--keychain-profile") + 1], "WallpaperMachine Notary")
        self.assertNotIn("--keychain", command)

    def test_a_profile_in_another_keychain_names_it(self):
        tools = Tools()
        notary.submit(Path("/tmp/x.zip"), notary.Credentials("Notary", Path("/tmp/signing.keychain-db")), tools)
        command = tools.named("submit")[0]
        self.assertEqual(command[command.index("--keychain") + 1], "/tmp/signing.keychain-db")

    def test_a_refused_submission_reports_the_issues_from_its_log(self):
        tools = Tools(submit=(1, INVALID, ""))
        with self.assertRaises(notary.NotarizationError) as raised:
            notary.submit(Path("/tmp/WallpaperMachine.zip"), CREDENTIALS, tools)
        message = str(raised.exception)
        self.assertIn("Invalid", message)
        self.assertIn("3333-4444", message)
        self.assertIn("libfoo.dylib", message)
        self.assertIn("not signed with a valid Developer ID", message)
        self.assertEqual(tools.named("log")[0][3], "3333-4444")

    def test_a_submission_apple_has_not_finished_names_its_id_and_fetches_no_log(self):
        # What notarytool prints, on stderr, when --timeout runs out.
        timeout = json.dumps({"id": "5555-6666", "message": "Timeout of 3000 second(s) was reached before processing completed."})
        tools = Tools(submit=(1, "", timeout))
        with self.assertRaises(notary.NotarizationError) as raised:
            notary.submit(Path("/tmp/WallpaperMachine.zip"), CREDENTIALS, tools)
        message = str(raised.exception)
        self.assertIn("has not finished", message)
        self.assertIn("notarytool info 5555-6666", message)
        self.assertEqual(tools.named("log"), [])

    def test_a_submission_that_never_started_reports_the_tool_error(self):
        tools = Tools(submit=(69, "", "Error: No Keychain password item found for profile: Notary"))
        with self.assertRaisesRegex(notary.NotarizationError, "No Keychain password item"):
            notary.submit(Path("/tmp/x.zip"), CREDENTIALS, tools)
        self.assertEqual(tools.named("log"), [])


class NotarizeTests(unittest.TestCase):
    def test_an_app_is_zipped_for_upload_and_the_ticket_stapled_to_the_bundle(self):
        tools = Tools()
        app = Path("/build/WallpaperMachine.app")
        notary.notarize(app, CREDENTIALS, tools)
        ditto = tools.named("ditto")[0]
        upload = ditto[-1]
        self.assertTrue(upload.endswith("WallpaperMachine.zip"))
        self.assertEqual(ditto[-2], str(app))
        self.assertEqual(tools.named("submit")[0][3], upload)
        self.assertEqual(tools.named("staple")[0][-1], str(app))
        self.assertEqual(tools.named("validate")[0][-1], str(app))
        spctl = tools.named("spctl")[0]
        self.assertEqual(spctl[spctl.index("--type") + 1], "execute")

    def test_a_disk_image_is_uploaded_as_it_is_and_assessed_as_a_signed_image(self):
        tools = Tools()
        image = Path("/build/WallpaperMachine-1.9.0-arm64.dmg")
        notary.notarize(image, CREDENTIALS, tools)
        self.assertEqual(tools.named("ditto"), [])
        self.assertEqual(tools.named("submit")[0][3], str(image))
        self.assertEqual(tools.named("staple")[0][-1], str(image))
        spctl = tools.named("spctl")[0]
        self.assertEqual(spctl[spctl.index("--type") + 1], "open")
        self.assertIn("context:primary-signature", spctl)

    def test_steps_run_in_order(self):
        tools = Tools()
        notary.notarize(Path("/build/WallpaperMachine.app"), CREDENTIALS, tools)
        order = [command[2] if command[0] == "xcrun" else Path(command[0]).name for command in tools.commands]
        self.assertEqual(order, ["ditto", "submit", "staple", "validate", "spctl"])

    def test_a_ticket_that_cannot_be_stapled_fails_after_the_retries(self):
        tools, waits = Tools(staple=(65, "", "Could not find base64 encoded ticket in response")), []
        with self.assertRaisesRegex(notary.NotarizationError, "could not staple"):
            notary.notarize(Path("/build/x.dmg"), CREDENTIALS, tools, sleep=waits.append)
        self.assertEqual(len(tools.named("staple")), len(notary.STAPLE_RETRY_DELAYS) + 1)
        self.assertEqual(waits, list(notary.STAPLE_RETRY_DELAYS))
        self.assertEqual(tools.named("spctl"), [])

    def test_a_lost_connection_while_stapling_is_retried(self):
        tools, waits = Tools(staple=[LOST, LOST, STAPLED]), []
        notary.notarize(Path("/build/WallpaperMachine-1.9.1-arm64.dmg"), CREDENTIALS, tools, sleep=waits.append)
        self.assertEqual(len(tools.named("staple")), 3)
        self.assertEqual(len(tools.named("validate")), 1)
        self.assertEqual(waits, list(notary.STAPLE_RETRY_DELAYS[:2]))
        self.assertEqual(len(tools.named("spctl")), 1)

    def test_a_ticket_that_staples_at_once_waits_for_nothing(self):
        waits = []
        notary.notarize(Path("/build/WallpaperMachine.app"), CREDENTIALS, Tools(), sleep=waits.append)
        self.assertEqual(waits, [])

    def test_gatekeeper_must_call_the_source_notarized(self):
        tools = Tools(spctl=(0, "", "accepted\nsource=Unnotarized Developer ID"))
        with self.assertRaisesRegex(notary.NotarizationError, "Unnotarized"):
            notary.notarize(Path("/build/WallpaperMachine.app"), CREDENTIALS, tools)

    def test_a_rejection_by_gatekeeper_fails(self):
        tools = Tools(spctl=(3, "", "rejected\nsource=Notarized Developer ID"))
        with self.assertRaisesRegex(notary.NotarizationError, "rejected"):
            notary.notarize(Path("/build/WallpaperMachine.app"), CREDENTIALS, tools)


class StapledCopyTests(unittest.TestCase):
    def test_a_copy_with_its_ticket_passes(self):
        notary.check_stapled(Path("/Volumes/x/WallpaperMachine.app"), Tools())

    def test_a_copy_without_a_ticket_fails_after_the_retries(self):
        tools, waits = Tools(validate=(65, "WallpaperMachine.app does not have a ticket stapled to it.", "")), []
        with self.assertRaisesRegex(notary.NotarizationError, "no valid notarization ticket"):
            notary.check_stapled(Path("/Volumes/x/WallpaperMachine.app"), tools, sleep=waits.append)
        self.assertEqual(waits, list(notary.STAPLE_RETRY_DELAYS))

    def test_a_lost_connection_while_validating_the_copy_is_retried(self):
        tools, waits = Tools(validate=[LOST, (0, "The validate action worked!", "")]), []
        notary.check_stapled(Path("/Volumes/x/WallpaperMachine.app"), tools, sleep=waits.append)
        self.assertEqual(len(tools.named("validate")), 2)
        self.assertEqual(waits, [notary.STAPLE_RETRY_DELAYS[0]])


if __name__ == "__main__":
    unittest.main()
