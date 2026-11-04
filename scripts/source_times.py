#!/usr/bin/env python3
"""Let a renderer build restored from a CI cache stay current after a fresh checkout.

A checkout writes every file with the current time, so the restored `Renderer/target`
looks older than all of its sources. Cargo and CMake decide what to rebuild by comparing
modification times, and so they recompiled every workspace crate, the vendored naga and
the C++ engine on every CI run, although the cache held them built from the same text.

`record` writes `Renderer/target/source-times.json` before a build: the blob id of every
tracked file under `Renderer/` and `ThirdParty/`, the entries of every directory there, and
the toolchain the build uses (Rust, Apple clang and the SDK, CMake, the Homebrew libraries,
the cargo manifests and the build's environment). The file travels in the cache with the
build it describes. `restore` reads it after the next checkout and, only when the toolchain
is unchanged, gives every file whose blob id is unchanged, and every directory whose
entries are unchanged, one fixed time older than any build output. Changed, added and
removed files keep the checkout's time, so cargo and CMake rebuild exactly what changed.

The record vouches for everything in the target directory only while every job that keeps
it builds the same thing, `scripts/build.py`'s renderer stage. Any other job runs `forget`,
which deletes the record so a cache it saves is never trusted (docs/release.md).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from lib.glyphs import markers
from lib.homebrew import RENDERER_PACKAGES
from lib.paths import RENDERER, ROOT

MARK = markers()
FORMAT = 1
RECORD = RENDERER / "target/source-times.json"
# What the renderer build reads: the Rust workspace, the C++ engine, and vendored code.
SCOPE = ("Renderer", "ThirdParty")
# 2001-01-01T00:00:00Z: older than any output a build could have written.
AGED = 978307200
# Manifests whose change alters what cargo builds, not only how a crate compiles: a
# change to any of them turns reuse off for that run, so no unit an older manifest
# produced, still lying in the target directory, is ever mistaken for current.
CARGO_FILES = ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "rust-toolchain", "config.toml")
# Environment that changes what the compilers produce.
ENVIRONMENT = ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_WRAPPER", "CC", "CXX", "CFLAGS", "CXXFLAGS",
               "LDFLAGS", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET")
ENVIRONMENT_PREFIXES = ("CARGO_BUILD_", "CARGO_PROFILE_", "CARGO_TARGET_", "CMAKE_", "OWE_")


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=True).stdout


def tracked(root, scope=SCOPE):
    """`(entries, dirty)`: `{path: "mode blob"}` of the tracked files under `scope`, and the
    paths whose working copy differs from the index (their blob id says nothing about them)."""
    entries = {}
    for record in git(root, "ls-files", "--stage", "-z", "--", *scope).split(b"\0"):
        if not record:
            continue
        meta, _, path = record.partition(b"\t")
        mode, blob, stage = meta.decode().split(" ")
        # Unmerged entries have no single content; submodules are directories.
        if stage == "0" and mode != "160000":
            entries[path.decode()] = f"{mode} {blob}"
    dirty = set()
    status = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=no", "--no-renames", "--", *scope)
    for record in status.split(b"\0"):
        if len(record) > 3:
            dirty.add(record[3:].decode())
    return entries, dirty


def directories(paths, dirty=frozenset()):
    """`{directory: digest of its entries}` for every directory holding the tracked `paths`.

    A directory's time changes when an entry is added, removed or renamed, and cargo's
    `rerun-if-changed` on a directory reads the times of the directory and all it holds, so
    a directory may only be aged when its entries are the recorded ones. Directories with a
    dirty entry are left out.
    """
    children = {}
    for path in paths:
        parts = path.split("/")
        for depth in range(1, len(parts)):
            children.setdefault("/".join(parts[:depth]), set()).add(parts[depth])
    unsafe = {path.rsplit("/", 1)[0] for path in dirty if "/" in path}
    return {directory: hashlib.sha256("\0".join(sorted(names)).encode()).hexdigest()
            for directory, names in children.items() if directory not in unsafe}


def command_output(arguments, cwd):
    try:
        completed = subprocess.run(arguments, cwd=cwd, capture_output=True, text=True, check=False)
    except OSError as error:
        return f"unavailable: {error.strerror}"
    return f"exit {completed.returncode}: {completed.stdout.strip()}"


def toolchain(root, environ=None):
    """What the build used besides the sources: compilers, SDK, libraries, manifests, flags."""
    environ = os.environ if environ is None else environ
    renderer = root / RENDERER.relative_to(ROOT)
    manifests = hashlib.sha256()
    for path in sorted(git(root, "ls-files", "-z", "--", *SCOPE).decode().split("\0")):
        if path and path.rsplit("/", 1)[-1] in CARGO_FILES and (root / path).is_file():
            manifests.update(path.encode() + b"\0" + (root / path).read_bytes() + b"\0")
    return {
        # rustup reads Renderer/rust-toolchain.toml from the working directory.
        "rustc": command_output(["rustc", "-vV"], renderer),
        "cargo": command_output(["cargo", "-V"], renderer),
        "clang": command_output(["xcrun", "clang", "--version"], root),
        "sdk": command_output(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"], root),
        "cmake": command_output(["cmake", "--version"], root),
        "homebrew": command_output(["brew", "list", "--versions", *RENDERER_PACKAGES], root),
        "manifests": manifests.hexdigest(),
        "environment": {name: value for name, value in sorted(environ.items())
                        if name in ENVIRONMENT or name.startswith(ENVIRONMENT_PREFIXES)},
    }


def record(root=ROOT, target=RECORD, current=None):
    """Describe the sources and toolchain the coming build uses, next to its output."""
    entries, dirty = tracked(root)
    payload = {
        "format": FORMAT,
        "scope": list(SCOPE),
        "toolchain": toolchain(root) if current is None else current,
        "files": {path: entry for path, entry in sorted(entries.items()) if path not in dirty},
        "directories": directories(entries, dirty),
    }
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n")
    return len(payload["files"])


def restore(root=ROOT, target=RECORD, current=None):
    """Age every file and directory unchanged since the recorded build; return the reason
    nothing was aged, or None."""
    try:
        recorded = json.loads(target.read_text())
    except FileNotFoundError:
        return "no record of the sources the restored build came from"
    except (OSError, ValueError) as error:
        return f"unreadable {target.name} ({error})"
    if recorded.get("format") != FORMAT or recorded.get("scope") != list(SCOPE):
        return f"{target.name} was written by another version of this script"
    current = toolchain(root) if current is None else current
    changed = sorted(key for key in current.keys() | recorded.get("toolchain", {}).keys()
                     if current.get(key) != recorded.get("toolchain", {}).get(key))
    if changed:
        return f"the build's {', '.join(changed)} changed since the restored build"
    entries, dirty = tracked(root)
    files = recorded.get("files", {})
    aged = [path for path, entry in entries.items() if path not in dirty and files.get(path) == entry]
    folders = recorded.get("directories", {})
    aged_directories = [path for path, digest in directories(entries, dirty).items() if folders.get(path) == digest]
    for path in aged + aged_directories:
        os.utime(root / path, (AGED, AGED), follow_symlinks=False)
    rebuilt = len(entries) - len(aged)
    print(f"{MARK.ok} {len(aged)} unchanged source file(s) keep the restored build current; "
          f"{rebuilt} changed or new file(s) rebuild")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("restore", "record", "forget"),
                        help="restore: age unchanged sources; record: describe the coming build; "
                             "forget: delete the record")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args()
    root = args.root.resolve()
    target = root / RECORD.relative_to(ROOT)
    if args.action == "forget":
        target.unlink(missing_ok=True)
        return 0
    if args.action == "record":
        count = record(root, target)
        print(f"{MARK.ok} Recorded {count} source file(s) for the next restore of this build")
        return 0
    reason = restore(root, target)
    if reason:
        print(f"{MARK.warn} Rebuilding the renderer's workspace crates: {reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
