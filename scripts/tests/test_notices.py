#!/usr/bin/env python3
"""scripts/notices.py: which license a notice carries, where its text comes from, and the exit codes."""
import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import check_licenses  # noqa: E402
import notices  # noqa: E402

MIT = "Copyright (c) 2024 Someone\n\nPermission is hereby granted, free of charge, to any person obtaining a copy\nof this software.\n"
APACHE = "Apache License\nVersion 2.0, January 2004\n"
BSD = "Copyright (c) 2020 Other\nRedistribution and use in source and binary forms, with or without modification.\n"
UNICODE = "UNICODE LICENSE V3\nCopyright 1991-2023 Unicode, Inc.\n"


def write(directory, files):
    directory.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (directory / name).write_text(text)
    return directory


def crate(name, version, license, kind="crate"):
    return check_licenses.Component(name, kind, "crates", version, license, "cargo")


def collected(components, prefix=None, sections=None):
    return check_licenses.Collected(components, sections or {"dylibs": {"status": "checked"}}, [], [], None, prefix)


def no_brew(command, cwd=None, env=None):
    return subprocess.CompletedProcess(command, 127, "", "no brew")


class ChoiceTests(unittest.TestCase):
    def test_a_dual_licensed_crate_is_noticed_under_mit(self):
        self.assertEqual(notices.chosen_ids("MIT OR Apache-2.0"), ("MIT",))
        self.assertEqual(notices.chosen_ids("Apache-2.0 OR MIT"), ("MIT",))
        self.assertEqual(notices.chosen_ids("MIT/Apache-2.0"), ("MIT",))
        self.assertEqual(notices.chosen_ids("Zlib OR Apache-2.0 OR MIT"), ("MIT",))
        self.assertEqual(notices.chosen_ids("Unlicense OR MIT"), ("MIT",))

    def test_without_mit_the_best_allowed_option_is_used(self):
        self.assertEqual(notices.chosen_ids("BSD-3-Clause OR Apache-2.0"), ("BSD-3-Clause",))
        self.assertEqual(notices.chosen_ids("FTL OR GPL-2.0-or-later"), ("GPL-2.0-or-later",))

    def test_a_conjunction_carries_every_part(self):
        self.assertEqual(notices.chosen_ids("(MIT OR Apache-2.0) AND Unicode-3.0"), ("MIT", "Unicode-3.0"))

    def test_no_or_unparseable_metadata_chooses_nothing(self):
        self.assertEqual(notices.chosen_ids(None), ())
        self.assertEqual(notices.chosen_ids("MIT OR"), ())


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.directory, ignore_errors=True))

    def select(self, files, chosen):
        directory = write(self.directory / "crate", files)
        return notices.select_texts(notices.license_files(directory), chosen)

    def test_files_are_told_apart_by_what_they_say_not_what_they_are_called(self):
        texts, missing = self.select({"LICENSE-APACHE": APACHE, "LICENSE": MIT}, ("MIT",))
        self.assertEqual([file.name for file, _ in texts], ["LICENSE"])
        self.assertEqual(missing, ())

    def test_only_an_apache_text_leaves_the_mit_option_missing(self):
        texts, missing = self.select({"LICENSE": APACHE}, ("MIT",))
        self.assertEqual(texts, [])
        self.assertEqual(missing, ("MIT",))

    def test_a_pointer_to_the_license_is_not_the_license(self):
        texts, missing = self.select({"COPYING": "Licensed under the MIT license <LICENSE-MIT>\n"}, ("MIT",))
        self.assertEqual((texts, missing), ([], ("MIT",)))

    def test_every_chosen_license_needs_its_own_text(self):
        texts, missing = self.select({"LICENSE-MIT": MIT}, ("MIT", "Unicode-3.0"))
        self.assertEqual(len(texts), 1)
        self.assertEqual(missing, ("Unicode-3.0",))
        texts, missing = self.select({"LICENSE-MIT": MIT, "LICENSE-UNICODE": UNICODE, "NOTES": "x"}, ("MIT", "Unicode-3.0"))
        self.assertEqual(len(texts), 2)
        self.assertEqual(missing, ())

    def test_a_combined_file_is_written_once(self):
        texts, _ = self.select({"LICENSE": MIT + "\n" + BSD}, ("MIT", "BSD-3-Clause"))
        self.assertEqual(len(texts), 1)

    def test_a_crate_without_license_files_has_nothing_to_select(self):
        self.assertEqual(self.select({"README.md": MIT}, ("MIT",)), ([], ("MIT",)))

    def test_line_ends_are_normalised_and_trailing_blanks_dropped(self):
        directory = write(self.directory / "crate", {"LICENSE": MIT.replace("\n", "\r\n") + "   \n\n"})
        (_, text), = notices.select_texts(notices.license_files(directory), ("MIT",))[0]
        self.assertNotIn("\r", text)
        self.assertTrue(text.endswith("copy\nof this software."))

    def test_the_notice_at_the_end_of_a_header_is_extracted(self):
        header = write(self.directory / "h", {"stb.h": "int x;\n/* code */\n/*\n" + "-" * 78 + "\nThis software is available under 2 licenses -- choose.\n"
                                              + "-" * 78 + "\nALTERNATIVE A - MIT License\nPermission is hereby granted, free of charge.\n*/\n"}) / "stb.h"
        text = notices.header_notice(header, "This software is available under 2 licenses")
        self.assertTrue(text.startswith("-" * 78 + "\nThis software"))
        self.assertIn("ALTERNATIVE A", text)
        self.assertNotIn("int x", text)
        self.assertIsNone(notices.header_notice(header, "no such marker"))


class NoticeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.root, ignore_errors=True))
        self.cargo = self.root / "cargo"
        self.registry = self.cargo / "registry/src/index.crates.io-test"
        self.environment = {"CARGO_HOME": str(self.cargo)}
        patches = [mock.patch.object(notices, "THIRD_PARTY", self.root / "ThirdParty"),
                   mock.patch.object(notices, "SUPPLEMENTS", self.root / "supplements")]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def build(self, components, prefix=None, runner=no_brew, sections=None):
        return notices.build_notices(collected(components, prefix, sections), runner, self.environment)

    def find(self, noticeset, name):
        return next(notice for notice in noticeset.notices if notice.name == name)

    def test_a_crate_notice_carries_the_mit_text_from_the_registry(self):
        write(self.registry / "cfg-if-1.0.4", {"LICENSE-MIT": MIT, "LICENSE-APACHE": APACHE})
        noticeset = self.build([crate("cfg-if", "1.0.4", "MIT OR Apache-2.0")])
        notice = self.find(noticeset, "cfg-if")
        self.assertTrue(notice.found)
        self.assertEqual([label for label, _ in notice.texts], ["LICENSE-MIT"])
        self.assertEqual(notice.chosen, ("MIT",))

    def test_a_vendored_crate_reads_its_copy_under_third_party(self):
        write(self.root / "ThirdParty/naga", {"Cargo.toml": "[package]\n", "LICENSE.MIT": MIT, "LICENSE.APACHE": APACHE})
        notice = self.find(self.build([crate("naga", "29.0.3", "MIT OR Apache-2.0")]), "naga")
        self.assertTrue(notice.found)
        self.assertEqual([text for _, text in notice.texts], [notices.read(self.root / "ThirdParty/naga/LICENSE.MIT")])

    def test_a_crate_without_a_license_text_is_not_found_and_says_why(self):
        write(self.registry / "objc2-0.6.4", {"README.md": "x"})
        noticeset = self.build([crate("objc2", "0.6.4", "MIT")])
        self.assertEqual([notice.name for notice in noticeset.missing], ["objc2"])
        self.assertEqual(noticeset.missing[0].missing_ids, ("MIT",))
        self.assertIn(notices.NOT_FOUND, noticeset.text if noticeset.text else notices.entry_text(noticeset.missing[0]))

    def test_a_crate_missing_from_the_registry_is_not_found(self):
        self.assertEqual([notice.name for notice in self.build([crate("ghost", "1.0.0", "MIT")]).missing], ["ghost"])

    def test_the_repository_supplies_a_text_the_crate_does_not_carry(self):
        write(self.registry / "siphasher-0.3.11", {"COPYING": "Licensed under the MIT license <LICENSE-MIT>\n"})
        write(self.root / "supplements/siphasher", {"LICENSE-MIT": MIT})
        notice = self.find(self.build([crate("siphasher", "0.3.11", "MIT/Apache-2.0")]), "siphasher")
        self.assertTrue(notice.found)
        self.assertEqual([label for label, _ in notice.texts], ["LICENSE-MIT"])

    def test_labels_never_carry_a_home_directory(self):
        write(self.registry / "cfg-if-1.0.4", {"LICENSE-MIT": MIT})
        notice = self.find(self.build([crate("cfg-if", "1.0.4", "MIT")]), "cfg-if")
        self.assertEqual(notice.texts[0][0], "LICENSE-MIT")

    def test_a_homebrew_component_carries_every_license_file_of_its_keg(self):
        prefix = self.root / "brew"
        write(prefix / "Cellar/lz4/1.10.0", {"LICENSE": BSD, "NEWS": "n", "COPYING": "c"})
        component = check_licenses.Component("lz4", "dylib", "dylibs", "1.10.0", "BSD-2-Clause", "brew")
        notice = self.find(self.build([component], prefix), "lz4")
        self.assertEqual(sorted(label for label, _ in notice.texts), ["COPYING", "LICENSE"])
        self.assertTrue(notice.found)

    def test_a_header_only_package_is_found_through_brew_and_takes_the_keg_version(self):
        keg = write(self.root / "brew/Cellar/argparse/3.2", {"LICENSE": MIT})

        def brew(command, cwd=None, env=None):
            self.assertEqual(command, ["brew", "--prefix", "argparse"])
            return subprocess.CompletedProcess(command, 0, f"{keg}\n", "")

        component = check_licenses.Component("argparse", "cmake-package", "inventory", "", "MIT", "map")
        notice = self.find(self.build([component], None, brew), "argparse")
        self.assertTrue(notice.found)
        self.assertEqual(notice.version, "3.2")

    def test_a_keg_that_cannot_be_found_is_a_missing_text(self):
        component = check_licenses.Component("lz4", "dylib", "dylibs", "1.10.0", "BSD-2-Clause", "brew")
        self.assertEqual([notice.name for notice in self.build([component]).missing], ["lz4"])

    def test_vendored_code_reads_its_repository_files(self):
        write(self.root / "ThirdParty/miniaudio", {"LICENSE": MIT})
        with mock.patch.dict(notices.VENDORED_FILES, {"miniaudio": [self.root / "ThirdParty/miniaudio/LICENSE"]}):
            component = check_licenses.Component("miniaudio", "vendored", "inventory", "", "Unlicense OR MIT-0", "map")
            notice = self.find(self.build([component]), "miniaudio")
        self.assertTrue(notice.found)

    def test_first_party_system_and_unlinked_entries_are_not_noticed(self):
        components = [check_licenses.Component("wp-engine", "first-party", "inventory", license="GPL-3.0-only"),
                      check_licenses.Component("(apple system)", "system", "inventory"),
                      check_licenses.Component("glad", "not-linked", "inventory"),
                      check_licenses.Component("pkgconfig", "tool", "inventory")]
        names = [notice.name for notice in self.build(components).notices]
        self.assertNotIn("wp-engine", names)
        self.assertNotIn("(apple system)", names)
        self.assertNotIn("glad", names)

    def test_a_component_found_by_several_inventories_is_noticed_once(self):
        write(self.root / "brew/Cellar/lz4/1.10.0", {"LICENSE": BSD})
        components = [check_licenses.Component("lz4", "dylib", "dylibs", "1.10.0", "BSD-2-Clause", "brew"),
                      check_licenses.Component("lz4", "link-dylib", "inventory", "", "BSD-2-Clause", "map")]
        noticeset = self.build(components, self.root / "brew")
        self.assertEqual([notice.name for notice in noticeset.notices].count("lz4"), 1)

    def test_the_file_lists_every_component_marks_the_missing_and_never_names_the_home_directory(self):
        write(self.registry / "cfg-if-1.0.4", {"LICENSE-MIT": MIT})
        noticeset = self.build([crate("cfg-if", "1.0.4", "MIT OR Apache-2.0"), crate("ghost", "1.0.0", "MIT")])
        text = notices.render(noticeset)
        self.assertIn("Components (", text)
        self.assertIn("cfg-if 1.0.4", text)
        self.assertIn(f"{notices.NOT_FOUND} (cargo registry", text)
        self.assertIn("Permission is hereby granted", text)
        self.assertNotIn(str(Path.home()), text)
        self.assertNotIn(str(self.root), text)

    def test_mpl_crates_say_where_their_source_is(self):
        write(self.registry / "uniffi-0.28.3", {"LICENSE": "Mozilla Public License Version 2.0\n"})
        text = notices.entry_text(self.find(self.build([crate("uniffi", "0.28.3", "MPL-2.0")]), "uniffi"))
        self.assertIn("MPL-2.0 section 3.2", text)
        self.assertIn("https://crates.io/crates/uniffi/0.28.3", text)

    def test_the_embedded_notices_are_listed_even_when_the_walk_did_not_reach_them(self):
        noticeset = self.build([])
        self.assertEqual([notice.name for notice in noticeset.notices], ["mediaremote-adapter", "Phosphene ABI reference"])
        self.assertEqual(noticeset.missing, [])

    def test_an_embedded_notice_the_walk_found_is_not_listed_twice(self):
        component = check_licenses.Component("mediaremote-adapter", "dylib", "dylibs", "", "BSD-3-Clause", "map")
        names = [notice.name for notice in self.build([component]).notices]
        self.assertEqual(names.count("mediaremote-adapter"), 1)


class CommandTests(unittest.TestCase):
    def run_main(self, noticeset, *arguments):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, ignore_errors=True))
        output = directory / "out/THIRD-PARTY-NOTICES.txt"
        with mock.patch.object(notices, "generate", return_value=noticeset), contextlib.redirect_stdout(io.StringIO()) as stdout:
            status = notices.main([*arguments, "--output", str(output)], environment={})
        return status, output, stdout.getvalue()

    def noticeset(self, *, missing):
        found = notices.Notice("cfg-if", "1.0.4", "MIT", ("MIT",), "cargo registry", (("LICENSE-MIT", MIT),))
        absent = notices.Notice("ghost", "1.0.0", "MIT", ("MIT",), "cargo registry", (), ("MIT",))
        result = notices.NoticeSet([found, absent] if missing else [found])
        result.text = "file text"
        return result

    def test_a_gap_is_reported_but_exits_zero_without_enforce(self):
        status, output, stdout = self.run_main(self.noticeset(missing=True))
        self.assertEqual(status, 0)
        self.assertEqual(output.read_text(), "file text")
        self.assertIn("LICENSE TEXT NOT FOUND: ghost 1.0.0", stdout)
        self.assertIn("2 components, 1 with license text, 1 without", stdout)

    def test_a_gap_exits_one_with_enforce_and_the_file_is_still_written(self):
        status, output, stdout = self.run_main(self.noticeset(missing=True), "--enforce")
        self.assertEqual(status, 1)
        self.assertTrue(output.is_file())
        self.assertIn("ghost 1.0.0", stdout)

    def test_a_complete_set_passes_even_when_enforced(self):
        status, _, stdout = self.run_main(self.noticeset(missing=False), "--enforce")
        self.assertEqual(status, 0)
        self.assertIn("1 components, 1 with license text, 0 without", stdout)

    def test_a_tool_error_exits_one_in_both_modes_and_writes_nothing(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, ignore_errors=True))
        output = directory / "THIRD-PARTY-NOTICES.txt"
        for arguments in ([], ["--enforce"]):
            with mock.patch.object(notices, "generate", side_effect=check_licenses.ToolError("cargo tree failed")), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(notices.main([*arguments, "--output", str(output)], environment={}), 1)
        self.assertFalse(output.exists())


class GenerateTests(unittest.TestCase):
    def test_generate_collects_the_closure_without_printing_progress(self):
        component = crate("cfg-if", "1.0.4", "MIT")
        with mock.patch.object(check_licenses, "collect_components", return_value=collected([component])) as collect, \
                mock.patch.object(notices, "crate_directory", return_value=None), \
                contextlib.redirect_stdout(io.StringIO()) as stdout:
            noticeset = notices.generate(notices.options_for(Path("/nonexistent/App.app")), no_brew, {})
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("cfg-if 1.0.4", noticeset.text)
        collect.assert_called_once()

    def test_a_run_without_the_app_says_so_in_the_file(self):
        with mock.patch.object(check_licenses, "collect_components",
                               return_value=collected([], sections={"dylibs": {"status": "skipped"}})):
            noticeset = notices.generate(notices.options_for(skip_app=True), no_brew, {})
        self.assertIn("generated without the built app", noticeset.text)


if __name__ == "__main__":
    unittest.main()
