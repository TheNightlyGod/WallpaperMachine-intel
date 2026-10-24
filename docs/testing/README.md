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

Each of those requires an explicit user decision, with one standing exception: a
wallpaper fix may download the reported Workshop item with the app's saved Steam
sign-in (`scripts/we_reference.py fetch`, never a new sign-in), wake the Parallels
Windows VM, capture Wallpaper Engine's frames in it with Wallpaper Engine muted, and
suspend it again ([wallpaper-fixes.md](wallpaper-fixes.md),
[wallpaper-engine-reference.md](wallpaper-engine-reference.md)). `python3 scripts/test.py --ui`
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
| Rust crates | `Renderer/Shader`, `Renderer/Core`, `Renderer/Bridge` | `python3 scripts/check_rust.py` runs the isolated release checks and reports exclusions/skips; individual Cargo commands remain available |
| C++ renderer tests | `Renderer/Engine` | `python3 scripts/check_renderer.py` uses one `REGRESSION_BINARIES` registry for build, execution and the verdict, plus image/reload probes. Every test binary the regression docs name is registered, and every other test executable is too or is listed with its reason in `MANUAL_BINARIES`; [renderer.md](renderer.md#ccmake-test-binaries) lists what a registered binary must do without (a window, an audio device, shared temporary files) and how to run one by hand while iterating |
| License closure | built app, `Renderer/`, `ThirdParty/` | `python3 scripts/check_licenses.py` lists every Mach-O dependency of the built app (`otool -L`, walked recursively), the code compiled or statically linked into the renderer (a source inventory with a hand-kept license table) and every linked Rust crate (`cargo tree`; a vendored path crate under `ThirdParty/`, such as `naga`, counts as third party with the license its `Cargo.toml` declares), each with its SPDX license, and classifies them against the policy table in the script (GPL-3.0-only: a GPLv3-compatible license passes; GPL-2.0-only, known GPLv3-incompatible licenses such as EPL-1.0 or CDDL-1.0, and unknown licenses fail). Report-only by default; `--enforce` exits 1 on a finding or when the default Release build is missing (an incomplete check is not a pass); `--app` picks the bundle (default: the Release build), `--skip-app` skips the dylib walk as an explicit choice that `--enforce` accepts and the verdict line names. Read-only: it never builds, installs or launches anything. Run it after any dependency, link-line or `Cargo.lock` change; it needs Homebrew and Cargo, so the routine gate does not run it |
| License notices | built app, cargo registry, Homebrew kegs | `python3 scripts/notices.py` writes `THIRD-PARTY-NOTICES.txt` (default `artifacts/licenses/`): for every third-party component of the same closure `check_licenses.py` reports, its name, version, SPDX license and the license text taken from the component itself (the crate's `LICENSE*` files in the cargo registry or under `ThirdParty/`, the Homebrew keg's license files, a vendored library's file or header notice; a dual `MIT OR Apache-2.0` crate carries the MIT text). A component whose text is not found is marked `LICENSE TEXT NOT FOUND` in the file and named in the output. Report-only by default; `--enforce` exits 1 on a gap; `--app`/`--skip-app` as for `check_licenses.py`. `scripts/package.py` runs the same generator and bundles the file. Needs Homebrew, Cargo and a populated cargo registry (`cargo fetch` or any earlier build), so the routine gate does not run it |
| Headless GPU probes | same CMake tree | explicitly invoked executables (`offscreen_scene_probe`, `scene_reload_cycle_probe`, `wpdump`); see [renderer.md](renderer.md) |

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
assembles; run the Rust commands from `Renderer/`. Build prerequisites
are in [../build.md](../build.md).

Bridge operation regressions in `Renderer/Bridge/src/api/operation_contract_tests.rs`
exercise the real actor, transport, state/configuration and journal with isolated
files and controlled engine IO. They distinguish saved, pending, published and live
state across persistence failures, stale completions, repair and Cancel. Core/prune/
readiness still share the real serialized facade turn. Out-of-order completion cases
park the last actually processed render-scale result, at explicitly reduced scale,
after mutation and lock release—not inside overlapping held core turns or midway
through audio registration. Narrow test-only observations and initial-value seeds
do not simulate publication or export the whole actor state. These cases establish
no native-renderer, visual, hardware or permission fidelity.

The Apply/settings consumer children distinguish an unsaved wallpaper draft from
property/display reset markers: saved nondefault choices remain resettable even
when the enclosing options are clean. Clean Apply is not a startup primitive; use
real Bootstrap for configured startup and actual edits for Apply transitions. A
controlled live setter must update the direct-template snapshot as well as its
observation cell, or refresh classification observes a stale scene. Scenario-owned
request waits retain cancellation and join ownership across timeouts; canceling a
wait does not replace the real actor drain before disposing owned paths.
One separately identified `FakeEngineFacade` case preserves synthetic core-blocked
command admission. It does not model the common readiness/audio exclusion and does
not replace the real-turn consumer cases or establish native responsiveness.

Power callback cases await the matching actual handoff completion before checking
unchanged playback/effect vectors; an already-equal vector or an early snapshot is
not a callback receipt. Watching construction includes a synchronous baseline read,
distinct from startup policy sampling. The controlled construction test lets that
baseline return, then holds an actual resample and releases it before joining and
draining. API projection fixtures also distinguish a missing first-seen monitor
record (which may inherit Primary) from an explicitly enabled but unassigned row.

The retained bridge suites share independently authored value and observation
helpers. Profiles keep their own scale, refresh and window/pointer state; a live
handle-only fixture is not silently converted to a direct wallpaper assignment.
Exact reconcile waits read the actual recorded-vector length without cloning its
scene history, retain the caller bound and assert completion. They do not replace
the separate 3–4-call coalescing contract or the retained cache-storage assertions.

The independent display/config/project/draft contract suites now carry the mapped
self-mirror, corrupt-file backup, raw rich-text/type and Cancel-baseline assertions
formerly duplicated in small inherited bridge tests. Constructor-pointer equality,
record-construction echoes and shallow duplicate default inventories are deliberately
retired, not counted as replacement lifecycle coverage. Five real consumers in
`Renderer/Bridge/src/api/small_library_contract_tests.rs` now cover public filter replies
and later snapshots, hidden inventory across owned concurrent refresh, supported Web
and Scene beside unsupported Application, cleared selection in both public snapshots,
and full configuration equality after opening a distinct store. The refresh uses two
actors with owned paths, never a process-wide HOME change; actor drain precedes root
deletion. Only assertion-mapped inherited cases are retired. Remaining apply/settings
cases, contributor corrections and the entire cache-clear storage-observation case
stay intact; suite membership alone is not evidence for deleting their assertions.

The old Rust project/resource/rendergraph/runtime corpus wrappers are retired,
together with their hard-coded developer-library paths, generated-data fallback
and macro registry. Independent disk-manifest, source-resolution and scene-loader
contracts retain the real type/loading/path-rejection behavior. Nonempty-object
and default-target inventories were incidental checks, not native graph/runtime
coverage; they are not recreated. The routine Rust gate excludes only the five
desktop-window cases explicitly. Other asset skips remain reported, and removing
the obsolete corpus exclusions does not make real corpus compatibility verified.

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

The Test workflow's `native` job runs `--serial` too: on hosted macOS runners serial
costs almost no wall clock (the step's comment in `.github/workflows/test.yml` has the
timings), and the `test-logs-<run id>-native` artifact carries the run's crash and
jetsam reports when a run fails there and not locally.

The per-test `UserDefaults` suite is not only a parallelism concern: the unit
bundle runs inside the real app as its test host, so `UserDefaults.standard`
*is* `app.wallpapermachine`, the preferences of the installed app. Any
`PanelController` (or other store) built without `defaults:` writes there —
the first-run welcome's `welcomeSeen` flag, the learned drag-select hint, favorites — and
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
System-global readers (system language and desktop-click preferences) keep their
original domains.

The same rule covers a second shape: a test that measures a *wall-clock window*
rather than shared state. It is still a race, it can lose alone as well as in
the gate, and widening the sleep only moves the threshold. Measure "what did
this action cause" from a settled state: await the task `controller.launch`
returns instead of sleeping, drain what is already in flight before latching a
count, drive timers with `ManualSleeper` (`Tests/Unit/Support/`), and wait for a
state the model or view reports (`PanelFixture.waitUntil`) rather than for a
duration. `waitUntil`'s two-second default is short for a loaded machine; a new
panel test that waits on real work gives it a longer timeout.

A test double that holds an answer suspends the task, never the thread:
`PixivGate` and `PixivHeldTransport` (`Tests/Unit/Pixiv/`) hold pixiv's
answers until the test opens the gate or the request is cancelled. A
`DispatchSemaphore` in a fixture's answer blocks a concurrency-pool thread that
cancellation cannot reach, so a fixture that shuts down waits out its timeout, and
the answer lets itself through when the test runs slowly. A timed-out wait was also
reported by Xcode's thread performance checker as a priority inversion, and the
test host symbolicates that report on the main thread; under the gate's load that
has held a test until its time allowance ran out. AppKit raises the same report
itself: the first time a focused text field with unchecked text is removed, the
main thread waits for its data detectors to load. So `test.py` turns the checker's
priority-inversion reports off in the test host (`PERFC_DISABLE_PRIORITY_INVERSIONS`,
forwarded as `TEST_RUNNER_PERFC_DISABLE_PRIORITY_INVERSIONS`), and a blocking
wait in a fixture now shows only as a slow test. Work off the main actor needs its
own sync point: a nonisolated `async` double such as `ManualSleep` runs on the
global executor, so flushing the main queue does not show it has run; wait for the
state it records.

A failed assertion in the app-hosted bundle can take about two minutes to
report while XCTest symbolicates the failing frame, so a failure inside a loop
or a hosted panel can read as a hang or a timeout; look for the assertion in the
log before raising a timeout.

Before blaming your own change for a timing-shaped gate failure, confirm
ownership: revert the change and run the gate again. A failure that survives
the revert is not yours. Check the load average too — a gate taking three to
five times its usual wall clock is measuring contention.

## Verification tiers

The full gate compiles the Debug app and test bundle and then runs well over a
thousand native tests, several of which host the panel in offscreen windows,
load web wallpapers in offscreen web views or drive a real PTY downloader; the test phase alone takes minutes, before any Release build. Match
the effort to the change:

| Change | While iterating | Before reporting |
| --- | --- | --- |
| Bug fix, refactor, test-only, one domain | `python3 scripts/test.py --only <TestClass>` (repeatable; `Class/testMethod` also works) | full gate once; no Release build, no log entry unless asked or a documented behavior changed |
| New feature or cross-domain change | targeted runs as above | full gate once, log entry; Release build only if delivery was requested |
| Rust crates | `cargo test` in the touched crate | full gate plus `scripts/check_rust.py` |
| Renderer / bridge | `cargo test` or the touched CMake target | full gate plus `scripts/check_rust.py` and `scripts/check_renderer.py` |
| How a wallpaper looks | as above for the layer touched | as above, plus a before/after comparison with Wallpaper Engine's frames ([wallpaper-engine-reference.md](wallpaper-engine-reference.md)) |
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
| `artifacts/licenses/<run>/` | `python3 scripts/check_licenses.py` (`report.json`, `closure.txt`, `cargo-tree.txt`) |
| `artifacts/licenses/THIRD-PARTY-NOTICES.txt` | `python3 scripts/notices.py` |
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
   stores and the control panel's controller and view models go to
   `Tests/Unit/<Domain>/` (`Panel/` for the panel); developer-script
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
6. **Expect the CI gate to run on macOS 26.** CI's runner is a macOS 26 VM
   while developers may be on a later macOS. There SwiftUI builds no
   accessibility tree for an unshown window until a client has contacted the app;
   `PanelTestCase` does that once (`AccessibilityClient`), so panel tests read the
   tree through it. Behaviour of an unshown window that only macOS 27 shows
   (toolbar overflow, sidebar arrow keys) skips earlier with
   `PanelTestSupport.skipBeforeMacOS27`, which leaves it unverified there.
   `gh workflow run test.yml --ref <branch>` runs the gate on that runner
   ([release.md](../release.md#test-testyml)).
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
