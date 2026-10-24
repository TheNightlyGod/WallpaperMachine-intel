#!/usr/bin/env python3
"""Rust gate failures, skip reporting and per-run state isolation."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("check_rust", SCRIPTS / "check_rust.py")
check_rust = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_rust)


class RustGateTests(unittest.TestCase):
    def gate(self, fail=None, unavailable=False):
        environments = []
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "logs"

            def run(command, log, cwd, env):
                environments.append(dict(env))
                self.assertTrue(Path(env["WALLPAPER_MACHINE_HOME"]).is_dir())
                if unavailable:
                    raise FileNotFoundError("cargo unavailable")
                code = 1 if log.stem == fail else 0
                log.write_text("skipping local corpus case: fixture directory is unavailable\n"
                               + ("test result: FAILED. 1 failed\n" if code else "test result: ok. 1 passed\n"))
                return subprocess.CompletedProcess(command, code), log

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = check_rust.run_checks(output, {**dict.fromkeys(check_rust.OPT_INS, "1"),
                                                      "WALLPAPER_MACHINE_HOME": "/never-use-the-real-library"}, run)
            report = json.loads((output / "report.json").read_text())
        return code, report, environments

    def test_every_cargo_failure_blocks_the_gate_and_remains_in_the_report(self):
        for name, _, _ in check_rust.CHECKS:
            with self.subTest(check=name):
                code, report, _ = self.gate(fail=name)
                self.assertEqual(code, 1)
                self.assertEqual(next(r for r in report["results"] if r["name"] == name)["exit"], 1)

    def test_missing_cargo_cannot_report_success(self):
        code, report, _ = self.gate(unavailable=True)
        self.assertEqual(code, 1)
        self.assertTrue(all(r["exit"] != 0 for r in report["results"]))

    def test_success_never_inherits_live_opt_ins_and_removes_isolated_state(self):
        code, _, environments = self.gate()
        self.assertEqual(code, 0)
        for env in environments:
            self.assertTrue(all(name not in env for name in check_rust.OPT_INS))
            self.assertNotEqual(env["WALLPAPER_MACHINE_HOME"], "/never-use-the-real-library")
            self.assertFalse(Path(env["WALLPAPER_MACHINE_HOME"]).exists(), "isolated state is removed after the run")



if __name__ == "__main__":
    unittest.main()
