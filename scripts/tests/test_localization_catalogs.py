"""Guard the shipped string catalogs and the language registry without Xcode.

Every language the app ships is declared in `AppLanguage.supported` (Swift) and must be
translated, completely, in both shipped catalogs: `App/Resources/Localizable.xcstrings`
(the app and its SwiftUI panel) and `Extension/Localizable.xcstrings` (the lock-screen
extension). The catalogs also have to survive being
used as format strings: a translation must take the same arguments as its key, and a literal
`%` must be escaped exactly where Foundation reads the string as a format. See
docs/localization.md.
"""
import json
from pathlib import Path
import re
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from lib.localization import ARGUMENT, SOURCE_LANGUAGE, arguments, stray_percent, swift_languages  # noqa: E402

ROOT = SCRIPTS.parent
CATALOGS = [
    ROOT / "App/Resources/Localizable.xcstrings",
    ROOT / "Extension/Localizable.xcstrings",
]
# `${name}` is how App Intents parameter summaries refer to a parameter; it is not a leftover.
PLACEHOLDER = re.compile(r"(?<!\$)\{\w+\}")
SHOWN = 8


def load(path):
    """Parse a catalog, keeping every `strings` key so a duplicate can be reported."""
    duplicates = []

    def pairs(items):
        seen = {}
        for key, value in items:
            if key in seen:
                duplicates.append(key)
            seen[key] = value
        return seen

    return json.loads(path.read_text(), object_pairs_hook=pairs), duplicates


def values(entry):
    """(language, value, state) of every unit of an entry."""
    for tag, unit in entry.get("localizations", {}).items():
        string = unit.get("stringUnit", {})
        yield tag, string.get("value"), string.get("state")


def report(problems):
    return "\n  ".join([f"{len(problems)} problem(s):"] + problems[:SHOWN]
                       + ([f"... and {len(problems) - SHOWN} more"] if len(problems) > SHOWN else []))


class CatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shipped = swift_languages()
        cls.translated = [tag for tag in cls.shipped if tag != SOURCE_LANGUAGE]
        cls.catalogs = {path: load(path) for path in CATALOGS}

    def test_the_language_registry_starts_with_english_and_lists_each_language_once(self):
        self.assertEqual(self.shipped[0], SOURCE_LANGUAGE, "English is the source language and stays first")
        self.assertEqual(len(self.shipped), len(set(self.shipped)), "Duplicate language in AppLanguage.supported")
        self.assertGreater(len(self.translated), 0)

    def test_every_catalog_ships_exactly_the_registered_languages(self):
        for path, (data, _) in self.catalogs.items():
            with self.subTest(catalog=path.name):
                self.assertEqual(data.get("sourceLanguage"), SOURCE_LANGUAGE)
                languages = {tag for entry in data["strings"].values() for tag, _, _ in values(entry)}
                self.assertEqual(sorted(languages - {SOURCE_LANGUAGE}), sorted(self.translated),
                                 f"{path.name} disagrees with AppLanguage.supported")

    def test_every_key_is_translated_into_every_registered_language(self):
        for path, (data, _) in self.catalogs.items():
            problems = []
            for key, entry in data["strings"].items():
                have = {tag: state for tag, _, state in values(entry)}
                for tag in self.translated:
                    if tag not in have:
                        problems.append(f"{key!r}: no {tag} unit")
                    elif have[tag] != "translated":
                        problems.append(f"{key!r}: {tag} is {have[tag]!r}, not 'translated'")
            with self.subTest(catalog=path.name):
                self.assertEqual(problems, [], report(problems))

    def test_catalogs_have_no_duplicate_keys_or_blank_values(self):
        for path, (data, duplicates) in self.catalogs.items():
            with self.subTest(catalog=path.name):
                self.assertGreater(len(data["strings"]), 0)
                self.assertEqual(duplicates, [], f"Duplicate key in {path.name}")
                blank = [f"{key!r} ({tag})" for key, entry in data["strings"].items()
                         for tag, value, _ in values(entry) if not (value or "").strip()]
                self.assertEqual(blank, [], report(blank))
        self.assertGreater(len(self.catalogs[CATALOGS[0]][0]["strings"]), 500)

    def test_translations_take_the_same_arguments_as_their_keys(self):
        for path, (data, _) in self.catalogs.items():
            problems = []
            for key, entry in data["strings"].items():
                want = arguments(key)
                for tag, value, _ in values(entry):
                    if value is not None and arguments(value) != want:
                        problems.append(f"{key!r} ({tag}): {dict(arguments(value))} instead of {dict(want)}")
            with self.subTest(catalog=path.name):
                self.assertEqual(problems, [], report(problems))

    def test_a_string_never_mixes_positional_and_plain_arguments(self):
        # Foundation leaves the result of `%@ %2$@` undefined.
        problems = []
        for path, (data, _) in self.catalogs.items():
            for key, entry in data["strings"].items():
                for label, text in [("key", key)] + [(tag, value) for tag, value, _ in values(entry)]:
                    positions = [position for position, _ in ARGUMENT.findall((text or "").replace("%%", ""))]
                    if any(positions) and not all(positions):
                        problems.append(f"{path.name}: {key!r} ({label})")
        self.assertEqual(problems, [], report(problems))

    def test_percent_signs_are_escaped_exactly_where_the_string_is_a_format(self):
        # Foundation formats a string only when it has arguments: there a literal `%` must be
        # `%%` in the key and every value; elsewhere `%%` would be shown twice.
        for path, (data, _) in self.catalogs.items():
            problems = []
            for key, entry in data["strings"].items():
                formatted = bool(arguments(key))
                texts = [("key", key)] + [(tag, value) for tag, value, _ in values(entry) if value is not None]
                for label, text in texts:
                    if formatted and stray_percent(text):
                        problems.append(f"{key!r} ({label}): unescaped % in a format string")
                    if not formatted and "%%" in text:
                        problems.append(f"{key!r} ({label}): %% in a string that is not a format")
            with self.subTest(catalog=path.name):
                self.assertEqual(problems, [], report(problems))

    def test_no_brace_placeholder_survives_the_migration(self):
        for path, (data, _) in self.catalogs.items():
            problems = [f"{key!r} ({label})" for key, entry in data["strings"].items()
                        for label, text in [("key", key)] + [(tag, value) for tag, value, _ in values(entry)]
                        if text and PLACEHOLDER.search(text)]
            with self.subTest(catalog=path.name):
                self.assertEqual(problems, [], report(problems))


if __name__ == "__main__":
    unittest.main()
