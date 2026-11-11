#!/usr/bin/env python3
"""Watch Valve's SteamCMD for macOS the way the app installs it, and say when it changes.

The app installs SteamCMD from Valve's package manifest (`steam_cmd_osx`) and runs it
with `-inhibitbootstrap`, so a copy never updates itself; the app compares it with the
manifest instead (docs/features/workshop-downloads.md#keeping-steamcmd-current). When
Valve ships a new SteamCMD, an older one can stop being able to sign in, which is how
1.6.4 had to be rushed out. This reads the manifest, installs its packages into a
temporary folder with the same checks (size, SHA-256, SHA-1 file name, paths that stay
inside the folder, Valve's code signature), and signs in anonymously, which needs no account and proves the
client still reaches Steam and is accepted by it:

    python3 scripts/steamcmd_canary.py                  # report the version and run the sign-in
    python3 scripts/steamcmd_canary.py --version-only   # only read and report the manifest
    python3 scripts/steamcmd_canary.py --report-issues  # also open or update GitHub issues (gh)

`--report-issues` is what the SteamCMD canary workflow (.github/workflows/steamcmd-canary.yml)
runs every day on an Apple silicon runner: a version no issue names yet opens
"SteamCMD <version> released <date>", and a failed sign-in opens "SteamCMD canary
failing", or comments on the one already open. The exit status is 1 when the sign-in
failed and 2 when the manifest could not be read or installed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile
from typing import NamedTuple
import urllib.request
import zipfile

from lib.glyphs import markers

MARK = markers()
BASE = "https://steamcdn-a.akamaihd.net/client/"
MANIFEST_URL = BASE + "steam_cmd_osx"
MANIFEST_LIMIT = 64 * 1024
TOTAL_LIMIT = 256 * 1024 * 1024
REQUIRED = ("steamcmd_osx", "steamcmd_bins_osx")
USER_AGENT = "WallpaperMachine/1.0 (SteamCMD canary; scripts/steamcmd_canary.py)"
TIMEOUT_SECONDS = 60
SIGN_IN_TIMEOUT_SECONDS = 300
# SteamCMD's own words once Steam has accepted an anonymous sign-in.
SIGNED_IN = re.compile(r"Waiting for user info\.\.\.\s*OK", re.IGNORECASE)
MACH_O = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
FAILING_TITLE = "SteamCMD canary failing"
# Valve's Developer ID team; a SteamCMD signed by anyone else is not run.
VALVE_TEAM = "MXGJJ98X76"
OUTPUT_LINES = 60


class CanaryError(Exception):
    """The manifest or a package is not what Valve publishes; nothing was run."""


class Package(NamedTuple):
    name: str
    file: str
    size: int
    sha256: str

    @property
    def sha1(self) -> str:
        return self.file.rsplit(".", 1)[-1]


class Manifest(NamedTuple):
    version: str
    packages: tuple[Package, ...]

    @property
    def published(self) -> dt.date:
        """Valve's version is the Unix time the manifest was written."""
        return dt.datetime.fromtimestamp(int(self.version), dt.timezone.utc).date()


def tokens(text: str) -> list[str]:
    """Quoted strings and braces; `//` comments dropped. Escapes are refused, not guessed at."""
    found: list[str] = []
    index = 0
    while index < len(text):
        char = text[index]
        if char.isspace():
            index += 1
        elif text.startswith("//", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end + 1
        elif char in "{}":
            found.append(char)
            index += 1
        elif char == '"':
            end = text.find('"', index + 1)
            value = text[index + 1:end] if end >= 0 else ""
            if end < 0 or "\\" in value or not value.isascii():
                raise CanaryError("the manifest has a string this reader does not accept")
            found.append('"' + value)
            index = end + 1
        else:
            raise CanaryError(f"the manifest has an unexpected character {char!r}")
    return found


def block(items: list[str], index: int) -> tuple[dict[str, object], int]:
    """One `{ … }` body starting after its brace, returned with the index past its close."""
    entries: dict[str, object] = {}
    while index < len(items) and items[index] != "}":
        key = items[index]
        if not key.startswith('"') or index + 1 >= len(items):
            raise CanaryError("the manifest is not a key-value document")
        value = items[index + 1]
        if value == "{":
            entries[key[1:]], index = block(items, index + 2)
        elif value.startswith('"'):
            entries[key[1:]] = value[1:]
            index += 2
        else:
            raise CanaryError("the manifest is not a key-value document")
    if index >= len(items):
        raise CanaryError("the manifest ends inside a block")
    return entries, index + 1


def parse_manifest(text: str) -> Manifest:
    """The `osx` block of Valve's manifest, held to the rules the app holds it to."""
    # Valve's signature blocks follow `osx` at the top level; the closing brace makes the
    # document one block.
    items = tokens(text) + ["}"]
    document, end = block(items, 0)
    osx = document.get("osx")
    if end != len(items) or not isinstance(osx, dict):
        raise CanaryError("the manifest has no osx block")
    version = osx.get("version")
    if not isinstance(version, str) or not version.isdigit() or not 1 <= len(version) <= 20:
        raise CanaryError("the manifest has no numeric version")
    packages = []
    for name, fields in osx.items():
        if not isinstance(fields, dict):
            continue
        file, size, sha256 = fields.get("file"), fields.get("size"), fields.get("sha2")
        if not (re.fullmatch(r"[a-z0-9_]{1,64}", name) and isinstance(file, str)
                and re.fullmatch(re.escape(name) + r"\.zip\.[0-9a-f]{40}", file)
                and isinstance(size, str) and size.isdigit() and 0 < int(size) <= TOTAL_LIMIT
                and isinstance(sha256, str) and re.fullmatch(r"[0-9a-f]{64}", sha256)):
            raise CanaryError(f"the manifest lists package {name!r} incompletely")
        packages.append(Package(name, file, int(size), sha256))
    names = {package.name for package in packages}
    if not all(name in names for name in REQUIRED) or sum(p.size for p in packages) > TOTAL_LIMIT:
        raise CanaryError("the manifest lacks SteamCMD's own packages or is too large")
    return Manifest(version, tuple(packages))


def fetch(url: str, limit: int) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise CanaryError(f"{url} is larger than {limit} bytes")
    return data


def verify(package: Package, data: bytes) -> None:
    if len(data) != package.size:
        raise CanaryError(f"{package.name} is {len(data)} bytes, the manifest says {package.size}")
    if hashlib.sha256(data).hexdigest() != package.sha256 or hashlib.sha1(data).hexdigest() != package.sha1:
        raise CanaryError(f"{package.name} does not match Valve's published checksums")


def safe_member(name: str) -> PurePosixPath | None:
    """Where a zip entry lands inside the install folder (Valve mixes `\\` and `/`), or None to refuse it."""
    path = PurePosixPath(name.replace("\\", "/"))
    parts = [part for part in path.parts if part not in ("", ".")]
    if path.is_absolute() or ".." in parts or any(ord(c) < 32 for c in name):
        return None
    return PurePosixPath(*parts) if parts else None


def inside(path: Path, folder: Path) -> bool:
    return path == folder or folder in path.parents


def extract(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            relative = safe_member(entry.filename)
            if relative is None:
                if entry.filename.strip("./\\"):
                    raise CanaryError(f"{archive.name} has an unsafe path {entry.filename!r}")
                continue
            target = destination / relative
            if entry.is_dir() or entry.filename.endswith(("/", "\\")):
                target.mkdir(parents=True, exist_ok=True)
                continue
            if target.exists() or target.is_symlink():
                raise CanaryError(f"{relative} is in more than one package")
            target.parent.mkdir(parents=True, exist_ok=True)
            if not inside(target.parent.resolve(), destination.resolve()):
                raise CanaryError(f"{relative} would be written through a link out of the folder")
            if stat.S_ISLNK(entry.external_attr >> 16):
                # Breakpad.framework's version links, which the framework needs to load.
                link = bundle.read(entry).decode("utf-8")
                if link.startswith("/") or not inside(Path(os.path.normpath(target.parent / link)), destination):
                    raise CanaryError(f"{relative} links out of the folder")
                target.symlink_to(link)
                continue
            with bundle.open(entry) as source, open(target, "xb") as sink:
                head = source.read(4)
                sink.write(head)
                while chunk := source.read(1 << 20):
                    sink.write(chunk)
            # Valve's zips carry no permission bits; its updater marks code images executable.
            target.chmod(0o755 if head in MACH_O else 0o644)


def install(manifest: Manifest, folder: Path) -> Path:
    """Downloads, checks and unpacks every package; returns the folder holding `steamcmd`."""
    runtime = folder / "runtime"
    runtime.mkdir(parents=True)
    for package in manifest.packages:
        data = fetch(BASE + package.file, package.size)
        verify(package, data)
        archive = folder / package.file
        archive.write_bytes(data)
        extract(archive, runtime)
    executable = runtime / "steamcmd"
    if not executable.is_file() or not executable.stat().st_mode & stat.S_IXUSR:
        raise CanaryError("the packages contain no executable steamcmd")
    require_valve_signature(executable)
    return runtime


def require_valve_signature(executable: Path) -> None:
    """Apple's verification of the signature, and Valve's team as its signer."""
    verified = subprocess.run(["codesign", "--verify", "--strict", str(executable)],
                              capture_output=True, text=True, check=False)
    described = subprocess.run(["codesign", "-dv", "--verbose=2", str(executable)],
                               capture_output=True, text=True, check=False)
    if verified.returncode != 0 or f"TeamIdentifier={VALVE_TEAM}" not in described.stderr.splitlines():
        raise CanaryError(f"steamcmd is not signed by Valve: {(verified.stderr or described.stderr).strip()}")


def sign_in(runtime: Path, folder: Path) -> tuple[bool, str]:
    """An anonymous sign-in with the arguments downloads use, and what SteamCMD printed."""
    home = folder / "home"
    home.mkdir()
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "TMPDIR": str(home),
        "DYLD_LIBRARY_PATH": str(runtime), "DYLD_FRAMEWORK_PATH": str(runtime / "Frameworks"),
        "TERM": "dumb", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
    }
    command = [str(runtime / "steamcmd"), "-inhibitbootstrap", "+@ShutdownOnFailedCommand", "1",
               "+login", "anonymous", "+quit"]
    try:
        finished = subprocess.run(command, cwd=runtime, env=environment, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  timeout=SIGN_IN_TIMEOUT_SECONDS, check=False)
    except subprocess.TimeoutExpired as expired:
        output = (expired.stdout or b"").decode("utf-8", "replace")
        return False, output + f"\n(stopped after {SIGN_IN_TIMEOUT_SECONDS} s)"
    output = finished.stdout.decode("utf-8", "replace")
    ok = finished.returncode == 0 and bool(SIGNED_IN.search(output))
    return ok, output + ("" if ok else f"\n(exit status {finished.returncode})")


def tail(output: str, lines: int = OUTPUT_LINES) -> str:
    kept = [line.rstrip() for line in output.replace("\r", "\n").splitlines() if line.strip()]
    return "\n".join(kept[-lines:])


class Action(NamedTuple):
    """One GitHub issue change: `number` None opens `title`, otherwise comments on it."""
    title: str
    body: str
    number: int | None = None


def issue_actions(manifest: Manifest, signed_in: bool, output: str,
                  titles: dict[str, tuple[int, str]]) -> list[Action]:
    """What to tell the maintainers, given every issue title in the repository with its number and state."""
    actions = []
    release = f"SteamCMD {manifest.version} released"
    if not any(title.startswith(release) for title in titles):
        result = "signs in anonymously" if signed_in else "**could not sign in anonymously**"
        actions.append(Action(
            f"{release} {manifest.published.isoformat()}",
            f"Valve published a new SteamCMD for macOS (manifest version {manifest.version}, "
            f"{manifest.published.isoformat()}). Installed the way the app installs it, it {result}.\n\n"
            "The app replaces its own copy within a day of a download being started, so check before "
            "that reaches everyone: sign in and download a wallpaper with a real account in a build of "
            "`main`, and look at `steamcmd-failures.txt` in a diagnostics report if it fails.\n\n"
            f"```\n{tail(output)}\n```"))
    if not signed_in:
        body = (f"The anonymous sign-in with SteamCMD {manifest.version} failed. "
                f"What SteamCMD printed:\n\n```\n{tail(output)}\n```")
        existing = titles.get(FAILING_TITLE)
        if existing and existing[1] == "OPEN":
            actions.append(Action(FAILING_TITLE, body, existing[0]))
        else:
            actions.append(Action(FAILING_TITLE, body))
    return actions


def existing_titles() -> dict[str, tuple[int, str]]:
    listed = subprocess.run(
        ["gh", "issue", "list", "--state", "all", "--search", "SteamCMD in:title", "--limit", "200",
         "--json", "number,title,state"], capture_output=True, text=True, check=True)
    return titles_from(json.loads(listed.stdout))


def titles_from(issues: list[dict]) -> dict[str, tuple[int, str]]:
    """Each title once, with its open issue when one of several sharing it is open."""
    titles: dict[str, tuple[int, str]] = {}
    for issue in issues:
        known = titles.get(issue["title"])
        if known is None or (issue["state"] == "OPEN" and known[1] != "OPEN"):
            titles[issue["title"]] = (issue["number"], issue["state"])
    return titles


def apply(actions: list[Action]) -> None:
    for action in actions:
        if action.number is None:
            subprocess.run(["gh", "issue", "create", "--title", action.title, "--body", action.body], check=True)
            print(f"{MARK.step} opened: {action.title}")
        else:
            subprocess.run(["gh", "issue", "comment", str(action.number), "--body", action.body], check=True)
            print(f"{MARK.step} commented on #{action.number}: {action.title}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--version-only", action="store_true", help="only read and report the manifest")
    parser.add_argument("--report-issues", action="store_true",
                        help="open or comment on GitHub issues with gh (the workflow's mode)")
    args = parser.parse_args(argv)
    try:
        manifest = parse_manifest(fetch(MANIFEST_URL, MANIFEST_LIMIT).decode("ascii"))
    except (OSError, UnicodeDecodeError, CanaryError) as error:
        print(f"{MARK.missing} Valve's SteamCMD manifest could not be read: {error}")
        return 2
    print(f"{MARK.ok} SteamCMD {manifest.version}, published {manifest.published.isoformat()}, "
          f"{len(manifest.packages)} packages")
    if args.version_only:
        return 0
    with tempfile.TemporaryDirectory(prefix="steamcmd-canary-") as temporary:
        folder = Path(temporary)
        try:
            runtime = install(manifest, folder)
        except (OSError, zipfile.BadZipFile, CanaryError) as error:
            print(f"{MARK.missing} SteamCMD could not be installed: {error}")
            return 2
        signed_in, output = sign_in(runtime, folder)
    if signed_in:
        print(f"{MARK.ok} anonymous sign-in accepted")
    else:
        print(f"{MARK.missing} anonymous sign-in failed:\n{tail(output)}")
    if args.report_issues:
        apply(issue_actions(manifest, signed_in, output, existing_titles()))
    return 0 if signed_in else 1


if __name__ == "__main__":
    raise SystemExit(main())
