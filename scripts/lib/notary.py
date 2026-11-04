"""Apple notarization of a Developer ID signed build: submit, staple, and prove Gatekeeper accepts it.

    credentials = Credentials("WallpaperMachine Notary", keychain=None)
    notarize(app, credentials)     # zipped for upload; the ticket is stapled to the bundle
    notarize(image, credentials)   # a signed disk image is uploaded as it is
    check_stapled(app)             # the ticket travelled with a copy (the app inside the image)

`Credentials` names a profile that `xcrun notarytool store-credentials` saved in a
keychain (the login keychain, or `keychain`): an App Store Connect API key, or an
Apple ID with an app-specific password. No secret passes through here.

`notarytool submit --wait` blocks until Apple has an answer, for at most `WAIT`. Anything
but `Accepted` raises `NotarizationError`: a refusal with the issues from the submission's
log, which name the file and the reason (an unsigned library, a missing hardened runtime,
no secure timestamp); a submission Apple has not finished with its id, so
`xcrun notarytool info <id>` can follow it. A new team's first submissions can stay
`In Progress` for hours. After stapling, `stapler validate` and a Gatekeeper assessment must both
pass: Gatekeeper has to call the source `Notarized Developer ID`, which is what lets a
downloaded copy open without **Open Anyway**, offline included. `stapler staple` and
`stapler validate` both ask Apple's CloudKit ticket service, which can drop a connection
or not serve a fresh ticket yet, so a failed stapler step is retried after
`STAPLE_RETRY_DELAYS` before it fails.

The tool runner is a parameter, so the flow is tested without Apple's service.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import time
from typing import NamedTuple

# Generous: Apple usually answers within minutes, but the first submissions of a new
# team can be held for analysis much longer. The build job's own timeout still applies.
WAIT = "50m"
NOTARIZED = "source=Notarized Developer ID"
# Seconds to wait before each new stapler attempt. Stapling and validating both look the
# ticket up over the network (releases failed on "The network connection was lost",
# stapler error 68, in either step) and a just-accepted ticket can take a moment to reach
# the service; a real refusal or a missing ticket still fails, about two minutes later.
STAPLE_RETRY_DELAYS = (15, 30, 60)


class NotarizationError(Exception):
    """Apple refused the submission, or the result failed a check; the message is the whole report."""


class Credentials(NamedTuple):
    profile: str
    keychain: Path | None = None

    def arguments(self):
        arguments = ["--keychain-profile", self.profile]
        if self.keychain is not None:
            arguments += ["--keychain", str(self.keychain)]
        return arguments


def _run(command):
    return subprocess.run(list(map(str, command)), capture_output=True, text=True, errors="replace")


def _issues(log):
    """The readable part of a `notarytool log` answer: one line per issue, or the raw text."""
    try:
        data = json.loads(log)
    except ValueError:
        return log.strip()
    lines = [f"{issue.get('severity', 'issue')}: {issue.get('path', '?')}: {issue.get('message', '')}"
             for issue in data.get("issues") or []]
    return "\n  ".join(lines) or data.get("statusSummary", "") or log.strip()


def _answer(completed):
    """The JSON object notarytool printed: on stdout normally, on stderr when it gives up waiting."""
    for text in (completed.stdout, completed.stderr):
        try:
            answer = json.loads(text)
        except ValueError:
            continue
        if isinstance(answer, dict):
            return answer
    return None


def submit(path, credentials, run=_run):
    """Uploads `path` (a zip or a signed disk image) and waits; returns the submission id once Accepted."""
    path = Path(path)
    completed = run(["xcrun", "notarytool", "submit", path, *credentials.arguments(),
                     "--wait", "--timeout", WAIT, "--output-format", "json"])
    result = _answer(completed)
    if result is None:
        detail = (completed.stderr or completed.stdout).strip()
        raise NotarizationError(f"notarytool could not submit {path.name}: {detail}")
    identifier, status = result.get("id"), result.get("status")
    if status == "Accepted":
        return identifier
    if not identifier:
        raise NotarizationError(f"notarytool could not submit {path.name}: {result.get('message') or completed.stderr.strip()}")
    if status in (None, "In Progress"):
        raise NotarizationError(
            f"Apple has not finished notarizing {path.name} (submission {identifier}) within {WAIT}: "
            f"{result.get('message', 'still in progress')}. A new team's first submissions can take hours; "
            f"`xcrun notarytool info {identifier}` shows when it ends (docs/build.md#release-signing).")
    log = run(["xcrun", "notarytool", "log", identifier, *credentials.arguments()])
    raise NotarizationError(f"Apple did not notarize {path.name} ({status or 'no status'}, submission {identifier}):\n  "
                            + _issues(log.stdout if log.returncode == 0 else log.stderr))


def _stapler(actions, path, run, sleep):
    """Runs `xcrun stapler` with each action in turn, the sequence again after each delay
    while one fails; returns None once all pass, else the last failure's output."""
    def attempt():
        for action in actions:
            completed = run(["xcrun", "stapler", action, path])
            if completed.returncode != 0:
                return action, (completed.stdout + completed.stderr).strip()
        return None

    failure = attempt()
    for delay in STAPLE_RETRY_DELAYS:
        if failure is None:
            break
        print(f"stapler {failure[0]} failed for {Path(path).name}, retrying in {delay}s: {failure[1]}", flush=True)
        sleep(delay)
        failure = attempt()
    return failure


def _attempts():
    return f"after {len(STAPLE_RETRY_DELAYS) + 1} attempts"


def staple(path, run=_run, sleep=time.sleep):
    """Attaches the ticket to `path` and validates it, so Gatekeeper needs no network to accept it."""
    failure = _stapler(("staple", "validate"), path, run, sleep)
    if failure is not None:
        action, detail = failure
        raise NotarizationError(f"stapler could not {action} {Path(path).name} ({_attempts()}): {detail}")


def assess(path, run=_run):
    """Gatekeeper's verdict on `path` must be a notarized Developer ID source."""
    path = Path(path)
    options = ["--type", "execute"] if path.suffix == ".app" else ["--type", "open", "--context", "context:primary-signature"]
    completed = run(["/usr/sbin/spctl", "--assess", *options, "-vv", path])
    verdict = (completed.stdout + completed.stderr).strip()
    if completed.returncode != 0 or NOTARIZED not in verdict:
        raise NotarizationError(f"Gatekeeper does not accept {path.name} as notarized: {verdict}")


def notarize(path, credentials, run=_run, sleep=time.sleep):
    """Notarizes, staples and assesses `path`: an `.app` (uploaded as a zip) or a signed `.dmg`."""
    path = Path(path)
    if path.suffix == ".app":
        with tempfile.TemporaryDirectory(prefix="notarize-") as scratch:
            upload = Path(scratch) / f"{path.stem}.zip"
            zipped = run(["/usr/bin/ditto", "-c", "-k", "--keepParent", path, upload])
            if zipped.returncode != 0:
                raise NotarizationError(f"Could not zip {path.name} for notarization: {zipped.stderr.strip()}")
            submit(upload, credentials, run)
    else:
        submit(path, credentials, run)
    staple(path, run, sleep)
    assess(path, run)


def check_stapled(app, run=_run, sleep=time.sleep):
    """A copy of a notarized app (the one inside the disk image) still carries its ticket."""
    failure = _stapler(("validate",), app, run, sleep)
    if failure is not None:
        raise NotarizationError(f"{Path(app).name} carries no valid notarization ticket ({_attempts()}): {failure[1]}")
