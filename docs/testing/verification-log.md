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

## 2026-11-11 — Wallpaper-switch teardown and lock-screen recovery (issue 184)

- `python3 scripts/test.py` in an isolated HEAD checkout plus this patch: 687 Python tests passed; native gate 4,741 passed, 66 skipped, zero failures. The shared checkout was blocked by its pre-existing missing `CLAUDE.md`; an earlier targeted build also encountered concurrent desktop-widget API edits.
- Native result: one main-thread runtime warning, attributed by the detailed xcresult issue to `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`; no source location.
- `scripts/check_renderer.py` entry point with its output redirected to the task directory: 3,520 passed, seven local-asset/opt-in tests skipped; all 12 generated image comparisons and eight projects with two reload cycles passed. GPU and cadence checks ran; timer diagnostics were collected.
- `python3 scripts/check_rust.py`: all four groups passed (2,499 tests); five desktop-window cases were explicitly excluded, and desktop/media/network opt-ins remained disabled.
- The retiring-renderer acknowledgement regression and the pending-Metal-command release regression failed before their respective fixes and passed afterwards. Interrupted refreshes and genuine repeated renderer exits remain covered.
- No live desktop run, Wallpaper Engine comparison, or Release app build. The exact Apple Metal HUD crash on the reported macOS build remains unverified; tests cover the identified teardown and acknowledgement races.

## 2026-11-11 — Review fixes for the Steam QR sign-in and native downloads

Addresses the PR review: CM logon cleanup, endpoint fallback and cancellation; HTTPS-only content servers with failover promotion; Workshop app check; free-space check from the manifest size; QR actions through PanelController and cancelled when the dialog closes; localized native failure messages.

- `python3 scripts/test.py` — 4839 tests: 4767 passed, 70 skipped, 2 failed: WebWallpaperErrorStackTests/testStacksReadAsV8WritesThem and WebWallpaperWindowCompositionTests/testPreservingLiveSurfacesLeavesOtherWindowPoliciesIntact, both failing the same way on main on this Mac
- `python3 scripts/test.py --only SteamCMConnectionTests SteamContentClientTests NativeWorkshopDownloadTests SteamQRSignInTests SteamKeyValuesTests WorkshopStoreTests DownloadQueueTests` — 58 passed, including 10 new tests (logon cleanup, endpoint fallback, cancellation, wrong app, free space, server promotion, HTTPS-only servers, joined logon failure, message mapping)
- `python3 -m unittest scripts.tests.test_localization_catalogs scripts.tests.test_panel_localization` — 17 passed
- Not covered: live Steam and the UI were not rerun after these fixes

## 2026-11-11 — Reduce volume while another app plays sound (issue 182)

Adds Reduce volume beside Mute under When another app plays sound, with a Reduce volume to slider (0% to 100%, default 30%). The bridge gains a transient audio gain (set_audio_gain) multiplied into each saved volume for scenes, web pages and native video; no saved volume is rewritten.

- `python3 scripts/build.py --renderer-only` — exit 0; renderer built and Swift bindings regenerated (one added call, `setAudioGain`).
- `python3 scripts/check_rust.py` — exit 0; 2,499 passing tests (core 429, bridge 956, core-integration 20, shader 1,094), 0 failed. Five desktop-window tests explicitly excluded; desktop/media/network opt-ins disabled.
- New bridge tests: the gain scales an open scene's volume live and restores the saved one, a volume or a mirror's volume changed meanwhile is saved whole and played reduced, a wallpaper applied meanwhile starts reduced, web and native-video descriptors carry the product, a display refresh does not reload a turned-down scene, and a gain outside 0 to 1 is refused.
- `python3 scripts/check_renderer.py` — exit 0; all 12 generated scenes matched between pooled and isolated runs; seven local-asset-dependent cases skipped.
- `python3 scripts/test.py` — exit 0: all 32 Python suites, XcodeGen, and 4,739 native tests passed, 0 failed, 66 skipped of 4,805, the skip count of the gate runs logged before it (opt-in media, live Steam and reference jobs). An earlier targeted run failed in CodeSign on build-product extended attributes; `xattr -cr build/Build/Products/Debug`, as [build](../build.md#troubleshooting) says, cleared it.
- Three runtime warnings, all the known main-thread one (a method that should not be called on the main thread); none was traced to this change.
- New native tests cover the level preference (default, range, corrupt values, reset, one change posted), its backup validation, the policy's gain channel (only while other sound plays and Reduce volume is chosen, a new level delivered while the rule holds, mute still silences, refused delivery retried, teardown restores) and the panel row (offered beside Mute, shown only while chosen, out-of-range refused).
- Not checked: the lower volume was not heard on a real output, and the slider was not operated in the running app; no desktop automation and no Release build. A [manual smoke](manual-smoke.md#audio-responsiveness) item covers both.

## 2026-11-11 — Workshop inspector removal (#183)

- Added Move to Trash for installed Workshop items using the existing confirmed library removal action; collections remain open-only.
- Reused the existing label and translations in all shipped app languages; documented removal in workshop-downloads.md.
- python3 scripts/test.py --only WorkshopInspectorTests: 13 passed.
- Initial full gate blocked by the pre-existing deleted CLAUDE.md documentation link; temporarily restored its relative symlink for validation.
- Parallel full gate: 4722 passed, 5 timing/session failures, 66 skipped.
- python3 scripts/test.py --serial: 4727 passed, 0 failed, 66 skipped; one runtime warning.
- Opt-in media/network and desktop UI checks were not run; visual behavior was not manually checked.

## 2026-11-10 — Steam QR-code sign-in and native Workshop downloads

Downloads signed in with a QR code run through the app's own Steam client (App/Services/Steam/) instead of SteamCMD; the Rust bridge unpacks depot content (decompress_steam_content).

- `python3 scripts/test.py` — 4830 tests: 4759 passed, 70 skipped, 1 failed: WebWallpaperErrorStackTests/testStacksReadAsV8WritesThem, which fails the same way on main without this change
- `python3 scripts/check_rust.py` — passed; `cargo test -p wallpaper-bridge steam_content` — 3 passed (zstd, VZip LZMA, zip stored/deflated, CRC and truncation)
- `python3 scripts/test.py --only Steam…Tests NativeWorkshopDownloadTests` — 23 passed against a scripted Steam: QR flow, logon, Multi routing, manifests, chunks, unsafe paths, PICS, queue import, shared connection, refused token
- `WALLPAPER_MACHINE_NETWORK_TESTS=1 WALLPAPER_MACHINE_STEAM_TOKEN_FILE=… python3 scripts/test.py --only SteamNativeLiveTests` — 2 passed against live Steam (QR session; logon with a QR token and download of Workshop item 3521337568); the later depot-431961 chunk check was not run live
- Manual Debug-build run: QR sign-in from the panel, 8 Workshop items and the shared scene assets downloaded and imported natively; the log shows no SteamCMD run and no staging left behind
- Not covered: welcome guide has no QR option yet; no free-space check before the ~800 MB scene depot; native jobs restart from zero after a pause

## 2026-11-10 — Library tile menu, drop to import, keyboard and batch favorites; service fixes

Installed gains a right-click menu on tiles (the inspector's More actions list, shared as WallpaperActionItems), files dropped on the page import, Command-Delete and Command-Return on the grid, File › Import… and Refresh Library, and a favorite tool for the ticked selection. The same change fixes six service defects (unreadable saved entries no longer erase their neighbours; an automatic command replacing a queued rule or Focus change no longer marks it handled; a day and night display keeps a manual choice across a relaunch; a shuffle round ends without a wallpaper that keeps failing; a stale Steam request no longer signs out a newer session; equal day and night start times are refused), adds feedback where actions were silent, and gathers the renderer's leftover material constants into one log line per scene.

- `python3 scripts/test.py` — exit 0; 4789 tests: 4723 passed, 0 failed, 66 skipped (the first run failed two tests that asserted the old batch-limit error; both were updated and the gate rerun)
- `python3 scripts/check_renderer.py` — exit 0; generated scenes pixel-equal pooled and isolated, 0 reload-cycle diagnostics; the local-corpus tests (particle corpus, local projects through the native backend, poster pictures, energy, corpus stamps, a local clip) skipped: no corpus configured
- New unit tests: PreservedJSONTests; unreadable entries in WallpaperAutomationStoreTests, PlaylistStoreTests, WallpaperCollectionStoreTests and PlaybackPreferencesTests; queue outcomes in UserCommandQueueTests; a Focus change replaced by a reload in WallpaperAutomationSchedulerTests; relaunch and shuffle rounds in PlaylistSchedulerTests; the Steam session in WorkshopSourceTests
- New panel tests: add-to-playlist and refresh notices, the unreadable-library state, the failed-still mark (offscreen render), drop import, the favorite tool, Command-Delete and Command-Return on the hosted grid, equal start times, preset and batch-limit refusals
- Renderer: two gtest cases for UnmatchedConstantTally in material_constant_behavior_test; no frame output changed, so no Wallpaper Engine reference comparison was made
- Not exercised: the tile's context menu, the drop outline and a real Finder drag, and the File menu items with their shortcuts in a real window. They need desktop control, which was not authorized; the menu's item rules are InspectorPolicy's existing tests, and the drop and menu actions are covered through the model
- Not rebuilt: no Release build was made, so the delivered app does not contain these changes
- Runtime warnings in the result bundle (2, main-thread call) come from AppUpdateTests and WebMOpeningTests, which this change does not touch

## 2026-11-09 — Web wallpaper submitted background for Stage Manager

- The desktop web container now submits one opaque black 1×1 Metal frame per backing layer and retains it through resize and page suspension, with no recurring GPU submission or rendering loop. The bounded allocation trade-off was approved; battery impact was not measured.
- On the Dell display, the user reported that a submitted surface kept Belle smooth, removing it or replacing it with an empty Metal queue brought the freeze back, and using the submitted surface as the existing black background looked normal and stayed smooth.
- The earlier tag-only Release candidate and native backing-flattening override failed the visible Stage Manager check. The override is removed; the existing transition tag remains alongside the submitted background.
- `python3 scripts/test.py --only WebWallpaperWindowCompositionTests` — before the Metal implementation, 3 passed and 2 new regressions failed; final run: 7 passed, 0 failed, 0 skipped. Coverage includes a real submitted frame, resize, suspension/resume and the no-Metal fallback.
- `python3 scripts/test.py` — passed: Python checks and XcodeGen succeeded; native suite: 4,698 passed, 0 failed, 66 skipped. Three unrelated runtime warnings concerned main-thread use in video and app-update tests.
- `python3 scripts/build.py --renderer-only` rebuilt current upstream dependencies; `python3 scripts/build.py --swift-only --configuration Release` passed. No renderer source changes were made by this fix.
- The clean Release app was restarted with the original covered-desktop preference restored. Runtime inspection confirmed attached web views and submitted 1×1 Metal backgrounds on both the Dell and built-in displays, with no diagnostic layer or runtime patch.
- The additional clean-build Stage Manager and Mission Control visual check was requested but remains unconfirmed. The accepted smoothness result above is from the working prototype, not a claimed final-build visual observation.
- Wallpaper Engine reference-frame comparison and measured power consumption were not performed; this change addresses host-window presentation rather than wallpaper content rendering.

## 2026-11-09 — Issue #177 rebuilt candidate rejected

- The user tested the Release app from local commit 5cb12719 and reported that the issue was not fixed. Its prior passing gate and manual flag-toggle trials do not establish a fix.
- Read-only process inspection confirmed the running executable was build/Build/Products/Release/WallpaperMachine.app/Contents/MacOS/WallpaperMachine.
- WindowServer readback acknowledged tag 55 on both the Built-in Retina Display and DELL U2725QE web windows. The debugger detached after inspection; no window policy was changed.
- The built-in window contained its live web view. The Dell window contained an NSImageView suspension poster; session logs recorded repeated presentation suspend/resume decisions for display 3.
- The foreground-app rule was Keep running, covered-desktop behavior was the default Pause, and the power source was External. The relationship between this pause and the reported stutter remains unconfirmed; a controlled manual retest with the coverage rule disabled is pending authorization.
- No new fix, desktop automation, app restart or settings mutation was performed. The candidate remains local and must not be treated as resolving #177.

## 2026-11-09 — Web transition composition final review (#177)

- Reviewed the web-window transition policy and live-resize restoration against current main; retained the general fix without wallpaper-specific behavior or per-frame work.
- python3 scripts/test.py --only WebWallpaperWindowCompositionTests: 3 passed, 0 failed, 0 skipped; reads WindowServer policy on unordered windows and exercises an AppKit live-resize cycle.
- python3 scripts/test.py: all 32 Python suites passed; 4,667 native passed, 0 failed, 66 skipped. The skipped asset, media, network and desktop-dependent checks are not passing coverage.
- One runtime warning in AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy: a method called on the main thread may cause unresponsiveness; unrelated to web transition composition.
- python3 scripts/build.py --swift-only --configuration Release: passed; built build/Build/Products/Release/WallpaperMachine.app. Existing linker deployment-target warnings remain.
- Prior same-window Belle manual trials recorded smooth playback with tag 55 set, stutter after clearing it, and smooth playback after setting it again; the prior rebuilt app readback also showed the flag set automatically.
- Final rebuilt-app visual acceptance remains unconfirmed. No desktop automation, wallpaper changes or app restart were performed during this final review. No valid Wallpaper Engine frame comparison is available.

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
