# Development tools

Optional tools for diagnosing behavior that the routine test suite cannot
observe. None of them is a build or test dependency, and every use that touches
the desktop needs an explicit request (see [Authorization boundary](#authorization-boundary)).

## Safe setup check

Run `python3 scripts/check_dev_tools.py`. It looks for the Peekaboo CLI on `PATH`
(and runs `peekaboo --version`), for Instruments and Accessibility Inspector in
the selected Xcode, and for `xctrace`, and exits 1 when something is missing. It
does not run Peekaboo desktop commands, request permissions, launch apps, or
start background services. An installed CLI is not proof that screen capture or
input permissions work.

No additional desktop automation framework or MCP server is needed: the agent
can invoke the Peekaboo CLI directly. If Peekaboo is missing, follow the
installation instructions in its README (see [References](#references)); do not
reinstall or upgrade a working installation just to run this check. Instruments
and Accessibility Inspector come with full Xcode.

## Status markers

Scripts print their `OK` / `WARN` / `MISSING` / `+` markers through `markers()`
in `scripts/lib/glyphs.py`. In an interactive Warp session with a Nerd Font
installed under `~/Library/Fonts` or `/Library/Fonts`, those markers become Nerd
Font glyphs; Warp resolves them through its font fallback, so the terminal's
configured font does not have to be the patched one. Everywhere else, including
pipes, redirects, and CI logs, the output stays plain ASCII, because the glyphs
are private use code points that render as tofu without a patched font.

Set `MWE_GLYPHS=nerd` to force glyphs (another terminal already configured with
a Nerd Font) or `MWE_GLYPHS=ascii` to force plain markers. `python3
scripts/lib/glyphs.py` prints the detected style and one line per marker;
`scripts/tests/test_glyphs.py` covers the detection rules and runs as part of
`python3 scripts/test.py`.

## Authorization boundary

The rule itself, and what routine verification must not do, is in
[testing/README.md](testing/README.md#authorization-boundary) and `AGENTS.md`.
For these tools it means:

- Installing a tool is not permission to test the desktop. Run screenshots, UI
  inspection, input, app launches, profiling of playback, or wallpaper changes
  only when the user explicitly requests the relevant desktop test.
- Never open System Settings automatically to request permissions. Screen
  Recording and Accessibility permissions are granted by the user to the actual
  execution host when needed.
- Do not collect unrelated windows, login credentials, or clipboard data.

After desktop testing is authorized, `peekaboo permissions status` can diagnose
permissions; use the installed CLI's `--help` for version-specific commands.
Prefer semantic accessibility actions and an explicit app/window target over
coordinates. Avoid autonomous open-ended agent runs. Keep screenshots and traces
local under `artifacts/`, and do not commit them.

## Which tool to use

- Routine correctness: `python3 scripts/test.py`, plus the relevant headless
  renderer checks described in [testing/renderer.md](testing/renderer.md).
- Exploratory visual/UI diagnosis: Peekaboo, only in an authorized desktop run.
- Repeatable UI regression: the existing `python3 scripts/test.py --ui`,
  separately authorized. Do not build a second framework for the same flows.
- UI labels and accessibility structure: Xcode > Open Developer Tool >
  Accessibility Inspector, during an authorized interactive session.
- CPU hot spots and memory growth: Instruments Time Profiler and Allocations.
- GPU/CPU scheduling and final Metal execution: Instruments Metal System Trace
  and Xcode Metal debugger. Correlate findings with renderer logs; Metal capture
  does not directly explain the shader translation behavior.
- Power and energy claims: the procedure and comparison rules in
  [testing/power-benchmark.md](testing/power-benchmark.md).

Debug and Release instances share the app bundle identifier. During desktop
tests, target the PID of the exact executable under test and quit only that
instance. `kill -TERM <pid>` (or `-HUP`) now quits in order: the desktop picture is
restored first, and the log's `quit: reason=signal signal=SIGTERM` line says so. Send
the signal twice to end a wedged quit at once, which skips whatever it had not yet
finished; `kill -KILL` is for a process that does not answer even that and leaves the
poster installed until the next launch. Signals sent while the app is still launching
are not handled. Discard performance comparisons if another copy starts, foreground
visibility changes unexpectedly, or the presentation policy suspends playback.

For an offscreen look at the control panel, a temporary test hosts the real view
(`ControlPanelView`, `PanelRootView` over a test controller, or one page or inspector)
in an unordered window from `ControlPanelWindow.make`, sets the window's own
`appearance` for light or dark (never `NSApp.appearance`), lays it out with
`layoutSubtreeIfNeeded()` and draws it with `bitmapImageRepForCachingDisplay(in:)`
and `cacheDisplay(in:to:)`. Write the image to `FileManager.default.temporaryDirectory`
and copy it out with the shell: test code never writes under `~/Documents`
([conventions](conventions.md#tests)). Delete the test afterwards; screenshots are
never committed. `ImageRenderer` draws only pure SwiftUI, so AppKit-backed parts
(lists, text fields, the split view, the toolbar, `AnimatedPreview`) are missing from
its output. What such a capture cannot show: the inspector column, an
`NSGlassEffectView` that draws blank (render the inspector alone in an
`NSHostingView` at its width instead), a list selection (drawn solid black),
controls in their active colours (an unordered window is inactive, so switches,
sliders and progress views are grey), sheets and popovers (an unordered window
attaches none; render their content alone), hover, pressed and focus states, Reduce
Motion and Reduce Transparency, VoiceOver, and full-screen or Split View
transitions. Report those as unverified.

## Asset corpus and manual smoke

Register local, legally usable assets in
[testing/wallpaper-corpus.md](testing/wallpaper-corpus.md); do not download
arbitrary Workshop items or commit asset packages, account/session data, or
personal filesystem paths. The release smoke checklist is
[testing/manual-smoke.md](testing/manual-smoke.md); how to record an authorized
desktop run is in the corpus document. Mark visual behavior unverified when only
headless tests ran.

## References

- Peekaboo: https://github.com/openclaw/Peekaboo
- Apple Metal tools: https://developer.apple.com/metal/tools/
- Accessibility Inspector: https://developer.apple.com/documentation/accessibility/accessibility-inspector
