#!/usr/bin/env python3
"""License closure: SPDX policy, the Mach-O walk, the source inventory, the crate list and the exit codes."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("check_licenses", SCRIPTS / "check_licenses.py")
check_licenses = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_licenses)

BUILD_RS = """
fn main() {
    for lib in [
        "wescene-renderer",
        // Dependents come first.
        "wpAudio",
        "wmBrandNew",
        "wpBrandNew",
        "wmMediaApple",
        "wmMedia",
        "stb_vorbis",
    ] {
        println!("cargo:rustc-link-lib=static={lib}");
    }
    for lib in ["c++", "lz4", "freetype"] {
        println!("cargo:rustc-link-lib=dylib={lib}");
    }
    for framework in ["Metal", "AppKit"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
"""
CARGO_TREE_OUTPUT = """\
wm-shader v0.1.0 (/work/Renderer/Shader)|GPL-3.0-only
miette v7.6.0|Apache-2.0
backtrace v0.3.76|MIT OR Apache-2.0
cfg-if v1.0.4|MIT OR Apache-2.0
rustc-demangle v0.1.27|MIT/Apache-2.0
shadow-rs v2.0.0|MIT AND GPL-2.0-only
cfg-if v1.0.4|MIT OR Apache-2.0 (*)
mystery v1.0.0|
legacy-crate v0.9.0|EPL-1.0

wallpaper-core v0.2.0 (/work/Renderer/Core)|GPL-3.0-only
cfg-if v1.0.4|MIT OR Apache-2.0 (*)
"""
CLEAN_TREE_OUTPUT = "wallpaper-core v0.2.0 (/work/crates/core)|GPL-3.0-only\ncfg-if v1.0.4|MIT OR Apache-2.0\n"


def otool_text(path, dependencies):
    lines = [f"{path}:"] + [f"\t{name} (compatibility version 1.0.0, current version 1.0.0)" for name in dependencies]
    return "\n".join(lines) + "\n"


class FakeTools:
    """Stands in for otool, brew and cargo; nothing real is ever run."""

    def __init__(self, otool=None, brew_prefix=None, brew_licenses=None, tree=CLEAN_TREE_OUTPUT, cargo_status=0):
        self.otool = otool or {}  # file name -> dependency list
        self.brew_prefix = brew_prefix
        self.brew_licenses = brew_licenses if brew_licenses is not None else {}
        self.tree = tree
        self.cargo_status = cargo_status
        self.commands = []

    def __call__(self, command, cwd=None, env=None):
        command = [str(part) for part in command]
        self.commands.append(command)
        done = lambda text="", status=0, error="": subprocess.CompletedProcess(command, status, text, error)
        if command[0] == "otool":
            name = Path(command[2]).name
            if name not in self.otool:
                return done(status=1, error=f"{name}: no such file")
            return done(otool_text(command[2], [command[2], *self.otool[name]]))
        if command[:2] == ["brew", "--prefix"]:
            return done(str(self.brew_prefix), 0) if self.brew_prefix else done(status=127, error="brew: not found")
        if command[:2] == ["brew", "info"]:
            if not self.brew_licenses:
                return done(status=1, error="unavailable")
            asked = command[3:]
            return done(json.dumps([{"name": name, "license": self.brew_licenses[name]}
                                    for name in asked if name in self.brew_licenses]))
        if command[0] == "cargo":
            return done(self.tree, self.cargo_status, "error: no lockfile" if self.cargo_status else "")
        raise AssertionError(f"unexpected command {command}")


class PolicyTests(unittest.TestCase):
    def verdict(self, expression):
        return check_licenses.classify(expression)

    def test_a_choice_needs_one_allowed_option_and_a_conjunction_needs_all(self):
        self.assertEqual(self.verdict("MIT OR GPL-2.0-only").status, "ok")
        self.assertEqual(self.verdict("GPL-2.0-only OR MIT").status, "ok")
        self.assertEqual(self.verdict("MIT AND BSD-3-Clause").status, "ok")
        self.assertEqual(self.verdict("MIT AND GPL-2.0-only").status, "gpl2")
        self.assertEqual(self.verdict("FTL OR GPL-2.0-or-later").status, "ok")

    def test_the_project_license_and_gplv3_compatible_licenses_pass(self):
        for expression in ("GPL-3.0-only", "GPL-3.0-or-later", "GPL-2.0-or-later", "Apache-2.0", "MPL-2.0",
                           "LGPL-2.1-or-later", "LGPL-3.0-only", "MIT OR Apache-2.0", "Apache-2.0 AND MIT"):
            with self.subTest(expression=expression):
                self.assertEqual(self.verdict(expression).status, "ok")

    def test_gpl2_only_and_known_incompatible_licenses_fail_with_their_own_class(self):
        self.assertEqual(self.verdict("GPL-2.0-only").classes, ("gpl2",))
        self.assertEqual(self.verdict("EPL-1.0").classes, ("incompatible",))
        self.assertEqual(self.verdict("CDDL-1.0").classes, ("incompatible",))
        self.assertEqual(self.verdict("Apache-1.1").classes, ("incompatible",))
        self.assertEqual(self.verdict("OpenSSL").classes, ("incompatible",))

    def test_unlisted_licenses_are_unknown_and_need_a_human(self):
        self.assertEqual(self.verdict("FTL").classes, ("unknown",))
        self.assertEqual(self.verdict("AGPL-3.0-or-later").classes, ("unknown",))
        self.assertEqual(self.verdict("Some-Unlisted-License").classes, ("unknown",))

    def test_a_composite_reports_every_failing_class(self):
        composite = self.verdict("BSD-3-Clause AND GPL-2.0-only AND MIT AND EPL-1.0 AND Apache-2.0")
        self.assertEqual(set(composite.classes), {"gpl2", "incompatible"})
        self.assertEqual(composite.status, "gpl2")
        self.assertEqual(set(composite.rejected), {"GPL-2.0-only", "EPL-1.0"})

    def test_parentheses_and_precedence(self):
        self.assertEqual(self.verdict("(MIT OR GPL-2.0-only) AND BSD-3-Clause").status, "ok")
        self.assertEqual(set(self.verdict("(EPL-1.0 OR GPL-2.0-only) AND MIT").classes), {"gpl2", "incompatible"})
        # AND binds tighter than OR.
        self.assertEqual(self.verdict("MIT OR EPL-1.0 AND GPL-2.0-only").status, "ok")
        self.assertEqual(self.verdict("EPL-1.0 AND GPL-2.0-only OR MIT").status, "ok")
        self.assertEqual(self.verdict("GPL-2.0-only AND (EPL-1.0 OR MIT)").status, "gpl2")

    def test_exceptions_never_make_a_rejected_license_acceptable(self):
        self.assertEqual(self.verdict("GPL-2.0-only WITH Classpath-exception-2.0").status, "gpl2")
        self.assertEqual(self.verdict("GPL-2.0-only WITH Classpath-exception-2.0 OR GPL-2.0-only OR MIT").status, "ok")
        self.assertEqual(self.verdict("GPL-3.0-or-later WITH Bison-exception-2.2").status, "ok")

    def test_spellings_cargo_and_homebrew_use(self):
        self.assertEqual(self.verdict("MIT/Apache-2.0").status, "ok")
        self.assertEqual(self.verdict("Apache-2.0/MIT").status, "ok")
        self.assertEqual(self.verdict("GPL-2.0/GPL-2.0-only").status, "gpl2")
        self.assertEqual(self.verdict("GPL-2.0+").status, "ok")
        self.assertEqual(self.verdict("GPL-3.0+").status, "ok")
        self.assertEqual(self.verdict("  mit   or   apache-2.0 ").status, "ok")
        self.assertEqual(self.verdict("GPL-2.0").classes, ("gpl2",))
        self.assertEqual(self.verdict("GPL-3.0").status, "ok")

    def test_missing_or_unparseable_metadata_is_unknown(self):
        for expression in (None, "", "   ", "FILE:LICENSE", "NOASSERTION", "MIT OR", "(MIT", "MIT)", "AND MIT",
                           "MIT AND AND MIT", "MIT WITH", "()"):
            with self.subTest(expression=expression):
                verdict = self.verdict(expression)
                self.assertEqual(verdict.status, "unknown")
                self.assertTrue(verdict.reason)

    def test_every_allowed_license_passes_and_the_rejected_ones_are_not_allowed(self):
        for identifier in check_licenses.ALLOWED:
            with self.subTest(identifier=identifier):
                self.assertEqual(self.verdict(identifier).status, "ok")
        for identifier in ("GPL-2.0-only", "EPL-1.0", "CDDL-1.0", "AGPL-3.0-only"):
            self.assertNotIn(identifier.lower(), check_licenses.ALLOWED)
        self.assertEqual(check_licenses.POLICY, "GPL-3.0-only")

    def test_hand_kept_tables_are_self_consistent(self):
        for name, (license, reason) in check_licenses.OVERRIDES.items():
            self.assertTrue(reason.strip(), f"override {name} needs a reason")
            self.assertEqual(check_licenses.classify(license).status, "ok")
        for alias, target in check_licenses.ALIASES.items():
            self.assertIn(target, check_licenses.COMPONENTS, alias)
        for name, target in check_licenses.LIBRARY_STEMS.items():
            self.assertIn(target, check_licenses.COMPONENTS, name)
        for name, entry in check_licenses.COMPONENTS.items():
            self.assertTrue(entry.note.strip(), name)
            if not entry.kind:
                self.assertIsNotNone(entry.license, f"{name} is third-party code and needs a license")
            else:
                self.assertIn(entry.kind, check_licenses.PASSING)


class CargoTreeTests(unittest.TestCase):
    def test_duplicates_fold_workspace_crates_are_first_party_and_empty_licenses_are_unknown(self):
        components = check_licenses.parse_cargo_tree(CARGO_TREE_OUTPUT)
        crates = [c for c in components if c.kind == "crate"]
        self.assertEqual(sorted(c.name for c in crates),
                         ["backtrace", "cfg-if", "legacy-crate", "miette", "mystery", "rustc-demangle", "shadow-rs"])
        self.assertEqual(sorted(c.name for c in components if c.kind == "first-party"), ["wallpaper-core", "wm-shader"])
        by_name = {c.name: c for c in crates}
        self.assertEqual(by_name["miette"].version, "7.6.0")
        self.assertEqual(by_name["cfg-if"].license, "MIT OR Apache-2.0")
        self.assertIsNone(by_name["mystery"].license)
        self.assertEqual(check_licenses.assess(by_name["mystery"])[0], "unknown")
        self.assertEqual(check_licenses.assess(by_name["rustc-demangle"])[0], "ok")
        self.assertEqual(check_licenses.assess(by_name["miette"])[0], "ok")
        self.assertEqual(check_licenses.assess(by_name["shadow-rs"])[1], ("gpl2",))
        self.assertEqual(check_licenses.assess(by_name["legacy-crate"])[1], ("incompatible",))

    def test_a_vendored_path_crate_is_third_party_with_the_license_its_manifest_declares(self):
        text = (
            "wallpaper-core v0.2.0 (/work/Renderer/Core)|GPL-3.0-only\n"
            "naga v29.0.3 (/work/ThirdParty/naga)|MIT OR Apache-2.0\n"
            "naga v29.0.3 (/work/ThirdParty/naga)|MIT OR Apache-2.0 (*)\n"
            "cfg-if v1.0.4|MIT OR Apache-2.0\n"
        )
        components = {c.name: c for c in check_licenses.parse_cargo_tree(text)}
        self.assertEqual(components["wallpaper-core"].kind, "first-party")
        naga = components["naga"]
        self.assertEqual((naga.kind, naga.license, naga.source), ("crate", "MIT OR Apache-2.0", "cargo"))
        self.assertEqual(check_licenses.assess(naga)[0], "ok")
        self.assertEqual(sum(1 for c in check_licenses.parse_cargo_tree(text) if c.name == "naga"), 1)

    def test_vendored_crates_are_told_apart_by_directory_under_the_repository_root(self):
        root = check_licenses.ROOT
        for path, vendored in (
            (root / "ThirdParty/naga", True),
            (root / "ThirdParty/naga/crate", True),
            (root / "Renderer/Shader", False),
            (root / "tools/helper", False),
            (Path("/elsewhere/ThirdParty/naga"), True),
            (Path("/elsewhere/Renderer/Core"), False),
            (root / "ThirdParty", False),
            (Path("/work/crates/core"), False),
        ):
            with self.subTest(path=str(path)):
                self.assertEqual(check_licenses.is_vendored_crate(str(path)), vendored)

    def test_a_vendored_crate_with_a_rejected_license_is_flagged(self):
        text = "naga v29.0.3 (/work/ThirdParty/naga)|GPL-2.0-only\n"
        (naga,) = check_licenses.parse_cargo_tree(text)
        self.assertEqual(naga.kind, "crate")
        self.assertEqual(check_licenses.assess(naga)[0], "gpl2")

    def test_a_table_entry_supplies_a_license_cargo_does_not(self):
        with mock.patch.dict(check_licenses.COMPONENTS, {"mystery": check_licenses.Entry("MIT", "checked by hand")}):
            component = next(c for c in check_licenses.parse_cargo_tree(CARGO_TREE_OUTPUT) if c.name == "mystery")
        self.assertEqual((component.license, component.source), ("MIT", "map"))


class AppWalkTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tmp = Path(directory.name).resolve()
        self.app = self.tmp / "Test.app"
        self.prefix = self.tmp / "brew"
        for path in ("Contents/MacOS/Main", "Contents/Extensions/Ext.appex/Contents/MacOS/Ext"):
            self.touch(self.app / path)

    def touch(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"\x00")
        return path

    def keg(self, formula, version, *libraries):
        """A Cellar keg with an `opt/<formula>` link, the way Homebrew lays it out."""
        keg = self.prefix / "Cellar" / formula / version
        for library in libraries:
            self.touch(keg / "lib" / library)
        (self.prefix / "opt").mkdir(parents=True, exist_ok=True)
        (self.prefix / "opt" / formula).symlink_to(keg)
        return self.prefix / "opt" / formula / "lib"

    def opt(self, formula, library):
        return str(self.prefix / "opt" / formula / "lib" / library)

    def walk(self, tools, prefix=True):
        return check_licenses.walk_app(self.app, tools, self.prefix if prefix else None)

    def test_homebrew_dependencies_resolve_to_their_kegs_transitively_and_cycles_end(self):
        self.keg("sample-lib", "16.6.0", "libsample.16.dylib", "libsampleio.16.dylib")
        self.keg("sample-tools", "1.4.357.0", "libsample-tools.dylib", "libsample-tools-opt.dylib")
        tools = FakeTools(otool={
            "Main": ["/usr/lib/libc++.1.dylib", "/System/Library/Frameworks/Metal.framework/Versions/A/Metal",
                     self.opt("sample-lib", "libsample.16.dylib"), "@rpath/libswiftCore.dylib"],
            "Ext": [self.opt("sample-lib", "libsampleio.16.dylib"), "/usr/lib/libSystem.B.dylib"],
            "libsample.16.dylib": [self.opt("sample-tools", "libsample-tools-opt.dylib")],
            "libsampleio.16.dylib": [],
            "libsample-tools-opt.dylib": [self.opt("sample-tools", "libsample-tools.dylib")],
            # A cycle back to the first library must not loop.
            "libsample-tools.dylib": [self.opt("sample-lib", "libsample.16.dylib")],
        })
        walk = self.walk(tools)
        self.assertEqual(len(walk.roots), 2)
        self.assertEqual({path.name for path in walk.libraries},
                         {"libsample.16.dylib", "libsampleio.16.dylib", "libsample-tools-opt.dylib", "libsample-tools.dylib"})
        self.assertEqual(walk.unresolved, [])
        self.assertEqual(walk.system, {"/usr/lib/libc++.1.dylib", "/System/Library/Frameworks/Metal.framework/Versions/A/Metal",
                                       "@rpath/libswiftCore.dylib", "/usr/lib/libSystem.B.dylib"})
        analysed = [command[2] for command in tools.commands if command[0] == "otool"]
        self.assertEqual(len(analysed), len(set(analysed)), "every file is read once")

        # Fictional kegs, so the classes below come from the license strings Homebrew reports.
        licenses = {"sample-lib": "BSD-3-Clause AND GPL-2.0-only AND MIT AND EPL-1.0", "sample-tools": "GPL-2.0-only"}
        components = check_licenses.dylib_components(walk, self.prefix, self.app,
                                                     FakeTools(brew_licenses=licenses))
        by_name = {c.name: c for c in components}
        self.assertEqual(sorted(by_name), ["sample-lib", "sample-tools"])
        self.assertEqual(by_name["sample-lib"].version, "16.6.0")
        self.assertEqual(by_name["sample-lib"].source, "brew")
        self.assertEqual(by_name["sample-lib"].files, ("libsample.16.dylib", "libsampleio.16.dylib"))
        self.assertEqual(check_licenses.assess(by_name["sample-lib"])[1], ("gpl2", "incompatible"))
        self.assertEqual(check_licenses.assess(by_name["sample-tools"])[0], "gpl2")

    def test_without_homebrew_the_table_supplies_the_license_and_says_so(self):
        self.keg("lz4", "1.10.0", "liblz4.1.dylib")
        tools = FakeTools(otool={"Main": [self.opt("lz4", "liblz4.1.dylib")], "Ext": [], "liblz4.1.dylib": []})
        components = check_licenses.dylib_components(self.walk(tools), None, self.app, FakeTools())
        self.assertEqual([(c.name, c.license, c.source) for c in components], [("lz4", "BSD-2-Clause", "map")])

    def test_an_override_beats_the_homebrew_string(self):
        self.keg("freetype", "2.14.3", "libfreetype.6.dylib")
        tools = FakeTools(otool={"Main": [self.opt("freetype", "libfreetype.6.dylib")], "Ext": [], "libfreetype.6.dylib": []})
        components = check_licenses.dylib_components(self.walk(tools), self.prefix, self.app,
                                                     FakeTools(brew_licenses={"freetype": "FTL"}))
        self.assertEqual((components[0].license, components[0].source), ("FTL OR GPL-2.0-or-later", "override"))
        self.assertEqual(check_licenses.assess(components[0])[0], "ok")

    def test_a_packaged_app_resolves_rpath_into_its_frameworks(self):
        frameworks = self.app / "Contents/Frameworks"
        for name in ("liblz4.1.dylib", "libpng16.16.dylib", "libmystery.1.dylib"):
            self.touch(frameworks / name)
        self.touch(frameworks / "MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter")
        (frameworks / "MediaRemoteAdapter.framework/MediaRemoteAdapter").symlink_to("Versions/A/MediaRemoteAdapter")
        tools = FakeTools(otool={
            "Main": ["@rpath/liblz4.1.dylib", "@rpath/libswiftCore.dylib"],
            "Ext": ["@rpath/liblz4.1.dylib"],
            "liblz4.1.dylib": ["@rpath/libpng16.16.dylib"],
            "libpng16.16.dylib": [],
            "libmystery.1.dylib": [],
            "MediaRemoteAdapter": [],
        })
        walk = self.walk(tools, prefix=False)
        self.assertEqual({path.name for path in walk.libraries},
                         {"liblz4.1.dylib", "libpng16.16.dylib", "libmystery.1.dylib", "MediaRemoteAdapter"})
        components = {c.name: c for c in check_licenses.dylib_components(walk, None, self.app, FakeTools())}
        self.assertEqual(sorted(components), ["libmystery.1.dylib", "libpng", "lz4", "mediaremote-adapter"])
        self.assertEqual(check_licenses.assess(components["libmystery.1.dylib"])[0], "unknown")
        self.assertEqual(check_licenses.assess(components["mediaremote-adapter"])[0], "ok")
        self.assertEqual(check_licenses.assess(components["libpng"])[0], "ok")

    def test_an_ffmpeg_library_that_returns_to_the_bundle_is_unknown(self):
        # FFmpeg is no longer used and has no table entry, so a libav* dylib in a
        # packaged app fails the policy instead of passing as a known component.
        self.touch(self.app / "Contents/Frameworks/libavcodec.62.dylib")
        tools = FakeTools(otool={"Main": ["@rpath/libavcodec.62.dylib"], "Ext": [], "libavcodec.62.dylib": []})
        components = check_licenses.dylib_components(self.walk(tools, prefix=False), None, self.app, FakeTools())
        self.assertEqual([c.name for c in components], ["libavcodec.62.dylib"])
        self.assertEqual(check_licenses.assess(components[0])[0], "unknown")

    def test_an_unresolvable_dependency_is_reported_not_dropped(self):
        tools = FakeTools(otool={"Main": ["@rpath/libgone.dylib", "/opt/homebrew/opt/nothing/lib/libnothing.dylib"], "Ext": []})
        walk = self.walk(tools, prefix=False)
        self.assertEqual(sorted(dependency for dependency, _ in walk.unresolved),
                         ["/opt/homebrew/opt/nothing/lib/libnothing.dylib", "@rpath/libgone.dylib"])
        components = check_licenses.dylib_components(walk, None, self.app, FakeTools())
        self.assertEqual({check_licenses.assess(c)[0] for c in components}, {"unknown"})
        self.assertTrue(all("not found" in c.note for c in components))

    def test_an_app_without_executables_is_an_error(self):
        empty = self.tmp / "Empty.app"
        (empty / "Contents").mkdir(parents=True)
        with self.assertRaises(check_licenses.ToolError):
            check_licenses.walk_app(empty, FakeTools(), None)

    def test_a_failing_otool_stops_the_walk(self):
        with self.assertRaises(check_licenses.ToolError):
            self.walk(FakeTools(otool={"Main": []}))  # Ext is unknown to the fake: otool fails


class InventoryTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tmp = Path(directory.name).resolve()
        self.engine = self.tmp / "engine"
        self.build_rs = self.tmp / "build.rs"
        self.build_rs.write_text(BUILD_RS)
        (self.engine / "src/Audio").mkdir(parents=True)
        self.third_party = self.tmp / "ThirdParty"
        for name in ("glad", "miniaudio", "mystery_lib", "naga", "mediaremote-adapter", "received-licenses"):
            (self.third_party / name).mkdir(parents=True)
        (self.third_party / "stb_image.h").write_text("")
        (self.engine / "Dependencies").mkdir()
        (self.engine / "Dependencies/CMakeLists.txt").write_text(
            "find_package(PkgConfig REQUIRED)\nfind_package(nlohmann_json CONFIG REQUIRED)\n# find_package(Commented REQUIRED)\n")
        (self.engine / "src/CMakeLists.txt").write_text(
            "find_package(Threads REQUIRED)\npkg_check_modules(LZ4 REQUIRED IMPORTED_TARGET liblz4)\n"
            "pkg_check_modules(AVCODEC REQUIRED IMPORTED_TARGET libavcodec)\n")
        (self.engine / "src/Audio/CMakeLists.txt").write_text("find_package(Brand_New_Package REQUIRED)\n")

    def components(self):
        return {c.name: c for c in check_licenses.inventory_components(self.engine, self.build_rs, self.third_party)}

    def test_link_lists_come_from_the_build_script_comments_ignored(self):
        self.assertEqual(check_licenses.link_lists(self.build_rs),
                         [("static", "wescene-renderer"), ("static", "wpAudio"), ("static", "wmBrandNew"),
                          ("static", "wpBrandNew"), ("static", "wmMediaApple"), ("static", "wmMedia"),
                          ("static", "stb_vorbis"), ("dylib", "c++"), ("dylib", "lz4"),
                          ("dylib", "freetype"), ("framework", "Metal"), ("framework", "AppKit")])

    def test_link_lists_also_come_from_named_arrays_and_a_kind_table(self):
        self.build_rs.write_text(
            'const STATIC_ARCHIVES: [&str; 2] = [\n    "wpAudio",\n    // "wpRetired",\n    "stb_vorbis",\n];\n'
            'const SHARED_LIBRARIES: [&str; 1] = ["lz4"];\nconst FRAMEWORKS: [&str; 1] = ["Metal"];\n'
            'fn main() {\n    let kinds = [("static", &STATIC_ARCHIVES), ("dylib", &SHARED_LIBRARIES), ("framework", &FRAMEWORKS)];\n'
            '    for (kind, names) in kinds { for name in names { println!("cargo:rustc-link-lib={kind}={name}"); } }\n}\n')
        self.assertEqual(check_licenses.link_lists(self.build_rs),
                         [("static", "wpAudio"), ("static", "stb_vorbis"), ("dylib", "lz4"), ("framework", "Metal")])

    def test_first_party_archives_pass_and_third_party_ones_carry_their_license(self):
        components = self.components()
        # wp* are the scene engine's archives, wm* the project's own (Renderer/).
        for name in ("wescene-renderer", "wpAudio", "wmBrandNew", "wpBrandNew", "wmMediaApple", "wmMedia"):
            self.assertEqual(components[name].kind, "first-party")
            self.assertEqual(check_licenses.assess(components[name])[0], "first-party")
        self.assertEqual(components["stb_vorbis"].license, "MIT OR Unlicense")
        self.assertEqual(check_licenses.assess(components["stb_vorbis"])[0], "ok")
        # The link-lib list and pkg_check_modules name the same component once.
        self.assertEqual(sum(1 for name in components if name == "lz4"), 1)
        self.assertEqual(components["lz4"].reached_from, ("CMake src/CMakeLists.txt", "build.rs dylib"))

    def test_entries_missing_from_the_table_are_unknown(self):
        components = self.components()
        for name in ("mystery_lib", "Brand_New_Package"):
            self.assertEqual(check_licenses.assess(components[name])[0], "unknown", name)
            self.assertIsNone(components[name].license)

    def test_third_party_entries_other_sections_check_are_not_engine_inventory(self):
        components = self.components()
        for name in ("naga", "mediaremote-adapter", "received-licenses"):
            self.assertNotIn(name, components)
        self.assertEqual(components["miniaudio"].reached_from, ("ThirdParty/miniaudio",))

    def test_unlinked_system_and_tool_entries_do_not_count_against_the_policy(self):
        components = self.components()
        self.assertEqual(check_licenses.assess(components["glad"])[0], "not-linked")
        self.assertEqual(check_licenses.assess(components["(build tool)"])[0], "tool")
        self.assertEqual(check_licenses.assess(components["(apple system)"])[0], "system")
        self.assertEqual(components["(apple system)"].files, ("AppKit", "Metal"))
        self.assertNotIn("commented", {name.lower() for name in components})
        self.assertEqual(components["stb_image"].license, "MIT OR Unlicense")
        self.assertEqual(check_licenses.assess(components["lz4"])[0], "ok")
        # FFmpeg is no longer used: a libav* library or CMake package that comes back is
        # reported as unknown rather than waved through by a table entry.
        self.assertEqual(check_licenses.assess(components["libavcodec"])[0], "unknown")
        self.assertIsNone(components["libavcodec"].license)
        self.assertNotIn("mwe-ffmpeg", components)

    def test_an_unrecognised_build_script_is_an_error_not_an_empty_list(self):
        self.build_rs.write_text("fn main() {}\n")
        with self.assertRaises(check_licenses.ToolError):
            check_licenses.inventory_components(self.engine, self.build_rs, self.third_party)


class ReportTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tmp = Path(directory.name).resolve()
        self.engine = self.tmp / "engine"
        self.third_party = self.tmp / "ThirdParty"
        (self.third_party / "miniaudio").mkdir(parents=True)
        (self.engine / "Dependencies").mkdir(parents=True)
        (self.engine / "Dependencies/CMakeLists.txt").write_text("find_package(argparse CONFIG REQUIRED)\n")
        self.build_rs = self.tmp / "build.rs"
        self.build_rs.write_text('for lib in ["lz4"] { println!("cargo:rustc-link-lib=dylib={lib}"); }\n')
        self.app = self.tmp / "Test.app"
        for path in ("Contents/MacOS/Main",):
            (self.app / path).parent.mkdir(parents=True, exist_ok=True)
            (self.app / path).write_bytes(b"\x00")
        self.output = self.tmp / "out"

    def check(self, *arguments, tools=None, licensing="shadow-rs legacy-crate mystery", app=True):
        tools = tools or FakeTools(otool={"Main": ["/usr/lib/libSystem.B.dylib"]}, tree=CARGO_TREE_OUTPUT)
        argv = ["--output", str(self.output), *arguments]
        if app and "--app" not in arguments and "--skip-app" not in arguments:
            argv += ["--app", str(self.app)]
        stdout = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(check_licenses, "ENGINE", self.engine))
            stack.enter_context(mock.patch.object(check_licenses, "THIRD_PARTY", self.third_party))
            stack.enter_context(mock.patch.object(check_licenses, "CORE_BUILD_SCRIPT", self.build_rs))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            code = check_licenses.main(argv, runner=tools, environment={}, licensing_text=licensing)
        return code, stdout.getvalue(), tools

    def report(self):
        return json.loads((self.output / "report.json").read_text())

    def test_findings_exit_zero_in_report_only_mode_and_one_with_enforce(self):
        code, output, _ = self.check()
        self.assertEqual(code, 0)
        self.assertIn("report-only", output)
        report = self.report()
        self.assertGreater(report["counts"]["failing"], 0)
        enforced, output, _ = self.check("--enforce")
        self.assertEqual(enforced, 1)
        self.assertNotIn("report-only", output)

    def test_apache_and_gpl3_crates_and_the_projects_own_crates_pass_when_enforced(self):
        tree = ("wallpaper-core v0.2.0 (/work/crates/core)|GPL-3.0-only\nmiette v7.6.0|Apache-2.0\n"
                "gpl-lib v1.0.0|GPL-3.0-or-later\nlgpl-lib v1.0.0|LGPL-3.0-only\n")
        code, output, _ = self.check("--enforce", tools=FakeTools(otool={"Main": []}, tree=tree))
        self.assertEqual(code, 0, output)
        self.assertEqual(self.report()["counts"]["failing"], 0)

    def test_a_gpl2_only_crate_fails_when_enforced(self):
        tree = "wallpaper-core v0.2.0 (/work/crates/core)|GPL-3.0-only\nold-lib v1.0.0|GPL-2.0-only\n"
        code, output, _ = self.check("--enforce", tools=FakeTools(otool={"Main": []}, tree=tree),
                                     licensing="old-lib")
        self.assertEqual(code, 1, output)
        self.assertEqual(self.report()["lists"]["gpl2"], ["old-lib"])

    def test_a_clean_closure_passes_even_when_enforced(self):
        tools = FakeTools(otool={"Main": []}, tree=CLEAN_TREE_OUTPUT)
        (self.third_party / "miniaudio").mkdir(exist_ok=True)
        code, output, _ = self.check("--enforce", tools=tools)
        self.assertEqual(code, 0, output)
        self.assertEqual(self.report()["counts"]["failing"], 0)

    def test_the_report_lists_failing_components_by_class_and_the_closure(self):
        self.check()
        report = self.report()
        self.assertEqual(report["policy"], "GPL-3.0-only")
        self.assertEqual(report["lists"]["gpl2"], ["shadow-rs"])
        self.assertEqual(report["lists"]["incompatible"], ["legacy-crate"])
        self.assertNotIn("miette", report["lists"]["gpl2"] + report["lists"]["incompatible"] + report["lists"]["unknown"])
        for key in ("generated", "policy", "enforce", "app", "sections", "counts", "lists", "components",
                    "violations", "unrecorded_in_licensing_md", "incomplete"):
            self.assertIn(key, report)
        self.assertEqual(set(report["sections"]), {"dylibs", "inventory", "crates"})
        self.assertEqual(report["sections"]["crates"]["third_party"], 7)
        self.assertEqual(report["sections"]["dylibs"]["system_libraries"], ["/usr/lib/libSystem.B.dylib"])
        self.assertTrue((self.output / "closure.txt").read_text().strip())
        self.assertTrue(all(c["status"] for c in report["components"]))

    def test_a_failing_component_missing_from_licensing_md_is_reported_and_enforced(self):
        code, output, _ = self.check(licensing="nothing relevant")
        self.assertEqual(code, 0)
        self.assertIn("legacy-crate", self.report()["unrecorded_in_licensing_md"])
        self.assertIn("shadow-rs", self.report()["unrecorded_in_licensing_md"])
        tools = FakeTools(otool={"Main": []}, tree="miette v7.6.0|GPL-2.0-only\n")
        recorded, _, _ = self.check("--enforce", tools=tools, licensing="GPL-2.0-only crate miette")
        self.assertEqual(recorded, 1, "GPL-2.0-only still fails")
        tools = FakeTools(otool={"Main": []}, tree=CLEAN_TREE_OUTPUT)
        code, _, _ = self.check("--enforce", tools=tools, licensing="")
        self.assertEqual(code, 0, "nothing failing needs no record")

    def test_a_missing_default_app_is_skipped_in_the_verdict_and_fails_only_when_enforced(self):
        tools = FakeTools(tree=CLEAN_TREE_OUTPUT)
        missing = self.tmp / "none/WallpaperMachine.app"
        with mock.patch.object(check_licenses, "app_bundle", return_value=missing):
            code, output, _ = self.check(tools=tools, app=False)
            self.assertEqual(code, 0)
            self.assertIn("skipped", output.splitlines()[-1])
            self.assertEqual(self.report()["sections"]["dylibs"]["status"], "skipped")
            self.assertEqual(self.report()["incomplete"], ["dylibs"])
            code, _, _ = self.check("--enforce", tools=tools, app=False)
            self.assertEqual(code, 1)
        self.assertFalse(any(command[0] == "otool" for command in tools.commands))

    def test_skip_app_is_an_explicit_choice_that_enforce_accepts(self):
        code, output, tools = self.check("--skip-app", "--enforce", tools=FakeTools(tree=CLEAN_TREE_OUTPUT))
        self.assertEqual(code, 0, output)
        self.assertEqual(self.report()["sections"]["dylibs"]["status"], "skipped")
        verdict = output.strip().splitlines()[-1]
        self.assertIn("skipped", verdict)
        self.assertIn("dylibs", verdict)
        self.assertEqual(self.report()["incomplete"], [])
        self.assertFalse(any(command[0] in ("otool", "brew") for command in tools.commands))

    def test_an_explicit_app_that_does_not_exist_is_a_tool_error_in_both_modes(self):
        for extra in ((), ("--enforce",)):
            code, output, _ = self.check("--app", str(self.tmp / "gone.app"), *extra)
            self.assertEqual(code, 1)
            self.assertIn("gone.app", output)

    def test_cargo_failure_is_a_tool_error_in_both_modes(self):
        for extra in ((), ("--enforce",)):
            tools = FakeTools(otool={"Main": []}, cargo_status=101)
            code, _, _ = self.check(*extra, tools=tools)
            self.assertEqual(code, 1)

    def test_a_missing_cargo_executable_is_a_tool_error(self):
        def runner(command, cwd=None, env=None):
            if command[0] == "cargo":
                return subprocess.CompletedProcess(command, 127, "", "cargo: not found")
            return FakeTools(otool={"Main": []})(command, cwd, env)

        code, output, _ = self.check(tools=runner)
        self.assertEqual(code, 1)
        self.assertIn("cargo", output)

    def test_cargo_runs_offline_for_the_app_target_without_proc_macros(self):
        _, _, tools = self.check()
        command = next(command for command in tools.commands if command[0] == "cargo")
        for argument in ("--offline", "--workspace", "normal,no-proc-macro", "aarch64-apple-darwin", "{p}|{l}"):
            self.assertIn(argument, command)


if __name__ == "__main__":
    unittest.main()
