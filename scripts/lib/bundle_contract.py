"""What a signed WallpaperMachine bundle must still carry: the facts the lock screen and the privacy prompts depend on.

Re-signing, copying into a disk image and Xcode setting changes can all drop an
entitlement or an Info.plist key without breaking the signature. The result is only
visible on a user's Mac, as a lock screen that never starts or a missing permission
prompt. `verify_bundle(app)` reads those facts back from the built artifact:

* every embedded extension is sandboxed, signed with every key and value of
  `Extension/WallpaperExtension.entitlements` (the source of truth; no key list is
  repeated here), and declares the `com.apple.wallpaper` extension point;
* the host is not sandboxed, is signed with every key and value of
  `Packaging/WallpaperMachine.entitlements` (what the hardened runtime lets it do),
  carries the Apple Events and audio capture usage strings, registers the
  `wallpapermachine` URL scheme, and requires at least the project's deployment target
  (packaging may raise it, never lower it);
* an app and an extension that are not ad hoc signed share a team identifier;
* a Developer ID signed host, which is what gets notarized, has the hardened runtime on
  itself and every extension, no `com.apple.security.get-task-allow` in either, and
  every library and framework in `Contents/Frameworks` signed by its team: Apple refuses
  to notarize anything else, and the runtime's library validation refuses to load a
  library another team or an ad hoc signature signed.

Findings that would break the app are errors; entitlements the signature adds beyond
the repository files are warnings, because Xcode and signing profiles inject some
(`com.apple.security.get-task-allow` in a debuggable build, an error under Developer ID).

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

from lib.paths import EXTENSION, PROJECT_YML, ROOT

APP_IDENTIFIER = "app.wallpapermachine"
EXTENSION_IDENTIFIER = "app.wallpapermachine.wallpaper-extension"
EXTENSION_POINT = "com.apple.wallpaper"
URL_SCHEME = "wallpapermachine"
USAGE_DESCRIPTIONS = ("NSAppleEventsUsageDescription", "NSAudioCaptureUsageDescription")
SANDBOX = "com.apple.security.app-sandbox"
GET_TASK_ALLOW = "com.apple.security.get-task-allow"
EXTENSION_ENTITLEMENTS = EXTENSION / "WallpaperExtension.entitlements"
# Applied by scripts/package.py, not Xcode: they only matter under the hardened runtime
# packaging turns on, and debug builds and the test host run without it.
HOST_ENTITLEMENTS = ROOT / "Packaging/WallpaperMachine.entitlements"
DEVELOPER_ID = "Developer ID Application:"

DEPLOYMENT_TARGET = re.compile(r"MACOSX_DEPLOYMENT_TARGET:\s*\"?([\d.]+)")
NOT_SIGNED = "not signed at all"
# macOS 27 deprecates the ":-" spelling and prints a warning; older releases only know it.
ENTITLEMENT_OPTIONS = (("--xml", "--entitlements", "-"), ("--entitlements", ":-"))


class BundleContractError(Exception):
    """The bundle breaks its contract (or cannot be read); the message lists every finding."""


class Signature(NamedTuple):
    adhoc: bool
    team: str | None
    # The leaf certificate is a Developer ID Application certificate.
    developer_id: bool = False
    # The code directory carries the hardened runtime flag.
    runtime: bool = False


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
    completed = _codesign("-dvv", path)
    if NOT_SIGNED in completed.stderr:
        return None
    if completed.returncode != 0:
        raise BundleContractError(f"codesign could not read the signature of {path}: {completed.stderr.strip()}")
    lines = completed.stderr.splitlines()
    # `Authority=` repeats from the leaf up to the root; the first one is the signer.
    fields = {}
    for line in lines:
        key, _, value = line.partition("=")
        fields.setdefault(key, value)
    team = fields.get("TeamIdentifier")
    # `CodeDirectory v=20500 size=… flags=0x10000(runtime) hashes=…`
    flags = re.search(r"\bflags=\S+", fields.get("CodeDirectory v", ""))
    return Signature(adhoc=fields.get("Signature") == "adhoc", team=None if team in (None, "not set") else team,
                     developer_id=fields.get("Authority", "").startswith(DEVELOPER_ID),
                     runtime=bool(flags and "runtime" in flags.group()))


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


def _plist(path):
    with Path(path).open("rb") as handle:
        return plistlib.load(handle)


def check_bundle(app, *, entitlements=read_entitlements, signature=read_signature, extension_entitlements=None,
                 host_entitlements=None, minimum_system=None):
    """Every way `app` (a built or mounted `.app`) breaks its contract, as `Findings`.

    `entitlements(path)` and `signature(path)` read a signed bundle; `extension_entitlements`
    and `host_entitlements` are the repository files' contents and `minimum_system` the
    deployment target, all read from the repository when omitted.
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

    def held_to(name, actual, expected, ignore=()):
        """Records how the signed `actual` entitlements stray from the repository's `expected` ones."""
        for key, value in sorted(expected.items()):
            if key in ignore:
                continue
            if key not in actual:
                errors.append(f"{name}: the signature lacks {key}")
            elif _differs(actual[key], value):
                errors.append(f"{name}: {key} is signed as {actual[key]!r}, but the repository entitlements say {value!r}")
        extra = sorted(set(actual) - set(expected))
        if extra:
            warnings.append(f"{name}: the signature adds {', '.join(extra)}, which the repository entitlements do not list")

    def notarizable(path, found, actual):
        """Records what keeps a component of a Developer ID signed app from notarizing."""
        if not found.runtime:
            errors.append(f"{label(path)} is signed with a Developer ID but without the hardened runtime, so Apple will not notarize it")
        if actual.get(GET_TASK_ALLOW) is True:
            errors.append(f"{label(path)}: {GET_TASK_ALLOW} is signed in, so Apple will not notarize it; package a Release build")

    if extension_entitlements is None:
        extension_entitlements = _plist(EXTENSION_ENTITLEMENTS)
    if host_entitlements is None:
        host_entitlements = _plist(HOST_ENTITLEMENTS)
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
    distributed = host_signature is not None and host_signature.developer_id
    if host_signature is not None:
        actual = entitlements(app)
        if actual.get(SANDBOX) is True:
            errors.append(f"{app.name} is sandboxed, but it reads Homebrew, Steam and the user's wallpaper folders; {SANDBOX} must not be signed into it")
        held_to(app.name, actual, host_entitlements, ignore=(SANDBOX,))
        if distributed:
            notarizable(app, host_signature, actual)
            frameworks = app / "Contents/Frameworks"
            for code in sorted([*frameworks.glob("*.dylib"), *frameworks.glob("*.framework")]):
                found = signature(code)
                if found is None or found.adhoc or found.team != host_signature.team:
                    signer = "nothing" if found is None else "an ad hoc signature" if found.adhoc else f"team {found.team or 'none'}"
                    errors.append(f"{label(code)} is signed by {signer}, not the Developer ID team {host_signature.team}: "
                                  "Apple will not notarize it and library validation would refuse to load it")

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
        held_to(name, actual, extension_entitlements, ignore=(SANDBOX,))
        if distributed:
            notarizable(extension, extension_signature, actual)
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
