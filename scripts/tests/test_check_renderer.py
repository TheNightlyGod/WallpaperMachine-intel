#!/usr/bin/env python3
"""Behavior tests for renderer pixels, process policy, measurements and gate exit."""
from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("check_renderer", SCRIPTS / "check_renderer.py")
check_renderer = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(check_renderer)

WIDTH, HEIGHT = 384, 256
MARGIN = bytes((26, 51, 77))
PAGE = bytes((255, 255, 255))
# The paused parent timeline holds the third corner on its first key; leaving it
# on the constant value is the defect the fixture has to make visible.
AUTHORED = [(0.25, 0.5), (0.75, 0.375), (0.875, 0.875), (0.375, 1.0)]
STATIC_CORNER = [(0.25, 0.5), (0.75, 0.375), (0.375, 0.875), (0.375, 1.0)]


def benchmark_payload(delivered=50, **changes):
    payload = {"schema": 1, "requested_fps": 60, "busy_work_ns": 18_000_000,
               "requested_warmup_ns": 200_000_000, "requested_window_ns": 1_000_000_000,
               "window_start_ns": -100_000_000, "window_end_ns": 1_150_000_000,
               "count_before": 7, "count_after": 7 + delivered, "delivered": delivered}
    payload.update(changes)
    return payload


def benchmark_line(payload):
    return "TIMER_DELIVERY_BENCHMARK " + json.dumps(payload) + "\n"


def ppm(shade):
    """Render a 384x256 P6 frame the way the probe writes one."""
    body = bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            body += shade((x + 0.5) / WIDTH, (y + 0.5) / HEIGHT)
    return b"P6\n%d %d\n255\n" % (WIDTH, HEIGHT) + bytes(body)


def quad_mask(corners):
    """The square-to-quad homography the fixture shader inverts per fragment."""
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = corners
    sx, sy = x0 - x1 + x2 - x3, y0 - y1 + y2 - y3
    dx1, dy1 = x1 - x2, y1 - y2
    dx2, dy2 = x3 - x2, y3 - y2
    basis = dx1 * dy2 - dx2 * dy1
    g = (sx * dy2 - dx2 * sy) / basis
    h = (dx1 * sy - sx * dy1) / basis
    a, b, c = x1 - x0 + g * x1, x3 - x0 + h * x3, x0
    d, e, f = y1 - y0 + g * y1, y3 - y0 + h * y3, y0
    det = a * (e - f * h) - b * (d - f * g) + c * (d * h - e * g)
    rows = [[value / det for value in row] for row in
            [[e - f * h, c * h - b, b * f - c * e],
             [f * g - d, a - c * g, c * d - a * f],
             [d * h - e * g, b * g - a * h, a * e - b * d]]]

    def shade(u, v):
        point = (u, v, 1.0)
        w = sum(factor * value for factor, value in zip(rows[2], point))
        if w <= 0.0:
            return MARGIN
        square = [sum(factor * value for factor, value in zip(row, point)) / w for row in rows[:2]]
        return PAGE if all(0.0 <= value <= 1.0 for value in square) else MARGIN

    return shade


@unittest.skipUnless(sys.platform == "darwin", "Darwin process policy")
class TestProcessPolicyTests(unittest.TestCase):
    def test_background_driver_runs_foreground_tests_and_preserves_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            probe = root / "timer_tests"
            probe.write_text(f"#!{sys.executable}\n"
                             "import json, os\n"
                             "print(json.dumps([os.getpriority(kind, 0) for kind in "
                             "(os.PRIO_DARWIN_PROCESS, os.PRIO_DARWIN_THREAD)]))\n"
                             "raise SystemExit(23)\n")
            probe.chmod(0o755)
            control = subprocess.run(["/usr/sbin/taskpolicy", "-b", str(probe)],
                                     capture_output=True, text=True, timeout=30)
            self.assertEqual(control.returncode, 23)
            self.assertNotEqual(json.loads(control.stdout), [0, 0])
            log = root / "probe.log"
            driver = ("import os, sys; from pathlib import Path; "
                      f"sys.path.insert(0, {str(SCRIPTS)!r}); import check_renderer; "
                      f"raise SystemExit(check_renderer.run([{str(probe)!r}], "
                      f"Path({str(log)!r}), os.environ.copy()))")
            result = subprocess.run(["/usr/sbin/taskpolicy", "-b", sys.executable, "-c", driver],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertEqual(json.loads(log.read_text()), [0, 0])


class PerspectiveCornerPixelTests(unittest.TestCase):
    def test_accepts_the_page_drawn_from_the_authored_first_key(self):
        self.assertTrue(check_renderer.check_generated_pixels(ppm(quad_mask(AUTHORED)), 9))

    def test_rejects_the_wedge_left_by_the_unanimated_corner(self):
        self.assertFalse(check_renderer.check_generated_pixels(ppm(quad_mask(STATIC_CORNER)), 9))

    def test_rejects_frames_with_no_page_and_frames_that_are_only_page(self):
        for fill in [MARGIN, PAGE]:
            with self.subTest(fill=fill):
                self.assertFalse(
                    check_renderer.check_generated_pixels(ppm(lambda u, v, c=fill: c), 9))

    def test_rejects_the_right_page_over_the_wrong_background(self):
        # A correct page over a cleared-to-black or recoloured target is still a
        # broken frame, so matching the two margins to each other is not enough.
        for wrong in [bytes((0, 0, 0)), bytes((26, 51, 180))]:
            with self.subTest(background=wrong):
                page = quad_mask(AUTHORED)
                shade = lambda u, v: PAGE if page(u, v) == PAGE else wrong
                self.assertFalse(check_renderer.check_generated_pixels(ppm(shade), 9))


class CoveragePixelTests(unittest.TestCase):
    def test_checks_source_over_and_single_sample_coverage_identically(self):
        for index in (8, 11):
            def coverage(u, v):
                value = 128 if u < 0.375 else 191 if u < 0.625 else 255
                return bytes((value,) * 3)
            self.assertTrue(check_renderer.check_generated_pixels(ppm(coverage), index))
            for wrong in (64, 128, 255):
                self.assertFalse(check_renderer.check_generated_pixels(
                    ppm(lambda u, v: bytes((wrong,) * 3)), index))


class OriginCurtainPixelTests(unittest.TestCase):
    def test_accepts_both_halves_revealed_after_the_intro(self):
        self.assertTrue(check_renderer.check_generated_pixels(
            ppm(lambda u, v: bytes((51, 102, 153))), 10))

    def test_rejects_a_stuck_curtain_or_blank_frame(self):
        for shade in [lambda u, v: bytes((51, 102, 153)) if u < 0.5 else bytes(3),
                      lambda u, v: bytes(3)]:
            self.assertFalse(check_renderer.check_generated_pixels(ppm(shade), 10))


@unittest.skipUnless(sys.platform == "darwin", "Metal-device capability probe requires the macOS SDK")
class GPUAvailabilityProbeTests(unittest.TestCase):
    def test_compiled_probe_distinguishes_device_presence_without_rendering(self):
        with tempfile.TemporaryDirectory() as directory:
            result = check_renderer.gpu_preflight(Path(directory), dict(check_renderer.os.environ))
            log = (Path(directory) / "gpu-compile_exit.log").read_text()
        self.assertEqual(result["compile_exit"], 0, log)
        self.assertIn(result["probe_exit"], (0, 77))

    def test_compiled_timer_probe_measures_short_waits(self):
        with tempfile.TemporaryDirectory() as directory:
            result = check_renderer.timer_preflight(Path(directory), dict(check_renderer.os.environ))
            compile_log = (Path(directory) / "timer-compile_exit.log").read_text()
            probe_log = (Path(directory) / "timer-probe_exit.log").read_text()
        self.assertEqual(result["compile_exit"], 0, compile_log)
        self.assertIn(result["probe_exit"], (0, 77))
        self.assertIn("median 10 ms wait", probe_log)


class TimerDeliveryBenchmarkTests(unittest.TestCase):
    def test_collects_low_zero_and_high_counts_using_the_actual_outer_window(self):
        for delivered in (0, 1, 600):
            with self.subTest(delivered=delivered), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                payload = benchmark_payload(delivered)
                raw = "collection diagnostic\n" + benchmark_line(payload)
                environment = {"MEASUREMENT_FIXTURE": "1"}

                def process(command, **kwargs):
                    kwargs["stdout"].write(raw)
                    return subprocess.CompletedProcess(command, 0)

                with patch.object(check_renderer.subprocess, "run", side_effect=process) as child:
                    result = check_renderer.collect_timer_delivery_benchmark(root / "bin", root, environment)
                self.assertEqual(child.call_count, 1)
                self.assertEqual(result["exit"], 0)
                self.assertEqual(result["status"], "collected")
                self.assertTrue(result["diagnostic_only"])
                self.assertEqual(result["measurement"], payload)
                self.assertEqual(result["actual_outer_duration_ns"], 1_250_000_000)
                self.assertEqual(result["delivered_per_second"], delivered / 1.25)
                self.assertEqual(Path(result["log"]).read_text(), raw)

    def test_rejects_missing_nonintegral_and_boolean_fields(self):
        payload = benchmark_payload()
        for name in payload:
            missing = payload.copy()
            del missing[name]
            with self.subTest(missing=name), self.assertRaises(ValueError):
                check_renderer.parse_timer_delivery_benchmark(benchmark_line(missing))
            for value in (True, float(payload[name]), str(payload[name])):
                with self.subTest(field=name, value=value), self.assertRaises(ValueError):
                    check_renderer.parse_timer_delivery_benchmark(benchmark_line({**payload, name: value}))

    def test_rejects_wrong_schema_or_requested_configuration(self):
        for name in ("schema", "requested_fps", "busy_work_ns", "requested_warmup_ns", "requested_window_ns"):
            payload = benchmark_payload()
            payload[name] += 1
            with self.subTest(field=name), self.assertRaises(ValueError):
                check_renderer.parse_timer_delivery_benchmark(benchmark_line(payload))

    def test_rejects_inconsistent_counters_and_nonpositive_outer_windows(self):
        payload = benchmark_payload()
        for changes in ({"window_end_ns": payload["window_start_ns"]},
                        {"window_end_ns": payload["window_start_ns"] - 1},
                        {"count_before": -1}, {"count_before": -1, "count_after": -1, "delivered": 0},
                        {"count_after": payload["count_before"] - 1}, {"count_after": -1},
                        {"delivered": -1}, {"delivered": payload["count_after"] - payload["count_before"] + 1}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                check_renderer.parse_timer_delivery_benchmark(benchmark_line({**payload, **changes}))

    def test_rejects_missing_duplicate_and_malformed_protocol_data(self):
        valid = benchmark_line(benchmark_payload())
        duplicate_key = valid.replace('"schema": 1', '"schema": 1, "schema": 1')
        for text in ("", "only an unrelated log line\n", valid + valid, duplicate_key,
                     "TIMER_DELIVERY_BENCHMARK{}\n", "TIMER_DELIVERY_BENCHMARK {\n",
                     "TIMER_DELIVERY_BENCHMARK []\n", "TIMER_DELIVERY_BENCHMARK null\n",
                     valid.rstrip() + " trailing text\n",
                     benchmark_line({**benchmark_payload(), "invalid": float("nan")})):
            with self.subTest(text=text), self.assertRaises(ValueError):
                check_renderer.parse_timer_delivery_benchmark(text)

    def test_operational_failures_preserve_logs_without_fabricating_a_measurement(self):
        raw = "raw collection diagnostics\n" + benchmark_line(benchmark_payload())
        for outcome, expected in ((9, 9), (subprocess.TimeoutExpired(["benchmark"], 30), "timeout"),
                                  (FileNotFoundError("benchmark could not be invoked"), "error")):
            with self.subTest(outcome=expected), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)

                def process(command, **kwargs):
                    kwargs["stdout"].write(raw)
                    if isinstance(outcome, Exception):
                        raise outcome
                    return subprocess.CompletedProcess(command, outcome)

                with patch.object(check_renderer.subprocess, "run", side_effect=process) as child:
                    result = check_renderer.collect_timer_delivery_benchmark(root / "bin", root, {})
                self.assertEqual(child.call_count, 1)
                self.assertEqual(result["exit"], expected)
                self.assertEqual(result["status"], "tooling-failure")
                self.assertTrue(result["diagnostic_only"])
                self.assertTrue(result["error"])
                for name in ("measurement", "actual_outer_duration_ns", "delivered_per_second"):
                    self.assertNotIn(name, result)
                self.assertEqual(Path(result["log"]).read_text(), raw)


class GateExitStatusTests(unittest.TestCase):
    def gate(self, failed=None, timeout=False, skipped=None, gpu=None, extra_project=False, timers=None,
             benchmark_text=None, benchmark_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "project.json"
            project.write_text('{"file":"scene.json"}')
            calls = []
            self.commands = {}
            assets_used = []

            def run(command, log, env, *args):
                name = Path(command[0]).name
                calls.append(name)
                self.commands[name] = [str(part) for part in command]
                if name in (check_renderer.OFFSCREEN_PROBE, check_renderer.RELOAD_PROBE):
                    assets = Path(env["WE_TEST_ASSETS"])
                    assets_used.append((name, assets == (root / "assets").resolve(), assets.is_dir()))
                log.write_text("[  SKIPPED ] unavailable fixture codec\n" if name == skipped else "")
                if name == "xcrun":
                    name = Path(command[command.index("-o") + 1]).name
                    probe = timers if name == check_renderer.TIMER_PROBE else gpu
                    if probe[0] == "timeout":
                        raise check_renderer.subprocess.TimeoutExpired(command, 1)
                    return probe[0]
                if name in ("gpu-availability", check_renderer.TIMER_PROBE):
                    if name == check_renderer.TIMER_PROBE:
                        log.write_text("median 10 ms wait: 55.00 ms\n")
                    result = (timers if name == check_renderer.TIMER_PROBE else gpu)[1]
                    if result == "timeout":
                        raise check_renderer.subprocess.TimeoutExpired(command, 1)
                    return result
                if name == check_renderer.TIMER_DELIVERY_BENCHMARK:
                    log.write_text(benchmark_line(benchmark_payload()) if benchmark_text is None else benchmark_text)
                    if benchmark_exit == "timeout":
                        raise check_renderer.subprocess.TimeoutExpired(command, 30)
                    if benchmark_exit == "error":
                        raise FileNotFoundError("benchmark invocation unavailable")
                    return benchmark_exit
                if name == failed:
                    if timeout:
                        raise check_renderer.subprocess.TimeoutExpired(command, 1)
                    return 1
                if name == check_renderer.OFFSCREEN_PROBE:
                    output = Path(env["WE_TEST_OUTPUT"])
                    output.mkdir(parents=True)
                    (output / "frame-2.ppm").write_bytes(b"same synthetic pixels")
                return 0

            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(check_renderer, "RENDERER_ARTIFACTS", root / "evidence"))
                stack.enter_context(patch.object(check_renderer, "build_environment", return_value={}))
                stack.enter_context(patch.object(check_renderer, "run", side_effect=run))
                stack.enter_context(patch.object(check_renderer, "fixtures", return_value=[]))
                for name in ("alpha_composite_fixture", "perspective_animation_fixture", "origin_animation_fixture"):
                    stack.enter_context(patch.object(check_renderer, name, return_value=project))
                stack.enter_context(patch.object(check_renderer, "check_generated_pixels", return_value=True))
                output = io.StringIO()
                stack.enter_context(contextlib.redirect_stdout(output))
                arguments = ["--skip-build", "--assets", str(root / "assets")]
                if extra_project:
                    arguments.extend(["--project", str(project)])
                if gpu is not None:
                    arguments.append("--allow-missing-gpu")
                if timers is not None:
                    arguments.append("--allow-imprecise-timers")
                status = check_renderer.main(arguments)
                self.last_output = output.getvalue()
                self.assets_used = assets_used
            report = json.loads(next((root / "evidence").glob("*/report.json")).read_text())
            return status, report, calls

    def test_each_required_binary_failure_and_timeout_fail_the_gate(self):
        for binary in (*check_renderer.REGRESSION_BINARIES, check_renderer.RELOAD_PROBE):
            for timeout in (False, True):
                with self.subTest(binary=binary, timeout=timeout):
                    status, report, calls = self.gate(binary, timeout)
                    self.assertEqual(status, 1)
                    self.assertEqual(report[binary], "timeout" if timeout else 1)
                    self.assertIn(check_renderer.RELOAD_PROBE, calls)

    def test_all_successful_binaries_and_pixel_checks_pass(self):
        status, report, calls = self.gate()
        self.assertEqual(status, 0)
        self.assertTrue(all(report[name] == 0 for name in check_renderer.REGRESSION_BINARIES))
        # Both parents' extra scenes remain: alpha, perspective, origin and single-sample alpha.
        self.assertEqual(len(report["cases"]), 4)
        self.assertEqual(calls.count(check_renderer.OFFSCREEN_PROBE), 8)
        self.assertTrue(all(case["pixels_equal"] for case in report["cases"]))

    def test_valid_delivery_counts_are_diagnostic_and_never_gate_throughput(self):
        for delivered in (0, 1, 600):
            payload = benchmark_payload(delivered)
            with self.subTest(delivered=delivered):
                status, report, calls = self.gate(benchmark_text=benchmark_line(payload))
                result = report[check_renderer.TIMER_DELIVERY_BENCHMARK]
                self.assertEqual(status, 0)
                self.assertEqual(calls.count(check_renderer.TIMER_DELIVERY_BENCHMARK), 1)
                self.assertEqual(result["status"], "collected")
                self.assertTrue(result["diagnostic_only"])
                self.assertEqual(result["measurement"], payload)
                self.assertEqual(result["actual_outer_duration_ns"], 1_250_000_000)
                self.assertEqual(result["delivered_per_second"], delivered / 1.25)
                self.assertIn("diagnostic only", self.last_output)

    def test_benchmark_operational_failures_fail_the_gate_without_retrying(self):
        for outcome in (7, "timeout", "error"):
            with self.subTest(outcome=outcome):
                status, report, calls = self.gate(benchmark_exit=outcome)
                result = report[check_renderer.TIMER_DELIVERY_BENCHMARK]
                self.assertEqual(status, 1)
                self.assertEqual(calls.count(check_renderer.TIMER_DELIVERY_BENCHMARK), 1)
                self.assertEqual(result["exit"], outcome)
                self.assertEqual(result["status"], "tooling-failure")
                self.assertTrue(result["error"])
                self.assertNotIn("measurement", result)
                self.assertIn(check_renderer.RELOAD_PROBE, calls)
                self.assertIn("tooling failure", self.last_output)

    def test_missing_duplicate_malformed_or_inconsistent_measurements_fail_the_gate(self):
        valid = benchmark_line(benchmark_payload())
        for text in ("", valid + valid, "TIMER_DELIVERY_BENCHMARK {\n",
                     benchmark_line(benchmark_payload(delivered=51, count_after=57)),
                     benchmark_line(benchmark_payload(window_end_ns=-100_000_000))):
            with self.subTest(text=text):
                status, report, calls = self.gate(benchmark_text=text)
                result = report[check_renderer.TIMER_DELIVERY_BENCHMARK]
                self.assertEqual(status, 1)
                self.assertEqual(result["exit"], 0)
                self.assertEqual(result["status"], "tooling-failure")
                self.assertTrue(result["error"])
                self.assertNotIn("measurement", result)
                self.assertEqual(calls.count(check_renderer.TIMER_DELIVERY_BENCHMARK), 1)

    def test_gpu_and_cadence_skips_do_not_skip_or_filter_the_benchmark(self):
        status, report, calls = self.gate(gpu=(0, 77), timers=(0, 77),
                                        benchmark_text=benchmark_line(benchmark_payload(0)))
        self.assertEqual(status, 0)
        self.assertEqual(calls.count(check_renderer.TIMER_DELIVERY_BENCHMARK), 1)
        self.assertEqual(report[check_renderer.TIMER_DELIVERY_BENCHMARK]["measurement"]["delivered"], 0)
        self.assertNotIn(check_renderer.TIMER_DELIVERY_BENCHMARK, report["skips"])
        self.assertEqual(len(self.commands[check_renderer.TIMER_DELIVERY_BENCHMARK]), 1)

    def test_generated_scenes_and_reload_work_without_an_installed_asset_directory(self):
        status, _, _ = self.gate()
        self.assertEqual(status, 0)
        self.assertTrue(self.assets_used)
        self.assertTrue(all(not explicit and exists for _, explicit, exists in self.assets_used))

    def test_optional_local_project_and_reload_keep_the_requested_assets(self):
        self.gate(extra_project=True)
        probes = [explicit for name, explicit, _ in self.assets_used
                  if name == check_renderer.OFFSCREEN_PROBE]
        self.assertEqual(probes, [False] * 8 + [True] * 2)
        reloads = [explicit for name, explicit, _ in self.assets_used
                   if name == check_renderer.RELOAD_PROBE]
        self.assertEqual(reloads, [True])

    def test_skip_reason_is_reported_separately_from_successful_exit(self):
        binary = next(iter(check_renderer.REGRESSION_BINARIES))
        status, report, _ = self.gate(skipped=binary)
        self.assertEqual(status, 0)
        self.assertEqual(report[binary], 0)
        self.assertEqual(report["skips"][binary], ["[  SKIPPED ] unavailable fixture codec"])

    def test_available_gpu_runs_every_registered_target_and_image_probe(self):
        status, report, calls = self.gate(gpu=(0, 0))
        self.assertEqual(status, 0)
        self.assertTrue(report["gpu_checks_executed"])
        self.assertTrue(set(check_renderer.REGRESSION_BINARIES).issubset(calls))
        self.assertIn(check_renderer.OFFSCREEN_PROBE, calls)

    def test_only_explicit_no_device_skips_exact_gpu_targets_and_warns(self):
        status, report, calls = self.gate(gpu=(0, 77))
        self.assertEqual(status, 0)
        expected = {name for name, needed in check_renderer.REGRESSION_BINARIES.items() if needed}
        expected.update([check_renderer.OFFSCREEN_PROBE, check_renderer.RELOAD_PROBE])
        self.assertEqual(set(report["skips"]), expected)
        self.assertTrue(expected.isdisjoint(calls))
        self.assertTrue({name for name, needed in check_renderer.REGRESSION_BINARIES.items() if not needed}.issubset(calls))
        self.assertFalse(report["gpu_checks_executed"])
        self.assertIn("::warning::", self.last_output)
        for target in expected:
            self.assertIn(target, self.last_output)

    def test_preflight_compilation_failure_is_a_failure_not_a_skip(self):
        status, report, calls = self.gate(gpu=(1, None))
        self.assertEqual(status, 1)
        self.assertEqual(report["gpu_preflight"]["compile_exit"], 1)
        self.assertEqual(report["skips"], {})
        self.assertNotIn("gpu-availability", calls)

    def test_abnormal_or_timed_out_preflight_is_a_failure_not_a_skip(self):
        for result in (1, 2, "timeout"):
            with self.subTest(result=result):
                status, report, _ = self.gate(gpu=(0, result))
                self.assertEqual(status, 1)
                self.assertEqual(report["gpu_preflight"]["probe_exit"], result)
                self.assertEqual(report["skips"], {})

    def test_started_gpu_failure_and_cpu_failure_without_gpu_still_fail(self):
        gpu_test = next(name for name, needed in check_renderer.REGRESSION_BINARIES.items() if needed)
        cpu_test = next(name for name, needed in check_renderer.REGRESSION_BINARIES.items() if not needed)
        for target, probe in ((gpu_test, (0, 0)), (cpu_test, (0, 77))):
            with self.subTest(target=target):
                status, report, _ = self.gate(failed=target, gpu=probe)
                self.assertEqual(status, 1)
                self.assertEqual(report[target], 1)
                self.assertNotIn(target, report["skips"])

    def test_precise_timers_run_every_cadence_test(self):
        status, report, _ = self.gate(timers=(0, 0))
        self.assertEqual(status, 0)
        self.assertTrue(report["realtime_checks_executed"])
        self.assertEqual(report["skips"], {})
        self.assertFalse(any("--gtest_filter" in part for command in self.commands.values() for part in command))

    def test_only_explicit_imprecise_timers_skip_exact_cadence_tests_and_warn(self):
        status, report, calls = self.gate(timers=(0, 77))
        self.assertEqual(status, 0)
        self.assertFalse(report["realtime_checks_executed"])
        self.assertTrue(set(check_renderer.REGRESSION_BINARIES).issubset(calls))
        for binary in check_renderer.REGRESSION_BINARIES:
            names = check_renderer.REALTIME_TESTS.get(binary, ())
            filters = [part for part in self.commands[binary] if part.startswith("--gtest_filter")]
            with self.subTest(binary=binary):
                self.assertEqual(filters, ["--gtest_filter=-" + ":".join(names)] if names else [])
                self.assertEqual([reason.split(":")[0] for reason in report["skips"].get(binary, [])], list(names))
        self.assertIn("::warning::" if check_renderer.os.environ.get("GITHUB_ACTIONS") == "true" else "SKIP ",
                      self.last_output)
        self.assertIn("55.00 ms", self.last_output)

    def test_timer_preflight_failure_is_a_failure_not_a_skip(self):
        for probe in ((1, None), (0, 1), (0, "timeout"), ("timeout", None)):
            with self.subTest(probe=probe):
                status, report, calls = self.gate(timers=probe)
                self.assertEqual(status, 1)
                self.assertEqual(report["skips"], {})
                self.assertTrue(set(check_renderer.REGRESSION_BINARIES).isdisjoint(calls))

    def test_remaining_failures_in_a_filtered_binary_still_fail(self):
        binary = next(iter(check_renderer.REALTIME_TESTS))
        status, report, _ = self.gate(failed=binary, timers=(0, 77))
        self.assertEqual(status, 1)
        self.assertEqual(report[binary], 1)

    def test_image_probe_failure_or_timeout_is_not_a_missing_gpu_skip(self):
        for timeout in (False, True):
            with self.subTest(timeout=timeout):
                status, report, _ = self.gate(failed=check_renderer.OFFSCREEN_PROBE, timeout=timeout, gpu=(0, 0))
                self.assertEqual(status, 1)
                self.assertTrue(report["gpu_checks_executed"])
                self.assertFalse(any(case["pixels_equal"] for case in report["cases"]))
                self.assertNotIn(check_renderer.OFFSCREEN_PROBE, report["skips"])


class ForeignBuildTreeTests(unittest.TestCase):
    def tree(self, home):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        source, build = root / "Engine", root / "bin"
        source.mkdir()
        build.mkdir()
        (build / "CMakeCache.txt").write_text(f"CMAKE_BUILD_TYPE:STRING=Release\nCMAKE_HOME_DIRECTORY:INTERNAL={home(root)}\n")
        return source, build

    def test_a_tree_from_another_source_directory_is_removed(self):
        source, build = self.tree(lambda root: root / "upstream/open-wallpaper-engine")
        self.assertTrue(check_renderer.discard_foreign_build_tree(build, source))
        self.assertFalse(build.exists())

    def test_a_tree_from_the_same_source_or_no_tree_is_kept(self):
        source, build = self.tree(lambda root: root / "Engine")
        self.assertFalse(check_renderer.discard_foreign_build_tree(build, source))
        self.assertTrue((build / "CMakeCache.txt").is_file())
        self.assertFalse(check_renderer.discard_foreign_build_tree(source / "missing", source))


if __name__ == "__main__":
    unittest.main()
