# Verification log archive — 2026-11 and earlier

Retired entries from [../verification-log.md](../verification-log.md), moved
here when that log was capped at its ten newest entries. No recorded result was
rewritten: each entry is reproduced verbatim, and the only edit is that
relative Markdown links gained one `../` for this file's extra directory
level.

These are historical results about the trees they were taken on. They are not
evidence about the current tree and must never be cited as such.

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

## 2026-11-04 — Library previews play on every tile on screen; hover-only is a setting

- Change: Installed tiles on screen all play their animated preview through LivePreviewScheduler (six loading at once, grid order); Settings › General › Play Library previews only on hover (off by default, WallpaperMachine.libraryPreviewsOnHover) restores the one hovered/focused tile.
- python3 scripts/test.py --only InstalledBrowserModelTests --only PanelPreferencesTests --only PanelSettingsResetTests --only SettingsEditingModelTests --only LivePreviewSchedulerTests --only LibraryTileRulesTests: 99 passed.
- python3 scripts/test.py: 4357 passed, 0 failed, 61 skipped of 4418; 2 runtime warnings in the result bundle, not examined.
- Catalog: two new strings translated into pt-BR, ko, ja, zh-Hans, zh-Hant; localization catalog and panel localization checks pass.
- Not checked: the grid playing in a real window (scrolling, many GIF tiles at once, Reduce Motion) and its CPU/energy cost; no desktop run, no Release build.

## 2026-11-04 — Developer ID signing and Apple notarization for releases

- Change: package.py signs every library, framework, the extension and the app with the hardened runtime and a secure timestamp for a Developer ID, has Apple notarize and staple the app and then the signed disk image, and writes the checksum last; build.yml imports the Developer ID certificate and an App Store Connect API key (five secrets, all present in the repository). The bundle contract enforces host entitlements, the runtime flag, no get-task-allow and one signing team.
- Certificate: G2 Developer ID Application (SHA-1 2076E28E…2E62, expires 2027-12-02); its signature meets the requirement 1.8.0 shipped (codesign -R).
- `python3 scripts/test.py` after rebasing onto main c32fb8d4: 4355 passed, 0 failed, 61 skipped. Upstream's scripts/tests/test_power_ab.py crashes on import on this Mac (dataclass in a module loaded without sys.modules; Python 3.13 and 3.14), though main's Checks pass it on Linux; the gate ran with a local, uncommitted `sys.modules` line in that test, restored afterwards. The Debug app carried a com.apple.FinderInfo attribute that made CodeSign refuse it; cleared.
- Real artifact (Release build of 1.8.2 contents, signed with the G2 certificate): Apple's notary service held the app submission 575b4e21 for about 18 hours (2026-11-03 01:50Z to 19:57Z, new-team hold, as were the team's earlier submissions); then Accepted. `stapler staple` and `stapler validate` passed; `spctl --assess --type execute` reports source=Notarized Developer ID.
- A fresh disk image of that app, signed with the Developer ID, was Accepted in about 2 minutes (a69de3ee, 20:02Z), so the 50-minute CI wait is enough again.
- Local `notarytool submit --wait` lost its connection through this Mac's system proxy (TLS -1200); submitting without waiting and polling `notarytool info` worked. CI has no proxy.
- Gap: this Mac has SIP and Gatekeeper assessments disabled, so library validation and first-launch behavior were not enforced here; the hardened runtime (Apple Events, system audio tap, lock screen including web wallpapers, SteamCMD) needs the 1.9.0 manual smoke on a Mac with both on. The full CI pipeline (package.py --notarize with the DMG step) runs for the first time on the 1.9.0 release.

## 2026-11-03 — Web wallpapers laid out in device pixels and fed silence, compared with Wallpaper Engine

Read off Wallpaper Engine 2.8.42's webwallpaper64.exe (CEF 146) in IDA: force-device-scale-factor=1, disable-web-security, autoplay without a gesture, CefSettings background black, the listener contract. Applied the two differences the local Workshop pages showed: the layout in device pixels and the audio listener called through silence.

- `python3 scripts/we_reference.py capture` of 9 local Workshop web wallpapers in the Parallels VM (Wallpaper Engine 2.8.0.42), then `render --label before/after` and `compare`: mean difference to Wallpaper Engine's frame 3.6 → 0.9 (RE4 case), 2.7 → 0.0 (Audio Visualizer), 3.6 → 1.0 (a visualiser that stayed dark), 19.1 → 15.6 (ZZZ capsules); the others unchanged within noise
- Performance A/B, same jobs back to back, 30 s per page on this Mac: WebContent CPU unchanged on all 9; frame rate unchanged on 7, Rhine Lab 60 → 52 (its renderer supersamples 1.8x at the device-pixel layout, as under Wallpaper Engine), ZZZ capsules 38 → 33 (GPU-bound before); pages that size a canvas from innerWidth draw 4x the pixels (Audio Visualizer GPU 9 → 19 %). WebKit's zoom itself costs no more memory than a native scale of 1 (probe: 69 vs 70 MB)
- `python3 scripts/test.py` after the rebase — 4335 passed, 1 failed (AppUpdateTests installer test over its 2-minute allowance under load; passes alone), 61 skipped; `--only WebWallpaperDeviceLayoutTests --only ScreenSaverWebSurfaceTests` — 22 passed
- Not checked: the desktop app on a real display (offscreen pages only), how a page reads matchMedia resolution queries, the GPU figures are the whole Mac's

## 2026-11-03 — Moving-layer effect reuse on by default

Developer decision: accept rare one-level texel differences from joined render passes for the GPU time layer-local reuse saves (WALLPAPER_MACHINE_LAYER_LOCAL_SIGNATURES, now on unless =0). Supersedes the opt-in line of the power and performance entry.

- `python3 scripts/check_renderer.py` — exit 0, including MetalSceneDraw.AMovingLayerBetweenTwoCardsIsReusedAndJoinsTheCardsRenderPasses
- `python3 scripts/perf_bench.py identity` =0 against the default, 240 draws hashed every 30, both surfaces — identical on 3796026374 and 3624257712; 3808922316 at 3456x2234@2 differs in frame 149 (2 pixels, max channel 1), identical at 3840x2160@2
- Saving (earlier Metal System Trace, 3808922316 at 3840x2160@2): 17 passes a frame left out, about 0.4 ms or 8 % of its GPU time

## 2026-11-03 — Experimental switch: draw only the visible part of cropped scenes

SDR display framing behind `scene_display_framing` under `[experimental]`, off by default; `WALLPAPER_MACHINE_SDR_FRAMING=1`/`=0` overrides it. Measured on an M5 Pro.

- `python3 -m unittest scripts/tests/test_localization_catalogs.py scripts/tests/test_panel_localization.py scripts/tests/test_doc_links.py scripts/tests/test_perf_bench.py` — OK, 56 tests
- `python3 scripts/check_rust.py` — exit 0 (core 419, bridge 935, shader 954 passed); AppKit window cases excluded without an authorized desktop run
- `python3 scripts/check_renderer.py` — exit 0; `RasterWindow.*` (10) and `SdrDisplayFraming.*` (6) pass; local-project and corpus cases skipped (no corpus named)
- `python3 scripts/test.py --only` PanelPerformanceSettingsTests, PanelSettingsResetTests, PanelEnergyRestartTests, DesktopSettledPosterStoreTests and the settings search, localization and render classes — 59 passed
- `perf_bench.py identity` setting off against the branch point (3784370784, 3796026374, 3626305963, 3808922316 at 3840x2160@2 and 3456x2234@2): identical on comparable frames; the remaining verdicts repeat in base-against-base runs (3784370784 is nondeterministic in the base itself)
- With `WALLPAPER_MACHINE_SDR_FRAMING=1` a cropped scene's frames change as stated (3808922316 at 3456x2234@2) and an uncropped one stays identical (3808922316 at 3840x2160@2)
- Cost figures (Miyabi 3784370784 at 3840x2160@2: render targets 508.5 → 437 MB, GPU about −6 to −16%; 16:9 scenes on 3456x2234@2: −3 to −5.5% memory, GPU within noise) come from the framing experiment, not rerun on this branch
- Not run: full `python3 scripts/test.py`, a desktop run, a power measurement and a Release build

## 2026-11-03 — Power and performance: byte-identical renderer savings, host idle work, frame pacing

Branch t3/optimize-power-usage (PR #156) against the v1.8.2 renderer on an M5 Pro (macOS 27), on the local library's heaviest scenes at the developer's settings (render scale 0.75, 60 fps, display resolution, fill), surfaces 3840x2160@2 and 3456x2234@2.

- `python3 scripts/check_rust.py`, `python3 scripts/check_renderer.py`, `python3 scripts/test.py` on the final tree — exit 0; test.py 4320 passed, 0 failed, 60 skipped
- `python3 scripts/perf_bench.py identity` base vs final, 240 draws hashed every 30, both surfaces — 128/128 comparable frames identical on 3808922316, 3796026374, 3626305963, 3624257712, 3669681034, 3537671609, 3441873795, 3013702957; 3784370784 differs between two baseline runs (wall-clock text), covered by masked comparison and equal pass plans
- Layer-local reuse signatures (`WALLPAPER_MACHINE_LAYER_LOCAL_SIGNATURES`) changed 2 pixels by one level on 3808922316 at 3456x2234 (merged render passes blend differently on Apple GPUs) — made opt-in; with it off the scene is identical
- Deterministic counters, all optimisation switches off vs on, 3840x2160@2: memory read by loading render passes 3,187 → 1,543 MB per frame over seven scenes; 3808922316 blits 14 → 0, copies 17.1 → 0 MB per frame
- Metal System Trace with `WALLPAPER_MACHINE_GPU_LABELS=1`: 3784370784 audio visualizer passes 0.81 → 0.01 ms per frame while silent
- Back-to-back GPU ms per draw, off vs on, 3 rounds on battery with other GPU load — indicative only: -7 to -10 % on four scenes, within noise on three
- Not run: `scripts/power_ab.py` desktop windows and the paired `perf_bench.py cost` energy run (machine on battery at 21–26 % and in use); frame pacing's on-screen gap distribution unverified on a real display
- SDR display framing measured and not merged (interior not byte-identical); Wallpaper Engine reference frames captured for 3784370784, 3796026374, 3626305963, 3808922316

## 2026-11-03 — Web lock screen: silence for audio listeners, wallpaper switches no longer count as renderer exits (issue 155)

- Cause 1: the lock-screen page never called the audio listener; 音域回响 starts its idle animation only after the first call, so it held its first frame. ScreenSaverWebSurface now feeds a subscribed, playing page 128 zeros once a second (the desktop's quiet-stretch spacing).
- Cause 2: applying a wallpaper reloads WallpaperAgent, which ends the old renderer while its exit watch was still armed; four switches in ten minutes restored the system wallpaper (seen with ZZZ at 15:58:05). LockScreenWallpaperService now cancels renderer watches before publishing a new revision.
- New tests testASubscribedPageHearsSilenceWhilePlayingAndAgainAfterAResume and testSwitchingWallpapersIsNotCountedAsTheRendererFailing fail with the fixes removed and pass with them.
- python3 scripts/test.py: 4298 passed, 0 failed, 53 skipped. Release build OK.
- Gap: real lock behaviour not checked by the agent; ZZZ's earlier memory-limit stall is unchanged.

## 2026-11-03 — Web lock screen: page paused state follows the surface (issue 155)

- Cause: the extension created a web page paused before its first frame while WallpaperSurface tracked it as playing; applyPolicy never resumed it, so the settling desktop and any lock within ~15 s kept the readiness frame (black/grey for 音域回响 and 阿洛娜指纹识别2.0). Evidence: unified log showed WebPageProxy::suspend 60 ms after load and no resume at the following lock.
- Fix: Extension/WallpaperSurface.swift creates and updates the page with rendererPaused, like scenes and clips; docs/features/lock-screen.md updated.
- python3 scripts/test.py: 4296 passed, 0 failed, 53 skipped.
- python3 scripts/build.py --swift-only --configuration Release: OK.
- Gap: WallpaperSurface is extension-only and has no unit-test harness, so no regression test; real lock behaviour not checked by the agent.

## 2026-11-03 — Web lock screen: a busy page no longer fails its pause or resume

- Symptom: a 3D web wallpaper sometimes held a still frame on lock; the app log showed 'The web wallpaper did not produce a frame in time.' at unlock and the lock screen was handed back to macOS.
- Unified log: on resume the extension's WebKit GPU process got a process-limit-critical memory event (32) and WebKit's display link reported the main thread stuck; the page's property delivery ran only after the 5 s transition deadline had closed the page.
- Fix: ScreenSaverWebSurface bounds waits on the page (properties, media, held frame) at 5 s and goes on without them; only WebKit's suspend/resume not answering within 15 s fails the surface.
- New test ScreenSaverWebSurfaceTests/testABusyPageIsStillResumedAndPausedWithoutFailingTheSurface fails on the old reconcile with timedOut, passes with the fix.
- python3 scripts/test.py: 4291 passed, 0 failed, 53 skipped. Release build OK.
- Not verified: repeated real locks with the user's wallpaper; why the GPU process reaches its limit on resume (two copies of a heavy page: desktop and lock screen) is not addressed.

## 2026-11-03 — Web lock screen and screen saver: export the live page, not only its snapshot

- Symptom after the issue 155 change: a web wallpaper on the lock screen showed a still frame; extension.log showed it was not paused while locked.
- Cause: ScreenSaverWebSurface.attach added the content view's backing layer to the exported root; AppKit kept it in the window's tree, so the CAContext held only the readiness snapshot beneath it (screen saver too).
- Headless probe (never-ordered window, CARenderer over the root): old attach left the root empty; exporting the frame view layer rendered the page's canvas alternating red/blue.
- New test ScreenSaverWebSurfaceTests/testTheLivePageStaysInTheLayerTreeItWasAttachedTo fails on the old attach, passes with the fix.
- python3 scripts/test.py: 4290 passed, 0 failed, 53 skipped. Release build: python3 scripts/build.py --swift-only --configuration Release, OK.
- Not verified: a real lock with the web wallpaper (the user's next run), and the screen saver on a real idle.

## 2026-11-03 — Web and still wallpapers animate the lock screen (issue 155)

- Change: web projects (and still images, which are web projects) are published for Animate lock screen, take the Desktop selection and follow the lock-screen settle/pause policy in the extension; the 'not applicable' status and compatibility verdict are gone.
- python3 scripts/test.py --only LockScreenWallpaperServiceTests --only WallpaperCompatibilityTests --only ScreenSaverWebSurfaceTests --only WallpaperPresentationAuthorityTests: 108 passed.
- python3 scripts/test.py: 4289 passed, 0 failed, 53 skipped; Python stage (localization catalogs, panel localization, doc links) OK.
- New test: a web wallpaper takes the lock screen and keeps it when the screen saver turns off.
- Catalogs: five web-surface errors reworded from 'web screen saver' to 'web wallpaper' in both catalogs; compatibility and Settings copy updated; three unused keys removed; all six languages.
- Not verified: a real lock/unlock with a web wallpaper on the desktop, extension WebKit memory while held, no Release build.

## 2026-11-02 — When another app is in front (discussion #91)

- Feature: Settings → Playback & Power gains When another app is in front (Keep running / Mute / Pause), default Keep running.
- AppRuleMonitor adds the chosen action while the frontmost app is not Finder or this app; no app in front counts as the desktop.
- python3 scripts/test.py --only AppRuleMonitorTests, PlaybackPreferencesTests, PanelSettingsResetTests, ConditionOverrideTests and six more Panel/Backup classes: 120 passed.
- python3 scripts/test.py: Python stage OK; native 4287 passed, 0 failed, 53 skipped.
- Localization catalog and panel localization checks pass; five languages added for title, note and prose.
- Not checked: the setting on a real desktop (no desktop run requested); the app was not rebuilt.

## 2026-11-01 — Discord invitation, About entry and Help menu item

A fifth one-time prompt, Join us on Discord?, invites once to MMFoundation's Discord through https://mmfoundation.dev/discord (ExternalLink.discord, allowlisted; never the invite itself), last in priority, after 21 days and 7 days of panel use on the star prompt's clock. Settings › About gains Join Discord beside MMFoundation and the Help menu gains Join Discord; either spends the invitation. Strings in all six languages.

- `python3 scripts/test.py --only SupportPromptStoreTests --only PanelSupportPromptTests --only SupportPromptPresenterTests --only WelcomeRenderTests --only SettingsSectionsLocalizationTests --only ExternalLinkTests` — 62 passed (after `xattr -cr build/Build/Products/Debug`, docs/build.md)
- `python3 scripts/test.py` — 4268 passed, 0 failed, 52 skipped
- `python3 scripts/build.py --swift-only --configuration Release` — OK
- Sheet (en, zh-Hans) and Settings › About (en, zh-Hans) rendered offscreen from a never-shown window to check the layout; the app was not launched and the Help menu item was not opened by hand

## 2026-11-01 — MMFoundation link in Settings › About

Settings › About gains an MMFoundation button beside the GPL link, opening https://mmfoundation.dev/ through ExternalLink's allowlist (mmfoundation.dev added); READMEs in all four languages name MMFoundation with a link. Run while another task's uncommitted Spaces/desktop-picture edits were in the same checkout.

- `python3 scripts/test.py --only ExternalLinkTests` — 5 passed (after `xattr -cr build/Build/Products/Debug`, docs/build.md)
- `python3 scripts/test.py --only SettingsSectionsLocalizationTests` — 2 passed; MMFoundation added to its same-everywhere names
- `python3 scripts/test.py` — first run 2 failed: the localization test above (fixed) and EnergyUsageMonitorTests.testKernelCountersForThisProcessAdvanceWithGPUWork (3.4 mW, hardware counter); rerun 4258 passed, 0 failed, 52 skipped
- Not checked: the button on screen (no desktop run requested); no Release build

