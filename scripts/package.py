#!/usr/bin/env python3
"""Bundle Homebrew dylibs, collect license notices, sign the local application, and wrap it in a disk image.

Nothing in the bundle is touched until the preflight passes: every bundled
Homebrew keg must carry license files to ship, and every notice the build places in
the bundle must match its repository original. The signed bundle then goes into
`WallpaperMachine-<version>-arm64.dmg`, the drag-to-install image laid out by
scripts/lib/dmg.py, which is mounted and verified before its `.sha256` sidecar is
written. LICENSING.md describes the license and the notices the bundle carries.

The signed bundle, and again the copy inside the mounted image, must still carry what the
lock screen extension and the permission prompts need: the extension's sandbox and
entitlements, the host's entitlements, the Info.plist keys, and a matching signing team
(scripts/lib/bundle_contract.py).

A Developer ID identity (`--sign-identity "Developer ID Application: …"`) signs every
library, framework, extension and the app with the hardened runtime and a secure
timestamp, and then the disk image. `--notarize PROFILE` (a `notarytool
store-credentials` profile; `--notary-keychain` when it is not in the login keychain)
has Apple notarize the app, staples the ticket to it before the image is made, then
notarizes and staples the image too (scripts/lib/notary.py). The checksum is written
last, because stapling changes the image's bytes.

Every bundled dylib keeps the minimum macOS it was built for, which for a Homebrew
bottle is the host's release. When one is newer than the app's deployment target the
bundle's `LSMinimumSystemVersion` is raised to match, so macOS refuses to open it
instead of it failing at launch; `--require-deployment-target` makes that an error.
A `minos` does not cover the system libraries a file loads, so every one the bundle
loads unconditionally must be known to ship with macOS 15.0 (SYSTEM_LIBRARIES), or
packaging stops: one that macOS lacks makes dyld refuse to start the app.

`--check` runs the preflight against the built bundle and exits without changing it.

The preflight also generates `THIRD-PARTY-NOTICES.txt` (scripts/notices.py): the license text of
every Homebrew library, compiled-in component and linked Rust crate, taken from the component
itself, bundled as `Contents/Resources/THIRD-PARTY-NOTICES.txt`. A generation failure stops
packaging; a component whose license text cannot be found is named in the output and marked
in the file, and `--require-notices` makes it an error too (the gate for a distributed build).
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import NamedTuple

import check_licenses
from lib import bundle_contract, dmg, notary
from lib.homebrew import KEG_LICENSE_FILE, keg_of
from lib.glyphs import markers
from lib.paths import PROVENANCE, ROOT, THIRD_PARTY, app_bundle
import notices

MARK = markers()
# The GPLv2 text the imported renderer was received under; see LICENSING.md.
IMPORTED_RENDERER_LICENSE = THIRD_PARTY / "received-licenses/wallpaper-engine-for-macos.GPL-2.0.txt"
# Packaging is one-way: it rewrites load commands and fills Contents/Frameworks, and
# does not record where those dylibs came from. Repackaging therefore needs fresh
# build output rather than an incremental rebuild, which leaves Frameworks as it was.
FRESH_BUILD = "Packaging requires fresh, unrelocated build output; incremental builds retain bundled dylibs. See docs/build.md before cleaning any delivered app"
# The system libraries the bundle may load unconditionally: each ships with macOS 15.0, the
# deployment target. A Homebrew bottle is linked against the newest SDK of its macOS release
# and records that release's `minos`, so a library added later in the release passes the
# minimum-version check yet stops the app before main() on an earlier one (FreeType 2.15
# linked /usr/lib/libhvf.dylib, which macOS has only from 15.4). Add a library here only
# once it is known to ship with macOS 15.0. Weak loads are skipped when missing; not checked.
SYSTEM_LIBRARIES = frozenset({
    "/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib", "/usr/lib/libobjc.A.dylib",
    "/usr/lib/libiconv.2.dylib", "/usr/lib/libz.1.dylib", "/usr/lib/libbz2.1.0.dylib",
})
# What Xcode links the app and its extension against at the deployment target, weak-linking
# anything newer: Apple's frameworks and the Swift runtime. Bundled libraries get no such pass.
LINKED_AT_TARGET = ("/System/Library/Frameworks/", "/usr/lib/swift/")


class PackagingError(Exception):
    """A condition that stops packaging; the message is the whole report."""


def output(args):
    return subprocess.check_output(list(map(str, args)), text=True)


def run(args):
    subprocess.run(list(map(str, args)), check=True)


class Signing(NamedTuple):
    """How packaging signs: ad hoc (`-`), a certificate, or a Developer ID that can be notarized.

    Release builds use the Developer ID: its designated requirement (identifier, Apple's
    Developer ID chain and the team) stays the same from one release to the next, so macOS
    privacy permissions survive an update, and it is the only signature Apple notarizes.
    An ad-hoc requirement is the build's cdhash, which every release changes.
    """
    identity: str
    developer_id: bool = False

    def options(self):
        if self.developer_id:
            # Notarization requires both; library validation then needs every bundled
            # library signed by the same team, which this identity does.
            return ["--timestamp", "--options", "runtime"]
        # Without a team, the hardened runtime's library validation would refuse the
        # app's own libraries, so ad hoc and self-signed builds run without it.
        return ["--options", "0"] if self.identity == "-" else ["--timestamp=none", "--options", "0"]


IDENTITY_LINE = re.compile(r'^\s*\d+\) ([0-9A-F]{40}) "(.*)"')


def signing_for(identity, listing=None):
    """The `Signing` for `--sign-identity`, matched the way codesign matches it: a SHA-1 or part of the name.

    `listing` is `security find-identity -v -p codesigning` output (valid identities only), read
    from the keychains when omitted. An identity matching several of them stops packaging here,
    before the bundle is touched, rather than in codesign after it is relocated: a renewed
    certificate shares its name with the old one, so the SHA-1 picks between them. One that
    matches none (an untrusted self-signed certificate is not listed) is left to codesign.
    """
    if identity == "-":
        return Signing("-")
    if listing is None:
        listing = output(["security", "find-identity", "-v", "-p", "codesigning"])
    names = {match.group(1): match.group(2) for match in map(IDENTITY_LINE.match, listing.splitlines()) if match}
    matches = {digest: name for digest, name in names.items() if identity.upper() == digest or identity in name}
    if len(matches) > 1:
        listed = "; ".join(f"{digest} {name}" for digest, name in sorted(matches.items()))
        raise PackagingError(f"--sign-identity {identity!r} matches {len(matches)} identities; pass one SHA-1 instead: {listed}")
    return Signing(identity, any(name.startswith(bundle_contract.DEVELOPER_ID) for name in matches.values()))


def sign(file, signing, *options):
    run(["codesign", "--force", "--sign", signing.identity, *signing.options(), *options, file])


def report(warnings, reported):
    """Print the warnings not shown yet: the image check reads the same signatures the bundle check just did."""
    for warning in warnings:
        if warning not in reported:
            reported.add(warning)
            print(f"{MARK.warn} {warning}")


def dependencies(file):
    return [line.strip().split(" (compatibility")[0] for line in output(["otool", "-L", file]).splitlines()[1:] if line.strip()]


def rpaths(file):
    """The LC_RPATH entries of a Mach-O file, in load-command order."""
    load_commands = output(["otool", "-l", file]).splitlines()
    return [load_commands[index + 2].strip().split(" (offset")[0].removeprefix("path ")
            for index, line in enumerate(load_commands) if line.strip() == "cmd LC_RPATH"]


def keg_rpath_target(file, dependency, prefix):
    """The Homebrew file an `@rpath/` dependency of a Homebrew dylib names, or None.

    Some kegs load a sibling library through `@rpath` and an `@loader_path/../lib` entry
    of their own (brotli's decoder loads its common library that way, and FreeType loads
    brotli since 2.15). Only rpaths that stay inside the Homebrew prefix are followed:
    a bundle relocated by an earlier run points its rpaths at Contents/Frameworks, and
    that input is still refused.
    """
    root = Path(prefix).resolve()
    if not Path(file).resolve().is_relative_to(root):
        return None
    name = dependency.removeprefix("@rpath/")
    for entry in rpaths(file):
        if entry.startswith("@loader_path/"):
            base = Path(file).parent / entry.removeprefix("@loader_path/")
        elif entry.startswith(str(prefix)):
            base = Path(entry)
        else:
            continue
        # Named as it is loaded, like an absolute dependency, so the bundled copy keeps that
        # name; the check that it stays in the prefix follows any links.
        candidate = base / name
        if candidate.is_file() and candidate.resolve().is_relative_to(root):
            return candidate
    return None


def resolve_libraries(roots, seeds, prefix):
    """Every Homebrew dylib the roots load, directly or transitively, keyed by file name.

    Read-only: the walk runs over the Homebrew files themselves, so the bundle is
    known before anything is copied into it. A Homebrew dylib's `@rpath` dependency is
    followed through that dylib's own rpaths inside the prefix (`keg_rpath_target`).
    Any other `@rpath` dependency that is not a Swift runtime library means the input
    was already relocated by an earlier run, whose provenance this script does not
    track, so it is refused rather than resolved against whatever the host has installed.
    """
    libraries = {}
    relocated = []
    queue = list(roots)

    def add(source):
        if source.name not in libraries:
            libraries[source.name] = source.resolve()
            queue.append(source)

    for seed in seeds:
        add(seed)
    while queue:
        file = queue.pop(0)
        for dependency in dependencies(file):
            if dependency.startswith(str(prefix)):
                add(Path(dependency))
            elif dependency.startswith("@rpath/") and Path(dependency).name not in libraries and "libswift" not in dependency:
                target = keg_rpath_target(file, dependency, prefix)
                if target is not None:
                    add(target)
                else:
                    relocated.append(f"{file}: {dependency}")
    if relocated:
        raise PackagingError(f"{FRESH_BUILD}\n  " + "\n  ".join(relocated))
    return libraries


def minimum_system_version(file):
    """The `minos` a Mach-O file records in its LC_BUILD_VERSION load command."""
    for line in output(["vtool", "-show-build", file]).splitlines():
        fields = line.split()
        if fields[:1] == ["minos"]:
            return fields[1]
    raise PackagingError(f"No minimum macOS version recorded in {file}")


def strong_dependencies(file):
    """The libraries a Mach-O file loads unconditionally; `otool -L` marks the weak ones."""
    return [line.strip().split(" (compatibility")[0] for line in output(["otool", "-L", file]).splitlines()[1:]
            if line.strip() and not line.rstrip().endswith(", weak)")]


def unavailable_system_libraries(compiled, libraries, prefix):
    """`<file>: <library>` for every system library outside SYSTEM_LIBRARIES that the bundle loads unconditionally.

    `compiled` are the app's and extension's own executables, which may also load what
    LINKED_AT_TARGET names; `libraries` are the Homebrew files to bundle. Homebrew and
    `@rpath` dependencies are the bundle's own and are not system libraries.
    """
    found = []
    for file, exempt in [*((file, LINKED_AT_TARGET) for file in compiled), *((file, ()) for file in libraries)]:
        for dependency in strong_dependencies(file):
            if not dependency.startswith("/") or dependency.startswith(str(prefix)):
                continue
            if dependency not in SYSTEM_LIBRARIES and not dependency.startswith(exempt):
                found.append(f"{Path(file).name}: {dependency}")
    return found


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def raised_minimum(target, minimums):
    """The lowest macOS every file can load on, and the files that need more than `target`.

    `minimums` maps a file name to its `minos`; the floor never drops below `target`.
    """
    newer = {name: version for name, version in minimums.items() if version_key(version) > version_key(target)}
    floor = max([target, *newer.values()], key=version_key)
    return floor, newer


def keg_licenses(libraries):
    """Keg -> its license files, for every keg that contributes a bundled library."""
    result = {}
    problems = []
    for name, source in sorted(libraries.items()):
        keg = keg_of(source)
        if keg is None:
            problems.append(f"{name} ({source}) is not installed from a Homebrew keg")
            continue
        if keg not in result:
            result[keg] = sorted(file for file in keg.iterdir() if file.is_file() and KEG_LICENSE_FILE.match(file.name))
            if not result[keg]:
                problems.append(f"{keg} ships no license file")
    if problems:
        raise PackagingError("Missing license payload:\n  " + "\n  ".join(problems))
    return result


def preflight(notice_files, libraries):
    """Fail before mutation when the bundle could not carry every notice.

    `notice_files` maps each license file Xcode already placed in the build to the
    repository file it must match.
    """
    licenses = keg_licenses(libraries)
    sources = [ROOT / "LICENSE", ROOT / "LICENSING.md", IMPORTED_RENDERER_LICENSE, PROVENANCE, *notice_files.values()]
    missing = [f"{file} is missing from the repository" for file in sources if not file.is_file()]
    missing += [f"{file} is missing from the build or differs from {original}" for file, original in notice_files.items() if original.is_file() and (not file.is_file() or file.read_bytes() != original.read_bytes())]
    if missing:
        raise PackagingError("Missing license payload:\n  " + "\n  ".join(missing))
    return licenses


def third_party_notices(app, require):
    """The text of THIRD-PARTY-NOTICES.txt for the closure of `app`.

    A tool failure, or a closure with no components, stops packaging. A component whose license
    text is not found is reported, and stops packaging only when `require` is set.
    """
    try:
        noticeset = notices.generate(notices.options_for(app), environment=check_licenses.cargo_environment())
    except check_licenses.ToolError as error:
        raise PackagingError(f"Third-party notices could not be generated: {error}") from error
    if not noticeset.notices:
        raise PackagingError("Third-party notices could not be generated: the license closure is empty")
    if noticeset.missing:
        names = [f"{notice.name} {notice.version}".strip() for notice in noticeset.missing]
        message = f"{notices.NOT_FOUND} for {len(names)} of {len(noticeset.notices)} components: {', '.join(names)}"
        if require:
            raise PackagingError(message)
        print(f"{MARK.missing} {message}; THIRD-PARTY-NOTICES.txt marks them (`--require-notices` makes this an error)")
    else:
        print(f"{MARK.ok} Third-party notices: {notices.summary(noticeset)}")
    return noticeset.text


def write_licenses(resources, licenses, third_party):
    """Copy the notices for everything packaged into Resources/Licenses; the directory is rebuilt every run."""
    directory = resources / "Licenses"
    shutil.rmtree(directory, ignore_errors=True)
    for keg, files in licenses.items():
        target = directory / f"{keg.parent.name}-{keg.name}"
        target.mkdir(parents=True)
        for file in files:
            shutil.copy2(file, target / file.name)
    # The vendored C libraries statically linked into the renderer; their notices travel
    # with the app binary.
    for file in sorted(THIRD_PARTY.glob("*/LICENSE*")):
        if file.parent.name in check_licenses.NOT_ENGINE_VENDORED:
            continue
        target = directory / "renderer-third-party" / file.parent.name
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target / file.name)
    shutil.copy2(ROOT / "LICENSE", resources / "WallpaperMachine-LICENSE.txt")
    shutil.copy2(ROOT / "LICENSING.md", resources / "LICENSING.md")
    shutil.copy2(IMPORTED_RENDERER_LICENSE, resources / "Imported-Renderer-GPL-2.0-LICENSE.txt")
    shutil.copy2(PROVENANCE, resources / "provenance.json")
    (resources / "THIRD-PARTY-NOTICES.txt").write_text(third_party)


def relocate(file, prefix, rpath):
    for dependency in dependencies(file):
        if dependency.startswith(str(prefix)):
            run(["install_name_tool", "-change", dependency, f"@rpath/{Path(dependency).name}", file])
    # Executable-relative path also resolves transitive dylibs without a Homebrew installation.
    load_commands = output(["otool", "-l", file]).splitlines()
    paths = []
    for index, line in enumerate(load_commands):
        if line.strip() == "cmd LC_RPATH":
            paths.append(load_commands[index + 2].strip().split(" (offset")[0].removeprefix("path "))
    for path in set(paths):
        if path.startswith(str(prefix)) or path.startswith(str(ROOT)):
            run(["install_name_tool", "-delete_rpath", path, file])
    if rpath not in paths:
        run(["install_name_tool", "-add_rpath", rpath, file])


def package(args):
    signing = signing_for(args.sign_identity)
    credentials = None
    if args.notarize:
        if not signing.developer_id:
            raise PackagingError(f"Notarization needs a Developer ID Application identity, not {args.sign_identity!r} (docs/build.md#release-signing)")
        credentials = notary.Credentials(args.notarize, args.notary_keychain)
    app = app_bundle(args.configuration)
    binary = app / "Contents/MacOS/WallpaperMachine"
    extensions = list((app / "Contents/Extensions").glob("*.appex"))
    extension_binaries = [extension / "Contents/MacOS" / extension.stem for extension in extensions]
    if not binary.is_file():
        raise PackagingError("Build the application first using scripts/build.py")
    frameworks = app / "Contents/Frameworks"
    resources = app / "Contents/Resources"
    prefix = Path(output(["brew", "--prefix"]).strip())
    bundled = sorted(frameworks.glob("*.dylib"))
    if bundled:
        raise PackagingError(f"{FRESH_BUILD}; Contents/Frameworks already holds: {', '.join(file.name for file in bundled)}")
    libraries = resolve_libraries([binary, *extension_binaries], [], prefix)
    # Notices Xcode already bundles from project.yml; packaging never rewrites them.
    notice_files = {resources / "LICENSE": THIRD_PARTY / "mediaremote-adapter/LICENSE"}
    for extension in extensions:
        notice_files[extension / "Contents/Resources/Phosphene-LICENSE.txt"] = ROOT / "Extension/Phosphene-LICENSE.txt"
    licenses = preflight(notice_files, libraries)
    third_party = third_party_notices(app, args.require_notices)
    info = app / "Contents/Info.plist"
    target = output(["/usr/libexec/PlistBuddy", "-c", "Print :LSMinimumSystemVersion", info]).strip()
    unavailable = unavailable_system_libraries([binary, *extension_binaries], libraries.values(), prefix)
    if unavailable:
        raise PackagingError(f"The bundle loads system libraries macOS {target} may not have, so it would stop at launch "
                             "there; rebuild without them, or list one in SYSTEM_LIBRARIES once it is known to ship with "
                             "that release:\n  " + "\n  ".join(unavailable))
    floor, newer = raised_minimum(target, {name: minimum_system_version(source) for name, source in libraries.items()})
    if newer:
        detail = ", ".join(f"{name} ({version})" for name, version in sorted(newer.items()))
        if args.require_deployment_target:
            raise PackagingError(f"Bundled libraries need a newer macOS than the deployment target {target}; build them on macOS {target}: {detail}")
        print(f"{MARK.missing} Bundled libraries need macOS {floor}, above the deployment target {target}; the app will require macOS {floor}: {detail}")
    # The image's art and volume icon are inputs too: a missing or mismatched one must
    # stop packaging while the bundle is untouched, not after it is relocated and signed.
    dmg.check_inputs(icon=resources / "AppIcon.icns")
    for keg in licenses:
        print(f"{MARK.ok} {keg.parent.name} {keg.name}: {', '.join(name for name, source in sorted(libraries.items()) if keg_of(source) == keg)}")
    if args.check:
        print(f"{MARK.ok} Preflight passed; bundle left unchanged: {app}")
        return

    frameworks.mkdir(exist_ok=True)
    for name, source in libraries.items():
        destination = frameworks / name
        shutil.copy2(source, destination)
        destination.chmod(0o755)
        run(["install_name_tool", "-id", f"@rpath/{name}", destination])
    for file in [binary, *(frameworks / name for name in libraries)]:
        relocate(file, prefix, "@executable_path/../Frameworks")
    for file in extension_binaries:
        relocate(file, prefix, "@executable_path/../../../../Frameworks")

    write_licenses(resources, licenses, third_party)
    if floor != target:
        run(["/usr/libexec/PlistBuddy", "-c", f"Set :LSMinimumSystemVersion {floor}", info])
    # Inside out: a signature seals the nested code's signatures as they are.
    for file in sorted(frameworks.glob("*.dylib")):
        sign(file, signing)
    for framework in sorted(frameworks.glob("*.framework")):
        sign(framework, signing)
    # Exactly the repository's entitlements: Xcode adds com.apple.security.get-task-allow
    # to the extension even in a Release build, and Apple will not notarize it.
    for extension in extensions:
        sign(extension, signing, "--entitlements", bundle_contract.EXTENSION_ENTITLEMENTS)
    sign(app, signing, "--entitlements", bundle_contract.HOST_ENTITLEMENTS)
    run(["codesign", "--verify", "--deep", "--strict", app])
    # A valid signature says nothing about what it signs: re-signing can drop an entitlement
    # or a key silently, and the lock screen then fails on the user's Mac, not here.
    reported = set()
    report(bundle_contract.verify_bundle(app), reported)
    for file in [binary, *extension_binaries, *frameworks.glob("*.dylib")]:
        for dependency in dependencies(file):
            if dependency.startswith(str(prefix)):
                raise PackagingError(f"Unbundled dependency: {file}: {dependency}")
            if dependency.startswith("@rpath/") and not (frameworks / Path(dependency).name).exists() and "libswift" not in dependency:
                raise PackagingError(f"Missing bundled dependency: {dependency}")
    if credentials:
        # Stapled before the image is made, so the copy a user drags out opens offline too.
        notary.notarize(app, credentials)
        print(f"{MARK.ok} Notarized and stapled: {app.name}")
    version = output(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", info]).strip()
    image = dmg.build(app, app.parent / dmg.image_name(version), dmg.volume_name(version), icon=resources / "AppIcon.icns")
    if signing.developer_id:
        run(["codesign", "--force", "--sign", signing.identity, "--timestamp", image])
    if credentials:
        notary.notarize(image, credentials)
        print(f"{MARK.ok} Notarized and stapled: {image.name}")
    # Prove the image, not the build tree: users and the in-app updater install
    # exactly this file, and a bundle that does not survive the round trip is not one.
    metadata = {}
    report(dmg.verify(image, version, contract=image_contract(credentials is not None), metadata=metadata), reported)
    digest = sha256(image)
    metadata.update(image=image.name, size=image.stat().st_size, sha256=digest)
    image.with_name(image.name + ".metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    checksum = image.with_name(image.name + ".sha256")
    checksum.write_text(f"{digest}  {image.name}\n")
    if args.install:
        destination = Path.home() / "Applications/WallpaperMachine.app"
        destination.parent.mkdir(exist_ok=True)
        if destination.exists():
            raise PackagingError(f"An installation already exists: {destination}. Quit it and explicitly remove/replace it before installation.")
        shutil.copytree(app, destination)
        print(f"{MARK.ok} Installed {destination}")
    print(f"{MARK.ok} Verified bundle: {app}")
    print(f"{MARK.ok} Verified disk image: {image}")
    print(f"{MARK.ok} Checksum: {checksum}")


def image_contract(notarized):
    """What the app inside the mounted image must meet: the bundle contract, and its ticket when notarized."""
    if not notarized:
        return bundle_contract.verify_bundle

    def contract(app):
        notary.check_stapled(app)
        return bundle_contract.verify_bundle(app)
    return contract


def sha256(file):
    digest = hashlib.sha256()
    with open(file, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--configuration", default="Debug", choices=["Debug", "Release"])
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--check", action="store_true", help="Run the license preflight against the built bundle and change nothing.")
    parser.add_argument("--require-deployment-target", action="store_true", help="Fail instead of raising the app's minimum macOS when a bundled library needs a newer one.")
    parser.add_argument("--require-notices", action="store_true", help="Fail instead of warning when a component's license text cannot be found for THIRD-PARTY-NOTICES.txt.")
    parser.add_argument("--sign-identity", default="-", help="Code-signing identity for the dylibs, frameworks, extensions and app; `-` (the default) signs ad hoc. Release builds pass the Developer ID (docs/build.md#release-signing).")
    parser.add_argument("--notarize", metavar="PROFILE", help="Notarize and staple the app and the disk image with this `xcrun notarytool store-credentials` profile; needs a Developer ID --sign-identity.")
    parser.add_argument("--notary-keychain", type=Path, help="Keychain holding the --notarize profile, when it is not the login keychain.")
    args = parser.parse_args()
    try:
        package(args)
    except (PackagingError, dmg.DiskImageError, bundle_contract.BundleContractError, notary.NotarizationError) as error:
        print(f"{MARK.missing} {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
