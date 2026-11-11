#!/usr/bin/env python3
"""Unit tests for scripts/source_times.py."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("source_times", SCRIPTS / "source_times.py")
source_times = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(source_times)

IDENTITY = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
TOOLCHAIN = {"rustc": "rustc 1.0.0", "manifests": "a", "environment": {}}
SOURCES = {
    "Renderer/Cargo.toml": "[workspace]\n",
    "Renderer/Core/src/lib.rs": "pub fn core() {}\n",
    "Renderer/Core/src/window.rs": "pub fn window() {}\n",
    "Renderer/Engine/src/engine.cpp": "int engine() { return 1; }\n",
    "ThirdParty/naga/src/lib.rs": "pub fn naga() {}\n",
    "App/Main.swift": "print(1)\n",
}


class Checkout:
    """A repository whose files all carry the time of a fresh checkout, like a CI runner's."""

    def __init__(self, root):
        self.root = root
        self.record = root / "Renderer/target/source-times.json"
        self.git("init", "--quiet")
        for path, text in SOURCES.items():
            self.write(path, text)
        self.commit("sources")

    def git(self, *args):
        subprocess.run(["git", *IDENTITY, "-C", str(self.root), *args], check=True, capture_output=True)

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def commit(self, message):
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", message)

    def check_out_again(self):
        """Rewrite every tracked file and directory with the current time, keeping target/."""
        listed = subprocess.run(["git", "-C", str(self.root), "ls-files", "-z"], capture_output=True, check=True)
        for path in listed.stdout.decode().split("\0"):
            if path:
                (self.root / path).unlink()
        self.git("checkout", "--", ".")
        now = source_times.AGED + 10**9
        for directory, _, _ in os.walk(self.root / "Renderer"):
            os.utime(directory, (now, now))
        for directory, _, _ in os.walk(self.root / "ThirdParty"):
            os.utime(directory, (now, now))

    def aged(self, path):
        return int((self.root / path).stat().st_mtime) == source_times.AGED


class SourceTimesTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.checkout = Checkout(Path(directory.name))
        self.print = mock.patch("builtins.print").start()
        self.addCleanup(mock.patch.stopall)

    def record(self):
        return source_times.record(self.checkout.root, self.checkout.record, current=TOOLCHAIN)

    def restore(self, current=TOOLCHAIN):
        return source_times.restore(self.checkout.root, self.checkout.record, current=current)

    def test_unchanged_sources_and_their_directories_look_older_than_the_restored_build(self):
        self.record()
        self.checkout.check_out_again()

        self.assertIsNone(self.restore())
        for path in ("Renderer/Cargo.toml", "Renderer/Core/src/lib.rs", "ThirdParty/naga/src/lib.rs",
                     "Renderer/Core/src", "Renderer/Engine", "Renderer", "ThirdParty"):
            self.assertTrue(self.checkout.aged(path), path)

    def test_only_what_changed_keeps_the_checkout_time(self):
        self.record()
        self.checkout.write("Renderer/Core/src/window.rs", "pub fn window() { todo!() }\n")
        self.checkout.write("Renderer/Engine/src/added.cpp", "int added() { return 2; }\n")
        self.checkout.commit("change the renderer")
        self.checkout.check_out_again()

        self.restore()
        self.assertFalse(self.checkout.aged("Renderer/Core/src/window.rs"))
        self.assertFalse(self.checkout.aged("Renderer/Engine/src/added.cpp"))
        # The added file changed its directory's entries; the edited one did not.
        self.assertFalse(self.checkout.aged("Renderer/Engine/src"))
        self.assertTrue(self.checkout.aged("Renderer/Core/src"))
        self.assertTrue(self.checkout.aged("Renderer/Core/src/lib.rs"))

    def test_a_removed_source_leaves_its_directory_new_so_watchers_of_the_directory_rerun(self):
        self.record()
        self.checkout.git("rm", "--quiet", "Renderer/Core/src/window.rs")
        self.checkout.commit("remove a source")
        self.checkout.check_out_again()

        self.restore()
        self.assertFalse(self.checkout.aged("Renderer/Core/src"))
        self.assertTrue(self.checkout.aged("Renderer/Core/src/lib.rs"))

    def test_a_different_toolchain_ages_nothing(self):
        self.record()
        self.checkout.check_out_again()

        reason = self.restore({**TOOLCHAIN, "rustc": "rustc 2.0.0"})
        self.assertIn("rustc", reason)
        self.assertFalse(self.checkout.aged("Renderer/Core/src/lib.rs"))
        self.assertFalse(self.checkout.aged("Renderer"))

    def test_without_a_record_nothing_is_aged(self):
        self.checkout.check_out_again()

        self.assertIsNotNone(self.restore())
        self.assertFalse(self.checkout.aged("Renderer/Core/src/lib.rs"))

    def test_an_uncommitted_edit_is_never_aged_nor_is_its_directory(self):
        self.record()
        self.checkout.check_out_again()
        self.checkout.write("Renderer/Core/src/lib.rs", "pub fn core() { edited() }\n")

        self.restore()
        self.assertFalse(self.checkout.aged("Renderer/Core/src/lib.rs"))
        self.assertFalse(self.checkout.aged("Renderer/Core/src"))
        self.assertTrue(self.checkout.aged("Renderer/Engine/src/engine.cpp"))

    def test_sources_outside_the_renderer_keep_their_time(self):
        self.record()
        self.checkout.check_out_again()

        self.restore()
        self.assertFalse(self.checkout.aged("App/Main.swift"))

    def test_forget_removes_the_record_so_a_cache_saved_afterwards_is_not_trusted(self):
        self.record()
        with mock.patch.object(sys, "argv", ["source_times.py", "forget", "--root", str(self.checkout.root)]):
            self.assertEqual(source_times.main(), 0)
        self.checkout.check_out_again()

        self.assertIsNotNone(self.restore())
        self.assertFalse(self.checkout.aged("Renderer/Core/src/lib.rs"))


class ToolchainTests(unittest.TestCase):
    def test_a_changed_cargo_manifest_or_build_flag_changes_the_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Checkout(Path(directory))
            with mock.patch.object(source_times, "command_output", return_value="same"):
                before = source_times.toolchain(checkout.root, environ={})
                checkout.write("Renderer/Cargo.toml", "[workspace]\nmembers = []\n")
                checkout.commit("edit the manifest")
                edited = source_times.toolchain(checkout.root, environ={})
                self.assertNotEqual(edited, before)
                self.assertNotEqual(source_times.toolchain(checkout.root, environ={"RUSTFLAGS": "-Ctarget-cpu=native"}), edited)
                # The runner's own environment varies from job to job and changes no output.
                self.assertEqual(source_times.toolchain(checkout.root, environ={"HOME": "/elsewhere"}), edited)


if __name__ == "__main__":
    unittest.main()
