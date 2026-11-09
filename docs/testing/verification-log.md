# Verification log

Append-only history of what was actually verified, when, and with what result.
The newest entry goes on top; never rewrite an older entry to match today's
tree. Every entry is evidence about the tree it was taken on, not about the
current one — re-run the relevant checks after integration and add a new entry
instead of reusing an old result. Durable guidance belongs in the sibling docs:
test layers and policy in [README.md](README.md), renderer commands and
regression areas in [renderer.md](renderer.md), manual checks in
[manual-smoke.md](manual-smoke.md). Result bundles and probe output are local
and disposable, so entries state counts and commands rather than artifact
paths.

Entry format, so the log stays skimmable: a one-line summary heading, one short
paragraph of context only when the result needs it, then a bullet per command
with its exit status, counts and any skip. Keep an entry around ten lines. A
fact that will still matter next week is not an entry — promote it to the doc
that owns it (renderer behaviour and known-failing tests to
[renderer.md](renderer.md), build and signing traps to
[../build.md](../build.md)) and cite it from there.

Retention: this file keeps the ten newest entries. Add an entry with
`python3 scripts/log_verification.py --title "…" --line "…"`, which prepends it
and moves whatever falls past ten verbatim into a monthly file under
[archive/](archive/); promote anything durable before it goes. Editing an
entry's recorded result is not allowed.

## 2026-11-09 — Preload desktop wallpapers and preserve their uncleared frames

- Scope: serial preparation of inactive desktop scene, video and web wallpapers, parked-instance reuse and bounded shared still windows for repeated assignments.
- python3 scripts/build.py --renderer-only passed and regenerated Swift bridge bindings; XcodeGen regenerated the project for the source and test additions.
- Targeted scripts/test.py run passed: 240 native tests across parking, pinning, replicas, switch holds and video/web host lifecycles.
- Full scripts/test.py gate passed with local-only XCODE_XCCONFIG_FILE bundle identities: 4,686 native tests passed, 66 skipped; all 32 Python test modules passed.
- scripts/check_rust.py passed in an isolated child-process home with serial tests: core 428, bridge 941, all selected integration and shader suites passed; five desktop-window cases were excluded.
- Five targeted Metal regressions passed three consecutive rounds (15/15); all 77 render graph contract tests passed.
- python3 scripts/check_renderer.py passed: all registered binaries succeeded, 12 generated pooled/isolated frame comparisons matched and eight generated projects reloaded twice successfully.
- Uncleared output preserves prior pixels before partial writes; overflow coverage asserts draw admission without an Inf/NaN pixel-equivalence claim, while finite inputs retain exact frame comparisons.
- Asset-dependent renderer cases were skipped; desktop/media/network opt-ins, real Space animations, WindowServer stacking and Wallpaper Engine reference comparisons were not checked. No Release app was built or installed.
- Gitleaks scans of 1,278 existing commits, candidate staged differences and full staged files found no leaks; agent paths, private assets and build output are excluded.

## 2026-11-07 — Mission Control composition and desktop poster refresh

PR #175, including author updates 070caaa7 and 2ce3da8d, capture-cancellation fixes and native exported-web scheduling.

- `python3 scripts/build.py --renderer-only` — exit 0; renderer built and Swift bindings regenerated. The later author commits leave Renderer sources unchanged.
- `python3 scripts/test.py` — exit 0 on the final integrated tree: 687 Python tests passed; 4,648 native tests passed, 0 failed, 66 skipped (4,714 total).
- Native skips cover opt-in live Steam, media/device integration and Wallpaper Engine web-reference jobs. One runtime warning remains: a method called on the main thread may cause UI unresponsiveness.
- `python3 scripts/check_rust.py` — exit 0; 2,476 passing tests. Five desktop-window tests explicitly excluded; desktop/media/network opt-ins disabled.
- `cmake --build artifacts/renderer/bin --parallel 6` — exit 0; completed the cold build separately after the renderer check hit its 600-second build limit.
- `python3 scripts/check_renderer.py --skip-build` — exit 0; all 109 registered binaries succeeded, with seven local-asset-dependent cases skipped. All 12 generated scenes matched between pooled and isolated rendering; eight projects completed two reload cycles.
- Regression coverage checks final-settle publication over a black startup picture, intermediate-frame retention, appearance refresh precedence, cancellation of replaced timers, and cache reuse. Native exported web layers retain the existing 10/20 FPS and pause/resume assertions.
- Live Mission Control transitions, cancelled swipes and multiple displays were not exercised. No desktop automation or Release app build.

## 2026-11-07 — Update cache ownership — final follow-up

Final updater inspection added a cache-directory symlink guard and an explicit byte-count bound while rehashing a recovered package. The routine gate had already passed and was not repeated.

- python3 scripts/test.py --only AppUpdatePolicyTests --only AppUpdatePersistenceTests --only AppUpdateTests — passed: 83 passed, 0 failed, 0 skipped; covers the final code including preservation of files behind a linked cache directory.
- Earlier feature gate: python3 scripts/test.py — 4,642 native tests passed, 66 skipped, all Python modules passed. Targeted follow-up is additional evidence, not a replacement full-gate claim.
- Live desktop update, real release migration/signing/publication and Release delivery build remain unrun. No installed app or user wallpaper data changed.

## 2026-11-07 — Persistent, nonintrusive app updates

Existing updater retained: three modes, conservative migration, per-version postponement, verified complete-package recovery, passive update surfaces and artifact-derived publish metadata.

- python3 -m unittest scripts.tests.test_update_manifest scripts.tests.test_publish_release scripts.tests.test_dmg scripts.tests.test_package scripts.tests.test_localization_catalogs — passed, 76 tests; real synthetic signed DMG metadata round trip included.
- python3 scripts/test.py --only AppUpdatePolicyTests --only AppUpdatePersistenceTests --only AppUpdateTests --only AppReleaseHistoryTests --only UpdateWindowTests --only UpdatePresentationTests --only AboutSettingsTests --only StatusPanelModelTests --only StatusPanelControllerTests --only StatusPanelRenderTests --only FirstRunModelTests --only WelcomeRenderTests --only SettingsSectionsLocalizationTests — passed, 199 tests at the targeted checkpoint; final additional coordinator coverage included in the full gate.
- python3 scripts/test.py — passed once at completion: all 32 Python modules passed; native 4,642 passed, 0 failed, 66 skipped of 4,708. One runtime warning reported by the runner; skips are not passing evidence.
- Cache and installer tests use isolated temporary paths/defaults and fake restart/open actions; they do not replace the installed app.
- git diff --check and introduced documentation-link targets — passed. CLAUDE.md remains a relative symlink to AGENTS.md.
- Not run: authorized desktop/UI session, live old-to-new release update, production signing/notarization/publishing, or a Release delivery build. No app launch/restart, release or push performed.
- Rust/C++ renderer checks not applicable: no renderer changes. Task-owned transient test artifacts removed after recording the results.

## 2026-11-07 — Preserve saved sign-ins when keychain updates fail

- pixiv and Steam Community now share generic-password storage; refused updates preserve the saved item and the original keychain status.
- `python3 scripts/test.py --only KeychainGenericPasswordTests --only PixivStoreTests --only SteamWebSessionTests --only WorkshopStoreTests` — exit 0; 34 passed, 0 failed, 0 skipped.
- `python3 scripts/test.py` — exit 0; 682 Python tests across 32 modules passed; native: 4,641 passed, 0 failed, 66 skipped of 4,707.
- The first targeted build failed because Debug products carried Finder extended attributes; the documented `xattr -cr build/Build/Products/Debug` recovery cleared the signing failure before the passing runs.
- The full gate reported two main-thread runtime warnings, attributed to AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy and VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne; both tests passed.
- Keychain regressions use injected in-memory calls. Real keychain authorization prompts and signed-release upgrades remain unverified; no desktop/UI, live Steam or opt-in media run was requested.
- No Rust or renderer changes; their additional gates were not run. No Release build or version release was requested.

## 2026-11-07 — Fullscreen Space presentation guard (#173)

- Four focused regressions failed before the fix: early preview resume, cancelled swipes, hidden-display classification and Space-monitor arrival.
- python3 scripts/test.py --only WallpaperPresentationPolicyTests --only WallpaperSpaceMonitorTests --only PlaybackPolicyCompositionTests --only ActiveDisplayTrackerTests: 101 passed, 0 failed, 0 skipped.
- python3 scripts/test.py: Python checks passed; 4638 native tests passed, 0 failed, 66 skipped (opt-in media, live Steam and web reference rendering).
- The full gate reported one main-thread runtime warning in AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy, outside the changed presentation code.
- Restored the installed Xcode Metal Toolchain after the first test build could not find it.
- Live Mission Control transitions and the reported foreground-window trails were not checked. No Release build or desktop run; no wallpaper-specific rendering changes.

## 2026-11-06 — Reduce redundant lighting, video and idle media work

- Changed light packing to reuse exact per-draw arrays, preserving reflection camera ordering and rebuilding after simulation; no quality or cadence settings changed.
- Shader updater regression suite: 32 passed; 20 passes plus 20 reuse-key reads pack each light family 40 times without a draw scope and once within it, with identical bytes and hashes.
- AppleScript fallback has no timer while Music and Spotify are absent; launch/exit observation preserves immediate recovery and the existing 1 Hz live cadence.
- Filtered WebM reuses one compatible output format description; regression checks cover timing, pixels and changed dimensions.
- Targeted native tests: AppleScriptMediaProviderTests, FallbackSystemMediaProviderTests and WebMFilteredVideoSinkTests; 23 passed, none skipped.
- python3 scripts/test.py passed: Python checks plus 4622 native tests passed, 66 skipped, no failures; one main-thread runtime warning was reported.
- python3 scripts/check_rust.py --output artifacts/power-efficiency/rust-unsandboxed passed; desktop/media/network opt-ins remained disabled. Initial sandbox run could not access cache and IOSurface services.
- python3 scripts/check_renderer.py passed: 12 generated pooled/isolated pixel comparisons equal, zero diagnostic errors, reload cycles passed; local asset-dependent checks explicitly skipped.
- Missing Xcode Metal Toolchain component installed before native verification; no desktop run, Wallpaper Engine comparison or hardware battery/power measurement. No Release build or commit.

## 2026-11-05 — Nine features adopted from rival Mac wallpaper apps

Menu bar Now Playing panel, inactivity pause, playlist wait for a clip's end, hev1 HEVC from a retagged copy, broader Installed search and Last used, library-drive follow, Workshop search translation, Hide Desktop Icons and the notch strip, and the stalled audio-tap rebuild. Each was reviewed independently, plus once across all nine, and fixed in two verified rounds.

- `python3 scripts/test.py` — exit 0; 4653 tests: 4587 passed, 66 skipped
- `python3 scripts/check_rust.py` — exit 0; desktop/media/network opt-ins off
- `python3 scripts/check_renderer.py` — exit 0; generated probes pixel-equal, corpus and local-energy cases skipped
- `python3 scripts/build.py --configuration Release` — exit 0
- Offscreen captures (light and dark) of the menu bar panel and of Settings › General, Playback & Power and Desktop & Lock Screen; hover, popover attachment and active control colours unverified
- Not run on the desktop: status-item click routing, real idle detection, Finder restart and the notch strip's look, a real drive eject and remount, the Translation framework with real language packs (macOS 15 hand-off untested), a real hev1 Workshop clip, a real stalled audio tap
- Not compared with Wallpaper Engine: no change to how a scene is drawn

## 2026-11-05 — Battery: scene pass merge and opt-in battery choices

Scene draws that only their object order or depth attachment kept apart share one render pass (WALLPAPER_MACHINE_SCENE_PASS_MERGE); When another app is in front gains Pause on battery, the menu bar an On Battery submenu, and the panel a one-time battery question. M5 Pro, macOS 27.

- `python3 scripts/test.py` — exit 0; 4396 passed, 0 failed, 61 skipped
- `python3 scripts/check_renderer.py` — exit 0; generated cases pixels_equal=True, reload cycles 0; local-corpus tests skipped (no environment)
- Sweep of 91 installed scenes (metal_scene_draw_smoke, WE_TEST_METAL_TIMING, 3456x2234@2): every scene draws; 11 change structurally, e.g. 3808922316 32 → 11 scene render passes, 958 → 213 MB loaded a frame
- `perf_bench.py identity` base vs merge — identical on every compared frame of 7 changed scenes; 3 not comparable (base differs from itself)
- `perf_bench.py cost` base vs merge, 60 fps, 3456x2234@2, 5 ABBA pairs — GPU 4.36 → 3.84 W on 3808922316 (saving, CI −0.56 to −0.50 W); 3226487183 −0.71 W and 3662790108 −0.82 W in every pair taken but short of a verdict (thermal rejections); 2 scenes within spread
- `perf_bench.py cost` Reduced quality (30 fps, 75 %) vs full, 3 pairs — GPU 1.60 → 0.41 W (3802900973), 2.27 → 0.56 W (3413921910)
- `python3 scripts/build.py --configuration Release` — OK
- Not verified: a real unplug or plug-in, WindowServer and whole-desktop power (need an authorized desktop run), native review of the new translations

## 2026-11-05 — Faster, rehearsable release pipeline

Build reuses the cached renderer build through scripts/source_times.py, compiles beside the app-icon job instead of after it, checks the signing secrets before building, and gains a rehearsal mode (rehearsal.yml); CodeQL stops saving C++ object caches, and Warm caches becomes the daily writer of the caches a release restores. CI behaviour is not yet observed: nothing was pushed.

- Local clone, cargo after a fresh checkout over a cached Renderer/target: 4 crates in 17.7 s today; with source_times.py restore: 0 crates (0.09 s) for the same commit, wallpaper-bridge only (9.2 s) for a Swift-only commit, core + bridge (11.0 s) for a Core change, one C++ compile for an engine change; an added and a removed msdfgen source both reran CMake and the archive followed
- Local clone, `scripts/build.py --configuration Release --no-app-icon` then `--install-app-icon`: AppIcon.icns, CFBundleIconName and the compiled Assets.car present; `codesign --verify --deep --strict` passed
- Icon wait loop against a fake gh: artifact after polls exit 0; failed API calls retried; failed icon job exit 1
- `actionlint` with shellcheck on every workflow: no findings besides the existing `queue` key it does not know
- `python3 scripts/test.py` — exit 0; Python script tests all OK (test_source_times 9, test_build new cases); native 4424: 4363 passed, 0 failed, 61 skipped
- Not run: any GitHub Actions run (Rehearsal, Warm caches, a release); Developer ID signing and notarization unchanged and unexercised locally
