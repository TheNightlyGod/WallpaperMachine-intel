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

## 2026-11-09 — Web transition composition final review (#177)

- Reviewed the web-window transition policy and live-resize restoration against current main; retained the general fix without wallpaper-specific behavior or per-frame work.
- python3 scripts/test.py --only WebWallpaperWindowCompositionTests: 3 passed, 0 failed, 0 skipped; reads WindowServer policy on unordered windows and exercises an AppKit live-resize cycle.
- python3 scripts/test.py: all 32 Python suites passed; 4,667 native passed, 0 failed, 66 skipped. The skipped asset, media, network and desktop-dependent checks are not passing coverage.
- One runtime warning in AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy: a method called on the main thread may cause unresponsiveness; unrelated to web transition composition.
- python3 scripts/build.py --swift-only --configuration Release: passed; built build/Build/Products/Release/WallpaperMachine.app. Existing linker deployment-target warnings remain.
- Prior same-window Belle manual trials recorded smooth playback with tag 55 set, stutter after clearing it, and smooth playback after setting it again; the prior rebuilt app readback also showed the flag set automatically.
- Final rebuilt-app visual acceptance remains unconfirmed. No desktop automation, wallpaper changes or app restart were performed during this final review. No valid Wallpaper Engine frame comparison is available.

## 2026-11-08 — Issue 177: rejected candidates and visible-frame regression

Issue #177 remains unresolved. The user rejected the delivered candidate after repeating the Stage Manager desktop transition; passing callback timing and unit checks did not establish smooth visible playback.

- The `isVisible` override and its offscreen-only regression were removed; they did not fix the reported desktop behavior.
- A Release candidate adding `canJoinAllApplications` also still froze with original Belle. That source change was reverted.
- That candidate's checks passed: `python3 scripts/test.py --only WebWallpaperSuspensionTests` (24 passed), `python3 scripts/test.py` (32 Python suites; 4,658 native passed, 66 skipped, 0 failed; 3 runtime warnings), and `python3 scripts/build.py --swift-only --configuration Release`. These results are not a fix verification.
- During a user-confirmed 90-second freeze reproduction, animation callbacks continued with no visibility changes; after startup, the largest recorded callback gap was 29 ms. Callback timing does not measure screen presentation.
- The asset-free WebGL, Canvas 2D and CSS [continuity fixture](../../Tests/UI/Fixtures/WebFrameContinuity/project.json) also froze, including with the control panel closed. A one-tile library did not prevent the freeze. The [manual regression](manual-smoke.md#native-desktop-posters-and-mission-control) requires repeated visible transitions because the failure is intermittent.
- Raising the web window one level, with coverage probes moved above it, failed a controlled repeat: the same window retained its raised level while the user observed freezes. An earlier smooth run was inconclusive because wallpapers changed during it. Original levels were restored.
- Wallpaper Engine comparison was **not done**: the available VM's captures did not show Belle, so they cannot serve as reference frames. The VM was suspended again.
- `python3 scripts/tests/test_doc_links.py` passed 11 tests. No fix was committed.

## 2026-11-08 — Belle Release build and Stage Manager retest

Requested Release build and repeat desktop test for [issue #177](https://github.com/MMFoundation/WallpaperMachine/issues/177). The candidate visibility change remains uncommitted; the reported Stage Manager stutter is **not verified as resolved**.

- `python3 scripts/build.py --swift-only --configuration Release` — exit 0; built and ran `build/Build/Products/Release/WallpaperMachine.app`, binary UUID `C60DA559-5CD2-3C21-BE10-2ED77F3A5D02`. The installed app was not overwritten.
- Five automated panel-focus / Show Desktop cycles in installed 1.9.3 and five in the updated build on macOS 27.0.1, external 3840×2160 @2x / 120 Hz, wallpaper 60 fps / scale 1.0. A disposable copy measured animation callbacks and calls into the wallpaper's drawing function; production code contains no wallpaper detection.
- Longest measured draw gap during the automated cycle intervals: baseline 95 ms, updated 113 ms. Neither reproduced the reported approximately 600 ms hold. No page visibility changes or forwarded desktop clicks were recorded in those intervals; these cycles are not the exact mouse-click reproduction.
- The user reported visible stuttering in reply to the baseline question after the updated app had started. That observation lacks a timestamp identifying the binary/transition, and no separate updated-build manual verdict was received. Page callback timing cannot exclude a compositor-held frame. Current main also includes earlier changes absent from installed 1.9.3, so this is not an isolated patch A/B.
- The unchanged candidate code previously passed the full routine gate: 32 Python suites, XcodeGen, 4,659 native passed, zero failed, 66 skipped. The gate was not repeated for this build/test-only follow-up. Wallpaper Engine comparison remains **not done**: the available VM's captures did not contain Belle; no pixel metrics are claimed.
- Restored Lost Tower on the primary display and Stage Manager off, retained the internal display wallpaper, moved the temporary import to Trash and cleared the search. The updated Release build remains running. No commit, push or issue closure.

## 2026-11-08 — Desktop web scheduling during window visibility changes

Investigation of [issue #177](https://github.com/MMFoundation/WallpaperMachine/issues/177). The change repairs an independently reproduced window-visibility scheduling gap; its connection to the reporter's exact Stage Manager transition remains unconfirmed.

- The attached video holds different last frames for roughly 0.6 s on repeated returns to the desktop. The attached logs show no matching host presentation suspension; the CPU sample was taken later with another wallpaper active.
- WebKit checks window visibility separately from occlusion. An attached desktop page now remains schedulable until the host suspends it; no wallpaper identification, timer, polling loop or extra render pass was added.
- Before the fix, `python3 scripts/test.py --only WebWallpaperSuspensionTests/testDesktopPageSchedulingFollowsHostSuspensionWithoutAnOrderedWindow` failed: zero animation frames while the host permitted playback.
- After the fix, `python3 scripts/test.py --only WebWallpaperSuspensionTests --only WebWallpaperHostLifecycleTests --only WebWallpaperFramePacingTests` passed: 74 tests, no failures or skips. The regression also measures stopped frames during explicit suspension and resumed frames without reloading.
- `python3 scripts/test.py` passed: all 32 Python suites, XcodeGen, and 4,659 native tests; zero failures, 66 skipped of 4,725. Skips: 62 opt-in video/media asset cases, one live Steam install, two Workshop cases and the opt-in web reference renderer.
- One runtime warning came from `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`: a method called on the main thread may cause UI unresponsiveness. No warning was attributed to the new scheduling regression.
- Wallpaper Engine comparison **not done**. The Windows VM was available, but two muted `scripts/we_reference.py capture` attempts produced a black desktop with the Start menu, not Belle. The attempted native reference render also failed with `DecodingError.typeMismatch`; no valid before/after pixel metrics are claimed.
- Authorized desktop probing of installed 1.9.3 on macOS 27.0.1 did not reproduce the reporter's repeatable macOS 27.2 stall. This is not confirmation of the changed app's visual behavior. The previous wallpaper and Stage Manager setting were restored, the temporary import was removed, and the VM was suspended again.
- Updated the [web runtime description](../features/web-wallpapers.md#runtime-shape) and [test coverage](coverage.md#webwallpaper). No renderer/Rust changes or corresponding gates; no Release build, installation, commit or push.

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
