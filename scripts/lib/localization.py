"""The language registry and the string-format rules the catalogs must keep.

`AppLanguage.supported` (Swift) is the one list of shipped languages; the catalog test
and the Crowdin sync both read it from there. A translation is also a format string for
Foundation, so it must take the same arguments as its key and escape `%` exactly where
the string is a format. See docs/localization.md.
"""
from __future__ import annotations

from collections import Counter
import re

from lib.paths import ROOT

SOURCE_LANGUAGE = "en"
APP_LANGUAGE = ROOT / "App/Services/Localization/AppLanguage.swift"

# A format argument as the catalogs write one: `%@`, `%lld`, `%d`, `%u`, `%f`, with an optional
# position (`%2$@`). No flags or widths: those never appear, and without them a raw `% o` in
# "1% of a battery" is not mistaken for an argument.
ARGUMENT = re.compile(r"%(?:(\d+)\$)?((?:hh|h|ll|l|z|j|t|q)?[@diuxXfs])")


def swift_languages():
    """Tags of `AppLanguage.supported`, English first, in picker order."""
    source = APP_LANGUAGE.read_text()
    body = source[source.index("static let supported"):]
    body = body[body.index("= [") + 3:]
    body = body[:body.index("]")]
    tags = []
    for line in body.splitlines():
        if re.match(r"\s*english,", line):
            tags.append(SOURCE_LANGUAGE)
        tags.extend(re.findall(r'AppLanguage\(tag: "([^"]+)"', line))
    return tags


def arguments(text):
    """Multiset of argument types in a string, positions ignored (`%1$@` and `%@` agree)."""
    return Counter(kind for _, kind in ARGUMENT.findall(text.replace("%%", "")))


def stray_percent(text):
    """A `%` that is neither an escaped `%%` nor an argument; Foundation misreads it in a format."""
    return "%" in ARGUMENT.sub("", text.replace("%%", ""))


def translation_problem(key, value):
    """Why `value` cannot be the translation of `key`, or None when it can.

    The same rules as scripts/tests/test_localization_catalogs.py, so a translation that
    would fail the gate is caught before it is written into a catalog.
    """
    if not value.strip():
        return "blank"
    want = arguments(key)
    if arguments(value) != want:
        return f"takes {dict(arguments(value))} instead of {dict(want)}"
    positions = [position for position, _ in ARGUMENT.findall(value.replace("%%", ""))]
    if any(positions) and not all(positions):
        return "mixes positional and plain arguments"
    if want and stray_percent(value):
        return "has an unescaped % in a format string"
    if not want and "%%" in value:
        return "has %% in a string that is not a format"
    return None
