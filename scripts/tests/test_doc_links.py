#!/usr/bin/env python3
"""Check that every relative Markdown link names an existing file and, with `#anchor`, a heading or id there."""
# GitHub derives a heading's anchor from its rendered text: lowercased, punctuation and symbols
# removed, each space a hyphen, and `-1`, `-2` … appended to repeats. A link whose heading was
# renamed still opens the page, at the top, so nothing shows it is broken. Inline links, HTML
# links and reference definitions (`[label]: target`) are checked; `#` and setext headings both
# define anchors. External links, links inside code and anchors into files other than Markdown
# are out of scope. The archives are history and are not checked, though a current page may
# link into them.
from collections import Counter
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unicodedata
import unittest
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib.paths import ROOT  # noqa: E402

UNCHECKED = ("docs/archive/", "docs/testing/archive/", "ThirdParty/")
SHOWN = 12

# A fence opens with three or more backticks or tildes and closes with at least as many of the
# same, alone on its line, so a shorter or other fence inside the block is code.
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
HEADING = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
SETEXT_UNDERLINE = re.compile(r"^ {0,3}(=+|-+)\s*$")
REFERENCE_DEFINITION = re.compile(r"^ {0,3}\[[^\]]+\]:[ \t]*<?([^\s>]+)>?", re.M)
# A scheme (`https:`, `mailto:`) or a scheme-relative `//host` leads off the repository.
EXTERNAL = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//)", re.I)
COMMENT = re.compile(r"<!--.*?-->", re.S)
INLINE_CODE = re.compile(r"(`+)(.+?)\1")
# A paragraph: lines up to the next blank one.
PARAGRAPH = re.compile(r"(?:[^\n]|\n(?![ \t]*\n))+")
# A code span may carry on to the next line of its paragraph, though not past a blank line.
CODE_SPAN = re.compile(r"(`+)(?:.|\n(?![ \t]*\n))+?\1")
# `[text](target)` and `![alt](target)`, the target without its optional title.
MARKDOWN_LINK = re.compile(r"(?<!\\)!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
HTML_LINK = re.compile(r"""<(?:a|img)\b[^>]*?\b(?:href|src)\s*=\s*["']([^"']+)["']""", re.I)
EXPLICIT_ANCHOR = re.compile(r"""<a\b[^>]*?\b(?:id|name)\s*=\s*["']([^"']+)["']""", re.I)


def markdown_files():
    listed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.split("\n")
    return sorted({ROOT / name for name in listed if name and (ROOT / name).is_file()})


def prose_lines(text):
    """The page's lines outside fenced code, with their numbers, comments and inline code
    removed (both keep their line breaks, so the numbers stay true)."""
    text = COMMENT.sub(lambda match: "\n" * match.group(0).count("\n"), text)
    fence = None
    for number, line in enumerate(text.split("\n"), start=1):
        match = FENCE.match(line)
        if fence is None:
            if match and not (match.group(1)[0] == "`" and "`" in match.group(2)):
                fence = match.group(1)
            else:
                yield number, line
        elif match and match.group(1)[0] == fence[0] and len(match.group(1)) >= len(fence) \
                and not match.group(2).strip():
            fence = None


def heading_text(source):
    """What GitHub renders for a heading's Markdown: the words of links, code and emphasis."""
    text = re.sub(r"!?\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^)]*\)", r"\1", source)
    text = INLINE_CODE.sub(lambda match: match.group(2).strip(), text)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"(?<!\w)(\*{1,3}|_{1,3})(\S(?:.*?\S)?)\1(?!\w)", r"\2", text)
    return text.strip()


def slug(text):
    """GitHub's anchor for a heading's rendered text (github-slugger): lowercase; keep letters,
    marks, numbers, `_`, `-` and spaces; each space becomes `-`."""
    kept = (
        char for char in text.lower()
        if char in "-_ " or unicodedata.category(char)[0] in "LMN"
    )
    return "".join(kept).replace(" ", "-")


_ANCHORS = {}


def anchors(path):
    """Every anchor a page defines: its headings' slugs, repeats numbered, and explicit ids."""
    headings, ids = page_anchors(path)
    return headings | ids


def page_anchors(path):
    """`(heading slugs, explicit ids)` of a page. A setext heading is a line of text
    underlined with `=` or `-` on the next line."""
    if path not in _ANCHORS:
        found, ids, seen = set(), set(), Counter()

        def add(heading):
            base = slug(heading_text(heading))
            found.add(f"{base}-{seen[base]}" if seen[base] else base)
            seen[base] += 1

        text = path.read_text(encoding="utf-8")
        previous = None
        for number, line in prose_lines(text):
            match = HEADING.match(line)
            if match:
                add(match.group(2))
                previous = None
            elif previous and previous[0] == number - 1 and SETEXT_UNDERLINE.match(line):
                add(previous[1])
                previous = None
            else:
                previous = (number, line.strip()) if line.strip() else None
            ids.update(EXPLICIT_ANCHOR.findall(line))
        _ANCHORS[path] = (found, ids)
    return _ANCHORS[path]


def has_anchor(path, fragment):
    """A heading's slug is lowercase, so a fragment matches it in any case; an explicit
    id matches only as written, as a browser compares it."""
    headings, ids = page_anchors(path)
    return fragment in ids or fragment.lower() in headings


def links(path):
    """The page's relative link targets, with their line numbers."""
    prose = dict(prose_lines(path.read_text(encoding="utf-8")))
    text = "\n".join(prose.get(number, "") for number in range(1, max(prose, default=0) + 1))
    text = CODE_SPAN.sub(lambda match: "\n" * match.group(0).count("\n"), text)
    # Read a paragraph at a time, so a link wrapped onto the next line is still one link but
    # none runs on past a blank line.
    for paragraph in PARAGRAPH.finditer(text):
        found = [
            match for pattern in (MARKDOWN_LINK, HTML_LINK, REFERENCE_DEFINITION)
            for match in pattern.finditer(paragraph.group(0))
        ]
        for match in sorted(found, key=lambda match: match.start()):
            target = match.group(1)
            if not EXTERNAL.match(target):
                yield text.count("\n", 0, paragraph.start() + match.start()) + 1, target


def broken(path):
    """Each link of the page that leads nowhere, as `file:line: target (reason)`."""
    for number, target in links(path):
        location, _, anchor = target.partition("#")
        location = unquote(location.split("?")[0])
        destination = path if not location else (
            (ROOT / location.lstrip("/")) if location.startswith("/") else path.parent / location
        ).resolve()
        where = f"{path.relative_to(ROOT)}:{number}: {target}"
        if not destination.exists():
            yield f"{where} (no such file)"
        elif anchor and destination.suffix == ".md" and not has_anchor(destination, unquote(anchor)):
            yield f"{where} (no such heading)"


class DocLinkTests(unittest.TestCase):
    def test_slug_matches_github(self):
        cases = {
            "Switching wallpapers without a black gap": "switching-wallpapers-without-a-black-gap",
            "`scripts/check_renderer.py`": "scriptscheck_rendererpy",
            "10-bit and HDR video textures": "10-bit-and-hdr-video-textures",
            "C/C++ (CMake) test binaries": "cc-cmake-test-binaries",
            "Recovering a failed release": "recovering-a-failed-release",
            "开发与贡献": "开发与贡献",
            "What “verified” means": "what-verified-means",
        }
        for heading, expected in cases.items():
            with self.subTest(heading=heading):
                self.assertEqual(slug(heading_text(heading)), expected)

    def test_repeated_headings_are_numbered(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text("# Limits\n\n## Limits\n\n```\n# not a heading\n```\n", encoding="utf-8")
            self.assertEqual(anchors(page), {"limits", "limits-1"})

    def test_setext_headings_define_anchors(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text("Setup\n=====\n\nNext steps\n---\n\ntext\n\n---\n", encoding="utf-8")
            self.assertEqual(anchors(page), {"setup", "next-steps"})

    def test_a_longer_fence_holds_a_shorter_one_as_code(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text(
                "````md\n```\n[example](missing.md)\n```\n````\n\n[real](missing.md)\n", encoding="utf-8")
            self.assertEqual([number for number, _ in links(page)], [7])

    def test_reference_definitions_are_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text("[guide][install]\n\n[install]: missing.md#setup\n", encoding="utf-8")
            self.assertEqual(list(links(page)), [(3, "missing.md#setup")])

    def test_escaped_and_scheme_relative_links_are_not_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text(
                "\\[guide](missing.md) and [site](//example.com/guide)\n\n[real](missing.md)\n", encoding="utf-8")
            self.assertEqual([number for number, _ in links(page)], [3])

    def test_an_explicit_id_matches_only_as_written(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text('<a id="FAQ"></a>\n\n# Setup\n', encoding="utf-8")
            self.assertTrue(has_anchor(page, "FAQ"))
            self.assertFalse(has_anchor(page, "faq"))
            self.assertTrue(has_anchor(page, "Setup"))

    def test_a_link_wrapped_onto_the_next_line_is_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text("See the [guide](\nmissing.md) first.\n", encoding="utf-8")
            self.assertEqual(list(links(page)), [(1, "missing.md")])

    def test_a_link_does_not_run_on_past_a_blank_line(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text("See the [guide](\n\nmissing.md) first.\n", encoding="utf-8")
            self.assertEqual(list(links(page)), [])

    def test_a_code_span_over_two_lines_holds_no_link(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text("Say `thanks to\n[@login](…) here` once.\n\n[real](missing.md)\n", encoding="utf-8")
            self.assertEqual([number for number, _ in links(page)], [4])

    def test_relative_links_lead_somewhere(self):
        pages = [
            page for page in markdown_files()
            if not str(page.relative_to(ROOT)).startswith(UNCHECKED)
        ]
        self.assertTrue(pages, "found no Markdown pages to check")
        failures = [failure for page in pages for failure in broken(page)]
        if failures:
            self.fail(
                f"{len(failures)} broken link(s):\n" + "\n".join(failures[:SHOWN])
                + ("\n…" if len(failures) > SHOWN else "")
            )


if __name__ == "__main__":
    unittest.main()
