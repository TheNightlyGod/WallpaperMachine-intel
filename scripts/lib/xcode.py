"""Run noisy build tools quietly: full output to a log file, only failures on screen.

`xcodebuild` prints thousands of lines per run and `cargo` hundreds; when a script
is driven by a person or an agent, only compile errors, failing tests and the final
verdict matter, and the rest is evidence that belongs in `artifacts/`. `run_quiet`
streams every line to a log and echoes only the lines `interesting()` keeps, capped
so a pathological run cannot flood the terminal either. `--verbose` on the calling
script bypasses the filter for the cases where the raw stream is the point.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys

# Lines worth reading when something went wrong. Order does not matter; a line is
# echoed when any pattern matches and no NOISE pattern does.
INTERESTING = tuple(re.compile(pattern) for pattern in (
    r"^.+?\.(?:swift|rs|c|cc|cpp|h|hpp|m|mm|metal):\d+(?::\d+)?: (?:error|fatal error):",
    r"^error(?:\[E\d+\])?:",  # cargo / rustc
    r"^(?:xcodebuild|xcodegen|ld|clang|swiftc|cargo): error:",
    r"\*\* (?:BUILD|TEST|ARCHIVE|CLEAN) FAILED \*\*",
    r"^Test Case '.*' failed",
    r"^Testing failed:",
    r"^Test Suite '.*' failed",
    r"Restarting after unexpected exit, crash, or test timeout",
    r"^error: ",
    r"^fatal error: ",
    r"^Error: ",
    r"^The following build commands failed:",
    r"^Command \S+ failed with a nonzero exit code",
    r"^\s*(?:\S+\.swift:\d+: error: |XCTAssert|Executed \d+ tests?, with \d+ failures? \(\d+ unexpected\))",
    r"could not build module|no such module|linker command failed|Undefined symbols",
    # actool and other resource compilers: an absolute path with no line number, and
    # Interface Builder's agent dying mid-compile.
    r"^/\S+: (?:error|fatal error):",
    r"IBPlatformToolFailureException|Terminating app due to uncaught exception",
))

# Runtime chatter that happens to contain the word "error": Xcode plug-in faults,
# simulator warnings, `os_log` lines from the hosted app, and the rows XCTest prints
# for tests that passed.
NOISE = tuple(re.compile(pattern) for pattern in (
    r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}",  # timestamped process log lines
    r"DVTPlugIn|CoreSimulator|SimServiceContext|IDEDerivedDataPathOverride",
    r"^Test Case '.*' (?:passed|started|skipped)",
    r"with 0 failures \(0 unexpected\)",
))

# After one of these headers, the indented lines that follow are the useful part.
BLOCK_HEADERS = tuple(re.compile(pattern) for pattern in (
    r"^The following build commands failed:",
    r"^Testing failed:",
))

MAX_ECHOED_LINES = 200
SKIP_REASON = re.compile(r"\bskipping\s+|^\[\s*SKIP(?:PED)?\s*\]", re.IGNORECASE)


def skipped_test_lines(lines):
    """Keep explicit skip observations, including Rust's corpus early returns."""
    return list(dict.fromkeys(line.strip() for line in lines if SKIP_REASON.search(line)))


def interesting(line: str) -> bool:
    """True for a single line that should reach the terminal on its own merit."""
    if any(pattern.search(line) for pattern in NOISE):
        return False
    return any(pattern.search(line) for pattern in INTERESTING)


def filter_lines(lines, limit=MAX_ECHOED_LINES):
    """Yield the lines worth echoing, including bodies of failure blocks, deduplicated."""
    seen = set()
    in_block = False
    emitted = 0
    for raw in lines:
        # The caller writes the log while producing this iterator. Keep draining
        # it after the display limit so a noisy child can finish normally.
        if emitted > limit:
            continue
        line = raw.rstrip("\n")
        stripped = line.strip()
        if in_block:
            if stripped and (line[:1].isspace() or stripped.startswith("(")):
                keep = True
            else:
                in_block = False
                keep = interesting(line)
        else:
            keep = interesting(line)
        if keep and any(pattern.search(line) for pattern in BLOCK_HEADERS):
            in_block = True
        if not keep or stripped in seen:
            continue
        seen.add(stripped)
        emitted += 1
        if emitted > limit:
            yield f"... further lines omitted; see the log"
            continue
        yield line


def run_quiet(command, log_path: Path, cwd=None, env=None, verbose=False, echo=None):
    """Run `command`, write everything it prints to `log_path`, echo only what matters.

    Returns the `CompletedProcess`; the caller decides what a non-zero status means.
    With `verbose`, every line is echoed as well as logged.
    """
    echo = echo or (lambda text: print(text, flush=True))
    log_path = Path(log_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    warnings = 0
    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        log.write("$ " + " ".join(map(str, command)) + "\n")
        process = subprocess.Popen(
            list(map(str, command)), cwd=cwd, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1,
        )
        assert process.stdout is not None

        def logged():
            nonlocal warnings
            for line in process.stdout:
                log.write(line)
                if "warning:" in line:
                    warnings += 1
                if verbose:
                    sys.stdout.write(line)
                yield line

        try:
            if verbose:
                for _ in logged():
                    pass
            else:
                for line in filter_lines(logged()):
                    echo(line)
        finally:
            process.stdout.close()
            returncode = process.wait()
    if warnings and not verbose:
        echo(f"  {warnings} warning line(s) in the log")
    return subprocess.CompletedProcess(command, returncode), log_path


def test_summary(result_bundle: Path, cwd=None):
    """One-line verdict plus one line per failing test, from `xcresulttool`'s summary.

    Returns `(lines, failed)`; `failed` is None when the bundle could not be read.
    """
    try:
        raw = subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result_bundle)],
            cwd=cwd, text=True, stderr=subprocess.STDOUT,
        )
        summary = json.loads(raw)
    except (subprocess.CalledProcessError, ValueError, OSError) as error:
        return [f"Could not read test summary from {result_bundle}: {error}"], None
    return summarize(summary)


def summarize(summary: dict):
    """Format the JSON summary `xcresulttool get test-results summary` returns."""
    passed = summary.get("passedTests", 0)
    failed = summary.get("failedTests", 0)
    skipped = summary.get("skippedTests", 0)
    expected = summary.get("expectedFailures", 0)
    total = summary.get("totalTestCount", passed + failed + skipped)
    start, finish = summary.get("startTime"), summary.get("finishTime")
    duration = f" in {finish - start:.0f}s" if isinstance(start, (int, float)) and isinstance(finish, (int, float)) else ""
    verdict = summary.get("result", "Failed" if failed else "Passed")
    parts = [f"{passed} passed", f"{failed} failed", f"{skipped} skipped"]
    if expected:
        parts.append(f"{expected} expected failures")
    lines = [f"{verdict}: {', '.join(parts)} of {total}{duration}"]
    for failure in summary.get("testFailures", []):
        # Newer xcresulttool numbers `testIdentifier` and names the test in `testIdentifierString`.
        identifier = failure.get("testIdentifier")
        name = (failure.get("testIdentifierString") or (identifier if isinstance(identifier, str) else None)
                or failure.get("testName") or "?")
        text = " ".join(str(failure.get("failureText", "")).split())
        lines.append(f"  FAIL {name}: {text}" if text else f"  FAIL {name}")
    warnings = summary.get("runtimeWarnings") or []
    if warnings:
        lines.append(f"  {len(warnings)} runtime warning(s); see the result bundle")
    return lines, failed
