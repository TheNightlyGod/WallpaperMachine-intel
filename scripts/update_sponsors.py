#!/usr/bin/env python3
"""Rewrite the READMEs' Supporter list from the website's thank-you wall.

The website lists every Priority Support member who turned the listing on in their
account and still holds a purchase that was not refunded, earliest first, and counts
the ones who stay private (https://www.wallpapermachine.app/#sponsors). It serves the same
list, names and months only, at /api/sponsors, with a version that changes whenever
the wall does, and draws the wall as one picture at /sponsors/wall: its portraits,
names and months on the brand wallpaper. This reads the list and rewrites the block
between the `supporters:start` and `supporters:end` markers under README.md's
"Thank you. To every Priority Support member." heading, and under its translations' in
README.zh-CN.md, README.pt-BR.md and README.ko.md: the picture, linked to the wall, at /sponsors/wall?v=<version>, so
GitHub's image proxy fetches it again when the wall changes, with every listed name
and the count in its alt text. A member who turns the listing on, off, renames it
or changes their picture is followed here too. Nothing outside the markers changes.

    python3 scripts/update_sponsors.py                       # read the live wall, rewrite the list
    python3 scripts/update_sponsors.py --check               # exit 1 when a list is out of date
    python3 scripts/update_sponsors.py --input sponsors.json # a saved answer instead of the wall

The Supporters workflow (.github/workflows/supporters.yml) runs it every hour and
commits the READMEs when the list changed. A failed or malformed answer, or a README
without its block, leaves every README as it was.
"""
from __future__ import annotations

import argparse
import json
import hashlib
import html
from pathlib import Path
import re
import sys
from typing import NamedTuple
import urllib.error
import urllib.parse
import urllib.request

from lib.glyphs import markers
from lib.paths import ROOT

MARK = markers()
# Every README that carries the list: the English page and its translations.
READMES = (ROOT / "README.md", ROOT / "README.zh-CN.md", ROOT / "README.pt-BR.md", ROOT / "README.ko.md")
SOURCE = "https://www.wallpapermachine.app/api/sponsors"
# The picture and the wall it links to, on the same site as the list.
PICTURE_PATH = "/sponsors/wall"
WALL_PATH = "/#sponsors"
VERSION = re.compile(r"^[0-9A-Za-z_-]{1,64}$")
USER_AGENT = "WallpaperMachine/1.0 (README Supporter list; scripts/update_sponsors.py)"
TIMEOUT_SECONDS = 30

START = "<!-- supporters:start: written by scripts/update_sponsors.py from the website's thank-you wall; edits here are overwritten -->"
END = "<!-- supporters:end -->"
BLOCK = re.compile(r"<!-- supporters:start\b.*?-->.*?<!-- supporters:end -->", re.DOTALL)

# Characters HTML or Markdown give a meaning. Names are the members' own words, so
# none of them may become a tag, a link, an image or one of the markers above.
SIGNIFICANT = re.compile(r"[&<>\"'`*_\[\]()\\~|#!]")
# Control and format characters, which the website already drops from names.
INVISIBLE = re.compile(r"[\x00-\x1f\x7f-\x9f\u200b\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]")


class Wall(NamedTuple):
    """The thank-you wall: listed names, earliest first, the private count and the
    version the website gives the wall's current state."""

    names: tuple[str, ...]
    hidden: int
    version: str


def parse_wall(payload: object) -> Wall:
    """The wall from /api/sponsors' JSON; ValueError when it is not that shape."""
    if not isinstance(payload, dict):
        raise ValueError("the answer is not a JSON object")
    supporters = payload.get("supporters")
    hidden = payload.get("hidden")
    if not isinstance(supporters, list):
        raise ValueError("`supporters` is not a list")
    if not isinstance(hidden, int) or isinstance(hidden, bool) or hidden < 0:
        raise ValueError("`hidden` is not a count")
    names = []
    for supporter in supporters:
        name = supporter.get("name") if isinstance(supporter, dict) else None
        if not isinstance(name, str):
            raise ValueError("a Supporter has no name")
        name = " ".join(INVISIBLE.sub("", name).split())
        if name:
            names.append(name)
    version = payload.get("version")
    if version is None:
        # A site from before the picture: the names and the count stand in, so the
        # picture's address still changes with them.
        state = json.dumps([names, hidden], ensure_ascii=False).encode("utf-8")
        version = hashlib.sha256(state).hexdigest()[:12]
    elif not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError("`version` is not a version")
    return Wall(tuple(names), hidden, version)


def fetch_wall(source: str) -> Wall:
    """The wall as the website serves it now."""
    request = urllib.request.Request(
        source, headers={"Accept": "application/json", "User-Agent": USER_AGENT}
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        body = response.read()
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as error:
        raise ValueError(f"the answer is not JSON ({error.msg})") from error
    return parse_wall(payload)


def escape(name: str) -> str:
    """A name as literal text inside a README's HTML, attribute values included."""
    return SIGNIFICANT.sub(lambda match: f"&#{ord(match.group())};", name)


def plural(count: int, one: str, many: str) -> str:
    return f"{count:,} {one if count == 1 else many}"


def count_line(wall: Wall) -> str:
    """The count, as the website words it over the wall and in the picture."""
    shown = len(wall.names)
    if shown:
        line = f"{plural(shown, 'Priority Support member', 'Priority Support members')} on the wall."
        if wall.hidden:
            line += f" {plural(wall.hidden, 'more stays', 'more stay')} private."
        return line
    if wall.hidden:
        return f"{plural(wall.hidden, 'Priority Support member', 'Priority Support members')} so far, all private."
    return "No one is on the wall yet."


def alt_text(wall: Wall) -> str:
    """What the picture shows, in words: every listed name, then the count."""
    if wall.names:
        return f"WallpaperMachine Priority Support members: {', '.join(wall.names)}. {count_line(wall)}"
    return f"WallpaperMachine Priority Support members. {count_line(wall)}"


def render(wall: Wall, source: str = SOURCE) -> str:
    """The block between the markers, markers included: the picture of the wall on
    the site `source` belongs to, linked to the wall."""
    picture = urllib.parse.urljoin(source, PICTURE_PATH) + "?v=" + wall.version
    page = urllib.parse.urljoin(source, WALL_PATH)
    # One HTML block: GitHub renders it as written, never as Markdown.
    return "\n".join([
        START,
        '<p align="center">',
        f'  <a href="{html.escape(page)}"><img src="{html.escape(picture)}" width="100%" alt="{escape(alt_text(wall))}"></a>',
        "</p>",
        END,
    ])


def rewrite(text: str, wall: Wall, source: str = SOURCE) -> str:
    """A README's text with its Supporter list replaced; ValueError without the markers."""
    matches = BLOCK.findall(text)
    if len(matches) != 1:
        raise ValueError(f"expected one supporters:start … supporters:end block, found {len(matches)}")
    return BLOCK.sub(lambda _: render(wall, source), text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default=SOURCE, help=f"the thank-you wall's JSON (default {SOURCE})")
    parser.add_argument("--input", type=Path, help="read the wall from this JSON file instead of --source")
    parser.add_argument("--check", action="store_true", help="change nothing; exit 1 when a README is out of date")
    args = parser.parse_args()

    try:
        if args.input:
            wall = parse_wall(json.loads(args.input.read_text(encoding="utf-8")))
        else:
            wall = fetch_wall(args.source)
        # Every README is rewritten in memory first, so one without its block
        # leaves all of them as they were.
        changes = []
        for readme in READMES:
            before = readme.read_text(encoding="utf-8")
            try:
                after = rewrite(before, wall, args.source)
            except ValueError as error:
                raise ValueError(f"{readme.name}: {error}") from error
            if after != before:
                changes.append((readme, after))
    except (OSError, ValueError, urllib.error.URLError) as error:
        print(f"{MARK.missing} Could not update the Supporter list: {error}", file=sys.stderr)
        return 1

    summary = f"{plural(len(wall.names), 'member', 'members')} listed, {wall.hidden:,} private"
    names = ", ".join(readme.name for readme, _ in changes)
    if not changes:
        print(f"{MARK.ok} The READMEs are up to date: {summary}.")
        return 0
    if args.check:
        print(f"{MARK.warn} Out of date: {names}; the wall has {summary}.")
        return 1
    for readme, after in changes:
        readme.write_text(after, encoding="utf-8")
    print(f"{MARK.step} Updated {names}: {summary}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
