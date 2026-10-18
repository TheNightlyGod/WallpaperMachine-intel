"""Guard the control panel's localized literals against the app's string catalog, without Xcode.

SwiftUI looks a literal up in `App/Resources/Localizable.xcstrings` by its exact text: a
`Text("…")`, `Button("…")` or `L("…")` whose literal is not a catalog key renders English in
every language, silently. Interpolations become format arguments (`\\(count)` is `%lld` for an
integer and `%@` for a string), so a literal matches when some choice of argument types makes
it a key. This scans the panel's Swift sources for the literals SwiftUI and `L()` localize, and
fails for one that no key matches or whose key a shipped language lacks. The catalogs' own
shape (placeholders, escaping, completeness) is `test_localization_catalogs`'s. See
docs/localization.md.
"""
import itertools
import json
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_localization_catalogs import ROOT, SOURCE_LANGUAGE, swift_languages  # noqa: E402

PANEL = ROOT / "App/Views/ControlPanel"
CATALOG = ROOT / "App/Resources/Localizable.xcstrings"
# The calls whose first, unlabelled string literal is a localization key: `L()` and the SwiftUI
# initializers that take a `LocalizedStringKey` (a `Text(verbatim:)` or a variable is not one).
LOCALIZING_CALL = re.compile(
    r'(?<![\w.])(L|Text|Button|Label|Toggle|Section|Picker|Menu|TextField|SecureField|Link'
    r'|LabeledContent)\(\s*"(?!"")'
)
# What SwiftUI and `String.LocalizationValue` write for an interpolated value: an integer, a
# string or other object, a double, a float.
ARGUMENT_FORMATS = ["%lld", "%@", "%lf", "%f", "%d"]
SHOWN = 12


class Literal:
    """A string literal as the catalog sees it: the text, and one slot per interpolation."""

    def __init__(self, parts, file, line):
        self.parts = parts  # text pieces; between two pieces sits one interpolated argument
        self.file = file
        self.line = line

    @property
    def arguments(self):
        return len(self.parts) - 1

    def keys(self):
        """Every key the literal can stand for, one per choice of argument formats. A literal with
        arguments is a format string, whose own `%` is written `%%`."""
        parts = [part.replace("%", "%%") for part in self.parts] if self.arguments else self.parts
        for formats in itertools.product(ARGUMENT_FORMATS, repeat=self.arguments):
            key = parts[0]
            for form, part in zip(formats, parts[1:]):
                key += form + part
            yield key

    def __str__(self):
        shown = "\\(…)".join(self.parts)
        return f"{self.file.relative_to(ROOT)}:{self.line}: \"{shown}\""


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def skip_interpolation(text, index):
    """The index just past the `)` that closes the interpolation whose `(` is at `index`, skipping
    nested parentheses and the string literals inside it."""
    depth = 0
    while index < len(text):
        char = text[index]
        if char == '"':
            index = read_literal(text, index + 1)[1]
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    raise ValueError("unterminated interpolation")


def read_literal(text, index):
    """The pieces of the single-line literal whose text starts at `index` (just past its opening
    quote), and the index just past its closing quote."""
    parts, current = [], ""
    while index < len(text):
        char = text[index]
        if char == '"':
            parts.append(current)
            return parts, index + 1
        if char == "\n":
            raise ValueError("unterminated literal")
        if char == "\\":
            following = text[index + 1]
            if following == "(":
                parts.append(current)
                current = ""
                index = skip_interpolation(text, index + 1)
                continue
            if following == "u":
                close = text.index("}", index)
                current += chr(int(text[index + 3:close], 16))
                index = close + 1
                continue
            current += ESCAPES.get(following, following)
            index += 2
            continue
        current += char
        index += 1
    raise ValueError("unterminated literal")


def strip_comments(source):
    """`source` with `//` comments blanked out (line numbers kept), so commented-out code and
    prose are not read as calls. A `//` inside a string literal is left alone."""
    lines = []
    for line in source.splitlines():
        in_string, index = False, 0
        while index < len(line):
            if line[index] == "\\" and in_string:
                index += 2
                continue
            if line[index] == '"':
                in_string = not in_string
            elif not in_string and line.startswith("//", index):
                line = line[:index]
                break
            index += 1
        lines.append(line)
    return "\n".join(lines)


def panel_literals():
    """Every literal a localizing call in the panel's sources passes as its key."""
    found = []
    for path in sorted(PANEL.rglob("*.swift")):
        source = strip_comments(path.read_text())
        for match in LOCALIZING_CALL.finditer(source):
            parts, _ = read_literal(source, match.end())
            line = source.count("\n", 0, match.start()) + 1
            found.append(Literal(parts, path, line))
    return found


def is_text(literal):
    """Whether the literal holds words to translate; a symbol, a number or a bare argument is
    shown as it is in every language."""
    return any(char.isalpha() for char in "".join(literal.parts))


class PanelLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads(CATALOG.read_text())["strings"]
        cls.literals = panel_literals()

    def test_the_scan_reads_the_panels_sources(self):
        """A pattern that stopped matching would pass everything: the panel has many literals."""
        self.assertGreater(len(self.literals), 300)
        self.assertTrue(any(literal.arguments for literal in self.literals))

    def test_every_localized_literal_is_a_catalog_key(self):
        missing = [
            str(literal) for literal in self.literals
            if is_text(literal) and not any(key in self.catalog for key in literal.keys())
        ]
        self.assertFalse(
            missing,
            "\n  ".join(
                [f"{len(missing)} literal(s) without a key in {CATALOG.relative_to(ROOT)} "
                 "(they render English in every language):"] + missing[:SHOWN]))

    def test_the_keys_the_panel_uses_are_translated_in_every_shipped_language(self):
        languages = [tag for tag in swift_languages() if tag != SOURCE_LANGUAGE]
        untranslated = []
        for literal in self.literals:
            key = next((key for key in literal.keys() if key in self.catalog), None)
            if key is None:
                continue
            units = self.catalog[key].get("localizations", {})
            for tag in languages:
                value = units.get(tag, {}).get("stringUnit", {}).get("value")
                if not value and self.catalog[key].get("shouldTranslate", True):
                    untranslated.append(f"{literal} has no {tag}")
        self.assertFalse(untranslated, "\n  ".join(untranslated[:SHOWN]))


class LiteralReadingTests(unittest.TestCase):
    def read(self, source):
        match = LOCALIZING_CALL.search(source)
        self.assertIsNotNone(match, source)
        return Literal(read_literal(source, match.end())[0], ROOT / "x.swift", 1)

    def test_interpolations_become_arguments_of_every_kind(self):
        literal = self.read('Text("\\(count) wallpapers")')
        self.assertIn("%lld wallpapers", set(literal.keys()))
        self.assertIn("%@ wallpapers", set(literal.keys()))

    def test_a_percent_sign_beside_an_argument_is_escaped(self):
        self.assertIn("Downloading %lld%%", set(self.read('L("Downloading \\(percent)%")').keys()))
        self.assertEqual(list(self.read('Text("100%")').keys()), ["100%"], "no argument, no format")

    def test_nested_calls_and_strings_inside_an_interpolation_are_skipped(self):
        literal = self.read('L("Remove from “\\(names.joined(separator: ", "))”")')
        self.assertEqual(literal.parts, ["Remove from “", "”"])

    def test_escapes_are_the_characters_they_stand_for(self):
        self.assertEqual(self.read('Text("A \\"quoted\\" word\\u{2026}")').parts, ['A "quoted" word…'])

    def test_verbatim_text_and_variables_are_not_keys(self):
        self.assertIsNone(LOCALIZING_CALL.search('Text(verbatim: "pixiv")'))
        self.assertIsNone(LOCALIZING_CALL.search("Text(title)"))
        self.assertIsNone(LOCALIZING_CALL.search('row.Label("x")'))

    def test_comments_are_not_read_as_calls(self):
        self.assertEqual(strip_comments('let a = 1 // Text("Old")'), "let a = 1 ")
        self.assertEqual(strip_comments('Text("a // b")'), 'Text("a // b")')


if __name__ == "__main__":
    unittest.main()
