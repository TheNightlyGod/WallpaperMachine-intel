# Testing

How this project is verified, which layer a new test belongs in, and what
"verified" is allowed to mean in a report.

- [coverage.md](coverage.md) — what the native tests assert, domain by domain,
  and the limits of each claim.
- [renderer.md](renderer.md) — headless renderer/GPU checks and probe
  environment variables; the regression areas that must stay covered are in
  [scene-regressions.md](scene-regressions.md) and
  [runtime-regressions.md](runtime-regressions.md).
- [manual-smoke.md](manual-smoke.md) — manual release smoke checklist
  (requires authorization; not automated).
- [power-benchmark.md](power-benchmark.md) — how power and CPU/GPU comparisons
  are measured and when a power claim is allowed.
- [verification-log.md](verification-log.md) — dated history of what was
  verified, with results and explicit gaps; the ten newest entries, with older
  ones in [archive/](archive/).
- [wallpaper-corpus.md](wallpaper-corpus.md) — local regression corpus
  checklist and the environment variables that point tests at private assets.

## What "verified" means

- A claim is only as strong as the layer that produced it. Passing native tests
  do not establish visual, desktop, or OS-integration behavior.
- Report visual behavior, desktop presentation, live Steam accounts, real audio
  capture, and battery/power effects as **unverified** whenever no explicitly
  authorized manual check was performed. Do not run desktop automation to close
  that gap on your own.
- Results recorded in [verification-log.md](verification-log.md) are historical
  evidence from the branch and tree they were taken on. They are not
  verification of the current tree. Re-run the relevant non-desktop checks after
  integration and record fresh evidence as a new log entry.
- A skipped test is not a passing test. Asset-dependent cases print a reason and
  skip; read those lines before claiming coverage.
- A still screenshot does not prove animation smoothness or first-frame delivery.

## Authorization boundary

Routine verification **must not**:

- control the desktop or synthesize input,
- open application windows or capture screenshots,
- change the user's wallpapers or system appearance,
- initialize audio hardware or request system permissions,
- sign in to Steam, run a real SteamCMD login, or approve a Gatekeeper prompt,
- replace or restart the installed `/Applications/WallpaperMachine.app`.

Each of those requires an explicit user decision. `python3 scripts/test.py --ui`
and the manual smoke checklist take over the desktop and are neither part of
routine verification nor a required release gate. See
[../../AGENTS.md](../../AGENTS.md) for the agent-facing form of this rule and
[../development-tools.md](../development-tools.md) for the optional diagnostic
tooling that sits on the other side of the boundary.

The unit-test host deliberately skips app startup: it does not create the
control panel, initialize the renderer, or restore wallpapers. The default Xcode
scheme excludes UI tests.

## Test layers

Use Python 3.10 or newer for the routine gate: `test_brand.py` uses
`zip(strict=True)`, which the Python 3.9 shipped with some Xcode installations
does not support. If `python3 --version` reports 3.9, run the commands below
with an installed newer interpreter (for example, `python3.12`).

| Layer | Location | Command |
| --- | --- | --- |
| Python script tests | `scripts/tests/` | `python3 scripts/test.py` (runs first, before Xcode) |
| Swift unit/integration | `Tests/Unit/<Domain>/` | `python3 scripts/test.py` (`WallpaperMachineTests`); `--only <TestClass>` for a subset |
| XCUITest (desktop) | `Tests/UI/` | `python3 scripts/test.py --ui` — opt-in only |
| Media/device integration | `Tests/Unit/NativeVideo/`, `Tests/Unit/Library/VideoLetterboxProbeMediaTests.swift` | `WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py` — opt-in only |
| Live Steam pages / native SteamCMD install | `Tests/Unit/Workshop/WorkshopTests.swift`, `Tests/Unit/Steam/SteamCMDLiveInstallTests.swift` | `WALLPAPER_MACHINE_NETWORK_TESTS=1 python3 scripts/test.py` — opt-in only |
| Rust crates | `upstream/renderer/crates/` | `python3 scripts/check_rust.py` runs the isolated release checks and reports exclusions/skips; individual Cargo commands remain available |
| C++ renderer tests | `upstream/renderer/external/open-wallpaper-engine` | `python3 scripts/check_renderer.py` uses one `REGRESSION_BINARIES` registry for build, execution and the verdict, plus image/reload probes. Some test binaries (`scene_schema_tests`, `script_runtime_compat_test`, `mouse_input_test` and others) are not in that list and are built and run by hand; [renderer.md](renderer.md#ccmake-test-binaries) lists them and the commands |
| Headless GPU probes | same CMake tree | explicitly invoked executables (`offscreen_scene_probe`, `scene_reload_cycle_probe`, `playback_gpu_test`, `wpdump`); see [renderer.md](renderer.md) |

`python3 scripts/test.py` is the routine gate: it runs the Python script test
modules side by side (each isolates itself in temporary directories, and every
module's result is reported even when one fails),
runs `xcodegen generate --use-cache`, then builds and runs
`WallpaperMachineTests` only, with test classes in parallel worker processes.
The terminal gets only what matters — compile errors, failing assertions, the
`Testing failed:` block and a one-line verdict with counts — while the full
`xcodebuild` stream goes to `artifacts/tests/Tests-<timestamp>.log` next to the
result bundle. A green run prints nothing but the verdict; open the log or
rerun with `--verbose` when the raw stream is the point. `scripts/build.py`
filters the same way into `artifacts/build/<stage>-<timestamp>.log`.
Cargo and CMake commands need the Homebrew environment that `scripts/build.py`
assembles; run the Rust commands from `upstream/renderer`. Build prerequisites
are in [../build.md](../build.md).

An `IDELaunchServicesLauncher` assertion `childPID > 0` (exit 250) can abort
Xcode before the native test host starts, even after successful compilation
and bundle-signature verification. A missing verdict is not zero failing tests:
inspect the named log and report the native gate as blocked. Check
`launchctl managername`: the observed macOS 26.6.2 / Xcode 27A266a failure
occurred in a detached `Background` bootstrap session. Serial execution and
clearing environment variables did not fix it; running the unchanged gate in
the logged-in user's `Aqua` session did. Run from that login session, not a
detached background service. A temporary same-user launch job can run the
non-desktop gate there without opening a Terminal window; remove the job
afterwards. Standalone isolated checks do not replace the app-hosted gate.

`Tests/Unit/` is grouped by domain, mirroring `App/Services/`: Appearance,
Automation, Desktop, Diagnostics, GitHub, Library, Lifecycle, Localization,
LockScreen, NativeVideo, Panel, Pixiv, Playlist, Preview, Steam, SystemMedia,
UserAssets, WebWallpaper, Workshop; shared fixtures live in `Support/`.

### Opt-in layers

Two layers inside `Tests/Unit/` skip themselves unless asked for, because they
reach past this tree: they depend on the machine's media hardware and on Valve's
live pages, so a failure there is not evidence about the code and a red gate
invites a pointless re-run.

- `WALLPAPER_MACHINE_MEDIA_TESTS=1` — `NativeVideoPlayerMediaTests` drives the
  real `AVQueuePlayer`, `AVPlayerLooper` and `AVPlayerLayer` against generated
  silent clips, decoding real video. The clips that carry an audio track are
  sent to an output device that does not exist, which is how a failed audio
  output is reproduced. It still opens no window, changes no wallpaper, opens
  no real audio output and configures no audio session; it is not a desktop
  test and not a substitute for one. `VideoLetterboxProbeMediaTests` is in the
  same layer: it writes small H.264 clips with black bars at known rows and
  decodes frames back through `AVAssetImageGenerator`, so its bar edges are
  measured on lossy output that a different codec or decoder path can move by
  a few rows. The probe's logic (injected frames, unreadable files, timeout,
  cancellation, replaced files) stays in the routine `VideoLetterboxProbeTests`.
- `WALLPAPER_MACHINE_NETWORK_TESTS=1` — the two `testLive…` cases in
  `WorkshopTests` fetch Steam's real community pages. Steam's page *format*
  stays covered offline: `decodePage` runs against recorded markup in
  `WorkshopStoreTests`, so only the assumption that Valve still serves that
  shape goes untested by default. Run them before a release, after touching the
  Workshop parser, and whenever search results look wrong in the app.
  `SteamCMDLiveInstallTests/testLiveNativePackageInstall` also downloads Valve's
  package manifest and runtime into a temporary support directory, using the real
  setup store, signature/Gatekeeper checks and native no-login smoke run. It
  asserts Ready, arm64 availability and successful Steam API initialization;
  no saved session or real installed SteamCMD is read or changed. Run it after
  setup/runtime changes with `WALLPAPER_MACHINE_NETWORK_TESTS=1 python3
  scripts/test.py --only SteamCMDLiveInstallTests`. Network opt-in raises the
  per-test execution ceiling to 660 seconds for downloads and system assessment;
  the routine ceiling stays at 90 seconds. A cached-account login or Workshop
  download remains a separate explicitly authorized check, never part of this test.

Both are forwarded into the test host by `scripts/test.py`; setting them in your
shell is enough. A skipped test is not a passing test — read the skip lines
before claiming coverage.

### Parallel execution

Test classes run in parallel worker processes (`-parallel-testing-enabled YES`),
which cuts the native phase roughly in half: most of its wall clock is spent
waiting on debounce intervals and child-process reaping rather than on CPU.
This is safe only as long as every suite keeps isolating its own state —
`WALLPAPER_MACHINE_HOME`, a temporary directory, a per-test `UserDefaults`
suite — and never asserts on a process-wide singleton, a fixed port or a shared
path. A test that passes alone but fails in the gate is the symptom; reproduce
it with `python3 scripts/test.py --serial` and fix the shared state rather than
the scheduling. UI runs are always serial: they drive one desktop.

CI's `test` job runs `--serial` too. On hosted macOS runners, parallel runs
intermittently fail one offscreen control-panel test with
`InvalidTransition { phase: idle targetPhase: failed(deinit) }` — WebKit drops a
`callAsyncJavaScript` call unanswered — while the same tests pass locally in
parallel; on the runner, serial costs almost no wall clock. When it recurs, the
panel fixture's error says whether the page reloaded meanwhile, and the
`test-logs-<tag>` artifact carries the run's WebKit and jetsam reports.

The per-test `UserDefaults` suite is not only a parallelism concern: the unit
bundle runs inside the real app as its test host, so `UserDefaults.standard`
*is* `app.wallpapermachine`, the preferences of the installed app. Any
`WebPanelController` (or other store) built without `defaults:` writes there —
the first-run welcome's `welcomeSeen` flag, sidebar choices, favorites — and
silently changes what the app does at the next launch. Pass the test's own
suite everywhere; `PanelFixture` does.

A named suite also outlives its test: `removePersistentDomain(forName:)` still
leaves an empty `~/Library/Preferences/<suite>.plist`, because cfprefsd flushes
the removal after the test deletes the file. Every unit-test suite comes from
`TemporaryDefaults` (`Tests/Unit/Support/`), which names it by an absolute path
inside a temporary directory and deletes that directory when the test ends:
`make(for: self)` inside an `XCTestCase`, `makeForCurrentTest()` in fixtures
that have no test case to hand (`PanelFixture`, `AppLanguageStore.english()`).
Both return the suite's name with it for code that needs a domain name, such
as backup preferences. Never pass `UserDefaults(suiteName:)` a plain name.

For an explicitly authorized UI run, `WallpaperMachineUITests` creates both a
unique `WALLPAPER_MACHINE_HOME` and a `WALLPAPER_MACHINE_DEFAULTS_SUITE`. App-owned
default stores and direct private-key accesses use `ClientPreferences`; backup
preference domain names follow the same override. The suite pins English and
marks onboarding/launch announcements complete. Launch arguments pin Foundation's
native language without changing the system domain. Teardown stops the test app,
then removes the suite and support root, including when setup or a test fails.
System-global readers (title-bar double-click behavior, system language and
desktop-click preferences) keep their original domains.

The same rule covers a second shape: a test that measures a *wall-clock window*
rather than shared state. It is still a race, it can lose alone as well as in
the gate, and widening the sleep only moves the threshold. Two in
`ControlPanelShellTests` were fixed rather than tolerated, and both fixes are
the pattern to copy. One latched a snapshot count, submitted a form and read
the count 50 ms later, so a push already in flight when the count was latched
was indistinguishable from one the submit caused; it drains with
`panel.quiet()` before the window. The other read `getBoundingClientRect`
straight after `setFrameSize`, catching the layout before the page had
reflowed; it waits for `window.innerWidth` to reach the new width. Measure
"what did this action cause" from a settled state, and wait for a state the
page can report rather than for a duration.

Before blaming your own change for a timing-shaped gate failure, confirm
ownership: revert the change and run the gate again. A failure that survives
the revert is not yours. Check the load average too — a gate taking three to
five times its usual wall clock is measuring contention.

## Verification tiers

The full gate compiles the Debug app and test bundle and then runs well over a
thousand native tests, several of which drive offscreen WebKit or a real PTY
downloader; the test phase alone takes minutes, before any Release build. Match
the effort to the change:

| Change | While iterating | Before reporting |
| --- | --- | --- |
| Bug fix, refactor, test-only, one domain | `python3 scripts/test.py --only <TestClass>` (repeatable; `Class/testMethod` also works) | full gate once; no Release build, no log entry unless asked or a documented behavior changed |
| New feature or cross-domain change | targeted runs as above | full gate once, log entry; Release build only if delivery was requested |
| Rust crates | `cargo test` in the touched crate | full gate plus `scripts/check_rust.py` |
| Renderer / bridge | `cargo test` or the touched CMake target | full gate plus `scripts/check_rust.py` and `scripts/check_renderer.py` |
| Docs only | link, path and command check | nothing else |

`--only` skips the Python script tests and prints a warning: it is an
iteration tool, not evidence. Rerun the full gate only when it failed; a second
identical run adds minutes and no information. `xcodegen generate --use-cache`
(what `scripts/test.py` runs) leaves the project untouched when
`project.yml` has not changed, so Xcode's incremental build survives between
runs.

## Evidence

| Artifact | Produced by |
| --- | --- |
| `artifacts/tests/Tests-<timestamp>.xcresult` and `.log` | `python3 scripts/test.py` (five newest kept) |
| `artifacts/tests/UI-<timestamp>.xcresult` and `.log` | `python3 scripts/test.py --ui` |
| `artifacts/build/<stage>-<timestamp>.log` | `python3 scripts/build.py` (cargo, bindgen, xcodegen, xcodebuild) |
| `artifacts/renderer/<run>/` | `python3 scripts/check_renderer.py` |
| `artifacts/renderer/bin/` | renderer check binaries |
| `build/Build/Products/{Debug,Release}/WallpaperMachine.app` | `python3 scripts/build.py` |

`artifacts/` and `build/` are both Git-ignored and disposable; `python3
scripts/clean.py` removes them (`--dry-run` previews). Only `scripts/test.py`
prunes its own output: renderer runs (a few hundred megabytes each), Rust check
runs, build logs and hand-made investigation folders stay until someone deletes
them, so whoever produced them lists them and asks before deleting (see
[AGENTS.md](../../AGENTS.md)). Result bundles are local: cite the numbers and
the command, not a bundle path, when you report a result. Private GPU output,
local asset inventories, screenshots, and traces stay out of Git.

## Current native coverage

The domain-by-domain inventory of what the Swift bundle asserts, and the limits
of each claim, is in [coverage.md](coverage.md). Check it before writing a test:
most behaviors already have a home, and several entries name explicitly what
they do not establish.

## Adding a test

1. **Pick the lowest layer that can observe the behavior.** Renderer semantics
   go to Rust or C++; bridge state goes to `wallpaper-bridge`; app services,
   stores and panel bridging go to `Tests/Unit/<Domain>/`; developer-script
   behavior goes to `scripts/tests/`. `Tests/UI/` is a last resort — it controls
   the desktop and therefore cannot be part of routine verification.
2. **Keep it device-free.** No windows, no screenshots, no audio device, no
   swapchain, no real wallpaper setter, no real Steam account. Use injected
   services, unattached layers, `URLProtocol` archives, local PTY/socket
   fixtures, and disposable directories.
3. **Assert something a consumer observes**, and make blank or corrupt output
   fail. Two equally empty results must not both pass.
4. **Never hardcode a home directory.** Resolve private assets from the
   environment and skip with a printed reason when they are absent, so a clean
   checkout runs green — see [wallpaper-corpus.md](wallpaper-corpus.md).
5. **Use original synthetic fixtures** when you need content; do not check in
   Workshop packages or other copyrighted assets.
6. **Record the result** when the change calls for a log entry (a feature or
   cross-domain change, a changed documented behavior, or on request — see
   [Verification tiers](#verification-tiers)): the counts, the command, and what
   you did not verify in [verification-log.md](verification-log.md). Keep it to
   about ten lines; a fact that outlives the round belongs in the doc that owns
   it, not in the log. Use `python3 scripts/log_verification.py --title "…" --line "…"`
   (repeat `--line`; `--context` for one paragraph; `--dry-run` to preview): it
   prepends the entry, keeps the ten newest and moves the rest into
   [archive/](archive/) with links fixed, so nobody has to read the log to
   write to it.

Naming, style and review rules are in [../conventions.md](../conventions.md);
the contributor workflow is in [../../CONTRIBUTING.md](../../CONTRIBUTING.md).
