"""What a signed WallpaperMachine bundle must still carry: the facts the lock screen and the privacy prompts depend on.

Re-signing, copying into a disk image and Xcode setting changes can all drop an
entitlement or an Info.plist key without breaking the signature. The result is only
visible on a user's Mac, as a lock screen that never starts or a missing permission
prompt. `verify_bundle(app)` reads those facts back from the built artifact:

* every embedded extension is sandboxed, signed with every key and value of
  `Extension/WallpaperExtension.entitlements` (the source of truth; no key list is
  repeated here), and declares the `com.apple.wallpaper` extension point;
* the host is not sandboxed, carries the Apple Events and audio capture usage
  strings, registers the `wallpapermachine` URL scheme, and requires at least the
  project's deployment target (packaging may raise it, never lower it);
* an app and an extension that are not ad hoc signed share a team identifier.

Findings that would break the app are errors; entitlements the signature adds beyond
the repository file are warnings, because Xcode and signing profiles inject some
(`com.apple.security.get-task-allow` in a debuggable build).

The signature readers are parameters, so the checks run on a synthetic bundle without
`codesign`: `scripts/package.py` calls this after signing the build, and
`scripts/lib/dmg.py` calls it on the app inside the mounted image.
"""
from __future__ import annotations

from pathlib import Path
import plistlib
import re
import subprocess
from typing import NamedTuple
from xml.parsers.expat import ExpatError

from lib.paths import EXTENSION, PROJECT_YML

APP_IDENTIFIER = "app.wallpapermachine"
EXTENSION_IDENTIFIER = "app.wallpapermachine.wallpaper-extension"
EXTENSION_POINT = "com.apple.wallpaper"
URL_SCHEME = "wallpapermachine"
USAGE_DESCRIPTIONS = ("NSAppleEventsUsageDescription", "NSAudioCaptureUsageDescription")
SANDBOX = "com.apple.security.app-sandbox"
EXTENSION_ENTITLEMENTS = EXTENSION / "WallpaperExtension.entitlements"

DEPLOYMENT_TARGET = re.compile(r"MACOSX_DEPLOYMENT_TARGET:\s*\"?([\d.]+)")
NOT_SIGNED = "not signed at all"
# macOS 27 deprecates the ":-" spelling and prints a warning; older releases only know it.
ENTITLEMENT_OPTIONS = (("--xml", "--entitlements", "-"), ("--entitlements", ":-"))


class BundleContractError(Exception):
    """The bundle breaks its contract (or cannot be read); the message lists every finding."""


class Signature(NamedTuple):
    adhoc: bool
    team: str | None


class Findings(NamedTuple):
    errors: list[str]
    warnings: list[str]


def _codesign(*arguments):
    return subprocess.run(["/usr/bin/codesign", *map(str, arguments)], capture_output=True, text=True, errors="replace")


def read_entitlements(path):
    """The entitlements embedded in `path`'s signature; `{}` when it has none or is unsigned."""
    failure = None
    for options in ENTITLEMENT_OPTIONS:
        completed = _codesign("-d", *options, path)
        if NOT_SIGNED in completed.stderr:
            return {}
        if completed.returncode == 0:
            data = completed.stdout.strip()
            try:
                return plistlib.loads(data.encode()) if data else {}
            except (ValueError, ExpatError) as error:
                raise BundleContractError(f"{path}: the signed entitlements are not a property list: {error}") from error
        failure = completed.stderr.strip()
    raise BundleContractError(f"codesign could not read the entitlements of {path}: {failure}")


def read_signature(path):
    """`Signature` of `path`, or None when it is unsigned."""
    completed = _codesign("-dv", path)
    if NOT_SIGNED in completed.stderr:
        return None
    if completed.returncode != 0:
        raise BundleContractError(f"codesign could not read the signature of {path}: {completed.stderr.strip()}")
    fields = dict(line.partition("=")[::2] for line in completed.stderr.splitlines())
    team = fields.get("TeamIdentifier")
    return Signature(adhoc=fields.get("Signature") == "adhoc", team=None if team in (None, "not set") else team)


def deployment_target(project=PROJECT_YML):
    match = DEPLOYMENT_TARGET.search(Path(project).read_text(encoding="utf-8"))
    if not match:
        raise BundleContractError(f"No MACOSX_DEPLOYMENT_TARGET in {project}")
    return match.group(1)


def _version(text):
    try:
        return tuple(int(part) for part in text.split("."))
    except (AttributeError, ValueError):
        return None


def _differs(signed, expected):
    return signed != expected or type(signed) is not type(expected)


def check_bundle(app, *, entitlements=read_entitlements, signature=read_signature, extension_entitlements=None, minimum_system=None):
    """Every way `app` (a built or mounted `.app`) breaks its contract, as `Findings`.

    `entitlements(path)` and `signature(path)` read a signed bundle; `extension_entitlements`
    is the repository file's contents and `minimum_system` the deployment target, both
    read from the repository when omitted.
    """
    app = Path(app)
    errors, warnings = [], []

    def label(path):
        return app.name if path == app else str(path.relative_to(app))

    def info_of(path):
        file = path / "Contents/Info.plist"
        try:
            with file.open("rb") as handle:
                return plistlib.load(handle)
        except (OSError, ValueError, ExpatError) as error:
            errors.append(f"{label(path)}: Contents/Info.plist cannot be read ({error.__class__.__name__}: {error})")
            return None

    def signed(path):
        """The component's signature, or None after recording that it has none."""
        found = signature(path)
        if found is None:
            errors.append(f"{label(path)} is not signed")
        return found

    if extension_entitlements is None:
        with EXTENSION_ENTITLEMENTS.open("rb") as handle:
            extension_entitlements = plistlib.load(handle)
    if minimum_system is None:
        minimum_system = deployment_target()

    host = info_of(app)
    if host is not None:
        if host.get("CFBundleIdentifier") != APP_IDENTIFIER:
            errors.append(f"{app.name}: CFBundleIdentifier is {host.get('CFBundleIdentifier')!r}, not {APP_IDENTIFIER}")
        for key in USAGE_DESCRIPTIONS:
            value = host.get(key)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{app.name}: Info.plist has no {key}, so macOS would not ask for the permission or would refuse it")
        types = host.get("CFBundleURLTypes")
        schemes = {scheme for entry in types if isinstance(entry, dict) for scheme in entry.get("CFBundleURLSchemes", [])} if isinstance(types, list) else set()
        if URL_SCHEME not in schemes:
            errors.append(f"{app.name}: CFBundleURLTypes does not register the {URL_SCHEME}:// scheme")
        recorded = _version(host.get("LSMinimumSystemVersion"))
        if recorded is None:
            errors.append(f"{app.name}: LSMinimumSystemVersion is {host.get('LSMinimumSystemVersion')!r}, not a version")
        elif recorded < _version(minimum_system):
            errors.append(f"{app.name}: LSMinimumSystemVersion is {host['LSMinimumSystemVersion']}, below the deployment target {minimum_system}")

    host_signature = signed(app)
    if host_signature is not None and entitlements(app).get(SANDBOX) is True:
        errors.append(f"{app.name} is sandboxed, but it reads Homebrew, Steam and the user's wallpaper folders; {SANDBOX} must not be signed into it")

    extensions = sorted((app / "Contents/Extensions").glob("*.appex"))
    if not extensions:
        errors.append(f"{app.name} embeds no extension (Contents/Extensions/*.appex), so the lock screen would never start")
    for extension in extensions:
        name = label(extension)
        info = info_of(extension)
        if info is not None:
            if info.get("CFBundleIdentifier") != EXTENSION_IDENTIFIER:
                errors.append(f"{name}: CFBundleIdentifier is {info.get('CFBundleIdentifier')!r}, not {EXTENSION_IDENTIFIER}")
            attributes = info.get("EXAppExtensionAttributes")
            point = attributes.get("EXExtensionPointIdentifier") if isinstance(attributes, dict) else None
            if point != EXTENSION_POINT:
                errors.append(f"{name}: EXExtensionPointIdentifier is {point!r}, not {EXTENSION_POINT}")
        extension_signature = signed(extension)
        if extension_signature is None:
            continue
        actual = entitlements(extension)
        if actual.get(SANDBOX) is not True:
            errors.append(f"{name} is not sandboxed: {SANDBOX} must be signed in as true")
        for key, value in sorted(extension_entitlements.items()):
            if key == SANDBOX:
                continue
            if key not in actual:
                errors.append(f"{name}: the signature lacks {key}")
            elif _differs(actual[key], value):
                errors.append(f"{name}: {key} is signed as {actual[key]!r}, but the repository entitlements say {value!r}")
        extra = sorted(set(actual) - set(extension_entitlements))
        if extra:
            warnings.append(f"{name}: the signature adds {', '.join(extra)}, which the repository entitlements do not list")
        if host_signature is not None and host_signature.adhoc != extension_signature.adhoc:
            errors.append(f"{name} and {app.name} are not signed the same way (one is ad hoc, the other is not)")
        elif host_signature is not None and not host_signature.adhoc and host_signature.team != extension_signature.team:
            errors.append(f"{name} is signed by team {extension_signature.team or 'none'}, but {app.name} by team {host_signature.team or 'none'}")
    return Findings(errors, warnings)


def verify_bundle(app, **readers):
    """The warnings for `app`; raises `BundleContractError` listing every error.

    `readers` are the keyword arguments of `check_bundle`.
    """
    errors, warnings = check_bundle(app, **readers)
    if errors:
        raise BundleContractError(f"{Path(app).name} does not match its signing and Info.plist contract:\n  " + "\n  ".join(errors))
    return warnings
