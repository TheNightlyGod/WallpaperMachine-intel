#!/usr/bin/env python3
"""Attach a built disk image to its GitHub Release, draft first, never to a live one.

The in-app updater reads the newest non-draft release (its update manifest, or the API
for releases without one), so a release that is public before its image is uploaded
is a release users cannot download. This creates the release as a draft, uploads,
and clears the draft flag last; a failure anywhere in between leaves a draft, which
neither `releases/latest` nor `releases/latest/download/…` returns.
Two things the naive `gh` sequence gets wrong, both covered by
`scripts/tests/test_publish_release.py`:

* A release that is *already* published is refused rather than updated.
  `gh release upload --clobber` deletes an existing asset before writing its
  replacement, so re-running against a live release takes the download away and
  only puts it back if the upload succeeds — the window the draft-first order
  exists to close. Republishing different bytes under a tag people already
  downloaded is wrong anyway: cut the next version.
* Latest is decided after upload, using the releases public at promotion time.
  Build's publish job holds a repository-wide concurrency lock; builds for different
  tags can still overlap. Manual invocations must use the same serialized publishing
  boundary rather than run alongside a workflow or another publisher.

    python3 scripts/publish_release.py --tag v0.6.0 --notes notes.md \\
        WallpaperMachine-0.6.0-arm64.dmg WallpaperMachine-0.6.0-arm64.dmg.sha256 WallpaperMachine-update.json

Add --dry-run to validate local artifacts and print the publish commands without mutation.

Called by .github/workflows/build.yml; `gh` reads GH_TOKEN from the environment.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from lib.glyphs import markers

MARK = markers()
VERSION_TAG = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")

CREATE = "create"
RESUME = "resume"
REFUSE = "refuse"


class PublishError(Exception):
    """A condition that stops publishing; the message is the whole report."""


def version_key(tag):
    match = VERSION_TAG.match((tag or "").strip())
    return tuple(int(part) for part in match.groups()) if match else None


def plan(existing):
    """What to do about a release for this tag.

    `existing` is None when no release exists, True for a draft, False for one that
    is already published.
    """
    if existing is None:
        return CREATE
    return RESUME if existing else REFUSE


def promotes_to_latest(tag, published):
    """Whether this tag may claim Latest, given the versions already public."""
    ours = version_key(tag)
    if ours is None:
        raise PublishError(f"Not an x.y.z version tag: {tag!r}")
    return not any(other > ours for other in published)


def draft_commands(tag, action, notes, assets):
    """Create/resume the draft, then attach all its files before promotion."""
    if action == CREATE:
        first = ["gh", "release", "create", tag, "--draft", "--verify-tag", "--title", tag, "--notes-file", notes]
    else:
        first = ["gh", "release", "edit", tag, "--title", tag, "--notes-file", notes]
    return [
        first,
        ["gh", "release", "upload", tag, *assets, "--clobber"],
    ]


def runner(command, check=True):
    completed = subprocess.run(command, capture_output=True, text=True)
    if check and completed.returncode != 0:
        raise PublishError(f"{' '.join(command)} failed: {completed.stderr.strip() or completed.stdout.strip()}")
    return completed


def lookup(tag, run):
    """True when a release for the tag exists as a draft, False when published, None when absent."""
    completed = run(["gh", "release", "view", tag, "--json", "isDraft", "--jq", ".isDraft"], check=False)
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    if value not in ("true", "false"):
        raise PublishError(f"gh reported an unreadable draft state for {tag}: {value!r}")
    return value == "true"


def published_versions(run):
    """Versions of every release that is already public; drafts and prereleases are not."""
    completed = run(["gh", "release", "list", "--limit", "200", "--json", "tagName,isDraft,isPrerelease"])
    versions = []
    for entry in json.loads(completed.stdout or "[]"):
        if entry.get("isDraft") or entry.get("isPrerelease"):
            continue
        key = version_key(entry.get("tagName", ""))
        if key is not None:
            versions.append(key)
    return versions


def validate_assets(tag, notes, assets):
    """Fail closed before mutation: all three public assets describe exactly this image."""
    version = tag.removeprefix("v")
    image_name = f"WallpaperMachine-{version}-arm64.dmg"
    paths = {Path(path).name: Path(path) for path in assets}
    required = {image_name, image_name + ".sha256", "WallpaperMachine-update.json"}
    if set(paths) != required or len(paths) != len(assets):
        raise PublishError("A release requires exactly its DMG, SHA-256 sidecar and update manifest.")
    try:
        for path in [Path(notes), *paths.values()]:
            if not path.is_file():
                raise PublishError(f"Missing release file: {path}")
        with paths[image_name].open("rb") as handle:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
        if paths[image_name + ".sha256"].read_text().strip() != f"{digest}  {image_name}":
            raise PublishError("The checksum does not match the image.")
        manifest = json.loads(paths["WallpaperMachine-update.json"].read_text(encoding="utf-8"))
        entries = manifest.get("assets", [])
        if (manifest.get("tag_name") != tag or manifest.get("prerelease") is not False
                or manifest.get("bundle_identifier") != "app.wallpapermachine"
                or not isinstance(manifest.get("architectures"), list)
                or "arm64" not in manifest["architectures"]
                or not re.fullmatch(r"\d+(?:\.\d+){0,2}", manifest.get("minimum_system_version", ""))
                or manifest.get("body") != Path(notes).read_text(encoding="utf-8") or len(entries) != 1):
            raise PublishError("The manifest identity, notes or compatibility metadata is invalid.")
        entry = entries[0]
        url = entry.get("browser_download_url", "")
        if (entry.get("name") != image_name or entry.get("size") != paths[image_name].stat().st_size
                or entry.get("digest") != "sha256:" + digest
                or not re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/"
                                    + re.escape(tag + "/" + image_name), url)):
            raise PublishError("The manifest asset does not match the image.")
        return paths
    except (OSError, ValueError, TypeError, AttributeError) as error:
        raise PublishError(f"Cannot validate release assets: {error}") from error


def verify_uploaded(tag, paths, run):
    completed = run(["gh", "release", "view", tag, "--json", "assets,isDraft,tagName"])
    try:
        release = json.loads(completed.stdout)
        entries = release["assets"]
        uploaded = {entry["name"]: entry for entry in entries}
        if release["isDraft"] is not True or release["tagName"] != tag:
            raise PublishError("The uploaded release is not the expected draft.")
        if set(uploaded) != set(paths) or len(uploaded) != len(entries):
            raise PublishError("The draft does not contain exactly the required assets.")
        for name, path in paths.items():
            entry = uploaded[name]
            if entry.get("size") != path.stat().st_size:
                raise PublishError(f"Uploaded size mismatch: {name}")
            if entry.get("digest"):
                with path.open("rb") as handle:
                    digest = "sha256:" + hashlib.file_digest(handle, "sha256").hexdigest()
                if entry["digest"] != digest:
                    raise PublishError(f"Uploaded digest mismatch: {name}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise PublishError(f"Cannot verify uploaded assets: {error}") from error


def publish(tag, notes, assets, run=runner, dry_run=False):
    promotes_to_latest(tag, [])  # Refuse malformed versions before any mutation.
    paths = validate_assets(tag, notes, assets)
    action = plan(lookup(tag, run))
    if action == REFUSE:
        raise PublishError(
            f"{tag} is already published. Uploading over it would remove the live download first, "
            "which is what the draft-first order exists to prevent. Cut the next version, or delete "
            "that release by hand if it was a mistake."
        )
    for command in draft_commands(tag, action, notes, assets):
        if dry_run:
            print(f"{MARK.step} {' '.join(command)}")
            continue
        run(command)
    if not dry_run:
        verify_uploaded(tag, paths, run)
    # This check must be inside the workflow's repository-wide publish lock and
    # after the potentially slow upload. Never reuse a pre-upload decision.
    latest = promotes_to_latest(tag, published_versions(run))
    promotion = ["gh", "release", "edit", tag, "--draft=false", "--latest" if latest else "--latest=false"]
    if dry_run:
        print(f"{MARK.step} {' '.join(promotion)}")
    else:
        run(promotion)
    return action, latest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True, help="Version tag the release belongs to.")
    parser.add_argument("--notes", required=True, help="Markdown file holding the release body.")
    parser.add_argument("--dry-run", action="store_true", help="Print the gh commands and run none of them.")
    parser.add_argument("assets", nargs="+", help="Files to upload, disk image first.")
    args = parser.parse_args(argv)
    for path in [args.notes, *args.assets]:
        if not Path(path).is_file():
            raise PublishError(f"Not a file: {path}")
    action, latest = publish(args.tag, args.notes, args.assets, dry_run=args.dry_run)
    verb = ("Would create and publish" if action == CREATE else "Would finish the draft for") if args.dry_run else (
        "Created and published" if action == CREATE else "Finished the draft for")
    mark = "Latest" if latest else "not Latest: a greater version is already public"
    print(f"{MARK.ok} {verb} {args.tag} ({mark}): {', '.join(Path(asset).name for asset in args.assets)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PublishError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
