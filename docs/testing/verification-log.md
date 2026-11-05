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
