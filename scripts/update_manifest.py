#!/usr/bin/env python3
"""Write the update manifest the in-app updater reads instead of the GitHub API.

Anonymous GitHub API requests are limited to 60 an hour per public IP address, shared
by every app and device behind it, so a busy network can leave the updater locked out.
A release asset is not an API request: the app fetches
`https://github.com/<repository>/releases/latest/download/WallpaperMachine-update.json`,
which github.com redirects to this file on the release marked Latest.

The manifest is the release object in the REST API's shape (`tag_name`, `html_url`,
`prerelease`, `body`, `assets` with `browser_download_url`, `size` and a `sha256:`
`digest`), so the app parses both with `GitHubReleaseParser`. Everything in it is
derived from the tag, the notes file that becomes the release body, the changelog and
the image bytes;
the name is `AppUpdateConfiguration.manifestName` in the app.

`--changelog` adds one field the API does not have: `changelog`, the newest 20
(CHANGELOG_SECTIONS) `## ` version sections of CHANGELOG.md verbatim, in all their
languages, without the file's preamble. The app's update window shows the sections of
every version newer than the installed one from it, so an update across several
versions lists them all; a manifest without the field falls back to `body`.

    python3 scripts/update_manifest.py --tag v1.0.3 --repository owner/name --notes notes.md \\
        --changelog CHANGELOG.md WallpaperMachine-1.0.3-arm64.dmg

Called by .github/workflows/build.yml before publishing; writes the manifest beside the
image and prints its path.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

from lib.dmg import image_name
from lib.glyphs import markers

MARK = markers()
MANIFEST_NAME = "WallpaperMachine-update.json"
VERSION_TAG = re.compile(r"^v(\d+\.\d+\.\d+)$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
# How many versions an update window can list: an install this many releases behind
# still sees every change, and the manifest stays small.
CHANGELOG_SECTIONS = 20
# A release heading, `## [1.6.2](<compare link>) (2026-10-24)` or the older `## 1.6.2 — 2026-10-24`.
SECTION_HEADING = re.compile(r"^## \[?v?(\d+\.\d+\.\d+)(?:\]|[ \t]|$)", re.MULTILINE)


class ManifestError(Exception):
    """A condition that stops writing the manifest; the message is the whole report."""


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def changelog_sections(path, tag, limit=CHANGELOG_SECTIONS):
    """The newest `limit` version sections of a changelog, verbatim, without its preamble.

    The release's own version must be the newest section, so a manifest never describes
    notes the window cannot show: the app reads the history only when it starts there.
    """
    text = Path(path).read_text(encoding="utf-8")
    starts = [match.start() for match in re.finditer(r"^## ", text, re.MULTILINE)]
    if not starts:
        raise ManifestError(f"{path} has no ## version sections.")
    versions = SECTION_HEADING.findall(text)
    if not versions or versions[0] != tag.removeprefix("v"):
        raise ManifestError(f"{path} does not start with the section for {tag}.")
    end = starts[limit] if len(starts) > limit else len(text)
    return text[starts[0]:end].rstrip("\n") + "\n"


def manifest(tag, repository, notes, image, changelog=None, metadata=None):
    """The manifest for one release, as a dict ready for JSON; `changelog` adds its sections."""
    match = VERSION_TAG.match(tag)
    if not match:
        raise ManifestError(f"{tag!r} is not a release tag like v1.2.3.")
    if not REPOSITORY.match(repository):
        raise ManifestError(f"{repository!r} is not an owner/name repository.")
    image = Path(image)
    expected = image_name(match.group(1))
    if image.name != expected:
        raise ManifestError(f"{image.name} is not {expected}, the image the updater installs for {tag}.")
    base = f"https://github.com/{repository}/releases"
    content = {
        "tag_name": tag,
        "html_url": f"{base}/tag/{tag}",
        "prerelease": False,
        "body": Path(notes).read_text(encoding="utf-8"),
        "assets": [{
            "name": image.name,
            "browser_download_url": f"{base}/download/{tag}/{image.name}",
            "size": image.stat().st_size,
            "digest": f"sha256:{sha256(image)}",
        }],
    }
    if changelog is not None:
        content["changelog"] = changelog_sections(changelog, tag)
    if metadata is not None:
        facts = json.loads(Path(metadata).read_text(encoding="utf-8"))
        expected_facts = {"image": image.name, "version": match.group(1), "size": image.stat().st_size,
                          "sha256": content["assets"][0]["digest"].removeprefix("sha256:"),
                          "bundle_identifier": "app.wallpapermachine"}
        if any(facts.get(key) != value for key, value in expected_facts.items()):
            raise ManifestError("Build metadata does not match the verified disk image and tag.")
        minimum = facts.get("minimum_system_version")
        architectures = facts.get("architectures")
        if not isinstance(minimum, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", minimum):
            raise ManifestError("Build metadata has no valid minimum macOS version.")
        if not isinstance(architectures, list) or "arm64" not in architectures or any(
                arch not in ("arm64", "arm64e", "x86_64") for arch in architectures):
            raise ManifestError("Build metadata has no supported architecture list.")
        content.update(minimum_system_version=minimum, architectures=architectures,
                       bundle_identifier=facts["bundle_identifier"])
    return content


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True, help="Version tag the release belongs to, like v1.2.3.")
    parser.add_argument("--repository", required=True, help="owner/name of the repository the release is in.")
    parser.add_argument("--notes", required=True, help="Markdown file that becomes the release body.")
    parser.add_argument("--changelog", help=f"CHANGELOG.md whose newest {CHANGELOG_SECTIONS} sections the manifest carries.")
    parser.add_argument("--metadata", help="Digest-bound metadata from the verified signed disk image; required by release CI.")
    parser.add_argument("image", help="The disk image the release publishes.")
    args = parser.parse_args(argv)
    for path in (args.notes, args.image, *([args.changelog] if args.changelog else [])):
        if not Path(path).is_file():
            raise ManifestError(f"Not a file: {path}")
    output = Path(args.image).with_name(MANIFEST_NAME)
    content = manifest(args.tag, args.repository, args.notes, args.image, args.changelog, args.metadata)
    output.write_text(json.dumps(content, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(output)
    print(f"{MARK.ok} {output.name} for {args.tag}: {content['assets'][0]['digest']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
