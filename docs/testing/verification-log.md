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

## 2026-10-14 — Send performance data, sharing and the one-time prompts

Opt-in telemetry (docs/features/telemetry.md), share buttons, and a prompt store that schedules the support, star and performance data prompts. The website endpoint lives in the website repository and is not deployed.

- `python3 scripts/test.py` — exit 0; 2730 tests: 2685 passed, 0 failed, 45 skipped (opt-in layers)
- `python3 scripts/test.py --only TelemetrySamplerTests --only TelemetryServiceTests --only TelemetryClientTests --only SupportPromptStoreTests --only WebPanelSharingTests --only WebPanelSupportPromptTests` — 45 passed while iterating
- First full run failed one assertion: ControlPanelShellTests counted 3 welcome preference controls, now 4 with the new switch; updated, class passes 27/27
- `scripts/tests/test_panel_localization.py` — 6 passed; 17 new panel keys and 3 native strings in every shipped language
- webui-bridge-reviewer: no CSP, escaping, origin or URL findings; two prompt-flow bugs it found are fixed and tested
- Website: `pnpm typecheck` passed; local `wrangler dev` end to end (store, row dropping, 400/413/429, delete, 180-day cron) passed; not deployed, D1 database not created
- Not verified: energy cost of the 60 s frame window (T9 in power-benchmark.md, needs an authorized desktop run); share menu placement and the inspector row layout with the new button (no desktop run); live upload to production
- App not rebuilt (no Release build)

## 2026-10-14 — Reduced quality under heat and live property edits: integrated gate

The reduced-quality request (heat, Low Power Mode, low battery) and live property edits (preview window, optional desktop, live slider and colour drags), verified together on top of 51975a7f.

- `python3 scripts/test.py` — exit 0 on the first run; Python 316 tests OK; Swift 2656 passed, 0 failed, 45 skipped of 2701 (media, asset and live-network opt-ins)
- `python3 scripts/check_rust.py` — exit 0; core 305, bridge 596, core-integration 16, shader 551 passed; desktop window tests and corpus cases skipped
- `python3 scripts/check_renderer.py` — exit 0; 753 passed, 6 skipped (local-asset cases), 0 failed; project_property_preview_test 23 passed; generated scenes 12 of 12 pixel-equal pooled versus isolated
- `python3 scripts/build.py --renderer-only` — exit 0; regenerated bindings identical to the committed ones
- Not verified: no desktop run. Frame rate and render scale following heat, Low Power Mode or low battery on a real Mac, energy saved by Reduced quality, a web page at a fast display's full refresh reloading when Reduced quality starts or ends, and the feel of live property edits on a running wallpaper

## 2026-10-13 — Follow sliders and colours while they are dragged

A property's slider or colour picker now shows its value in the preview window and, with the Settings switch on, on the displays while the person is still dragging (propertyPreview, at most one step every 100 ms, one in flight), through a pending list on the bridge's wallpaper_preview and preview_wallpaper_properties; releasing saves through the normal property edit. Lane worktree, targeted runs only, not the bare full gate.

- `python3 scripts/test.py --only` the touched and neighbouring panel, preview and store classes (WebPanelPropertyPreviewTests, WebPanelPropertyDragPageTests, WebPanelDisplayPositionTests, WallpaperEditorStateTests, PropertyPreviewSchedulerTests, WallpaperPreviewLivePropertiesTests, WallpaperPreviewRequestTests, PropertyDraftHookTests and 11 more) — exit 0; 182 passed, 0 failed, 0 skipped
- `cargo test -p wallpaper-bridge --lib` — 579 passed (7 new in property_preview, 3 in wallpaper_preview, 1 in state::drafts); `python3 scripts/check_rust.py` — exit 0 (core 299, bridge 579, core-integration, shader)
- `python3 scripts/build.py --renderer-only` — exit 0; the regenerated bindings are in the commit
- Every `scripts/tests/test_*.py` module run directly — all passed
- Mutation checks: dropping the property-preview clears in the edit path and the zero-delay scheduler wait fails 6 tests; dropping the release wait on the step in flight and the colour picker first-step deferral fails 4
- Not run: the bare full gate, `python3 scripts/check_renderer.py` (no C++ change), a Release build, any desktop run
- Unverified without a desktop run: the feel and rate of a drag under load, whether WebKit's colour picker sends input events while it is open (and whether its change event comes with each), the preview window and displays following a real drag, and Revert while holding the thumb (listed in manual-smoke.md)

## 2026-10-13 — Optional live property edits on the desktop

A Settings switch (off by default, this Mac only) lets the displays follow a scene wallpaper's pending property edits through the bridge's property preview before Apply changes; Revert, Apply and turning the switch off put the saved look back. Swift, WebUI and docs only; the renderer and bridge sides were verified in the earlier commits of this package.

- `python3 scripts/test.py --only PropertyPreviewSchedulerTests --only LivePropertyEditingTests --only WebPanelPropertyPreviewTests --only WebPanelGeneralSettingsTests --only PropertyDraftHookTests --only WallpaperPresetStoreTests --only WallpaperPreviewLivePropertiesTests` — exit 0; 69 passed, 0 failed, 0 skipped (a first run failed one existing, timing-shaped scheduler test under load and passed unchanged on the single rerun)
- Mutation checks: dropping the schedule-time applying guard, the due-time switch check or the scene-only guard fails 3 WebPanelPropertyPreviewTests; dropping the Apply and Revert cancels and the mark removals fails 4
- `python3 -m unittest scripts/tests/test_panel_localization.py` — 6 passed (the two new strings are in zh-Hans, zh-Hant and ja)
- Not run: the full gate, `scripts/check_renderer.py` and `scripts/check_rust.py` (no Rust, C++ or bridge change), a Release build
- Unverified without a desktop run: displays following edits, Revert and turning the switch off restoring them, a panel closed mid-edit, several displays and mirrors, Reapply, display changes and wake mid-edit, and the lock screen staying at the saved look (listed in manual-smoke.md)

## 2026-10-13 — Live property preview in the preview window

The Wallpaper Preview window follows the property draft (debounced, hidden-aware) for scenes and Web pages; pictures and files stay as the preview loaded them and the window offers a reload. Swift only; the renderer's hot path was verified in the earlier renderer commits of this package.

- `python3 scripts/test.py --only` the touched preview, draft-hook, preset and panel-property classes (WallpaperPreviewLivePropertiesTests, LivePropertyPayloadTests, PropertyPreviewSchedulerTests, PropertyDraftHookTests, WallpaperPreviewSessionTests, WallpaperPreviewRequestTests, WebWallpaperPreviewSurfaceTests, WallpaperPreviewLayoutTests, WallpaperPresetStoreTests, ControlPanelPreviewTests, WebPanelAssetPropertiesTests, WebPanelHiddenPropertyTests, WebPanelPropertyLabelTests) — exit 0; 93 passed
- `python3 -m unittest scripts/tests/test_panel_localization.py` — 6 passed (the new string is in all four native languages)
- Not run: the full gate, `scripts/check_renderer.py` and `scripts/check_rust.py` (no Rust or C++ change in this commit), a Release build
- Unverified without a desktop run: the visible follow of sliders, colours, combos and booleans in an open preview of a scene and of a Web wallpaper, hidden and paused behaviour, the status line, a real renderer taking the document inside the window (listed in manual-smoke.md)

## 2026-10-13 — Reduced quality for Low Power Mode, heat and a low battery

The panel offers Reduced quality for the three system conditions and names the cause; the bridge, monitor and policy it drives were verified by the three commits before it. Targeted runs only: the full gate and a Release build were not part of this commit's verification.

- `python3 scripts/test.py --only` the 44 classes in `Tests/Unit/Panel` — 283 passed, 0 failed, 0 skipped; includes the new `testReducedQualityShowsItsProfileAndNamesItsCause`, `testDisplayFrameRateNoteCountsTheThrottle` and two `WebPanelPerformanceSettingsTests` cases
- The two new shell tests were re-run against the previous `WebUI/settings.js` — both failed, so they do not pass vacuously
- Each `scripts/tests/test_*.py` module (20, including `test_panel_localization.py`: every `t()` literal translated, identical keys in all three catalogs) — all exit 0
- Skipped: the full `python3 scripts/test.py` gate, `check_rust.py` and `check_renderer.py` (no Rust or C++ change in this commit), `--ui`, any desktop run
- Not covered: the live layout of the Playback rows and how the new sentences read in each language, a real Low Power Mode, thermal change or discharge reaching a running wallpaper, a change while the Mac is locked
- The power saving of Reduced quality has not been measured; no claim is made in the app or the docs. Planned comparison: a power benchmark with the profile on and off (the condition matrix has no row for it yet) in an authorized session

## 2026-10-13 — Native Metal compatibility, cost and default

Native Metal draws scene lights, previous-frame effects and steps with an unproduced input, culls and steps the host frame like Compatibility, shares target images, survives a pipeline-archive folder deleted mid-write, and becomes the default renderer with Compatibility as the per-scene fallback.

- Admission, `metal_scene_draw_smoke` once per scene over the 60 local scene wallpapers: main 95dfb6bc 48/60 on Native Metal (8 history feedback, 4 dynamic lighting); this branch 60/60.
- Same-harness parity, `MetalSceneDraw.LocalProjectsDrawTheSamePictureOnBothRenderers` with `WE_TEST_METAL_FRAMES=180 WE_TEST_RANDOM_SEED=1 WE_TEST_METAL_WARMUP_TICKS=40`: 57/60 identical (mean abs < 0.05/255), 3616389236 0.06 and 3675966045 0.26 (at most 0.1% of pixels), 3610485014 8.6 but differs from itself run to run.
- Cost, `UnchangedPresent.LocalProjectEnergyIsMeasuredHeadlessly` (`WE_TEST_ENERGY_*`), 12 scenes at 3840x2160 and 60 FPS, C N N C, 2 x 15 s per renderer: process CPU time 21.6 -> 17.1 s (-21%, every scene lower), own command-buffer GPU time 59.5 -> 51.0 s (-14%), command buffers 3 -> 1 per frame, CPU energy -12%; Compatibility 50.1 and 57.8 FPS on 3226487183 and 3620484312, Native 60. Measured before the last rebase; whole-GPU energy unusable while other sessions drew.
- Footprint, same test with 2 x 5 s windows on the rebased build: 18954 -> 18318 MB in total (-3.4%), 9 of 12 lower, none more than +6% (within run-to-run spread).
- Target sharing: 3620484312 Native render targets 926 -> 247 MB with no blit added; `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0` restores one image per target.
- Archive crash: `MetalSceneDraw.AStoreFolderDeletedWhileItsArchiveIsWrittenCostsOnlyThatWrite` crashed 4 of 4 runs serialising beside the store and passes 4 of 4 with the fix; found as a SIGSEGV of `unchanged_present_test` in `check_renderer.py`.
- Every commit's tree built and passed `metal_scene_draw_smoke`, `metal_backend_test`, `unchanged_present_test` and `layer_texture_reference_test`; after the rebase onto 18ddfbd8 the same four and `script_runtime_compat_test` pass.
- `python3 scripts/check_rust.py` exit 0 (3 corpus/asset skips); `python3 scripts/check_renderer.py` exit 0 (env-gated local-project, energy, text-workshop and local-video skips); `python3 scripts/test.py` exit 0, 2564 passed, 45 skipped; all on 95dfb6bc plus this branch.
- Not checked: a real display or the desktop, wallpapers outside the local library, the lock screen (still Compatibility). Seen only under parallel load and passing alone: `TextThatHasNotChangedIsNeitherLaidOutNorUploadedAgain`, `TheSkipPresentsTheSameVideoFramesInTheSameOrder`.

## 2026-10-13 — One depth rule for both scene renderers

Native Metal dropped depth writes for translucent and additive materials and depth-tested into targets with no depth attachment; both renderers now take a draw's depth state from ResolveSceneDepthState. Wallpaper Engine's own translucent depth-tested font materials write depth, as Compatibility already did.

- `MetalSceneDraw.ADepthWritingDrawHidesLaterDrawsAsOnCompatibility` (seven authored blend/depth cases through both renderers): **failed** without the source change (translucent, additive and no-attachment opaque cases differ), **passed** with it
- `python3 scripts/check_renderer.py`: **exit 0**; `metal_scene_draw_smoke` **57 passed**, `metal_backend_test` **35 passed**, generated cases pixel-equal with no diagnostics, reload probe 8 projects x2 clean; local-project tests skipped (no `WE_TEST_*` projects)
- `python3 scripts/build.py --renderer-only` then `python3 scripts/test.py`: **2564 passed, 0 failed, 45 skipped**
- After rebasing onto `b0f1a177`: `metal_scene_draw_smoke` **58 passed**, `metal_backend_test` **35 passed**
- Renderer comparison (`LocalProjectsDrawTheSamePictureOnBothRenderers`, on the uncommitted Native Metal compatibility work, which draws model scenes natively) over 28 local model/perspective scenes plus Leon, baseline/fix/baseline: no change beyond run-to-run noise; 3675966045 differs by 0.417 mean in every run, unrelated
- Not checked: the app on the desktop; the Release build follows the commit

## 2026-10-13 — Workshop effect shaders the legalizer rejected

Shader legalizer repairs for permissive-path expressions that dropped whole Workshop effects on both renderers (scalar builtin broadcasts, mixed-width operands, scalar and bool stores, return conversion, widened float-array component subscripts, runtime global initializers, statements after annotations or directives). ShaderPipelineRevision 11 -> 12.

- `cargo test -p shader` — 528 passed; the 12 new regressions in legalize_type_coercion, legalize, naga_compile and tokenizer each failed before its fix
- Local-library A/B, 1,269 (scene, shader, combos) programs from 60 scenes, SPIR-V and MSL: failures 64 -> 28, none that compiled stops compiling; changed output for programs that already compiled is semantically neutral
- The 28 left are outside this change: Naga MSL lacks inverse() (stock lightshafts, perspective, reflection, clouds, waterwaves variants), two preprocessor #if forms, and a builtin scalar call initializing a vector
- `offscreen_scene_probe` and `metal_scene_draw_smoke` on the 11 affected scenes: 77 Vulkan load/compile failures before, 0 after; on Metal only the stock reflection inverse() failure remains; no native-Metal fallback
- `python3 scripts/check_rust.py` — exit 0 (core, bridge, core-integration, shader)
- `python3 scripts/check_renderer.py` — exit 0; generated cases pixel-equal pooled/isolated, no diagnostics; reload cycles clean
- `python3 scripts/test.py` — first run 1 failure in EnergyUsageMonitorTests.testKernelCountersForThisProcessAdvanceWithGPUWork (8.05 mW < 10 mW, own compute kernel, while another session ran GPU probes); class alone 13/13; rerun exit 0: 2,564 passed, 45 skipped
- Not checked: whether each restored effect looks as it does in Wallpaper Engine; no desktop run

## 2026-10-13 — Robustness, web, video, lock-screen and panel port: integrated gate

105 commits of independently implemented reliability, web-host, native-video, lock-screen, power, Workshop, playlist, menu-bar, switch-hold and per-display position work, verified together on one tree on top of 20f44470 (the per-commit entries record each area's targeted runs).

- `python3 scripts/test.py` — exit 0 on the second run; Python 316 tests OK; Swift 2564 passed, 0 failed, 45 skipped of 2609. The first run had one failure, ControlPanelLibraryTests.testHoldAndDragSelectsARunOfTilesWithoutWindow, under load from another build; the class passed alone (17/17) and the sweep code is unchanged by this work
- `python3 scripts/check_rust.py` — exit 0; core 293, bridge 542, core-integration 15, shader 534 passed; desktop window tests and corpus smoke cases skipped
- `python3 scripts/check_renderer.py` — exit 0; 708 gtest cases passed, 4 skipped (local-asset cases), 0 failed; no --project corpus, so authored-reference compatibility is not verified
- `python3 scripts/build.py --configuration Release` — exit 0; regenerated bindings identical to the committed ones
- Commits that change the bridge API or move test helpers were each compiled on their own with `scripts/test.py --only` at that commit
- Not verified: no desktop run. The switch-hold picture during a wallpaper change, wake and stall repair, the lock screen, menu-bar submenus, the position controls on real displays, native-video layout on real displays and live Steam downloads still need an authorized desktop check
