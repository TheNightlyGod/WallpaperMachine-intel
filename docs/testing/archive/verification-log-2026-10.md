# Verification log archive — 2026-10 and earlier

Retired entries from [../verification-log.md](../verification-log.md), moved
here when that log was capped at its ten newest entries. No recorded result was
rewritten: each entry is reproduced verbatim, and the only edit is that
relative Markdown links gained one `../` for this file's extra directory
level.

These are historical results about the trees they were taken on. They are not
evidence about the current tree and must never be cited as such.

## 2026-10-17 — Settings: Reset all settings

- python3 scripts/test.py --only PanelSettingsResetTests: 2 passed (confirm/cancel; defaults restored, content kept, unchanged engine settings not sent).
- python3 scripts/test.py: 3837 passed, 0 failed, 45 skipped.
- Not checked: the confirmation sheet and button on a real window (no desktop run); lock screen/screen saver turn-off and launch-at-login reset are exercised only through their existing services.

## 2026-10-16 — Per-language release banners, bulleted What's New

Each language block opens with its own banner (x.y.z.jpg, x.y.z.zh-Hans.jpg; Chinese falls back to English); What's New swaps the banner with the language tab, bullets list entries with a hanging indent and shows Highlights in the accent colour with ✦ markers. 1.5.0 now has English and Chinese banners.

- `python3 scripts/test.py` — exit 0; 3873 tests: 3828 passed, 45 skipped; test_release_notes.py 62 tests OK
- Visual: temporary on-screen XCTest window with a draft 1.5.0 section, captured in English and Chinese; probe deleted
- Skipped: live --ai model run (no key locally); the draft section was hand-written to preview layout only

## 2026-10-16 — Release banners and highlights in the changelog

Feature releases can carry a bundled 3:1 banner (Resources/ReleaseBanners/x.y.z.jpg) shown in CHANGELOG.md, the GitHub release page and the What's New window; the release-notes model writes Highlights for x.y.0 and groups many commits per area. Banner for 1.5.0 added.

- `python3 scripts/test.py` — exit 0; 3872 tests: 3827 passed, 45 skipped; test_release_notes.py 61 tests OK
- `python3 scripts/test.py --only WhatsNewTests` / `--only AppUpdateTests` — passed while iterating
- Visual: temporary offscreen XCTest snapshot of the What's New window with the bundled 1.5.0 banner (dark), banner above the header at 712 pt, notes below; probe deleted
- Skipped: live --ai model run (no RELEASE_NOTES_API_KEY locally), so the 1.5.0 wording is written by CI at release; the raw.githubusercontent banner URL is checked only by unit test until v1.5.0 is tagged

## 2026-10-16 — Tabs in the title bar, Now Playing bar and one-colour title bar on top of the Filters sidebar

- Rebased onto main's Filters sidebar (69955b77, cf9f5ebe): my own filters panel was dropped; the sidebar now slides from the window's leading edge, and Installed's has the Collections group at its top.
- Window: no window sidebar; Library, Steam Workshop, pixiv and Settings are tabs centred in the title bar (symbols only under 960 points) with the mark, name and version leading; Library has All wallpapers and Favorites chips; Now Playing is a bottom bar whose wallpaper part opens a details popover; Settings searches above its own section list.
- Title bar: macOS 26 draws a band per window column (opaque grey over a page without a top scroll view, its own dark band over the system inspector). The inspector is now an in-page InspectorColumn (260-420, drag to resize) and the Filters sidebar, page and inspector sit in one full-width scroll host, so the bar is one colour.
- Real window (desktop control allowed by the user): Library with Filters sidebar and inspector open, and Settings, sampled 29,29,31 across the whole bar in dark; inspector edge drag resized it.
- Gate: python3 scripts/test.py passed, 3826 passed, 0 failed, 45 skipped. Targeted shell, root, welcome, installed, inspector, pixiv and workshop classes: 160 passed.
- Not run: desktop UI tests (Tests/UI updated, not executed); light appearance not checked on the real window.

## 2026-10-16 — Filters sidebar replaces the Filters popover

- Change: Installed, Workshop and pixiv filters moved from a popover into one shell-level Filters sidebar (FilterSidebar in PanelDetail) that slides out from under the window sidebar; Filter buttons and the sidebar's own top-right button toggle it.
- python3 scripts/test.py: passed, 3829 passed, 0 failed, 45 skipped (Python suites OK).
- New tests: ShellModelTests (one sidebar across library pages, waits out Settings; takes turns with the inspector under 960 pt), ShellRenderTests (sidebar + inspector fit the split view from 1240 down to 760 pt).
- Migrated tests: InstalledBrowserModelTests, InstalledPageRenderTests (sidebar width 268 pt in every language and appearance), WorkshopBrowserModelTests, ShellModelTests support-prompt/popover cases.
- Visual: offscreen snapshot (temporary probe, deleted) confirmed placement beside the page and search bar; offscreen rendering draws no glass, so the glass look and the slide animation were not seen on a real desktop.
- Gap: InspectorRenderTests smallest-window test timed out twice earlier today on the untouched base and passed in this run: flaky, unrelated.

## 2026-10-16 — origin/main's telemetry and sharing carried into the native panel

Main's 103 unpushed commits were rebased onto origin/main, whose 1.4.1 telemetry and sharing commits were written for the web panel the native SwiftUI panel had replaced; their services kept, their web UI rebuilt natively (Storage switch and report, guide draft, three-prompt sheet, Share…, About links).

- `python3 scripts/test.py --only` the ten touched classes (PanelPerformanceDataTests, PanelSharingTests, PanelSupportPromptTests, SupportPromptPresenterTests, SupportPromptStoreTests, FirstRunModelTests, FirstRunDraftTests, Telemetry{Service,Sampler,Client}Tests) — 97 passed
- `python3 scripts/test.py` — exit 65; 3864 tests: 3815 passed, 4 failed, 45 skipped. The 4 are SettingsBRenderTests.testTheEditorsAndOpenDisclosuresStillFitTheNarrowestWindowIn{English,Japanese,SimplifiedChinese,TraditionalChinese}: they hang laying out Keyboard shortcuts with its links disclosure open, and the English one fails the same way on 820c436a, before the rebase and this port
- `python3 scripts/build.py --swift-only --configuration Release` — built; the binary carries the new Storage rows
- Not checked: the share menu and the sheets on screen (no desktop run authorised), the live website endpoint

## 2026-10-16 — Settings name what overrides a quality or frame-rate choice

Reported as On battery: Keep running still capping wallpapers at 30 fps. The app's log showed the low-battery rule (saved as Reduced quality, level 20%) engaging at 20% charge; nothing in Quick Settings said so, and the Displays and inspector notes blamed Performance settings and linked to a Frame rate limit reading No limit. Quick Settings' Quality and On battery modules, Performance › Effective now and the Displays and inspector frame-rate notes now name the cause and open the page it is set on.

- `python3 scripts/test.py --only QualityReportTests --only QualityPresetTests --only DisplaysSettingsModelTests --only PanelPropertyRowsTests --only PanelLibraryActionsTests --only SettingsSectionsRenderTests --only SettingsSearchTests --only PanelSettingsValuesTests --only SettingsControlsRenderTests --only PanelPerformanceSettingsTests` — 157 passed
- `python3 scripts/test.py` — exit 0; 3819 tests: 3774 passed, 45 skipped (opt-in media and network layers)
- `python3 scripts/build.py --renderer-only` — run first in the worktree to replace a stale bridge library; regenerated bindings unchanged
- Skipped: no desktop run; the new lines were not looked at on screen (render tests lay out the Quick Settings and Performance pages with a throttle in force in every language). Manual check added to docs/testing/manual-smoke.md.
- Gap: a condition's Pause or Stop overriding On battery: Keep running is still not shown in Quick Settings.

## 2026-10-16 — Native Metal matched to Wallpaper Engine 2.8 scenes: gate, comparison with its frames and Release build

The 70 Wallpaper Engine parity commits on main (5f3e5d58..98be08fa: scene, text, particle, shader, script, video and harness changes), checked in an isolated worktree of the landing chain and then built from main.

- `python3 scripts/check_rust.py` — exit 0
- `python3 scripts/check_renderer.py` — exit 0; no FAILED line in the evidence logs and every report.json count 0; skipped: the shader asset tests (no WALLPAPER_MACHINE_ASSETS_ROOT) and the local-project gtests
- `python3 scripts/test.py` — 3767 to 3769 of 3815 passed, 45 skipped; `PixivBrowserRenderTests.testAtTheSmallestWindowThePillGivesWayToTheDownloadsButtonAndTheInspectorToggle` times out, as it does on main 5f3e5d58 without this work; `PowerSourceResamplerTests.testStartingTwiceDoesNotObserveTwice` and another Pixiv grid test failed once under load and passed in the other runs
- every one of the 70 commits built alone and passed the 30 renderer test binaries (and the Swift classes and Rust crates it touches)
- Native Metal renders of 40 Workshop scene wallpapers compared with Wallpaper Engine 2.8.42's own frames (display resolution, pointer at the centre, real-time pacing, clock at the capture time): of 324 differences found before, 142 fixed, 13 improved, 18 unchanged, 0 worse; no wallpaper left with a major difference
- gaps: web wallpapers were not recaptured (no change to the web host); volumetric lights, model MSAA and the other listed known limitations remain; one reference capture showed another wallpaper; the app was not run on the desktop
- `python3 scripts/build.py --configuration Release` — OK; the app's bridge checksums match its bindings

## 2026-10-16 — Text layout, placement, effect buffers and fonts: review follow-ups of the text steps

Follow-ups to the reviews of the ported text steps (face cache, alignment words and brightness, card layout, placement, effect buffers, composite, fonts), checked in an isolated worktree with the renderer test binaries; the app gate (`scripts/test.py`), `scripts/check_renderer.py` and the Swift unit target were not run, and there was no desktop, app launch or audio.

- every renderer test binary of the worktree (`run_suites.sh`, 30 binaries) — all passed, among them `text_object_runtime_test` 158, `metal_scene_draw_smoke` 130, `scene_schema_tests` 156, `script_runtime_compat_test` 171, `mouse_input_test` 30, `layer_texture_reference_test` 38
- new tests fail without their change: a font file rewritten or deleted under a cached face, the rows set within the widest row's width (not the block's), the effect matrices of a screen-anchored text, CJK punctuation drawn by the symbol face
- rebuild cost of a text card that changes in texels, six forced rebuilds on a real clock scene (72 passes, 1920 by 1080, native Metal) — 0.5 to 0.8 ms to lower and 39 to 45 ms to compile; 0.6 to 0.9 ms on a one-layer scene
- gaps: no Wallpaper Engine frame was compared for the changes of this pass; the brightness probes (`probetextb1`, `probetextb2`) and the exponent probe for a chain other than opacity are uncaptured, so the HDR half of the text brightness rule and the composite exponent of non-opacity chains stay inferred; that Segoe UI Symbol lacks the CJK punctuation is inferred; the sandboxed lock-screen extension was not run with a face opened by path

## 2026-10-15 — Scene font keys, Windows-font stand-ins, the glyph fallback list, opaque backgrounds and Windows font names in web wallpapers

Worktree steps T11, T12 and T10 of the text parity work, checked in an isolated worktree with the renderer test binaries and, for the Swift part, a standalone XCTest bundle built from the repository's own source files; the app gate (`scripts/test.py`), `scripts/check_renderer.py` and the Swift unit target were not run, and there was no desktop, app launch or audio.

- `ctest` over every renderer test binary built from the worktree — 1484 of 1485 passed; 10 not run (2 disabled, 8 skipped for lack of local corpus, video or project inputs); the one failure, `FrameTimerTest.ADrawSlightlyLongerThanTheIntervalDoesNotHalveTheRate`, is a wall-clock timing test in code this change does not touch and passed on 3 of 4 reruns alone
- `text_object_runtime_test` 154 (152 passed, 2 skipped: the local-project tests), `metal_scene_draw_smoke` 110 (108 passed, 2 skipped), `scene_schema_tests` 137, `script_runtime_compat_test` 163, `layer_texture_reference_test` 37, `project_property_preview_test` 23, `mouse_input_test` 22, `static_subgraph_cache_test` 26, `metal_backend_test` 36 — all passed, on both renderers where a test draws
- `WebWallpaperFontAliasTests` (10 cases, real offscreen `WKWebView`s, no window) compiled with `swiftc` against `Shared/` and run with `xcrun xctest` — all passed; with the script emptied the Han, Segoe UI and subframe cases fail
- the two opaque-background draw cases fail with the fill switched off (196 failed checks) and pass with it, on both renderers
- the Consolas clock of workshop 3299228616 rendered with `render_ours.py` against Wallpaper Engine's frame: digit rows 87 tall in both (101 with the first stand-in tried) and rows 362-448 here against 361-447, the date's 471-491 against 470-491; before the ascender was set to 0.743 em the clock stood 12 pixels low
- probetext1 against Wallpaper Engine's frame: cap tops and baselines unchanged and equal (793.0/651.0 and 602.5/320.1)
- gaps: the probe of the eight font keys at three alignments (`probefont1`) was queued and the capture loader was not running, so the ascender and descender of Cambria, Segoe UI and Calibri stay the fonts' remembered tables with only their sum checked; no Wallpaper Engine frame of Cambria, Segoe UI, Calibri or an opaque background was compared; the web stand-ins' glyphs and line metrics were not compared with a Wallpaper Engine frame; the lock-screen extension was not run

## 2026-10-15 — Text through effects is composed over the scene behind it, and padded only while an effect is visible

Worktree step T9 and T5 of the text parity work, checked in an isolated worktree with the renderer test binaries; the app gate (`scripts/test.py`) and `scripts/check_renderer.py` were not run, and the spec's generated-picture case for the composite is covered by drawn `metal_scene_draw_smoke` cases instead.

- `ctest` over every renderer test binary built from the worktree — all 1476 that ran passed; 2 are disabled and 8 skipped for lack of local corpus, video or project inputs
- `text_object_runtime_test` 145, `metal_scene_draw_smoke` 106 (2 skipped: the local-project tests), `scene_schema_tests` 137, `script_runtime_compat_test` 163, `layer_texture_reference_test` 37, `project_property_preview_test` 23, `mouse_input_test` 22, `static_subgraph_cache_test` 26, `metal_backend_test` 36 — all passed, on both renderers where a test draws
- probetext4 rendered with `render_ours.py` against Wallpaper Engine's frames: stems at alpha 1, 0.65 and 0.5 are 1.000, 0.651, 0.498 plain and 1.000, 0.275, 0.125 through `opacity`, equal to Wallpaper Engine's
- a scene of three text layers whose shipped `opacity` effect a script switches on from 0.5 s to 1 s, drawn natively at 1920x1080 with the shipped assets (`LocalProjectsDrawTheSamePictureOnBothRenderers`, native only): ink at frames 10, 45 and 90 with the same box, where frames 10 and 90 had none before the passthrough took a white `g_Color4`
- the new draw cases fail without their fix: the scripted, add and shipped-effects cases without the white `g_Color4`, the add case without `SetIdleFinalBlend`; the no-pass case fails without `EffectCountsForText` and the skip of effects with no pass
- gaps: whether an effect that leaves alpha alone composes at the alpha cubed is open (the VHS frame of 3465215190 reads the alpha squared) and the capture that settles it was not taken; no Wallpaper Engine frame of HDR text through an effect, nor of mode 31 text with an effect, was compared

## 2026-10-15 — 2D scene resolution: Display resolution by default

Headless only: no desktop, no audio, no app launch, no Release build.

- Renderer binaries rebuilt from the final tree and run whole: `render_scale_test` 23 passed (13 new `RasterResolution.*`), `wallpaper_scaling_test` 8, `metal_backend_test` 35, `unchanged_present_test` 11 (1 new, a running scene on both renderers), `metal_scene_draw_smoke` 86 (2 new). The picture test fails when the compatibility backend is made to ignore the choice.
- `python3 scripts/check_rust.py` — exit 0: core 315, bridge 602 (5 new), core-integration, shader; the asset-dependent shader cases skipped as printed (no Wallpaper Engine assets directory, no unpacked corpus).
- `python3 scripts/test.py --only` on the settings classes (PanelPerformanceSettingsTests, PanelEnergyRestartTests, SettingsSectionsLocalizationTests, SettingsSectionsRenderTests, SettingsControlsRenderTests, SettingsSearchOfferTests, PanelSettingsValuesTests, SettingsEditingModelTests) — 62 passed. All 113 panel classes at once: 994 passed, 27 failed, every failure a test that does not pin the language reading this Mac's saved app language (zh-Hans), and failing the same alone; not caused by this change.
- The 21 Python script test modules (catalog and panel localization included) — passed.
- Both renderers draw two local 1920x1080-canvas scenes byte for byte alike at 3456x2234 backed at 2x in both modes (`DrawTheSamePictureOnBothRenderers` with `WE_TEST_COMPARE_RESOLUTION`, 60 frames). Display mode crops show crisper edges and grain than Canvas at the same size; viewed offscreen, never on the desktop.
- Cost, `LocalProjectEnergyIsMeasuredHeadlessly` (`WE_TEST_ENERGY_RESOLUTION`), 3456x2234 at 2x, 60 fps, 2 x 20 s per mode, canvas/display/display/canvas: a bloom and effect-chain scene on Native Metal 1.62 -> 3.42 ms own GPU time per frame, render targets 35 -> 94 MB, peak footprint 380 -> 455 MB; on Compatibility 1.91 -> 3.27 ms and 399 -> 480 MB; a 26-layer scene of mostly author-sized buffers 1.76 -> 2.33 ms, 132 -> 160 MB, 515 -> 555 MB. CPU time per frame unchanged; energy not measured; footprint carries about 30 MB of run-to-run noise.
- Not run: the full `python3 scripts/test.py` and `python3 scripts/check_renderer.py` gates, a desktop run, the lock screen (it never sets the choice and keeps the canvas), a Release build.

## 2026-10-15 — Native SwiftUI control panel

- Change: the WKWebView control panel (WebUI/) is replaced by a native SwiftUI window (b5722da7, 511e3a86, 4767f8b4); typed PanelController actions, live language via per-language catalogs, DesktopActions test guard.
- Gate: `python3 scripts/test.py` on the final tree (identical to main at 4767f8b4): Python script tests OK; native 3758 passed, 0 failed, 45 skipped of 3803.
- Earlier full runs on the same tree failed only on load-sensitive waits (PanelDownloadActionsTests, PixivBrowserRenderTests, InstalledPageRenderTests); each was made to wait for state and passed alone and in the final gate.
- Strings: `scripts/tests/test_localization_catalogs.py` and the new literal check `scripts/tests/test_panel_localization.py` pass; a SWIFT_EMIT_LOC_STRINGS extraction diff found no panel literal without a catalog key (only the pre-existing App Intents `%@`).
- Regression tests added for two crashes found during integration: Installed→pixiv toolbar search swap (`PanelPageTransitionTests`) and the Installed grid's layout loop at 760×560 with scroll bars that take room (`InstalledPageRenderTests`).
- Release: `python3 scripts/build.py --swift-only --configuration Release` from the final tree; delivered to build/Build/Products/Release/WallpaperMachine.app (no WebUI resources, signature verified).
- Not checked (no desktop authorization): the real window — sidebar material, toolbar, full screen and Split View, hover/focus rings, VoiceOver and live drags were seen only in offscreen renders; `python3 scripts/test.py --ui` (updated for the native window) was not run.
- Known noise: ~455 AppKit runtime warnings per run, all toolbar-title constraint conflicts in squeezed test windows.

## 2026-10-14 — Settings drawn like System Settings, with its own solid glyphs

Settings restyled after a Claude Design mock-up: centred page cards, translucent grouped boxes, borderless pop-ups, small switches, the ⓘ beside each title, flattened Advanced, and a hand-drawn solid glyph set (WebUI/settings-glyphs.js) for sections and Quick Settings tiles. Layout bugs fixed on the way, plus search hiding an open disclosure whose title missed.

- `python3 scripts/test.py` — exit 0; 2704 tests: 2659 passed, 0 failed, 45 skipped
- `python3 scripts/test.py --only ControlPanelShellTests/testQuickSettingsSearchAndExplanationsWithoutWindow` — passes with the search fix; with only that hunk reverted the new assertion fails (seen as the panel harness's 2-minute timeout, which is how a failed assertion inside `withPanel` surfaces)
- Visual review: a temporary offscreen WebKit capture test (deleted) rendered all 11 sections in light and dark at 1100 and 780 px, plus search and an opened ⓘ; glyphs checked on a `qlmanage`-rendered contact sheet at 15, 18 and 34 px
- Not checked: the real window's vibrancy sidebar and hover states of the borderless pop-ups (offscreen snapshots draw neither); no desktop run

## 2026-10-14 — Control panel redesign: macOS sidebar, System Settings-style Settings

The control panel became a native-looking macOS window: a floating sidebar over the system sidebar material, a title bar naming the place on show, Now Playing in place of the activity bar, a Filters popover, and Settings reorganised into searchable System Settings-style sections with Quick Settings. New native action: nextWallpaper.

- `python3 scripts/test.py` — exit 0; 2,704 tests: 2,659 passed, 0 failed, 45 skipped
- Targeted offscreen panel suites (every `Tests/Unit/Panel` class plus `AppThemeTests`) — all pass, including the new `testQuickSettingsSearchAndExplanationsWithoutWindow`, `testSidebarShowsFavoritesAndCollectionsAsLibraryViewsWithoutWindow` and `testNextWallpaperMovesARotatingPlaylistAlongAndOtherwiseLeavesTheScheduler`
- `python3 -m unittest scripts/tests/test_panel_localization.py` — 47 new strings in zh-Hans, zh-Hant and ja
- Visual: offscreen WKWebView renders (dark/light; Installed, Discover with Filters, Quick Settings, Playback & Power, Appearance; 860px rail) reviewed; offscreen snapshots freeze transitions and do not draw backdrop blur, so those were checked in a browser harness instead
- `python3 scripts/build.py --swift-only --configuration Release` — built
- Not checked: the real sidebar material, traffic-light alignment and full-screen layout in a live window (no desktop run was authorised)

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

## 2026-10-13 — Position sliders follow a drag

Commit 8 of the framing lane: while a Position slider is dragged the running wallpaper follows through a non-saving preview call; the release is the ordinary move. Targeted runs in the lane's worktree; the bare full gate was not run, no desktop was opened and the app was not rebuilt there.

- `cargo test --release -p wallpaper-core --lib framing` and `-p wallpaper-bridge --lib display_position` — pass (core 17 framing tests, bridge 24 position tests); each bridge mutation of the preview mark, the saved-axis base and the commit clearing was caught
- `python3 scripts/check_rust.py` — exit 0; core 287, bridge 540, core integration and shader passed; six core tests excluded (desktop run, local wallpaper corpus)
- `python3 scripts/build.py --renderer-only` — exit 0; `App/Bridge/Generated` regenerated (one method, `preview_display_position`)
- `python3 scripts/check_renderer.py` — exit 0; skipped: local-asset cases in `text_object_runtime_test`, `playback_gpu_test` and `metal_scene_draw_smoke` (no corpus)
- `python3 scripts/test.py --only WebPanelDisplayPositionTests` and 13 neighbouring panel classes — 133 passed; the drag tests were broken one at a time (no interval, release not waiting for the step on its way, no settle on pointer-up, key presses previewing, a queued or saving preview) and each was caught
- Not checked: the wallpaper following a real drag on a display, the 100 ms interval and the feel under load, the lock screen and Mission Control picture staying put during a drag, and `SceneRuntime::preview_framing` against a live renderer (see manual-smoke.md)

## 2026-10-13 — Per-display wallpaper position

Commit 7 of the framing lane: the inspector's Position sliders and Center for scene and video wallpapers. Commits 1-6 had already carried the position through the engine, the bridge and the lock-screen export; commit 8 follows the sliders live.

- `python3 scripts/test.py --only WebPanelDisplayPositionTests` — exit 0; 10 passed
- `python3 scripts/test.py` with 23 `--only` classes (the panel suites, UserCommandQueueTests, WallpaperActivationRecoveryTests, ActivationLogTests) — exit 0; 198 passed, 0 failed
- Script tests (the 20 modules the gate runs first, run directly) — exit 0, including test_panel_localization: the ja, zh-Hans and zh-Hant catalogs carry the four new strings
- Mutation checks — eleven deliberate breakages (dead change handler, sliders hidden for scenes, request naming no axis accepted, clamping instead of refusing, no scene/video and display check, no change notice, native flag for any backend, reset sending one axis, move not queued, both axes sent, native note dropped) each failed the new class, which passed again once they were undone
- Not run: the bare `python3 scripts/test.py` gate, `check_rust.py` and `check_renderer.py` (no Rust or C++ change), a Release build
- Unverified (desktop only): the wallpaper visibly moving under the sliders on a real display on both scene renderers, slider feel and layout at the narrowest panel width, VoiceOver reading, the Mission Control picture being retaken after a move

## 2026-10-13 — Web host takes the switch hold

A replacement web page's window opens with the picture it replaces over it and drops it 500 ms after the page has loaded, or at once when it fails. A window closed with no web successor ends only the veil it carries. Targeted run only: the lane runs the full gate once, at its end.

- `python3 scripts/test.py --only WebWallpaperHostLifecycleTests --only WallpaperSwitchHoldTests` — exit 0; 51 passed (10 new: 8 web host, 2 hold)
- `python3 scripts/test.py` with the web test classes, `NativeVideoWallpaperHostTests`, `WallpaperActivationRecoveryTests` and `DesktopWallpaperTests` — exit 0; 336 passed
- Mutation check — five one-line breakages of `WebWallpaperHost` (no adopt, no release on load, no release on failure, the plan's unconditional `cancel` where a window closes, no release of a veil on the closed window) each failed between 1 and 4 of the host tests
- Skipped: the full gate and `check_rust.py`/`check_renderer.py` (no Rust or renderer change in this commit), any desktop run
- Not established: that 500 ms after `didFinish` is enough for a real project's first paint; how long the system picture shows while a page's window is replaced, and after a scene closes; the fade and the page-to-page, scene-to-page and page-to-scene switches on a real display ([manual smoke](../manual-smoke.md#wallpaper-switching))

## 2026-10-13 — Native video host takes the switch hold

A replacement clip's window opens with the picture it replaces over it and drops it on the clip's first frame; a replacement's admission is decided before the old surface stops. Targeted run only: the lane runs the full gate once, at its end.

- `python3 scripts/test.py --only NativeVideoWallpaperHostTests` — exit 0; 98 passed (11 new)
- `python3 scripts/test.py --only NativeVideoWallpaperHostTests --only WallpaperSwitchHoldTests --only WallpaperActivationRecoveryTests --only DesktopWallpaperTests` — exit 0; 225 passed
- Mutation check — seven one-line breakages of `NativeVideoWallpaperHost` (no adopt, close before admission, no cancel on failure, no settle after hand-off, no release on first frame, no overtaken-pass guard, no release for a layer ready at birth) each failed between 1 and 5 of the host tests
- Skipped: the full gate and `check_rust.py`/`check_renderer.py` (no Rust or renderer change in this commit), `NativeVideoPlayerMediaTests` (opt-in), any desktop run
- Not established: that `isReadyForDisplay` alone is late enough that the veil does not come off a frame early on a real clip; the fade and the clip-to-clip, scene-to-clip and refusal switches on a real display ([manual smoke](../manual-smoke.md#wallpaper-switching))

## 2026-10-13 — Wallpaper switch hold for scene successors

Commit 3 of the seamless-switch lane, built and tested in an isolated worktree on top of the layer-swap revert and layer announcement commits. Web pages and native-backend clips take the veil in the lane's next commits; this one carries it for scenes.

- `python3 scripts/test.py --only WallpaperSwitchHoldTests --only WallpaperActivationRecoveryTests --only DesktopWallpaperTests --only WallpaperPresentationPolicyTests --only WallpaperReapplyTests --only WallpaperDisplayTransferIntegrationTests --only WallpaperDisplayTransferTests --only UserCommandQueueTests --only ActivationLogTests --only WallpaperWindowAuditorTests` — exit 0; 234 passed, 0 failed, 0 skipped
- Mutation check on `WallpaperSwitchHold` (a reconfigure takes the veil, the engine settling no longer fades a scene's veil, the host grace is never applied): 7 of the 26 `WallpaperSwitchHoldTests` failed; the file was restored
- Not run: the full gate, `scripts/check_rust.py` and the renderer checks (no Rust, bridge or C++ change in this commit), and the gated window cases of the lane's first two commits (`case_wallpaper_window_layer_swap_revert`, `case_wallpaper_window_layer_swap_finish`, `case_wallpaper_window_announces_layers`)
- Unverified, desktop only: a sublayer above the `CAMetalLayer` composites over its drawables and hides the black placeholder, scene surfaces answer the still request within 250 ms (a paused renderer included), the held still looks like the live frame it replaces, the 0.2 s fade, Reduce Motion, multi-display and mirror switches (checklist in manual-smoke.md)

## 2026-10-13 — Workshop downloads in the menu bar

StatusMenuModel.DownloadActivity and WorkshopDownloadManager.inProgressTransfers: while Workshop downloads run, a line under Control Panel reads Downloads: N in progress with a byte-weighted percent that is left out when any counted job cannot report a size and stops at 99, and opens Discover. Built when the menu opens (no timer). Commit 10 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1; targeted runs only, not the full gate. No Rust, bridge or renderer change.

- `python3 scripts/test.py --only StatusMenuModelTests --only DownloadQueueTests --only WorkshopDownloadPersistenceTests --only WorkshopStoreTests --only AppAutomationTests --only AutomationCommandTests --only ControlPanelAutomationTests --only DownloaderLifecycleTests` — exit 0; 116 passed, 0 failed, 0 skipped
- Mutation check: counting a paused job, counting the sign-in job and letting the percent reach 100 each failed the test written for it (3 failures); all were reverted
- Every scripts/tests/test_*.py module run directly — 316 passed (the native catalog key `Downloads: %lld in progress, %lld%%` was confirmed against what the Swift compiler extracts for the literal)
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_rust.py`, `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: how the line draws and reads in the real menu, that it appears while a real SteamCMD transfer reports bytes, and that choosing it brings Discover forward; see manual-smoke "Download queue"

## 2026-10-13 — Mute every wallpaper (menu bar, links, Shortcuts, shortcut key)

PlaybackPreferences.wallpapersMuted, OR-ed into WallpaperPresentationPolicy's audio suppression (the bridge's audio_suppressed, which the engine ORs with each wallpaper's saved mute), reached from a ticked Mute Wallpapers menu item, wallpapermachine://mute, unmute and togglemute, three Shortcuts actions, a shortcut key and a Settings → Performance → Playback switch. Commit 9 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1; targeted runs only, not the full gate. No Rust, bridge or renderer change.

- `python3 scripts/test.py --only PlaybackPolicyCompositionTests --only PlaybackPreferencesTests --only AutomationCommandTests --only HotKeyPreferencesTests --only StatusMenuModelTests --only WebPanelGeneralSettingsTests --only WallpaperBackupTests --only WallpaperPresentationPolicyTests` plus AppAutomationTests, GlobalHotKeysTests, WebPanelPerformanceSettingsTests, ControlPanelShellTests, WebPanelExternalLinkTests, WebPanelAssetsTests, ControlPanelAutomationTests, WallpaperActivationRecoveryTests, OtherAudioMonitorTests, AppRuleMonitorTests and SystemConditionMonitorTests — exit 0; 247 passed, 0 failed, 0 skipped
- Mutation check: dropping the user mute from the policy, the muted arm of the menu item's condition, the unchanged-value guard in the preference and the Settings row each failed the tests written for them (5 failures); all were reverted
- Every scripts/tests/test_*.py module run directly — 316 passed (the WebUI key check includes the new keys in ja, zh-Hans and zh-Hant)
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_rust.py` and `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: that scene, video (Native and Compatibility) and Web wallpapers really go silent and come back through an audio output (audio hardware needs an authorized desktop run; only the suppression delivered to the bridge is tested), how the ticked menu item draws and reads, Siri or Shortcuts listing the three actions, and a real shortcut key press; see manual-smoke "Audio responsiveness"

## 2026-10-13 — Random Wallpaper command

A new AutomationCommand.random(display:pool:) with pools all and favorites, reached from the menu bar, wallpapermachine://random, a Shortcuts action and a shortcut key. Its pick comes from PlaylistStore.randomPick with a round of its own per display and pool (kept beside the shuffle rounds in WallpaperMachine.playlistRounds), and BridgeStore.activateRandomWallpaperAsync makes it in the display's turn of the command queue. Commit 8 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1; targeted runs only, not the full gate.

- `python3 scripts/test.py --only AutomationCommandTests --only PlaylistStoreTests --only PlaylistPlannerTests --only HotKeyPreferencesTests --only StatusMenuModelTests --only WallpaperDisplayTransferIntegrationTests --only WebPanelGeneralSettingsTests` — exit 0; 105 passed, 0 failed, 0 skipped
- `python3 scripts/test.py --only AppAutomationTests --only GlobalHotKeysTests --only PlaylistSchedulerTests --only WebPanelPlaylistTests --only WallpaperBackupTests --only ControlPanelPlaybackToolsTests --only ControlPanelShellTests --only WebPanelAssetsTests --only ActivationLogTests --only WallpaperActivationRecoveryTests` — exit 0; 172 passed, 0 failed, 0 skipped
- Mutation check: dropping the held-wallpaper exclusion and recording a pick before it was applied each failed the integration test written for it; both were reverted
- Every scripts/tests/test_*.py module run directly — all passed (the WebUI key check includes the two new keys in ja, zh-Hans and zh-Hant)
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_rust.py` and `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: how the menu item draws and reads, a real shortcut key press, Siri or Shortcuts listing the action and its Choose from option, and how a random pick looks on real displays; see manual-smoke "The menu bar with two displays"

## 2026-10-13 — Menu bar: control each display

The menu bar menu gets a submenu per display when two or more displays can show their own wallpaper (StatusMenuModel), with Remove from Display, Start Again and Open in Control Panel; one display keeps the flat menu. Lane worktree, targeted run only, not the full gate.

- `python3 scripts/test.py --only StatusMenuModelTests --only AutomationCommandTests --only WallpaperDisplayTransferIntegrationTests --only AppAutomationTests --only UserCommandQueueTests --only WallpaperActivationRecoveryTests --only WallpaperDisplayTransferTests --only HotKeyPreferencesTests --only GlobalHotKeysTests --only DisplayTitleResolverTests` — exit 0; 107 passed, 0 failed, 0 skipped
- `python3 -m unittest discover -s scripts/tests -p test_panel_localization.py` — OK (6 tests); the three new native strings are in all four languages
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: how the NSMenu draws, orders and reads (VoiceOver) with two or more real displays, and Remove then Start Again on real displays; see manual-smoke "The menu bar with two displays"

## 2026-10-13 — Apply a wallpaper to every display

A new transfer request, WallpaperDisplayTransfer.Request.everywhere, expands over the eligible displays when it is planned (main display first), so it keeps copy and swap's preflight, re-plan after preparing and verified rollback. Entry points: the inspector's Apply to all displays, apply?id=…&display=all and Apply Wallpaper's On all displays. Commit 6 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only WallpaperDisplayTransferTests --only WallpaperDisplayTransferIntegrationTests --only AutomationCommandTests --only ControlPanelDisplayLayoutTests --only WallpaperReapplyPanelTests --only AppAutomationTests --only ControlPanelLibraryTests --only WebPanelGeneralSettingsTests --only ControlPanelAutomationTests --only WallpaperActivationRecoveryTests --only ActivationLogTests --only WorkshopApplyOnArrivalTests --only ControlPanelShellTests --only WallpaperBackupTests` — 191 passed, 0 failed, 0 skipped
- Every module under `scripts/tests/` passes, including the new WebUI catalog key in zh-Hans, zh-Hant and ja.
- Mutation checks: with the main display no longer planned first, or the choice counted for no display when asked for, the matching transfer and integration tests fail and the rest pass. The first inspector test run failed because putting the displays back selects the wallpaper they showed, so the failure notice sat on a wallpaper the panel no longer showed; the panel now returns to the wallpaper it applied.
- Not run: the full gate, a Release build, any desktop run. Unverified: a real two-monitor apply and rollback, the button in the narrow inspector, and Shortcuts showing the On all displays switch; the display set is a two-display test bridge. See the new row in manual-smoke.md.

## 2026-10-13 — Rotate on unlock

A third How often choice for rotating playlists, Each time the Mac is unlocked (DisplayPlaylist.trigger). The presentation policy reports the locked-to-unlocked edge of its corrected lock state; PlaylistScheduler answers it for every display that waits for it, once, within a 30 second window. Commit 5 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only WallpaperPresentationPolicyTests --only PlaylistSchedulerTests --only PlaylistStoreTests --only PlaylistPlannerTests --only WebPanelPlaylistTests --only ControlPanelPlaybackToolsTests --only WallpaperBackupTests --only WallpaperAutomationSchedulerTests --only PlaybackPolicyCompositionTests --only ControlPanelAutomationTests --only ControlPanelHeldWallpaperTests` — 200 passed, 0 failed, 0 skipped
- Every module under `scripts/tests/` passes, including the new WebUI catalog keys in zh-Hans, zh-Hant and ja.
- Mutation checks: with Change now no longer answering a waiting unlock, or with the 30 second window never expiring, the matching scheduler test fails and the rest pass.
- Not run: the full gate, a Release build, any desktop run. Unverified: the order of the operating system's unlock events against a display waking, an unlock with a second display re-enumerating, and the visible change after unlock; the scheduler logic runs under fakes. See the new row in manual-smoke.md.

## 2026-10-13 — Switch to stop writing the macOS desktop picture

Settings › General › Use the wallpaper as the macOS desktop picture, on by default. Off, poster writes stop, the user's own picture is put back with the quit's verified restore, and a poster left behind is repaired at launch. Commit 1 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only PlaybackPreferencesTests --only DesktopWallpaperTests --only WebPanelGeneralSettingsTests --only LockScreenWallpaperServiceTests` — 133 passed, 0 failed, 0 skipped
- All Desktop, LockScreen, Panel and Lifecycle test classes — 839 passed, 0 failed, 0 skipped; `scripts/tests/test_panel_localization.py` passes with the new catalog keys
- Mutation check: with the settings.js row removed, the offscreen row test fails and the rest pass.
- Not run: the full gate, a Release build, any desktop run. Unverified: what Mission Control and the Spaces bar show after the switch goes off and on, the macOS 27 read-back during the 25-attempt restore, enabling Animate lock screen with the switch off, and the relaunch repair; `AppDelegate`'s decision of when to restore is wiring that no unit test reaches. See the new rows in manual-smoke.md.

## 2026-10-13 — Native video wake and resume repair

A stalled native video pipeline is now kicked, rebuilt once and then handed to Compatibility, after a resume, a wake or an unlock. Commit `fix(native-video): repair a stalled pipeline after a resume, wake or unlock`, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only NativeVideoHealthLadderTests --only NativeVideoHealthSupervisorTests --only NativeVideoWallpaperHostTests --only NativeVideoRecoveryBudgetTests --only NativeVideoLivenessTests` — 142 passed, 0 failed, 0 skipped
- `WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py --only NativeVideoPlayerMediaTests` — 37 passed, 0 skipped, twice (the hev1 clip is frame-less on this OS, so the kick, rebuild and give-up cases ran); all NativeVideo classes plus RuntimeCountersTests and WallpaperPresentationPolicyTests with media on: 256 passed, 0 failed, 0 skipped
- Mutation checks, each failing exactly the tests that defend it and then reverted: no absorb rule while repairing, no supersession of a wake settle, a rebuild that cancels its own check.
- The lock-screen extension target compiled the two new `RuntimeCounter` cases in the same builds.
- Not run: the full gate, a Release build, any desktop run. Unverified: that the system really reclaims a decoder across sleep, lock or a covered desktop, and that a kick or a rebuild brings one back; the `hev1` pipeline cannot be repaired, so only the failing ladder is shown. The 1 s wake settle and the cost of the check output on a 4K clip are untuned. See the sleep, lock and unlock rows in manual-smoke.md.

## 2026-10-13 — Native video liveness detection after a long pause

Observation only: the check logs and counts a stalled pipeline and acts on nothing. Commit `feat(native-video): detect a pipeline that stops delivering frames`, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only NativeVideoLivenessTests --only NativeVideoHealthSupervisorTests --only NativeVideoWallpaperHostTests` — 100 passed, 0 failed, 0 skipped
- `WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py --only NativeVideoPlayerMediaTests` — 31 passed, 0 skipped (the hev1 clip is frame-less on this OS, so its two cases ran); the other NativeVideo classes with media on: 182 passed, 0 failed, 0 skipped
- The lock-screen extension target compiled the new `RuntimeCounter` case in the same builds.
- Not run: the full gate, a Release build, any desktop run. Unverified: whether a real long suspension (covered desktop for hours, display sleep, Low Power Mode) ever costs a clip its decoder; no test reclaims one, so only the `nativeVideoPlaybackStalled` counter on a real Mac answers it. Cost of the check's video output on a 4K clip not measured.

## 2026-10-13 — Play only on the display in use

Commit `feat(playback): optionally play only on the display you are using`: opt-in Playback toggle `Only play on the display I’m using`. ActiveDisplayTracker follows the pointer through event monitors that exist only while the option is on and two displays are connected; WallpaperPresentationPolicy treats every other display as hidden after a 3 s dwell and resumes at once, never darkening every display. No bridge or Rust change. Taken in a worktree; the full gate was not run here.

- `python3 scripts/test.py --only ActiveDisplayTrackerTests --only WallpaperPresentationPolicyTests --only PlaybackPolicyCompositionTests --only PlaybackPreferencesTests --only WebPanelPerformanceSettingsTests --only PowerSourceResamplerTests --only WallpaperBackupTests` plus SystemConditionMonitorTests, LowBatteryTests, WebPanelGeneralSettingsTests, ControlPanelPlaybackToolsTests, ControlPanelSnapshotDeliveryTests, WebPanelAssetsTests, AppRuleMonitorTests, OtherAudioMonitorTests — 152 passed of 152 (19 new).
- Deliberate breaks (a wait that ignores cancellation, a pointer entry that leaves the old wait running, no never-darken-every-display guard) each failed the new tests; all were reverted.
- `python3 -m unittest scripts.tests.test_panel_localization` — 5 passed (three new WebUI strings in ja, zh-Hans, zh-Hant).
- Not run: the full gate; real global and local pointer events across two physical displays, whether the global monitor sees the pointer while this app is in front, the display-ID mapping with mixed scaling, how the 3 s dwell feels, and the live row layout. All need an authorized two-display desktop run.

## 2026-10-13 — Low-battery playback rule

New Playback rule `When the battery is low` (Keep running, Pause or Stop at 10, 20 or 30 percent; internal battery only). It joins SystemConditionMonitor's actions, reads IOKit's power-source notification only while an action is chosen, and is hidden on Macs without a battery. No bridge or Rust change.

- `python3 scripts/test.py --only LowBatteryTests --only SystemConditionMonitorTests --only PlaybackPreferencesTests --only WebPanelPerformanceSettingsTests --only WallpaperBackupTests` plus WebPanelGeneralSettingsTests, ControlPanelSnapshotDeliveryTests, WebPanelAssetsTests, WebPanelCompatibilityTests, ControlPanelPlaybackToolsTests, WallpaperPresentationPolicyTests, PlaybackPolicyCompositionTests — 122 passed of 122 (18 new).
- Seven deliberate breaks (no release margin, parse accepting a UPS, observing while Keep running, a wake refresh that reads nothing, unchecked level in preferences, panel action and backup restore) each failed at least one new test; all were reverted.
- `python3 -m unittest scripts.tests.test_panel_localization` — 5 passed (four new WebUI strings in ja, zh-Hans, zh-Hant).
- Not run: the full gate, a real discharge crossing the level, IOKit's notification cadence on this Mac, the live panel row layout. The live battery read is never asserted.

## 2026-10-13 — Mission Control poster kept while fresh

Commit `perf(desktop): stop retaking the Mission Control picture while the current one is fresh`: DesktopWallpaperSync retakes a surface's poster on a Space change, wake or resume only when it is older than 120 s or was taken before the wallpaper settled. Taken in a worktree; the full gate was not run here.

- `python3 scripts/test.py --only DesktopWallpaperTests` — 62 passed of 62 (8 new tests for the freshness floor, one existing test now builds the sync with a zero floor). Three mutations each fail the expected tests: a poster never kept (4 failures), the settle rule ignored (1), Space scope ignored plus a failed encode left counting as fresh (2).
- The same class plus WallpaperPresentationPolicyTests, PlaybackPolicyCompositionTests, WallpaperSpaceMonitorTests and WallpaperActivationRecoveryTests — 121 passed of 121.
- Gap: what Mission Control shows after rapid Space swipes with an animated wallpaper, and whether WallpaperAgent's container stops growing, were not observed; headless tests use synthetic pixels, an in-memory workspace and an injected clock.

## 2026-10-13 — Power source read again on wake (resample)

Commit `fix(power): read the power source again when the Mac wakes`: WallpaperBridge.resample_power_source() and PowerSourceResampler (wake plus a follow-up two seconds later). Taken in a worktree on top of the power watcher change (`perf(bridge): let the power watcher sleep until something happens`); the full gate was not run here.

- `cargo test -p wallpaper-bridge --lib power` — exit 0; 32 passed (7 new resample tests). Two mutations (resample never processed; unreadable source delivered) each fail the expected tests.
- `python3 scripts/build.py --renderer-only` — exit 0; App/Bridge/Generated diff limited to resamplePowerSource and its checksum.
- `python3 scripts/test.py --only PowerSourceResamplerTests` plus SystemConditionMonitorTests, PlaybackPolicyCompositionTests, WallpaperSpaceMonitorTests, WallpaperActivationRecoveryTests, WebPanelPerformanceSettingsTests — 56 passed of 56 (7 new). Removing the cancellation guard and stop()'s cancel together fails 2 tests; removing the start() guard fails 1.
- `python3 scripts/check_rust.py` — exit 0; bridge 401 passed, core 224 passed; local-corpus shader cases skipped.
- `python3 scripts/check_renderer.py` — exit 0; skipped: 4 asset-dependent cases (text_object_runtime_test x2, playback_gpu_test, metal_scene_draw_smoke).
- Gap: a real plug or unplug during sleep, and whether IOKit answers correctly at the instant of wake, were not exercised; headless tests prove the repair logic and idempotence only.

## 2026-10-13 — Battery share of Energy use and the per-wallpaper rating

Energy use's battery line was missing on macOS 27 (capacity keys moved into BatteryData, no CellVoltage); the per-wallpaper rating now carries the same share. M5 Pro MacBook Pro, macOS 27.0.1, on battery.

- Coalition fields rechecked under a Metal load: field 41 summed over all coalitions 28.3 W against IOReport `GPU Energy` 29.5 W (4 %); field 11 tracks CPU energy
- `BatteryCapacity.fullChargeWattHours()` on the live registry: nil before the fix, 98.5 Wh after (FullChargeCapacity 8,530 mAh × 3 × 3.85 V; rated 99.6 Wh)
- `python3 scripts/test.py --only EnergyUsageMonitorTests` — failed on the new macOS 27 fixture before the fix, 13 passed after
- `python3 scripts/test.py --only WallpaperEnergyRatingsTests` — 11 passed
- Inspector sentence rendered with Node from `panel.js`'s `energyRating` and the real catalogs in en, zh-Hans, zh-Hant and ja, with and without a battery share
- `python3 scripts/test.py` — 1342 passed, 0 failed, 14 skipped
- Not checked: the rendered panel on screen (no desktop run requested); the rating line on a real rated wallpaper

## 2026-10-13 — Layers a wallpaper's properties hide leave the render graph

Settled-hidden layers (authored or property-bound visibility, no script) are left out of sceneToRenderGraph; a script showing one rebuilds the graph once. Run in a detached worktree at 24aa0834 plus this change.

- `layer_texture_reference_test` HiddenLayers, `rendergraph_smoke` aHiddenFirstWriter…, `metal_scene_draw_smoke` ALayerItsPropertiesHide… — new; the first and last fail without the change
- `python3 scripts/check_renderer.py` — exit 0; 4 asset-dependent tests skipped (no local corpus assets)
- `python3 scripts/test.py` — exit 0; 1341 passed, 0 failed, 14 skipped
- By hand: `script_runtime_compat_test` 98, `scene_schema_tests` 111, `mdl_schema_tests` 57 — all passed
- Workshop 2531810451 defaults: native Metal targets 11.42 → 0.39 GB, peak footprint 12.66 → 1.64 GB, 240 → 19 passes/frame; Vulkan VMA 8.26 → 0.54 GB; frames byte-identical on both
- 60 local scenes, both probes, base ×2 vs fix: 29 use less memory, none more; same backend choices; no difference beyond base-vs-base noise (one Vulkan video-decode timing case converges by frame 89)
- Not checked: desktop/app run, a real SceneScript revealing a property-hidden layer (covered by the runtime call it makes), scenes with clearenabled false (none local; guarded by rendergraph_smoke)

## 2026-10-13 — Web wallpaper pointer and frame cadence (#45)

Issue #45 reported the Colorful Fluid Animation web wallpaper (1748506393) sampling the cursor at 10–20 Hz on a 120 Hz screen. Measured on a 120 Hz MacBook Pro, macOS 27.0.1. Web wallpapers now draw at a display's full refresh when its effective frame rate reaches a refresh above 60 Hz.

- Authorized live run, real hand movement over the bare desktop, temporary in-page probe (removed): cursor ~120/s → global monitor ~118/s (every move carried the window under the pointer) → page `mousemove` 60/s → the page's own loop 50/s. 10–20 Hz not reproduced.
- Scratch WKWebView harness hosted like `WebWallpaperWindow`: WebKit coalesces hover to one move per rendering update (60/s on 120 Hz). With `PreferPageRenderingUpdatesNear60FPSEnabled` off at creation: 120 moves/s and 120 rAF/s. Flipping it on a live page (re-attach, hide/show, reload) had no effect.
- Harness: a GPU-bound page drops pointer, rAF and its own loop together (13/s); a starved JS loop does not slow WebKit's pointer delivery; emulated audio splats had no effect.
- `python3 scripts/test.py --only` WebWallpaper host/page/routing/recovery/suspension classes — 39 passed; mutation without the new reuse check fails `testFrameRateCrossingTheDisplayRefreshRebuildsThePage` as expected.
- `python3 scripts/test.py` (isolated worktree) — Python script tests OK; 1355 native: 1341 passed, 14 skipped.
- Not measured: the rebuilt page's 120 Hz cadence inside the real app (needs a 120 fps setting and a live run); the reporter's own machine.

## 2026-10-12 — Control panel stays closed at login (issue #41)

- Change: ControlPanelLaunch reads the open-application Apple event's keyAELaunchedAsLogInItem; a login launch skips the startup panel unless the welcome guide is unfinished or BridgeStore failed to start.
- python3 scripts/test.py --only ControlPanelLaunchTests: 3 passed.
- python3 scripts/test.py on origin/main 1607a15 + this change: 1339 passed, 0 failed, 14 skipped of 1353.
- Gap: not verified with a real logout/login; whether SMAppService.mainApp launches still carry keyAELaunchedAsLogInItem on macOS 27 is unconfirmed. Look for 'startup: launched at login; control panel stays closed' in the app log after the next login.

## 2026-10-11 — macOS 27 per-Space poster writes: absolute paths and late acknowledgement

- Diagnosis (read-only, M5 Pro, macOS 27.0.1): DesktopPictureSetDisplayForSpace forwards to WallpaperServices, whose result HIServices discards; every poster write logged 'Failed to set legacy configuration: … no such file' because the sandboxed WallpaperAgent resolves the root-relative path inside its container.
- Live, with the user's permission, on one inactive Space: an absolute home-path poster was accepted with no WallpaperServices error, changed only that Space's two store nodes, and read back after ~0.3 s (not immediately); the original was restored and the probe image deleted.
- The WallpaperServices BOOL is returned before the agent applies the write (failures are logged later off-thread), so it is not used as acknowledgement.
- Store evidence: writes to a display's visible Space are copied into SystemDefault and Displays/<uuid>; the on-disk Index.plist can lag the agent's memory until a scheduled store write.
- Unit: python3 scripts/test.py --only DesktopWallpaperTests (51 passed), including late-acknowledgement, never-acknowledged pause, absolute-path configuration and the poster-pruning race the new test exposed.
- Gate: python3 scripts/test.py — 1339 passed, 0 failed, 14 skipped.
- Not checked: a full app session on macOS 27 with the rebuilt app, Mission Control thumbnails, or macOS 15/26 (root-relative path path unchanged there).

## 2026-10-11 — Aligned layers turn about their anchor

SceneRuntimeContext rotated a non-centre layer about its centre and slid its anchor offset along the scene's axes. Every gate below ran in a detached worktree at HEAD plus this change only, because another session's uncommitted audio edits in the shared tree stop audio_tests from compiling (SmoothAudioResponseBinsForTesting undeclared).

- `script_runtime_compat_test`: 97 passed; the new `RotatedAnchoredLayerTurnsAboutItsAnchor` and `ScriptedRingBarsHangOutwardFromTheirCircle` fail on HEAD's runtime (rotation assertions only). `scene_schema_tests` 110, `scenescript_media_event_smoke` 20, `text_object_runtime_test` 64 passed, 2 skipped (local assets).
- `metal_scene_draw_smoke` LocalProjects, 2850003448 at 2560x1440, 60 Hz noise (amplitude 0.5 for legible bars): before, the ring slid down over the planet; after, bars hang outward from a dark ring, as in the Workshop preview.
- Local corpus A/B, 57 scenes, `offscreen_scene_probe` `nodes.txt`, both arms built from HEAD: placement moves only on rotated non-centre layers in 6 scenes. 3276911872's audio strip now rests on the date line, flush with its left edge; 3665954520's hidden visualizer bar now spans its sibling bars' 150 units from their shared corner; three text layers tilted 0.6-2.2 degrees move up to 4.4 units. 3589454154's node diffs, and every pixel/state diff, also appear between two baseline runs.
- `python3 scripts/check_renderer.py`: exit 0; 12/12 generated scenes pixel-equal pooled vs isolated; reload cycles 0. Skipped: 2 local-asset text tests, local video import, local-project Metal (run by hand above).
- `python3 scripts/test.py`: Python suites OK; native 1334 passed, 0 failed, 14 skipped of 1348.
- Gap: Wallpaper Engine's offset for a script-set alignment (full size*scale vs this renderer's scale delta) is unconfirmed; 8-unit bars differ by 4 units, too little for a preview. Not rebuilt as a Release app.

## 2026-10-11 — Custom playlist interval: review fixes and first native gate

- Review follow-up for the custom rotation interval: abandoned or refused minutes keep or drop drafts correctly; draft keys come from one helper; the hint follows the native range; the minutes field reuses the display number helper; docs note older builds' fallback and backup refusal.
- First full gate on macOS: python3 scripts/test.py, first run failed 2 stale tests (PlaylistPlannerTests and WallpaperBackupTests still expected a 7-minute interval to be refused); both now use 0. Rerun: 1,321 passed, 0 failed, 14 skipped of 1,335.
- Run in a detached worktree of the PR branch, linked against main's libwallpaper_bridge.a (no App/Bridge differences between the trees).
- Headless Chromium harness over renderSettings with a stub snapshot: Custom sends nothing and starts from the saved interval; leaving after an invalid 0 restores the saved preset; switching apps keeps a typed value; a valid value committed on leave is saved; a refused send keeps the field and value next to the error; a typed preset snaps the menu back.
- Not checked: real WKWebView panel appearance and focus events (focusout was dispatched by hand in a hidden tab); no Release build, the branch is behind main.

## 2026-10-10 — Custom playlist rotation interval

Playlists accept any whole number of minutes from 1 to 10,080 next to the preset menu. Verified from a Linux cloud container without Xcode.

- `python3 -m unittest discover -s scripts/tests` — 271 tests OK, 17 skipped (includes panel localization key parity)
- `node --check` on settings.js, plans.js and the three locale catalogs — OK
- Headless Chromium harness over `renderSettings`: choosing Custom sends nothing and focuses the minutes field; 45 sends `interval: 45`; 0 is refused locally; 60 snaps the menu back to Every hour
- Native gate (`python3 scripts/test.py`, incl. new WebPanelPlaylistTests/PlaylistStoreTests cases) — not run: needs macOS/Xcode
- WKWebView appearance in the real panel — unchecked; no Release build

## 2026-10-10 — Lock state and scene-assets folder no longer probed per update

Cached the session lock state in WallpaperPresentationPolicy (asked at start, lock/unlock, display wake, user switch and while locked) and resolved the scene-assets folder with its readiness in WorkshopStore instead of in every page snapshot.

- `python3 scripts/test.py --only WallpaperPresentationPolicyTests --only WorkshopDownloadIntentTests --only ControlPanelSnapshotDeliveryTests --only ControlPanelShellTests` — 71 passed, including 6 new tests
- `python3 scripts/test.py` on the shared tree with the lock-screen re-sync change (artifacts/tests/Tests-20261010-134554-494250) — 1334 passed, 0 failed, 14 skipped
- `python3 scripts/build.py --swift-only --configuration Release` at 51e1d39 — OK; relaunched by the user
- Standalone loop: `CGSessionCopyCurrentDictionary` 52 µs median (84 µs p95), `ClientPaths.assetsURL` 124 µs, cached URL 0.3 µs
- Live, 30 vs 18 user-approved Bar Count drags in 40 s windows: page-snapshot samples in `assetsURL` 50 of 141 → 0 of 71; policy lock read 1 → 0; coalition energy within noise
- Driving the drags in the background activated the app per drag, so the on-key assets refresh took 15 samples; not representative of drags in the focused panel
- Not exercised live: a real screen lock, display wake with a lock, or fast user switching (unit tests only)
- `scripts/check_renderer.py` — not run: no renderer or bridge change

## 2026-10-10 — Lock-screen check skips unchanged store re-syncs

Release 1.3.2 (31) at HEAD bd55717, M5 Pro, macOS 27.0.1, AC power; animated lock screen and screen saver on one display with 45 Spaces (93 journal entries). Every two-second check and every snapshot apply re-synced the native selection.

- Before, live: `stat` of `native-selection.plist` 2 s apart showed a new inode each check; per-second coalition sampler (`ri_energy_nj`) idle ticks 12–16 ms app CPU and 4–6 mJ every 2 s; `sample <pid> 2` ×3: 8–12 of 10–14 on-CPU main-thread samples in `LockScreenWallpaperSelection.synchronize`, 2–3 in `persistEntries`
- Cause: re-encoding journaled baselines (global override, inherited and linked originals) reorders dictionary keys, so equal entries compared unequal and the journal was rewritten; the store was reread and every entry decoded each time
- `Index.plist` unchanged for over 15 min while idle (`stat` every 5 s), so an unchanged check now costs one `stat`
- Scratch `swiftc -O` benchmark, HEAD vs change, on copies of the real store and journal, 200 syncs ×2: unchanged store 2.9–3.6 ms → 1.6–2.6 µs per sync, journal writes 139–200 → 0; store rewritten with only an unrelated key 2.6–3.1 ms → 2.3–2.5 ms, writes 101–200 → 0
- New journal test's fixture replayed in scratch: HEAD rewrote the journal in 30/30 runs, change in 0/30
- `python3 scripts/test.py --only LockScreenWallpaperTests --only LockScreenWallpaperServiceTests` — 91 passed
- `python3 scripts/test.py` — 1334 passed, 0 failed, 14 skipped (shared tree with the concurrent session-lock and asset-path change)
- Not run: live after-measurement, which needs the rebuilt app relaunched; no desktop, wallpaper or lock-screen change was made

## 2026-10-10 — Screen changes that move nothing no longer refresh displays

Cause of the ~12 J bursts: on the built-in XDR display (M5 Pro, macOS 27.0.1) every EDR headroom ramp (1.0↔1.2 over 2 s, raised by a menu-bar banner or HDR content) posts 241 didChangeScreenParameters notifications with only maximumExtendedDynamicRangeColorComponentValue changed. A passive watcher saw 5,995 such notifications in 30 min and no frame, visibleFrame, scale or Space-driven change. Fix b3d3921 compares DisplayConfiguration (AppKit's copy of what DisplayDesc::all() reads, 11 µs per read) before refreshing; the Space monitor and presentation policy filter the same notification.

- `python3 scripts/test.py` — exit 0; 1340 tests: 1326 passed, 14 skipped (targeted: DisplayRefreshCoalescerTests, WallpaperSpaceMonitorTests, WallpaperPresentationPolicyTests, ControlPanelSpaceWallpaperTests — 38 passed)
- `python3 scripts/build.py --swift-only --configuration Release` — built; relaunched with the user's permission
- Before, per-second coalition energy (ri_energy_nj): one ramp with Settings open 0.6 + 6.5 + 5.2 J (app 3.3 W, WebContent 3.2 W); ten ramps with the panel closed 0.2–2.6 W and 300–650 ms CPU/s for 2–4 s
- Before, `sample` during a ramp: main thread 580 on-CPU samples (lock-screen re-sync 379, page snapshot 90, refresh 33) plus 233 blocked in CGSessionCopyCurrentDictionary; WebKit logged 252 snapshot pushes per ramp
- After, three ramps with the panel open: app 56–74 ms CPU/s against a 71 ms/s quiet median, panel WebContent no rise; one display refresh, the first after launch
- Not measured: WindowServer energy (proc_pid_rusage is denied without root); no external display, display wake or resolution change exercised live (covered by unit tests only)

## 2026-10-10 — Metal shader compile across launches (investigation, docs only)

Why MTLCompilerService recompiled Lucy (3521337568) after a launch despite warm shader and Vulkan pipeline caches. No app, renderer or upstream change; app not rebuilt; no desktop control or wallpaper change.

- Built `offscreen_scene_probe` and `metal_scene_draw_smoke` with `scripts/build.py`'s environment; per-process CPU energy from `proc_pid_rusage` (`ri_energy_nj`) of the probe and each `MTLCompilerService` it started.
- Same location, separate processes: first load 35.4–41.5 J, every later process 2.0–2.2 J with no compiler activity. New `LC_UUID`, new `CFBundleVersion`, bundle replaced in place: 2.0–2.1 J.
- Same bundle id at another path: 21.7 J (19.5 J compiler). Cold compiled source only: 21.8–22.1 J; cold pipelines only: 4.1 J. Two rounds each.
- No eviction or loss: 16 other wallpapers, a concurrent holder, a SIGKILLed holder, 3,400 entries (~45 MB) in one process.
- App logs: every warm-cache compile gap (Winter 10:57, Lucy 11:17, Lofi Girl 12:14) was the Release build's first load of a wallpaper last loaded by `/Applications/WallpaperMachine.app`; same-copy repeats hit.
- Native Metal admits Lucy and Lofi Girl, not Yae Miko (lighting) or Winter Nothingness (translation failure); MoltenVK 1.4.2 has no binary-archive option. Findings in features/performance.md, renderer.md and power-benchmark.md; links checked.

## 2026-10-10 — Energy readout: static loading notice replaces switch detection

- Change: the loading flag (switch detection, hidden grade and comparison) is removed; the Energy use row now always notes that right after a wallpaper is applied the figures include loading it. Per-wallpaper ratings still start no interval within 8 s of a presentation change.
- Why: the user saw the flag miss a second apply. The readout samples only while Settings is open, so a switch made from another page, or a re-apply of the same wallpaper, was never seen.
- Tests: targeted EnergyUsageMonitorTests, WallpaperEnergyRatingsTests, WebPanelEnergyUsageTests (24 passed); test_panel_localization OK; node --check WebUI/settings.js.
- Full gate: python3 scripts/test.py — 1320 passed, 0 failed, 14 skipped (opt-in media and network layers).
- Not verified: the note in the running panel (no screenshot taken).

## 2026-10-10 — Energy readout: wallpaper loading flagged, measured switch cost

- Change: readings whose window holds a sample within 8 s of a display's wallpaper changing (or of a rendering setting change) carry loading: shown with a note, no grade, battery share or comparison; a switch drops a comparison in progress. The rating recorder starts no interval within 8 s of a presentation change.
- Measured with the user's permission: 5 switches via wallpapermachine://apply on the covered primary display, per-second per-process coalition energy. First loads 10–22 J at 6–7 W for 2–4 s (app shader compile + MTLCompilerService); warm repeat 1.4 J; video 3 J; restore 5.8 J; WallpaperAgent ~0.5 J per desktop picture update. Wallpaper restored to 3796026374.
- Separate finding (flagged as a follow-up task): display-refresh bursts cost the app + panel WebContent ~12 J over 3 s each; MTLCompilerService recompiles despite a warm Vulkan pipeline cache (follow-up task).
- Tests: python3 scripts/test.py --only EnergyUsageMonitorTests --only WallpaperEnergyRatingsTests --only WebPanelEnergyUsageTests (26 passed); python3 -m unittest scripts.tests.test_panel_localization (OK); node --check and a Node render of loading, loading+contended, native+loading and normal readings.
- Full gate: python3 scripts/test.py — 1322 passed, 0 failed, 14 skipped (opt-in media and network layers).
- Not verified: the new note in the running panel (no screenshot taken).

## 2026-10-10 — Energy readout: native video left out, macOS 27 ABI rechecked

- Change: readings while a video is on the native player carry nativeVideo (no grade, battery share or comparison); the per-wallpaper recorder skips intervals with a presenting native-video display; ratings carry version 2 and a video's unversioned rating is hidden and replaced, not averaged.
- Evidence for the fix: a stored rating of 0.18 mW over 4.4 h for a video wallpaper; GPU billed_to_me fields are 0 in all 818 coalitions; decoding 720p H.264 at ~1,700 fps charged ~2 W CPU and 0 GPU.
- ABI on M5 Pro, macOS 27.0.1: struct coalition_resource_usage is 50 fields (5 appended); indices 8/11/41 unchanged. Saturating Metal load: coalition 16.85 W, all coalitions 17.56 W, IOReport GPU Energy 17.94 W.
- Unchanged: the 0.25 contention threshold. A 60 fps probe read 91 mW alone and 162 mW at 21 % other GPU time (below the flag); documented, not retuned.
- Tests: python3 scripts/test.py --only EnergyUsageMonitorTests --only WallpaperEnergyRatingsTests --only WebPanelEnergyUsageTests (23 passed); new GPU-counter guard failed once on a cold test host (0 mW after 0.8 s) and now waits up to 5 s for a post, then passed 4 runs.
- Full gate: python3 scripts/test.py — 1319 passed, 0 failed, 14 skipped (opt-in media and network layers).
- Page: node --check WebUI/settings.js; energyControl rendered in Node for native, native+contended, contended and normal readings. The panel itself was not opened (no desktop authorization).
- Not verified: a native-video wallpaper end to end in the running app, and the hardware decoder's own energy (needs powermetrics/root).

## 2026-10-09 — Keep web wallpapers animating through Show Desktop pointer moves

- Symptom: a web wallpaper (3747222633) froze briefly on every hot-corner Show Desktop; scene wallpapers did not. Unified logs showed no host suspension, WebKit activity-state change or poster capture at those moments.
- Before evidence (installed v1.3.2, three Show Desktops, 3 s sample of app/WebContent/GPU each): app main thread spent 122/234/210 ms in NSWindow.windowNumber(at:) via SLSCopyWindowRoutingRecordsForScreenLocation from WebWallpaperMouseForwarder, 0 ms in the idle baseline; WebContent updateRendering samples fell 20–45% in the same windows.
- Fix: routing reads the window the window server recorded in the event (kCGMouseEventWindowUnderMousePointer); only a press or scroll without it still queries, a move without it is dropped.
- Hand probe on real global-monitor events: field 91 matched windowNumber(at:) in 1536 of 1540 events (4 were transient screenshot-tool windows), never 0. Field 92 skipped the menu bar for moves, so it was not used. No scroll events were captured.
- python3 scripts/test.py --only WebWallpaperMouseRoutingTests: 6 passed (2 new); synthesized scroll events do not keep the field, so scrolls are covered by the fallback test.
- python3 scripts/test.py: 267 Python tests passed; native 1315 passed, 0 failed, 14 skipped of 1329. Full gate run once.
- Gap: smoothness after the fix on the real desktop is not yet measured; the same capture script must be re-run against a build that contains it.
- Separate, unfixed: a web page assigned while its display is suspended loads detached, so its first reveal is a cold start (327 ms hidden content plus shader compiles on 2026-10-09 18:03:57).

## 2026-10-09 — v1.3.2 published release and import-helper recovery

- Published [v1.3.2](https://github.com/WallpaperMachine/WallpaperMachine/releases/tag/v1.3.2), build 31, from `e278ae8f205e324835facd6f84c70e27f3d31cc7`; [Version run 37825423704](https://github.com/WallpaperMachine/WallpaperMachine/actions/runs/37825423704) passed every required job. Failed, unpublished v1.3.0/v1.3.1 tags were preserved; notes cover v1.2.6 through v1.3.2.
- Import-helper repair `8fb411a`: six targeted child-process tests passed normally and with `TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. Local `python3 scripts/test.py` passed 268 Python and 1,313 native tests, with 14 skips; no desktop picker was opened.
- CI `python3 scripts/test.py --serial` passed 268 Python and 1,312 native tests, with 15 skips and no failures. Rust core, bridge, core-integration and shader checks passed; six explicit desktop/corpus exclusions and three missing-asset shader skips remain unverified.
- CI renderer checks passed 12 generated pixel comparisons and eight projects through two reloads. Seven asset-dependent cases were skipped. The compiled timer probe exited 77 (35.20 ms median for a 10 ms wait), so ten named wall-clock cadence cases were skipped under `--allow-imprecise-timers`; these skips are not passing runtime coverage.
- CI verified the Release bundle and mounted disk image. Independently downloaded the public DMG: 36,496,549 bytes, SHA-256 `abaa683f21d1c24e97f8eb6f8c08839e9ba1bc0a4b573b893ea1d4258af47e32`; it matches the CI artifact, public sidecar, release asset metadata and public latest update manifest.
- Release body matches the tagged English notes and `Built from` commit; bundled changelog contains English and Simplified Chinese. Latest resolves to v1.3.2 and equals the highest public stable version. Public DMG and manifest requests succeeded.
- `gh attestation verify` passed for the public DMG, restricted to this repository and `.github/workflows/build.yml`, rejecting self-hosted runners and enforcing source digest `8fb411a34d05dc1a3f4218afaa1d647bc9d94089`. As documented, this event digest precedes the version-bump commit; `Built from` records the built revision.
- No install, launch/restart, desktop/Spaces/Mission Control/VoiceOver, real Siri/Focus, or manual disk-image smoke was performed. CI packaging and headless checks do not verify those surfaces. The release remains self-signed, not Developer ID signed or notarized.

## 2026-10-09 — Release recovery after hosted test timing failures

- v1.3.0 was tagged but not published: attempt 1 failed an onboarding test that counted incoming snapshots as requests; attempt 2 failed ThreadTimerTest.RequestsAfterALongWaitStillRespectTheCeiling on a host whose timer probe returned 77.
- Test-only welcome replay fix `5ff25f1` now checks outgoing actions and injects an unrelated snapshot. Application code remains unchanged.
- Added the omitted 50 ms cadence test to the existing exact-name CI fallback, only after the compiled timer probe reports imprecise timers. Default local runs still execute it; other failures remain failures.
- Version workflow accepts optional notes_from, passed as release_notes.py --previous, so a new patch after an unpublished failed tag can include all changes since the last public release. Tags and live releases are not rewritten.
- Python renderer/version/release-notes suites: 106 passed. Workflow shell arguments verified for default and explicit previous tag; developer preview includes the unpublished feature commits from v1.2.6.
- Full local gate: 268 Python and 1,312 native passed, 0 failed, 14 skipped; artifacts/tests/Tests-20261009-012014-576231.xcresult (disposable).
- First local renderer pass hit the time-sensitive UnchangedPresent frame-order assertion. Separate rerun python3 scripts/check_renderer.py --skip-build passed, with realtime_checks_executed=true, 12 equal pixel comparisons and 8 x 2 reloads; four asset checks skipped. Evidence artifacts/renderer/adaptive-20261009-012147 (disposable).
- No runtime implementation, desktop interaction, installation, first-launch or manual-smoke changes. Recovery publication is tracked separately and must still pass the CI gate.

## 2026-10-09 — Integrate Mission Control refreshes with Space-scoped posters

- Integrated upstream `dc6b764` (Mission Control refresh/settling, injected-clock downloader tests and Supporter list) with feature commit `81eb112`; preserved both histories without rebase or force.
- Kept JPEG encoding, changed-frame deduplication, immediate/3 s/15 s/optional 5-minute captures and lock-screen settling while retaining per-Space request contexts and scoped poster ownership.
- Added regressions proving settling/periodic requests use the current Space context and respect hold, and identical pixels are reused on another Space only after a fresh context is confirmed.
- Targeted desktop/native-video/Space/scheduler/lock-screen-authority/downloader tests — 129 passed, 0 failed, 0 skipped.
- `python3 scripts/test.py` — exit 0; 268 Python tests passed; native 1,312 passed, 0 failed, 14 skipped of 1,326. Full gate ran once for this integration.
- Native evidence: `artifacts/tests/Tests-20261009-001715-304824.xcresult` and same-name `.log` (disposable local evidence).
- Renderer/bridge source is unchanged from the feature commit; the prior renderer-only build and 12 pixel comparisons plus 8 x 2 reloads remain applicable. Four asset checks were skipped, not passing asset coverage.
- All 64 pre-existing verification entries from both merge parents were retained using the verification-log script; the active log remains bounded to ten entries. Diff and agent-path checks passed.
- No real desktop/Mission Control/Space transitions, visible UI, VoiceOver, Release app rebuild or install/restart was performed. User authorized commit and push; remote delivery is checked separately after this commit.

## 2026-10-08 — Lock-screen desktop settles before holding a frame

- Report: AbyssGaming【琉璃】 left Mission Control Space thumbnails black with Animate lock screen on; DesktopPosters was empty (poster sync suspended, extension owns Desktop).
- Root cause: offscreen_scene_probe, 21 frames at 1 s steps: frame 0 mean brightness 0.0, 67.8 at 1 s, ~122-135 from 2 s on. The extension held its readiness frame.
- Fix: WallpaperPresentationAuthority.desktopSettleBudget (15 s) keeps an unlocked lock-screen surface animating after its first frame; on pausing it reads the held frame back for snapshots/backing.
- python3 scripts/test.py --only WallpaperPresentationAuthorityTests: 16 passed. python3 scripts/test.py: 1215 passed, 0 failed, 14 skipped.
- Not checked: real Mission Control thumbnails with the extension; whether WallpaperAgent re-reads the extension snapshot after it pauses.

## 2026-10-08 — Mission Control poster refresh

- Change: desktop poster retaken 3 s and 15 s after a new/changed/resumed wallpaper, fresh capture on Space change and wake, unchanged frames skipped by pixel digest, JPEG (q0.9) instead of PNG, optional 5-minute refresh in Settings › General.
- Encode cost measured on M5 Pro at 3456x2234: PNG ~215 ms / 8.9 MB, JPEG ~32 ms / 2.8 MB, HEIC ~40 ms / 2.3 MB (synthetic graded frame).
- python3 scripts/test.py --only DesktopWallpaperTests --only PlaybackPreferencesTests: 49 passed.
- python3 scripts/test.py: 1214 passed, 0 failed, 14 skipped (opt-in layers).
- Not checked: real Mission Control thumbnails, WallpaperAgent caching of replaced pictures, the lock-screen-provider mode (unchanged; still a frozen frame). Needs the manual-smoke Mission Control steps.

## 2026-10-08 — Desktop Space choices and scoped poster ownership

- Added experimental Follow desktop Space automation: per-display UUID choices for wallpapers/playlists, persistent visit identities, manual overrides until the next regular desktop visit, fullscreen exclusion, Focus priority and animated-lock-screen conflict checks.
- `python3 scripts/build.py --renderer-only` — exit 0; rebuilt the renderer static library and regenerated bindings for the Objective-C++ poster context change. No Release app bundle was rebuilt or delivered.
- `python3 scripts/test.py` — exit 0; 268 Python passed; native 1,305 passed, 0 failed, 14 skipped of 1,319. Full gate ran once in this batch. Native evidence: `artifacts/tests/Tests-20261008-235505-811159.xcresult` and same-name `.log` (disposable).
- Targeted monitor/scheduler/store/poster/native-video/panel/backup run — 129 passed; poster scheduling/integration follow-up — 51 passed; final orphan-focus panel run — 2 passed.
- `python3 scripts/check_renderer.py` — exit 0; 12 generated pooled/isolated pixel comparisons matched, diagnostics 0; 8 projects x 2 reloads passed. Four local-asset checks skipped. Evidence: `artifacts/renderer/adaptive-20261008-234144` (disposable).
- Regression coverage includes independent/shared display groups, malformed/ambiguous topology, desktop reorder, fullscreen entries without UUIDs, visit persistence, paused catch-up, rapid queued switches, Focus exit with unknown topology, old-schema migration and backup transient-state exclusion/rollback.
- Scoped poster tests cover current-Space-only writes, public-fallback exclusion, late request/encode rejection, mode changes, replacement gaps, current-only eject and all-Space restore. Native-video poster context is exercised through the real coordinator with a fake surface; Scene bindings carry context beside captured request generations.
- Offscreen WKWebView tests cover choice save, UUID-preserving reorder, current-desktop accessible name, unavailable mode/native validation, orphan removal and final-orphan focus. One Impeccable detector invocation returned `[]`; source-only reviewer disposition `ship` for its single corrected focus finding.
- Localization and JS syntax checks passed; 192 local documentation links resolved; diff check passed excluding generator-owned bindings. Upstream provenance updated, notices retained, CLAUDE.md remains a relative AGENTS.md symlink; no agent state staged.
- No desktop/window/screenshot, actual Mission Control/Space/Focus transitions, visible layout, VoiceOver, installed-app test, install/restart, commit or push. Inactive Spaces retain posters, not resident renderer instances; brief reload transitions and animated-lock-screen incompatibility are documented.

## 2026-10-08 — Multi-display wallpaper layouts, copy and swap

- Added saved per-display wallpaper arrangements, independent-display copy/swap, a searchable Shortcuts layout action, URL routing and backup merge support. Separate live per-Space assignments remain unimplemented.
- `python3 scripts/test.py` — exit 0; 268 Python tests passed; native 1,290 passed, 0 failed, 14 skipped of 1,304. Full gate ran once for this batch.
- Native evidence: `artifacts/tests/Tests-20261008-230934-164642.xcresult`, log `Tests-20261008-230934-164642.log` (disposable local evidence). Existing live Workshop/SteamCMD and native-media skips remain skipped.
- Targeted core/store/BridgeStore integration tests — 15 passed; panel/backup/integration/command/catalog run — 44 passed; final focus-boundary panel/store run — 7 passed. A test fixture return type was corrected before these successful runs.
- Checked complete preflight, copy/swap from original assignments, failure after mutation, restoring empty destinations, preserving unexpected external choices, cancellation cleanup, clean-editor admission, net history and newer queued user commands.
- Offscreen WKWebView tests cover save/rename/apply/delete, copy/swap and recovery errors, escaped names, missing-screen eligibility, Escape/focus return, English/Chinese/Japanese at 760 points and saving the 64th layout.
- Panel/native localization coverage and JavaScript syntax checks passed; 160 local documentation links resolved. Impeccable detector returned `[]` once on this batch's changed JS/CSS.
- Static review disposition `ship` for its single focus finding after correction and regression coverage. Rendered appearance and VoiceOver remain unverified; no additional visual inspection was authorized.
- `git diff --check -- . ':!App/Bridge/Generated'` passed; existing generator-owned output from the preview batch is excluded. CLAUDE.md remains a relative symlink to AGENTS.md; no agent state was staged.
- No renderer/bridge ABI changes in this batch, so prior renderer checks were not rerun. No desktop/windows/screenshots, real multi-monitor compositor/Spaces or Siri/Shortcuts run, Release rebuild, install, commit or push.

## 2026-10-08 — Advanced wallpaper automation and Focus restoration

- Added per-display weekday/time/sunrise/sunset and system-appearance choices, temporary Focus wallpaper/playlist overrides, and saved playlist/property preset Shortcuts and URLs.
- `python3 scripts/test.py` — exit 0; 268 Python tests passed; native 1,270 passed, 0 failed, 14 skipped of 1,284. Full gate ran once for this batch; no renderer code changed in this batch.
- Full native evidence: `artifacts/tests/Tests-20261008-194956-595159.xcresult`; log `Tests-20261008-194956-595159.log` (disposable local evidence).
- Targeted automation/planner/store/Focus/panel/command/catalog tests — 35 passed. Offscreen automation editor and backup tests — 33 passed after correcting a test-fixture initializer argument order.
- Covered DST and solar boundaries, persisted/manual precedence, Focus restoration and interrupted state, deleted saved plans, queued multi-field playlist edits, backup merge and rollback.
- Offscreen WKWebView flows cover save/edit/cancel/delete, hidden invalid timing fields, local weekday errors/focus, appearance clearing, solar location save/clear and compact overflow.
- Panel localization checks passed for English source plus Simplified Chinese, Traditional Chinese and Japanese; JavaScript syntax checks passed; 168 local documentation links resolved.
- Impeccable detector returned `[]` on the three changed automation/settings UI sources. Static reviewer disposition `ship` for the three listed fixes, all resolved; rendered appearance and VoiceOver remain unchecked.
- `git diff --check -- . ':!App/Bridge/Generated'` passed; generator-owned bindings from the preceding preview batch retain generator whitespace. `CLAUDE.md` remains a relative symlink to `AGENTS.md`.
- No live Focus/appearance transitions, Siri/Shortcuts, desktop interaction, screenshots, permission prompts, Release rebuild, installation, commit or push. Existing corpus/runtime skips remain skipped, not passing asset evidence.

## 2026-10-08 — Independent live wallpaper preview

- Added an explicit preview window for installed Scene, Video and Web wallpapers. Read-only draft export, independent playback, mute by default, reload, scoped pointer input and close/replacement cleanup leave desktop assignments and history unchanged.
- python3 scripts/build.py --renderer-only: exit 0; regenerated UniFFI bindings for wallpaper_preview. project.yml and XcodeGen include the existing renderer C header for the app and hosted tests; no vendored C++ behavior changed.
- python3 scripts/test.py: final exit 0; all 268 Python tests passed; native tests 1242 passed, 0 failed, 14 skipped of 1256. An earlier gate stopped at CodeSign because com.apple.FinderInfo returned on disposable Debug output; only that attribute was removed before rerunning.
- The 14 native skips remain opt-in real-media, live Steam installation and live Workshop network cases. Preview regressions use isolated fixtures/offscreen views and cover drafts, path bounds, storage isolation, mute, cancellation, generation fences, readiness timeout, pointer mapping and the inspector action.
- WallpaperPreviewLayoutTests checks the 480-point NSView content in English, Chinese and Japanese without an NSWindow; controls fit and errors retain a full-width selectable row and complete tooltip. Scoped static UI review findings were resolved; the WebUI mechanical detector returned no findings.
- python3 scripts/check_rust.py: exit 0 for core, bridge, core-integration and shader groups. Six desktop/corpus cases were explicitly excluded and three asset-dependent shader checks reported skips; those surfaces remain unverified.
- python3 scripts/check_renderer.py: exit 0 with GPU and realtime checks enabled. All 12 generated pooled/isolated pixel pairs matched with no diagnostics; 8 projects completed two reload cycles. Four local-asset cases were skipped (2 text, 1 video, 1 native-Metal local-project case).
- Localization checks and local documentation link checks passed. git diff --check passed excluding raw generator-owned UniFFI output, whose existing generator emits trailing whitespace; bindings were not edited manually.
- Actual preview-window presentation, Scene/Video swapchain first frames in that window, OS visibility transitions and VoiceOver were not exercised. Web FPS is a cooperative host-property request; preview audio response and media integration are unavailable. No Release app, installation or desktop run was requested or delivered.

## 2026-10-08 — Wallpaper history, playlist ordering and failure recovery

- python3 scripts/test.py: exit 0; all 268 Python tests passed; native tests 1227 passed, 0 failed, 14 skipped of 1241. The full gate ran once after integration.
- The 14 native skips were 11 opt-in NativeVideoPlayerMediaTests and 3 live Steam/Workshop network or installation tests; no real media or live-account coverage is claimed.
- Targeted final run of ControlPanelPlaybackToolsTests and WallpaperActivationRecoveryTests: 21 passed, 0 failed, 0 skipped. Offscreen WebKit covered repeated keyboard moves, boundary focus fallback, drag sorting, stale-drag rejection, history order, escaped titles, current-state accessibility and target-only clearing.
- History and playlist regressions cover persistence, bounded recent lists, repeated Previous, failed-apply preservation, exact reorder membership, cooldown expiry, cancellation, bounded fallback attempts and a newer manual command taking precedence.
- python3 -m unittest scripts.tests.test_panel_localization: 5 passed. node --check succeeded for panel.js, settings.js and playlist-order.js. The Impeccable mechanical detector returned no findings for the changed WebUI targets; the scoped source review findings were resolved.
- XcodeGen regenerated the project for WallpaperHistoryStore and its new test files. Local documentation link targets and git diff --check passed.
- The first targeted build was blocked by com.apple.FinderInfo on disposable Debug products. Only that attribute was removed from build/Build/Products/Debug before the successful test runs.
- Desktop playback, OS shortcut invocation, actual dragging in an on-screen window and VoiceOver were not exercised. Failure skipping handles errors returned by Apply; it does not diagnose a visual defect after a successful assignment.
- No Release build, installation, app launch/restart, commit or push was requested or performed.

## 2026-10-07 — Keep web wallpaper animation running through transient occlusion

- Desktop web pages now leave window occlusion to WallpaperPresentationPolicy through a guarded per-view WebKit selector; host detach and inactive suspension remain in place.
- Before the fix, the new offscreen transient-occlusion regression failed because animation frames stopped while the host still allowed playback.
- python3 scripts/test.py --only WebWallpaperSuspensionTests: 5 passed, 0 failed, 0 skipped after the fix.
- python3 scripts/test.py: 268 Python tests passed; 1211 native tests passed, 0 failed, 14 skipped of 1225. Full gate run once.
- Skipped: 11 native media/device cases, 2 live Workshop searches, and 1 live SteamCMD install; opt-in layers were not enabled.
- The first targeted build hit the documented Finder metadata signing failure; clearing xattrs from Debug products let the unchanged command run.
- The regression uses an unshown window with simulated occlusion. Real Show Desktop/Space animations and the original wallpaper were not exercised on the desktop.
- No renderer changes, Release build, app installation/restart, settings mutation, commit, or push.

## 2026-10-07 — Automatic recovery from duplicate wallpaper extensions

- Activation now validates and reconciles native extension registrations to the running app, preserving other app bundles and verifying the resulting registry.
- A wrong extension copy triggers one fresh activation; snapshot refreshes share registration work and preserve the recovery limit, while disabling or shutdown cancels preparation.
- Read-only pluginkit discovery confirmed installed and worktree Debug registrations before implementation; no live registration-repair command was executed.
- Targeted iteration: python3 scripts/test.py --only LockScreenExtensionRegistrationTests --only LockScreenWallpaperServiceTests --only LockScreenExtensionDiagnosticsTests passed 60 tests; the final gate also covers parent-unregistration removing its extension first (61 related tests passed).
- Full gate, run once: python3 scripts/test.py exited 0; 268 Python script tests passed; native tests: 1209 passed, 0 failed, 14 skipped of 1223.
- Skipped opt-in coverage: 11 NativeVideoPlayerMediaTests and 3 live Steam network/install tests; no private asset corpus or desktop checks were run.
- Initial targeted compilation hit the documented Finder/File Provider xattr signing issue; cleared disposable Debug product xattrs with xattr -cr build/Build/Products/Debug, then verified through the passing gate.
- git diff --check passed; owning documentation links resolve; all shipped native language catalogs contain the new messages.
- Unverified: real LaunchServices/PlugInKit repair convergence, macOS choosing the intended extension, and visible lock-screen/screen-saver transitions. No Release build, app installation/restart, or desktop automation.

## 2026-10-05 — Code audit fixes: downloads, playlists, Discover, lock screen, updater, panel

- Scope: 16 fixes and Open on Steam from a read-only audit of aa47389 (Swift app, WebUI, bridge to panel); no renderer change.
- python3 scripts/test.py: Python suites OK; native 1186 passed, 0 failed, 14 skipped of 1200 (opt-in media and network tests).
- New tests that failed before their fix: silent Workshop transfer outliving the timeouts (mutation-checked), lock-screen refresh during readiness wait, failed resume across display reconnect.
- Also covered: failed source switch clears Discover and pixiv, requested playlist skip while paused, allowlisted panel links, queued panel request after a failure, screened subscriptions empty state, collections read-limit count, update digest required, newest poster per display, Steam cookie redirect stripping, paused web audio demand.
- Web navigation: refused top-frame navigation, replaced loads and hash routing never fail the page even without filtering; the suspected -999 report was not reproducible, so no code change.
- Not unit-testable, not run on a desktop: per-display uncover re-evaluating playlists, error alerts from the main run loop, poster sync in screen-saver-only mode, Open after a failed start.
- Not done: update code-signature pinning (self-signed release certificate, planned Developer ID move); setenv race in BridgeStore not reproducible.
- No Release build, no desktop, Steam sign-in or lock-screen run.

## 2026-10-05 — Discover Collections fill screened pages to 30

- Cause: under the default Everyone-only rating, WorkshopService.collections drops collections whose sampled wallpapers are Questionable/Mature; live Steam page 1 (trend, 365 days) kept 9 of 30.
- Fix: WorkshopStore.filledPage fills each panel page from consecutive screened Steam pages (cursor per page, cap 10, next page fetched alongside); page/result counts are estimates; jumps start at an estimated Steam page.
- python3 scripts/test.py --only WorkshopSourceTests: 18 passed (new testScreenedCollectionsFillEachPageFromTheSteamPagesAfterIt).
- python3 scripts/test.py --only WorkshopStoreTests: 10 passed.
- python3 scripts/test.py: 1171 passed, 0 failed, 14 skipped.
- Not checked: the live panel against Steam (no desktop run); Release build follows.

## 2026-10-05 — Discover source tabs (Your subscriptions findable)

- Change: Discover's source <select> replaced by a tab row (Wallpapers / Collections / Your subscriptions) heading the toolbar; signed-in subscriptions summary leads with a primary Download-missing button, count and Sign out; empty subscriptions offer Browse Workshop.
- python3 scripts/test.py --only ControlPanelDiscoverTests --only WebPanelWorkshopSourceTests: 10 passed (new testDiscoverListsAreTabsAndSubscriptionsLeadWithTheirDownload, incl. one-row tabs at the 760px minimum with filters open).
- python3 scripts/test.py: 1170 passed, 0 failed, 14 skipped; Python localization catalog tests OK.
- impeccable detect on WebUI/panel.css, panel.js: no findings.
- Gap: no visual/desktop check (no screenshot authorization); layout verified only through offscreen WKWebView DOM geometry.

## 2026-10-05 — Local XHR startup compatibility for web wallpapers (landed on main)

Commit 41e88a2 (2026-10-03) existed only on a local main worktree; applied onto current main on 2026-10-05. Its original 2026-10-03 entry is carried over below, and the gate was re-run on the new base.

- 2026-10-03: private offscreen WKWebView probe with the original host script reproduced a local settings-loader JSON parse failure and retained splash. With the fix, the same read-only assets initialized a 1920×1080 canvas, removed the splash and reported no script errors across six samples. Audio/capture disabled, nonpersistent storage, no window or screenshot; desktop animation remains unverified.
- 2026-10-03: `python3 scripts/test.py --only WebWallpaperLocalRequestTests` — exit 0; 4 passed, covering synchronous startup, empty responses, async callbacks, JSON/binary bodies, missing files, abort, reuse and non-file metadata.
- 2026-10-03: full `python3 scripts/test.py` — exit 0 on retry after one picker-cancellation timeout that passed alone without code changes; 229 Python and 1075 native tests passed, 12 opt-in skips.
- 2026-10-05, on current main: `python3 scripts/test.py` — exit 0; 1169 passed, 0 failed, 14 skipped (media/network opt-ins). Conflicts were only the verification logs and the generated project; the project was regenerated with xcodegen.
- No renderer source changes; renderer gate not required. No desktop control, wallpaper changes, live audio, installation or app restart.

## 2026-10-05 — Native video keeps playing when its audio output cannot start (issue 31)

Workshop 3582362359 (H.264 Main@5.2, 2880x2160, 60 fps, AAC) was handed to Compatibility with AVErrorUnknown. Reproduced in a scratch AVPlayerLooper probe: while this Mac's audio output could not start, any clip with audio, including a generated control clip and a muted player, failed with -11800 over OSStatus -66681 (kAudioQueueErr_CannotStart); a missing output device fails with -11800 over -12746. The same clip with only its video track played at 60 fps in both cases.

- `WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py --only NativeVideoPlaybackFailureTests --only NativeVideoWallpaperHostTests --only NativeVideoPlayerMediaTests --only NativeVideoAdmissionTests --only SyntheticVideoFixtureTests` — 62 passed, 0 skipped
- With the fallback disabled, `NativeVideoPlayerMediaTests/testAClipWhoseAudioCannotStartKeepsPlayingItsPicture` fails (the clip is handed off); restored afterwards
- `python3 scripts/test.py` — 1165 passed, 0 failed, 14 skipped (media/network opt-ins)
- Compatibility path with the Workshop clip (temporary `unchanged_present_test` case, reverted): ~380–400 MB footprint, 400–580 MB Metal, flat over 40 s at 2560x1440; no VRAM growth reproduced
- Gap: the Compatibility black desktop in the report was not reproduced; one Compatibility run during the audio fault took 229 s instead of ~4 s with the stall unlocated, and a rerun after audio recovered did not repeat it
- Not run: `check_renderer.py` (no renderer change), desktop playback of the Workshop item

## 2026-10-05 — Issue #30: frozen panel, false first-frame timeout, poster refusal loop

Three fixes from one multi-display report: panel.js send() no longer strands a pending key when its busy render throws (the next tab click spun an endless microtask loop); the bridge facade waits for a first frame only where the engine opens or replaces a scene, judged against its live display snapshot instead of its own stale cache; the poster ledger leaves a desktop that keeps refusing posters alone until a Space change or wake.

- `python3 scripts/test.py --only ControlPanelShellTests/testTabsStayUsableAfterARenderThrowsWhileSending` against the unfixed panel.js — failed (page hung, execution time allowance); passes with the fix
- `python3 scripts/test.py --only DesktopWallpaperTests/testDesktopThatKeepsRefusingPostersWaitsForTheNextSpaceChange` against the unfixed ledger — failed (refusals rose 4 → 9; XCTest then stalled recording the assertion until the allowance); passes with the fix
- `cargo test -p wallpaper-bridge --lib first_frame_tests` — 3 passed
- `python3 scripts/check_renderer.py` — exit 0; skipped: 4 local-corpus tests (TextObjectRuntime ×2, AppleVideoFrame.LocalVideoImportsVisiblePixels, MetalSceneDraw.LocalProjects…)
- `python3 scripts/check_rust.py` — exit 0; core 222, bridge 381 passed; shader skipped 3 corpus cases
- `python3 scripts/test.py` — exit 0; 1173 tests: 1161 passed, 12 skipped
- Not verified: the reporter's 4-display Mac, real WallpaperAgent refusals, and that their freeze was this exact page loop (no panel console log was available); the SIGABRT in SharedVideoSourceHandle::prime and the raw BridgeError banner text are not addressed

## 2026-10-04 — Workshop preset media, background-copy masks and script property order (#28)

Issue #28: preset 3610485014 (base 2983846453, a day/night switch template) drew a black background and an unclipped switch at the canvas centre. Diagnostics showed native Metal falling back on files/*.mp4. Both items were fetched with the user-approved saved Steam session into a disposable scratch directory and assembled the way the importer does; nothing from them is committed.

- Before: `metal_scene_draw_smoke` (local project) fell back on the missing `files/*.mp4`, then on `link tex 89 not found`; layer 32's script moved the switch by 0 instead of the preset's (+1346, +830).
- After: native Metal accepts the scene (120 frames, no fallback), and `offscreen_scene_probe` (Vulkan) shows the same picture: video background, switch top right, clipped to its pill. This matches the reporter's Windows screenshot by eye; no pixel reference.
- New regressions, each confirmed failing without its fix: `SceneSourceMount.APresetFileBesideThePackageLoadsAndThePackageStillWins`, `LayerTextureReference.ABareComposeLayerAnotherSamplesIsDrawnOnlyIntoItsComposite`, `ScriptRuntimeCompat.ModuleCodeSeesDeclaredDefaultsAndInitSeesTheBoundValue`.
- `python3 scripts/check_renderer.py --project <assembled preset>`: exit 0. All generated cases are pooled/isolated equal with 0 diagnostics; the preset is pooled/isolated equal with 4 known diagnostics (`.mp4.tex` probes before the loose fallback, and the clock script's `createLayer({text})` drop shadow, which is unsupported and hidden). Skipped: corpus-dependent text_object_runtime, playback_gpu local video and metal local-project tests (env unset).
- `python3 scripts/test.py`: exit 0; 1157 passed, 12 skipped of 1169.
- `python3 scripts/build.py --configuration Release`: the first run failed configuring wallpaper-core, because a compiler-path change reset its stale CMake cache without the build script's `-D` flags; the unchanged retry built the app. Bindings were regenerated unchanged.
- Not verified: desktop or app run, clicking the day/night switch, audio bars. Text-layer `padding` given as an "x y" string still parses to 0 (pre-existing; no visible effect here).

## 2026-10-04 — v1.2.4 hosted-runner timer precision gate

- Cause: v1.2.4 Release runs 37185728032, 37188243177 and 37190006244 failed 'Renderer regressions without a desktop' (new in v1.2.4) on wall-clock cadence tests: 11 ticks of a 10 ms cadence in 600 ms, ~10 fps at a 60 fps ceiling; the background-priority reset (265339e) did not change it.
- Fix: check_renderer.py --allow-imprecise-timers compiles a probe (median of 31 condition-variable 10 ms waits); only its exit 77 (median > 20 ms) filters the nine REALTIME_TESTS by --gtest_filter and records each as a warned skip; build.yml passes the flag.
- Probe locally: 11.0 ms median (exit 0); under taskpolicy -b: 47.95 ms (exit 77), matching the CI signature.
- Filtered timer_tests (29), audio_tests (51) and unchanged_present_test (1) all passed on the local binaries; no filtered name ran.
- python3 scripts/check_renderer.py --skip-build --allow-missing-gpu --allow-imprecise-timers: exit 0, every cadence test executed, 12 generated scenes matched, reload 8x2 passed.
- A first full-build run failed FrameTimerTest.AnIdleBurstOfWakeOnceProducesOneCallback once under load average ~6; 0/40 on repeat, unrelated to this change, passed on all three CI runs.
- python3 scripts/test.py: Python suites passed (test_check_renderer 26 tests); native 1156 passed, 0 failed, 12 skipped.
- Gap: the hosted-runner skip path is proven only through mocked gate tests until the v1.2.4 Release run; no desktop, app launch or Release rebuild.

## 2026-10-04 — v1.2.4 background runner regression

- Reproduced the CI timer failure with taskpolicy -b; application scheduling alone did not clear inherited Darwin background policy.
- Child-only process and main-thread priority reset preserves real-time assertions; 20 renderer harness Python tests passed, including background inheritance and exit-status propagation.
- /usr/sbin/taskpolicy -b python3 scripts/check_renderer.py --skip-build: passed all required binaries, all 12 generated scene pixel comparisons and expected pixels with zero diagnostics, and eight reload projects twice.
- python3 scripts/test.py: Python checks passed; native suite 1156 passed, 0 failed, 12 optional media/network tests skipped.
- User commit 9a63ed3 and its bilingual release note remain included. Optional local wallpaper/video corpus tests were skipped; no desktop launch, install, audio hardware, or visual smoke test was performed.

## 2026-10-04 — Normalize complete puppet poses across animation layers

- Original synthetic regressions: both NonAdditive tests fail against the original WPPuppet.cpp and pass with the correction.
- CMake mdl_schema_tests and scene_schema_tests: exit 0; 57 model and 109 scene tests passed.
- python3 scripts/test.py: exit 0; Python checks passed, native gate 1156 passed, 0 failed, 12 opt-in media/network skips.
- python3 scripts/check_renderer.py --project <local-project>: exit 0; all 30 registered binaries succeeded; 12 generated scenes and one local scene had pooled/isolated pixel equality and zero diagnostics; local reload x2 passed.
- Renderer gate skipped two optional private text scenes, a private video import and its unconfigured local Metal case; the affected local scene was separately rendered successfully by metal_scene_draw_smoke.
- Private offline renders of Into The Abyss inspected at scene time 15 seconds on Compatibility and native Metal: hair and arm reassembled. Compatibility before/after both used 1024 passes across 16 samples and 276121600 allocated GPU bytes.
- python3 scripts/build.py --configuration Release: exit 0; rebuilt renderer and Release app. No installation or launch.
- git diff --check passed. Desktop presentation, live smoothness and energy use unverified; no desktop control, screen capture or audio hardware used.

## 2026-10-04 — PR 25 declaration-scoped arrays and camera FOV

- Resolve stage-interface macro bounds at each declaration, including intervening and function-body directives; freeze literal bounds before hoisting/input-copy emission. Shader pipeline revision 10 -> 11 invalidates previously cached stale-sized programs.
- Omitted/nonpositive camera FOV inherits immutable authored scene settings; named camera creation, runtime shots and non-runtime playback share the resolved value. Positive object overrides remain authoritative.
- `cargo test -p shader -- --nocapture` with the project Cargo environment — exit 0; 515 reported passed, including three unavailable asset-dependent early-return skips. SPIR-V/MSL per-declaration and undefined-macro regressions passed.
- Camera-targeted scene-schema run — 20 passed. Rebuilt full scene_schema_tests with the current shader library — 109 passed, including named/default cameras, scene/shot overrides and visibility fallback in both playback paths.
- `python3 scripts/build.py --renderer-only` — passed; generated bridge bindings unchanged. No Release app build.
- `python3 scripts/check_renderer.py` — every recorded binary exited zero; all 12 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles.
- `python3 scripts/test.py` — all Python suites passed; 1,156 native passed, zero failed, 12 skipped.
- Corpus gaps: three shader cases, two renderer text scenes, the optional local video import case and environment-selected Metal projects skipped; these are not verified asset coverage.
- `git diff --check`, provenance JSON and generated-binding consistency passed. No desktop visual/live keyboard validation, authored-reference parity claim or app launch.

## 2026-10-03 — Software-decoded video GPU import

- Reproduced the initial GPU-import failure in the installed reported video, read-only, using playback_gpu_test --gtest_filter='DecodedFormats/*:AppleVideoFrame.LocalVideoImportsVisiblePixels' with WE_TEST_VIDEO. All five cases failed before the allocation fix and passed afterward.
- Generated BGRA, NV12, YUV420P and YUVJ420P cases verify exact strided color/alpha pixels after decoder-buffer release, with no conversion destination or CPU GPU-wait added by import.
- The local clip's first decoded frame imported successfully afterward: 667163 of 921600 pixels exceeded the visible-pixel threshold. This checks GPU texture import, not desktop presentation or authored-reference equivalence.
- python3 scripts/test.py: exit 0; Python modules passed; native tests 1156 passed, 0 failed, 12 opt-in skips.
- python3 scripts/check_renderer.py: exit 0; all 30 registered binaries passed; 12 generated pooled/isolated cases matched with expected pixels and no diagnostics; eight projects reloaded twice.
- Renderer skips: two asset-dependent text cases, one local-project Metal case, and WE_TEST_VIDEO unset in the routine gate. The video diagnostic was run separately with the reported clip; skipped asset cases are not claimed as passing.
- python3 scripts/build.py --configuration Release: exit 0; Release app built, not launched or installed.
- No wallpaper assets, settings, hardware-decoder selection or frame scheduling changed. No desktop control, screenshots or audio hardware; desktop appearance, sustained playback and energy impact remain unverified.

## 2026-10-03 — PR 25 merge with audited main

- Merged `origin/main` at `d895d74` without rebasing; preserve the audit registry/GPU prerequisites, all 12 synthetic scenes, both regression sets, and all 42 distinct historical verification entries.
- Reconciled stage-interface bounds with the audit leading-macro undefinition/redefinition behavior; the new unit regression passed.
- `python3 scripts/build.py --renderer-only` — passed; renderer rebuilt and bridge bindings regenerated, matching the incoming generated files. No Release app build.
- `python3 scripts/check_rust.py` — all four suites exited zero: core 223, bridge 378, core integration summaries 15, shader 533 reported passed; shader reports three unavailable corpus early-return skips.
- Rust exclusions remain explicit: two desktop window tests and four external-corpus tests; desktop/media/network opt-ins disabled.
- `python3 scripts/check_renderer.py` — all registered binaries passed; all 12 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles.
- Additional C++ suites rebuilt and passed in isolated state: scene_schema_tests 108, script_runtime_compat_test 91, mouse_input_test 13.
- `python3 scripts/test.py` — all Python suites passed; 1,156 native passed, zero failed, 12 skipped. Renderer-tooling targeted suite: 17 passed.
- Renderer corpus skips: two local text scenes and the environment-selected Metal project case. No desktop visual/live keyboard validation, authored-reference parity claim or app launch.
- `git diff origin/main --check`, regenerated-binding consistency, historical-entry preservation/order and conflict-marker checks passed; incoming generator whitespace was not hand-edited.

## 2026-10-03 — PR 24: retry eligibility and durable pixiv cancellation

- Web host state now explicitly grants retry only to failures from the current live page; panel rendering, action dispatch and host retry all honor that capability.
- Project validation and fingerprint failures remain visible without an ineffective retry action, including failures while an older surface still exists.
- Pixiv cancellation is excluded from the durable queue immediately while the task retains its slot until cleanup finishes; pause/shutdown cannot revive cancellation, and a fresh request discards orphaned partial data.
- python3 scripts/test.py --only WebWallpaperHostLifecycleTests --only ControlPanelHostStateTests: 9 passed, 0 failed/skipped. Initial test compile error in an error-pattern catch was corrected before this successful run.
- python3 scripts/test.py --only PixivDownloadQueueTests: 9 passed, 0 failed/skipped; held cancellation cleanup covers queue restore, slot ownership, shutdown, paused checkpoints and fresh enqueue.
- python3 scripts/test.py: 256 Python tests and 1148 native tests passed; 0 failures and 12 media/network opt-in skips. Full gate ran once after both changes were final.
- git diff --check passed. No renderer/bridge changes, so renderer checks and binding generation were not repeated.
- No Release app build, desktop automation, live pixiv/Steam access or real media-hardware validation. Panel assertions use offscreen fixtures.

## 2026-10-03 — PR 24 review follow-up

- Addressed all 12 inline review threads: per-wallpaper purge isolation, resume consent, benchmark schema lookup, effective-cap reporting, artwork validation, dangling symlinks, BGRA admission, encoder skips, allocator scope, termination order, checkpoint recovery and empty playback notifications.
- python3 scripts/test.py --only UserAssetStoreTests --only WorkshopStoreTests --only WorkshopDownloadPersistenceTests: 55 passed, 0 failed, 0 skipped.
- python3 -m unittest scripts.tests.test_power_benchmark scripts.tests.test_mediaremote_stream: 38 passed, including synthetic startup/track callbacks; no real player access.
- Targeted cargo test --release --locked --lib checks: wallpaper-bridge tests::quality_settings (10), tests::web_audio_media (21), wallpaper-core tests::general::shader_cache (5); all 36 passed with isolated WALLPAPER_MACHINE_HOME.
- python3 scripts/build.py --renderer-only: passed and regenerated bindings, with no generated API changes; no Release app build.
- python3 scripts/test.py: 256 Python tests and 1143 native tests passed; 0 failures, 12 native media/network opt-in skips. The new WorkshopDownloadIntentTests resume-consent case passed in this full gate.
- python3 scripts/check_renderer.py: passed with GPU checks executed; all 10 generated pooled/isolated pairs matched with zero diagnostics, expected pixels passed, and 8 projects completed two reload cycles each.
- Renderer gaps: three local-asset cases skipped; the existing disabled JPEG timing benchmark was not run. Desktop, visual presentation, live Steam, real media hardware and battery/power behavior were not exercised.
- git diff --check and all auditRemediation provenance SHA-256 checks passed; CLAUDE.md remains a relative AGENTS.md symlink. Changes remain local, uncommitted and unpushed.

## 2026-10-03 — Audit remediation across app, renderer and tooling

- Completed all 79 formal audit findings; the excluded/withdrawn audit candidates were not promoted into the repair scope. Owning feature/testing docs and 106 changed upstream file hashes are recorded.
- python3 scripts/build.py --renderer-only: exit 0; Rust/C++ renderer dependencies rebuilt and UniFFI bindings regenerated. No Release application build or delivery.
- python3 scripts/test.py: 254 Python tests passed; native 1140 passed, 0 failed, 12 skipped of 1152. First attempt stopped at catalog quote-format validation; fixed and full gate passed on retry.
- python3 scripts/check_renderer.py: exit 0; 662 gtests passed, 3 external-corpus tests skipped; 10 generated scene pixel comparisons and 16 reload cycles passed. Fixed one missed probe API migration and an obsolete prepared-state fixture before final success.
- python3 scripts/check_rust.py --output artifacts/remediation-20261003/rust-final: all four groups exit 0; core 223, bridge 377, integration 15 plus layer pixel executable, shader 529 reported including 3 corpus early-return skips. Two desktop and four corpus cases explicitly excluded.
- Focused regressions cover asset commit/cancel/rollback interleavings, same-path content refresh, host readiness/audio delivery, durable download pause/resume, updater cancellation/ownership, media withdrawals and failed extension-surface reuse. Security boundary candidate received independent source review; no new confirmed regression.
- Synthetic Debug measurements: 10000-row snapshot construction 35.70 ms initially versus 1.94 ms mean progress update; actual payload JSON UTF-8 2303731 to 5935 bytes. Asset cold preparation for 8/128/1024 files kept measured main-actor maximum delay below 7 ms; timings are observations, not whole-app energy claims.
- arm64 JPEG scalar/NEON output was byte-identical; decoder-only warm medians improved about 33%. Runtime GPU checks used private images. Desktop/UI opt-ins, live account/network/player tests and missing external corpus checks were not run; UI source typecheck passed.
- git diff --check passed for handwritten sources; generated UniFFI formatting retains generator whitespace. CLAUDE.md remains the relative AGENTS.md symlink. No commit, push, app install/restart or desktop interaction.

## 2026-10-03 — PR 25 CodeRabbit input-validation follow-ups

- Range-check parallax IDs and parent references before narrowing, handling unsigned JSON values before signed conversion; preserve valid int32 boundaries and declaration-order independence.
- Skip non-object entries, non-string names and nonnumeric IDs during layer-alias registration; retain missing-field defaults and valid alias-driven script updates.
- Hosted keyboard-loop test now waits for both fields to attach to its window and reports a setup failure immediately on timeout.
- Rebuilt `scene_schema_tests`; `--gtest_filter="SceneSchema.*Parallax*:SceneSchema.*Parented*:SceneSchema.*Duplicate*"` — 11 passed, including three new boundary/type regressions.
- `python3 scripts/test.py --only ControlPanelWindowSizingTests` — four passed; targeted iteration only.
- `python3 scripts/check_renderer.py` — every recorded binary exited zero; all 12 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles.
- `python3 scripts/test.py` — all Python suites passed; 1,072 native passed, zero failed, 12 skipped.
- Renderer skips: two local text scenes and the environment-selected Metal project case. No desktop visuals/live keyboard check, authored-reference parity, app launch or Release rebuild.
- Confirmed no configured/gated SwiftLint required_deinit rule; kept the controller unchanged. Current verification entries already satisfy newest-first ordering; no historical results rewritten.

## 2026-10-03 — PR 25 Claude review follow-ups

- Unified stage-interface array bounds for location allocation and emission; unsupported expressions, late/missing definitions and nonpositive sizes now fail explicitly.
- Single-sample alpha-to-coverage uses source-over blending on Metal/Vulkan; multisampled state retains unblended coverage without adding targets or passes.
- `cargo test -p shader -- --nocapture` using the project Cargo environment — exit 0; 507 reported passed, including three unavailable asset-dependent early-return skips.
- `python3 scripts/check_renderer.py` — exit 0; all 12 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles. All recorded test binaries exited zero.
- Negative control: the preceding renderer binary fails the new single-sample composed-coverage pixel assertion; the rebuilt renderer passes. Native Metal transparent/half/opaque pixel regression also passed.
- `scene_schema_tests --gtest_filter="SceneSchema.*Camera*:SceneSchema.PerspectiveFallback*"` after rebuilding — 19 passed, including steep/rolled look-at, scaled/zero deltas and fallback registration.
- `python3 scripts/test.py` — all Python suites passed; 1,072 native passed, zero failed, 12 skipped. Existing cancellation/preview-error tests and new offscreen Tab/Shift-Tab wrapping passed.
- Stable-sorted verification entries by date through the log helper functions, preserving every historical body and relative archive link; new evidence appended only via `scripts/log_verification.py`.
- Asset gaps: three shader corpus cases, two local text scenes, and the environment-selected Metal project case skipped. No desktop visual/live WebKit keyboard check, authored-reference parity, app launch or Release rebuild.

## 2026-10-03 — PR 25 merge conflict resolution

- Merged `origin/main` into `fix/scene-playback-panel-shaders` without rebasing; retained both sides of renderer provenance and all 36 distinct historical verification entries.
- `python3 scripts/test.py` — all Python suites passed; native results: 1,071 passed, zero failed, 12 skipped.
- `python3 scripts/check_renderer.py` — exit 0; all 11 synthetic pooled/isolated comparisons matched with zero diagnostics; eight projects completed two reload cycles.
- Built `scene_schema_tests` and `script_runtime_compat_test` with the project build environment; 26 targeted duplicate-name/parallax/camera/model tests and two color/composition tests passed.
- Targeted coverage includes both incoming regressions: duplicate names retain independent bindings, and authored color properties remain vectors across updates.
- Renderer asset gaps remain: two local text-scene tests and the environment-selected local-project Metal test skipped; no authored-reference parity claim.
- Provenance JSON, historical-entry preservation, conflict-marker checks, and `git diff --check` validated before commit.
- No desktop automation, visual validation, app launch, or Release app rebuild performed.

## 2026-10-03 — Shader macro fixes and pending scene/playback/panel PR

- `python3 scripts/test.py` — passed: 1,071 native tests passed, 12 skipped; all Python script suites passed.
- `cargo test -p shader -- --nocapture` from `upstream/renderer`, using `scripts/build.py` cargo environment — exit 0; 506 reported passed, including three asset-dependent early-return skips.
- Shader corpus gaps: two auto-sway/depth-parallax fixtures and the genericimage4 asset case were unavailable; those cases are skipped, not verified.
- New macro-sized varying and nested legacy macro regressions passed for SPIR-V and MSL.
- `python3 scripts/check_renderer.py` — exit 0; all 11 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles.
- Renderer gaps: two local text-scene cases and the environment-selected local-project Metal case skipped; no authored-reference parity claim.
- `git diff --check` — passed before commit.
- No desktop automation, visual validation, app launch, or Release app rebuild performed.

## 2026-10-03 — Tile layer textures, unblended alpha-to-coverage, random sprite frames

- Composite render targets follow the source layer clampuvs; alphatocoverage writes kept samples unblended on both backends; randomframe particles get a fixed hashed per-particle frame. No wallpaper-specific rules, MSAA, extra passes or allocations.
- Targeted: layer_texture_reference_test 20, particle_mouse_controlpoint_test 42, metal_backend_test 35, scene_schema_tests 100 passed.
- python3 scripts/check_renderer.py: passed; 509 renderer tests, 3 optional local-asset skips, 0 failures; 11 generated scenes pass pixel and pooled/isolated checks; 8 reload projects x2.
- python3 scripts/test.py: passed; 1,071 native passed, 12 skipped.
- Local packaged 3D scene, Compatibility offscreen, disposable package copies forcing single camera paths: the solid blue planes came from a 497x-tiled maze composite sampled with clamp; after the fix the maze tiles and sprite particles show varied frames.
- Remaining against the supplied Windows screenshot: maze lines are thinner/dimmer (single-sample coverage threshold vs likely MSAA) and distant lines alias; not changed, to avoid MSAA memory/perf cost.
- python3 scripts/build.py --configuration Release: passed. No desktop capture, Parallels inspection, wallpaper change or app launch.

## 2026-10-03 — Parent-controlled parallax keeps child layers aligned

- Resolved outermost-parent parallax once at parse time; no wallpaper identifiers, asset edits, new render passes, texture allocation or per-frame hierarchy traversal.
- scene_schema_tests: 100 passed, including declaration-order/cycle/default-depth resolution and parsed multi-slot puppet displacement with unchanged local transforms.
- MetalSceneDraw.ParentedCardsStayJoinedWhileParallaxMovesAndReverses: passed for direct/effect cards and repeated/reversed cursor motion; removing only the inheritance call in a private build makes its pixel assertion fail.
- check_renderer.py with an isolated artifact root: 507 passed, 3 asset-dependent skips; 11 generated pixel cases and the selected local wallpaper match pooled/isolated allocation, no diagnostics; two reload cycles passed.
- The first additional private-scene comparison failed only in 769 live-clock pixels. Retry used WE_TEST_PROPERTIES to hide its clock in memory; no imported files or saved user settings changed.
- Matched eight-frame Vulkan probes with synthetic pointer input reproduce detached head/flowers without inheritance and aligned pieces with it; both execute 1095 passes, reuse 49 and allocate 114272640 VMA bytes. This is not a battery/performance benchmark.
- python3 scripts/test.py: 1071 passed, 0 failed, 12 skipped; all Python script modules passed. No desktop/UI, live network or media-device opt-ins.
- python3 scripts/build.py --configuration Release: passed; delivered build/Build/Products/Release/WallpaperMachine.app, not launched or installed.
- Shared workspace contained concurrent shader/camera/model/UI work. A transient unrelated ParseCameraPaths test declaration blocker cleared before verification; unrelated edits remain separate.
- Desktop presentation, real cursor interaction and animation smoothness remain unverified; all image inspection was surface-free offscreen output.

## 2026-10-03 — Restore perspective shots and skeletal model playback

- Implemented runtime perspective-shot selection, packaged eye/center/up/FOV camera paths, shared skeletal-model playback and model-specific opaque depth/cull defaults; no wallpaper-specific rules or asset edits.
- scene_schema_tests: 100 passed, including five new camera/model regressions; orthographic camera coverage remains green.
- python3 scripts/test.py: passed; 229 Python tests, 1,071 native tests passed, 12 native skips.
- python3 scripts/check_renderer.py: passed; 507 renderer tests passed, three optional local-asset tests skipped; 11 generated scenes passed known-pixel and pooled/isolated equality checks, eight reload projects exercised twice.
- Local packaged scene, Compatibility offscreen: reproduced the missing model, wrong camera and rear-triangle artifacts before the fixes; after, fixed and dynamic camera views show the model and solid ghosts. Four animation samples confirm the jaw opens/closes; a 720-frame path run changes the camera pose with zero script errors.
- Native local-project probe reports Compatibility fallback for dynamic lighting; not a native rendering pass. Two optional text corpus cases remain skipped.
- 1920x1080 offscreen probes retain 176 executed passes/frame and 256,163,584 allocated Vulkan bytes before/after. Shared skeletal playback and parse-once camera curves add authored animation work, not extra passes/targets; sustained desktop performance not measured.
- python3 scripts/build.py --configuration Release: passed; built build/Build/Products/Release/WallpaperMachine.app. No installation, launch, restart, desktop capture, wallpaper change or Parallels control.
- Exact Parallels parity remains unverified without a supplied reference; camera-path zoom/events and camera-cut fades remain unsupported. Existing concurrent shader/parallax edits were preserved and included in shared-tree verification.

## 2026-10-03 — Wallpaper apply and background presentation ordering

- Reproduced the reported interruption with held fake-bridge operations: disabling the serialization fix makes both arrival-order regressions fail with the original interruption error; restored the fix afterwards.
- `python3 scripts/test.py --only WallpaperActivationRecoveryTests` — exit 0; 18 passed, covering Apply/Apply changes versus display refresh, global/per-display suspension, unload/reload and audio suppression, both arrival orders, failure release, cancellation and explicit Pause.
- `python3 scripts/test.py` — exit 0; Python suites passed; native 1070 passed, 12 skipped, 0 failed. Skips: nine real-player media tests, one live SteamCMD install and two live Workshop searches.
- `python3 scripts/build.py --swift-only --configuration Release` — exit 0; built the Release app with existing renderer/bindings, per local build opt-in.
- No desktop control, wallpaper changes, app launch/restart or UI run; visual behavior and private Workshop assets were not verified.
- Existing concurrent renderer/provenance edits were left untouched and were not rebuilt or verified by this Swift-only task.
- `git diff --check` — exit 0; existing documentation paths and commands retained.

## 2026-10-02 — Live Solar System scripted colors and duplicate layer lookup

- python3 scripts/test.py: exit 0; 227 Python tests and 1064 native tests passed, 12 native opt-in tests skipped.
- CMake targeted build: offscreen_scene_probe, scene_schema_tests and script_runtime_compat_test succeeded.
- scene_schema_tests --gtest_filter=SceneSchema.*Duplicate*: 5 passed, including mixed image/group order, module-initialization lookup, independent thisLayer writes and parsing without a runtime.
- script_runtime_compat_test --gtest_filter=ScriptRuntimeCompat.AuthoredColor*:ScriptRuntimeCompat.MaterialConstantUserBindingUpdatesThroughRuntimeProperties: 2 passed; saved color strings stay vectors over repeated ticks and property changes, while text stays a string.
- python3 scripts/check_renderer.py --project <local Live Solar System project.json>: exit 0; 503 C++ tests passed, 3 asset-dependent cases skipped; all 10 generated scenes and the local scene matched pooled/isolated pixels, with 2 successful reload cycles.
- Surface-free Vulkan probes with intro disabled: sun tint changed from black to the authored RGB value, the oversized foreground dwarf planet now receives the simulation scale, and sampled startup and 5.5-second frames had zero script errors.
- The local project retained the same 92 non-cache shader-value diagnostics as the baseline; no new diagnostics. These checks do not establish complete wallpaper compatibility.
- Skipped renderer asset cases: LonelyCatHeadlessRegression, Workshop3409533530FullSceneKeepsClockRenderPassAndTexture and the optional native-Metal local-project test. Live Solar System uses the dynamic-lighting Compatibility path.
- No Release build, app installation/restart, desktop control, screen capture, live audio or Steam sign-in. Desktop interaction and presentation remain unverified.
- python3 scripts/clean.py --dry-run: shared artifacts and other worktree caches were listed, so no shared cleanup was performed. Private probe outputs remain Git-ignored.

## 2026-10-02 — v1.2.3 pre-release gate

- `python3 scripts/build.py --renderer-only` — exit 0; renderer rebuilt and Swift bindings regenerated.
- `python3 scripts/test.py` — exit 0; 227 Python tests passed; native 1064 passed, 0 failed, 12 skipped (9 opt-in media, 3 live network/install).
- `cargo test --release -p wallpaper-bridge --lib` with the build helper environment — exit 0; 367 passed, 0 failed.
- `python3 scripts/check_renderer.py` — exit 0; 24 test binaries and reload cycles passed; all 10 generated pooled/isolated pairs matched with no diagnostics and expected pixels.
- Three asset-dependent renderer cases skipped: two local text-project regressions and the native local-project matrix. No authored-reference compatibility claim.
- `git diff --check` passed; origin/main is an ancestor of the reviewed main, with no unmerged paths. Version dry run: 1.2.2 (24) -> 1.2.3 (25).
- Compiler warnings remain, including Swift concurrency diagnostics and Rust unused-code warnings; zero warnings/issues is not claimed.
- No desktop run, wallpaper change, audio capture, live Steam login, or local Release app build. Release publication will use the Version workflow after the source push.

## 2026-10-02 — Web-only audio capture ownership

- Read-only inspection found the reported web wallpaper registers the standard audio listener; its saved Audio response switch is off. No user settings or private wallpaper assets changed.
- Regression: restoring the old scene-handle-only capture predicate makes capture_tap_follows_web_subscribers_with_no_scene_handle fail; restored the fix before the passing checks.
- cargo test --release -p wallpaper-core --lib: exit 0, 225 passed; cargo test --release -p wallpaper-bridge --lib: exit 0, 367 passed. Controller tests cover one shared tap, external ownership, permission, suspension and rollback; bridge tests exercise the production demand handler, web-only startup and shutdown.
- python3 scripts/build.py --renderer-only: exit 0; generated bindings refreshed without a UniFFI signature change.
- python3 scripts/test.py: exit 0; all 17 Python modules passed; native 1064 passed, 0 failed, 12 opt-in media/network cases skipped.
- python3 scripts/check_renderer.py: exit 0; all ten generated pooled/isolated cases pixel-identical with zero diagnostics, eight reload projects twice; three environment-selected private-asset checks skipped.
- python3 scripts/build.py --configuration Release: exit 0. Local Release app built, not installed or launched.
- Live system capture, actual music reaction, desktop visuals and battery effects remain unverified. No desktop control, windows, screenshots, audio devices or permission prompts used. Existing shared-workspace edits preserved.

## 2026-10-02 — Conditional texture masks contain brightness pulses

- `cargo test -p shader -- --nocapture` (renderer workspace, build environment): exit 0; 504 nominal successes, including 3 asset-dependent early-return skips, not 504 exercised cases. The new SPIR-V/MSL conditional-mask regression failed before the fix and passed after it; existing inactive-default and disabled-texture tests remain green.
- `python3 scripts/check_renderer.py --project <local-scene-project>`: exit 0; 502 native renderer checks passed, 3 optional corpus checks skipped; all ten generated scenes and the affected local scene matched pooled/isolated pixels with no diagnostics; two reload cycles passed. The GPU regression holds masked pixels constant across six alternating brightness frames while unmasked pixels continue changing.
- Surface-free before/after probes: same 30 frames at 1/60 s, fixed seed, untouched local package. Both pulse passes now retain their authored mask slot. Maximum consecutive-frame change in sampled mean red fell from 9.844 to 0.066 code values; both runs executed 540 passes. Masks add their intended texture residency/sampling, not extra passes or lower quality.
- `python3 scripts/test.py`: exit 0; Python modules passed; native gate 1064 passed, 0 failed, 12 skipped.
- `python3 scripts/build.py --configuration Release`: exit 0; local Release app rebuilt under the developer's build opt-in, not installed or launched.
- No desktop control, wallpaper changes, screenshots, audio devices or permissions. Desktop appearance, long-duration visual comfort and live power/frame-time performance remain unverified. Concurrent library/web/bridge/parallax edits were preserved; the gates and build used the shared working tree.

## 2026-10-02 — Workshop presets download and import as self-contained wallpapers

- Cause: Workshop presets (e.g. Purple Ink 1809081988, Ink 3356611918) have no project.json type, only dependency + preset values; validation rejected them.
- Fix: downloader fetches the base in a second SteamCMD pass of the same job; importer assembles base + preset files + merged manifest under the preset id; manual import uses a sibling or installed base.
- python3 scripts/test.py --only ImportTests --only DownloaderLifecycleTests: passed 53, failed 0.
- python3 scripts/test.py: passed 1064, failed 0, skipped 12 (opt-in layers).
- Not verified: a live SteamCMD download of the two real presets (needs Steam sign-in); no Release build.

## 2026-10-02 — Web wallpapers: Chromium-like file:// fetch responses (Unity/WASM)

- Cause: WebKit file:// fetch → status 0/ok false/no Content-Type; Unity 2022.3 wasm streaming + fallback both rejected, canvas stayed dark (Workshop 3756621387).
- Fix: host script serves found file:// GET/HEAD as 200 + extension MIME; served .wasm compiled from bytes (WebKit streaming compiler ~190 ms slower boot).
- Offscreen headless WKWebView repro (no desktop window): before abort('both async and sync fetching of the wasm failed'); after Unity boots, Live2D renders, music loads.
- Perf: 30 MB fetch+arrayBuffer native vs normalized ~68 ms both; Unity boot to first engine log 180 ms (vs 364 ms with native streaming).
- python3 scripts/test.py --only WebWallpaperPageTests/ScreenSaverWebSurfaceTests/WebWallpaperAuthorAPITests: 25 passed.
- python3 scripts/test.py: 1058 passed, 0 failed, 12 skipped.
- Not run: Release build, desktop/visual check of the live wallpaper.

## 2026-10-02 — Video preflight preserves Compatibility fallback (issue #23)

- Reproduction before the fix: python3 scripts/test.py --only WallpaperActivationRecoveryTests/testMatroskaVideoCanBeActivatedWithEitherBackendPreference --only WallpaperActivationRecoveryTests/testMatroskaVideoOptionsCanBeAppliedWithEitherBackendPreference — exit 65; both tests failed with the reported video-decode error on an original silent H.264 Matroska fixture.
- python3 scripts/test.py --only WallpaperActivationRecoveryTests — exit 0; 12 passed, 0 failed or skipped. Covers both apply paths and backend preferences, missing/empty/non-file entries, decoder-error propagation and retry.
- python3 scripts/test.py — exit 0; 227 Python tests passed; native suite 1,057 passed, 0 failed, 12 skipped. Full gate run once after the fix.
- Skipped: nine opt-in native player/media tests, two live Workshop searches and one live SteamCMD install. No media-device or network-test opt-ins enabled.
- Fixture metadata checked with ffprobe: Matroska, H.264, 16 x 16, two video packets, no audio stream; embedded bytes match the generated original. No FFmpeg CLI is required by the regression tests.
- git diff --check — exit 0. No renderer or generated-bridge changes.
- Workshop item 3351864056 is absent locally; its original file and desktop playback remain unverified. No Release build, app launch, install or desktop control performed.

## 2026-10-02 — Single-pass puppet lighting and complete four-light packing

- python3 scripts/test.py: 1064 passed, 0 failed, 12 skipped; 229 Python tests passed. First native attempt was blocked by another build holding the shared Xcode database; retry after it finished passed.
- python3 scripts/check_renderer.py --project <local-scene>: exit 0; 506 renderer tests passed, 3 asset-dependent cases skipped; all 11 generated pixel cases and the private scene matched pooled/isolated output; two reload cycles passed.
- script_runtime_compat_test --gtest_filter=ShaderValueUpdaterCompat.*: 10 passed, including zero-to-five-light color packing and clearing.
- MetalSceneDraw.PuppetEffectsApplyLightingOnceAfterAssembly: all eight original puppet/card, effect/direct, lit/unlit combinations passed across three draws each.
- Negative controls: disabling each fix made its respective new regression fail; restored fixes passed.
- Offscreen private scene: duplicate dimming and eye-patch boundaries removed at startup and a six-second sample. Same three-frame workload retained 197 executed / 40 reused passes and 266389504 allocated GPU bytes; lighting shader work is removed, not replaced with additional passes.
- Existing private scene init TypeError remains, unchanged from baseline. Native local-project probe reports Compatibility because of dynamic lighting; it did not render this scene natively.
- No desktop control, windows, screenshots, wallpaper changes, audio hardware or live services. Desktop appearance/smoothness and power use remain unverified. Concurrent work preserved.

## 2026-10-02 — Macro-sized shader interfaces and nested macro builtins

- Original synthetic shader regressions reproduced unknown COUNT and CAST3 failures before their respective repairs; both now compile SPIR-V and MSL. Numeric combo defaults/overrides and consecutive arrays are covered.
- WALLPAPER_MACHINE_ASSETS_ROOT=<local SceneAssets> cargo test -p shader -- --nocapture: exit 0; 506 reported successful tests, including two unavailable private-asset checks that returned early (504 exercised).
- python3 scripts/test.py: exit 0; Python script suites passed; native verdict 1064 passed, 0 failed, 12 skipped of 1076.
- python3 scripts/check_renderer.py --project <local project>: exit 1 in the shared working tree. All 11 synthetic pixel cases passed; local project pooled/isolated pixels matched and both reload cycles succeeded. The concurrently added MetalSceneDraw.PuppetEffectsApplyLightingOnceAfterAssembly failed; its source and the concurrent parser/updater changes were not modified by this task.
- Surface-free local scene renders restore the sky, mountain and bridge gradients; four formerly rejected gradient effects now compile. Existing dock script errors and a missing layer-texture link remain. Native Metal still refuses the same missing effects/blend image as before, so this scene was verified through Compatibility, not native presentation.
- Changes are shader-compilation-only, with no wallpaper IDs, asset edits or brightness compensation. Restored effects increase the sampled two-frame executed-pass total from 289 to 297 and allocated Vulkan target/image bytes from 244133504 to 278081152; this is authored work previously dropped, not a new correction pass. Desktop performance and exact reference parity are unverified.
- No desktop control, live settings changes, app restart or installation. Eye-square report could not be identified in the bridge scene; screenshot requested. No commit or Release build while the shared renderer gate is failing.

## 2026-10-02 — Layer origin timelines reveal animated intros

- python3 scripts/test.py: passed (1064 native tests, 12 opt-in skips; 17 Python modules).
- python3 scripts/check_renderer.py: passed; 23 test executables, eleven synthetic pooled/isolated pixel comparisons and eight scenes reloaded twice. Two private text cases and the environment-driven local-project case skipped in the default gate.
- scene_schema_tests: 93 passed; script_runtime_compat_test: 85 passed. Origin regressions cover absolute/relative offsets, anchors, missing axes, one loop clock, pause/seek/replay, text/groups, property precedence and relinquishing animation demand.
- MetalSceneDraw.AnAnimatedCurtainRevealsTheWholeCanvasAndStaysOpen: passed for direct and effect-chain layers at initial, intermediate, final and held positions. Compatibility generated-origin-animation independently checks both halves after the curtain exits.
- Installed Into The Abyss [4K]: reproduced the stuck right-side curtain on both backends; after the fix Compatibility at six seconds and Native Metal across 420 frames reveal the full canvas. Native run: 43 render passes/frame, zero blits, 217284608 render-target bytes. These are observations, not a before/after performance benchmark.
- No desktop control, screenshots, wallpaper changes, app restart or audio-device access. Desktop presentation, continuous-playback smoothness and full authored visual parity remain unverified. Concurrent shader/material edits were left intact.

## 2026-10-02 — Correct 2D shader projection and dark lit layers

- Shared LoadMaterial compilation now supplies the authored SCENE_ORTHO value, including effect passes; no brightness multiplier or wallpaper-specific code.
- Original Metal pixel regression covers both projections, direct/effect rendering and unlit colours; passes with the fix and fails with it removed.
- python3 scripts/check_renderer.py with the affected local project: exit 0; all ten generated cases and the local scene have identical pooled/isolated pixels, no diagnostics, and reload cycles pass.
- Renderer asset-dependent cases: two text fixtures and the environment-selected native-project test skipped. The separate native probe reports the affected scene's existing dynamic-lighting fallback to Compatibility.
- Before/after Compatibility probe: 366 executed passes and 845691008 allocated GPU bytes in both runs; restored brightness inspected only in private offscreen frames.
- python3 scripts/test.py: exit 0; Python modules pass, native gate reports 1064 passed, 0 failed, 12 skipped.
- Desktop presentation and exact authored-light parity unverified. Existing PerformLighting_V1 approximation unchanged; no desktop, audio hardware, live library changes or app restart.
- Unrelated concurrent renderer edits appeared during verification; leave them unstaged and defer the Release build rather than package unfinished shared-workspace changes.

## 2026-10-02 — Keep Discover responsive without canvas preview readback

- Live diagnostics: the native main thread remained in its event loop while WebKit logged RemoteImageBuffer_FlushContextSync failure and repeated 15-second FillRect/DrawNativeImage waits. No desktop control or restart was performed.
- Regression red check: python3 scripts/test.py --only ControlPanelDiscoverTests/testDiscoverPreviewsPlayWithoutCanvasReadbackAndReleaseOffscreenImages — failed on the old implementation; 33 canvas requests and neither loaded animation revealed with canvas unavailable.
- python3 scripts/test.py --only ControlPanelDiscoverTests — exit 0; 6 passed, 0 failed, 0 skipped. Covers loaded dark/bright previews without canvas, error fallback, still-first loading, hidden/offscreen release and cached resume.
- python3 scripts/test.py — exit 0; all 17 Python modules passed; native 1064 passed, 0 failed, 12 skipped (3 live-network and 9 opt-in media tests).
- python3 scripts/build.py --swift-only --configuration Release — exit 0; bundled panel.js matches source and codesign --verify --deep --strict passes.
- No renderer changes in this fix; concurrent renderer edits were left untouched. No live GPU-hang reproduction or desktop visual check; installed app not replaced or restarted.

## 2026-10-01 — Sync main download fixes with remote SteamCMD and lock-screen fixes

- Merged origin/main without rewriting existing commits; regenerated the Xcode project with xcodegen generate and preserved both sides of verification history.
- python3 scripts/test.py — passed; 1053 native tests passed, 0 failed, 12 skipped of 1065; all Python test suites passed.
- Uncommitted frame-rate slider changes were stashed and excluded from this gate and merge.
- No desktop run, live Steam sign-in/install, renderer corpus check, or Release build; this was a repository synchronization.

## 2026-10-01 — Steam and pixiv failure diagnosis

- Fixed unknown SteamCMD failures being attributed to credentials; classify compact network/rate-limit result names and log only a safe category.
- pixiv HTTP 403 now explains access denial rather than promising a one-minute wait; HTTP failures log status only, without URLs, cookies or bodies. Updated all four native locales.
- python3 scripts/test.py --only SteamCMDReportedFailureTests --only DownloaderLifecycleTests --only PixivServiceTests: passed 55, failed 0, skipped 0.
- First python3 scripts/test.py: Python passed; native 1036 passed, 1 failed, 11 skipped. WallpaperImportPickerTests/testCancellationReapsThePickerWaitingForASelection exceeded 120 seconds; no picker code changed.
- python3 scripts/test.py --only WallpaperImportPickerTests: passed 5, failed 0, skipped 0; timeout did not reproduce.
- Final python3 scripts/test.py: all 244 Python tests passed; native 1037 passed, 0 failed, 11 skipped (9 opt-in media tests, 2 live Steam tests).
- python3 scripts/build.py --swift-only --configuration Release: succeeded; app not launched or installed.
- The reported user's root cause remains unconfirmed without their diagnostics/network details. No live Steam login, live pixiv access or visual/desktop checks; unrelated workspace edits preserved.

## 2026-10-01 — PR 22 integration with current main

- Merged origin/main at e1fc9e1 into the native SteamCMD PR without rewriting history. The only conflict was the verification log; replayed the two PR-only entries through log_verification.py and asserted that both branches’ historical entries were preserved exactly, with ten active entries.
- `python3 scripts/test.py --only SteamCMDSetupTests --only SteamCMDApprovalTests --only LockScreenWallpaperServiceTests` — exit 0, 91 passed, none skipped.
- Full `python3 scripts/test.py` in the logged-in Aqua session — exit 0; 226 Python tests and 1,047 native tests passed, 12 opt-in skips. Ran the full gate once on the integrated tree.
- Skipped: nine opt-in media tests, two live Workshop-page cases and the live SteamCMD installer. No renderer/corpus, live account/CDN or desktop checks; no Release rebuild or production app restart.
- Resolved in the isolated PR worktree, leaving unrelated original-checkout edits untouched. git diff --check and staged conflict-marker checks passed.

## 2026-10-01 — PR 22 redirect-failure review fixes

- Addressed CodeRabbit and Claude: preserve a rejected redirect’s original failure if URLSession delivers its final response before cancellation; retain the isolated Foundation configuration copy with a narrowly documented SwiftLint force_cast suppression.
- Regression-first check: `python3 scripts/test.py --only SteamCMDSetupTests/testRejectedRedirectRetainsItsFailureWhenFinalResponseArrivesBeforeCancellation` failed before the fix by comparing original versus overwritten error values. It pins no localized wording and uses only URLProtocol fixtures.
- `python3 scripts/test.py --only SteamCMDSetupTests` — exit 0, 41 passed. Full `python3 scripts/test.py` in Aqua — exit 0, 226 Python tests and 1,042 native tests passed, 12 skipped; full gate ran once.
- Skipped: nine opt-in media tests, two live Workshop-page tests and the live SteamCMD install. No live account/CDN, renderer/corpus or desktop checks were run for this small download-delegate fix. SwiftLint is unavailable locally; its suppression was not verified with the lint executable.
- Verification ran on PR 22’s branch in an isolated worktree, leaving concurrent edits in the original checkout untouched. Coverage docs updated; git diff --check clean. No Release rebuild, production app launch/restart, security-setting changes or history rewrite.

## 2026-10-01 — Native Apple silicon SteamCMD package installation

- Full gate: `python3 scripts/test.py` in the logged-in Aqua session — exit 0; 226 Python tests and 1,041 native tests passed, 12 native tests skipped. Ran the full gate once.
- Gate skips: nine opt-in media cases, two live Workshop-page cases, and the opt-in SteamCMD install. Renderer/corpus and desktop/visual checks were not run; no renderer code changed.
- Targeted approval/runtime/downloader/queue/telemetry/WorkshopStore/ControlPanelShell runs with `python3 scripts/test.py --only …` — exit 0, 112 passed; remaining six ControlPanel classes — exit 0, 30 passed.
- `WALLPAPER_MACHINE_NETWORK_TESTS=1 python3 scripts/test.py --only SteamCMDSetupTests --only SteamCMDLiveInstallTests` — exit 0; 41 passed (40 offline setup regressions plus the live native installation), none skipped.
- Live install used temporary support/preferences/approval directories, real CDN packages, per-slice codesign and spctl, and the real native runner. Ready, arm64 resolution and Loading Steam API...OK were asserted; nothing installed into the user’s SteamCMD directory.
- Live checks exposed and fixed HTTP gzip Content-Length versus decoded-byte accounting and quarantined smoke exec being killed. Smoke now uses the downloader’s existing validated disposable-copy path; the installation candidate remains quarantined and policy failures are not bypassed.
- `spctl --assess --type execute --verbose=2` on the quarantined temporary native runtime returned 3 with valid-but-not-an-app, not the earlier sandbox’s internal error. All Mach-O slices verified and steamcmd satisfied Valve’s signing requirement; no system security settings changed.
- Authorized cached-session checks, using copied files and `arch -arm64`: sign-in without secret input, an active license listing app 431960, Workshop item 3773084716 downloaded successfully, and Windows app_update reached downloading then its owned process group was stopped. Temporary session copies were deleted, never written back.
- Localization: all ten changed native keys cover en/ja/zh-Hans/zh-Hant; panel localization passed in the gate. WebUI mechanical detector reported no findings; reinstall confirmation flow was inspected without desktop interaction.
- Owning feature/testing docs updated; Xcode project regenerated by test.py; git diff --check clean. Remaining risks: Valve changing/removing the package manifest and Intel-only copies needing reinstall. No Release rebuild, app launch/install/restart, wallpaper changes, or commit.

## 2026-10-01 — Preserve committed display mapping across lock-screen retry

- The reported timeout → missing display UUID → lock Retry → saver Off transition now invalidates only the lock request cache key, retaining the committed mapping needed for immediate Idle restoration.
- python3 scripts/test.py --only LockScreenWallpaperServiceTests --only LockScreenWallpaperTests — exit 0; 80 passed, 0 failed, 0 skipped. Includes pending lock recovery after the UUID returns without re-enabling the saver.
- python3 scripts/test.py — exit 0; 226 Python cases across 17 modules; native: 1036 passed, 0 failed, 11 skipped of 1047.
- Runtime smoke — temporary CLI linked current production Debug objects without the app entrypoint. With a software-generated silent video and isolated defaults/store, the missing-UUID transition restored original Idle immediately and removed the journal; exit 0. Temporary scaffolding removed.
- Owning feature and coverage documentation updated; relative links checked. No real WallpaperAgent reload, desktop changes, app launch, visual or power verification, or Release rebuild.

## 2026-10-01 — Keep screen saver selected when restored lock-screen activation times out

- Before fix: the restored-preferences regression failed (0 passed, 1 failed); after fix: all 33 LockScreenWallpaperServiceTests passed. The extra LockScreenWallpaperSelectionTests selector matched no class; the full gate below covered LockScreenWallpaperTests.
- python3 scripts/test.py — exit 0; all 17 Python test modules passed; native: 1035 passed, 0 failed, 11 skipped of 1046. Skips: 9 opt-in native-player media cases and 2 live Steam searches.
- Runtime smoke — temporary CLI linked the production Debug service/selection objects without the app entrypoint. A software-generated silent video, isolated defaults and wallpaper-store files exercised timeout retention, saver pause updates, lock disable and exact shutdown restoration; exit 0.
- Shared extension incompatibility, failed Idle-only publication, stale readiness and a later saver renderer failure remain covered by regression tests.
- No real WallpaperAgent reload, desktop changes, app launch, visual lock/idle transitions, or power measurements. The OS cause of the reported post-update missing lock-screen acknowledgement remains unverified; no Release rebuild requested.

## 2026-10-01 — PR 21 recovery journal review fix

- CodeRabbit: cancelled-quit synchronization and verification status findings were already addressed in 69fad27; fixed the remaining linked/inherited journal decoding finding.
- New linked and inherited baseline regressions reproduced both silent failures before the fix (targeted run exit 65); malformed arrays and invalid plist bytes now preserve the store and journal, skip reload, and recover after repair.
- python3 scripts/test.py --only LockScreenWallpaperTests: exit 0; 46 passed, 0 failed, 0 skipped.
- python3 scripts/test.py: exit 0; 226 Python tests and 1,031 native tests passed; 11 skipped (9 optional media and 2 live Workshop tests).
- python3 scripts/build.py --swift-only --configuration Release: exit 0; built the Release app containing the fix.
- Initial verification needed a test-fixture type annotation; sandboxed Xcode test-runner and compiler-plugin failures were resolved by rerunning with approved access outside the sandbox.
- git diff --check: exit 0. No renderer or generated-binding changes; desktop and visual behavior remain unverified. No app launch, install, restart, wallpaper change or live account access.

## 2026-10-01 — PR 21 cancelled-quit poster recovery

- Fixed the Codex review finding: a cancelled quit restarts desktop poster synchronization immediately when native desktop ownership has been released; an owned provider remains protected.
- python3 scripts/test.py --only DesktopWallpaperTests --only LockScreenWallpaperServiceTests: exit 0; 65 passed, 0 failed, 0 skipped. The initial sandboxed attempt failed before tests because Xcode could not launch its Swift macro compiler; the permitted unsandboxed rerun passed.
- python3 scripts/test.py: exit 0; 226 Python tests and 1029 native tests passed, 0 failed; 11 optional cases skipped (9 media, 2 live Workshop).
- python3 scripts/build.py --swift-only --configuration Release: exit 0; built the Release app after the gate.
- git diff --check: exit 0. No renderer or generated-binding changes.
- The real AppKit cancelled-quit flow and visual desktop behavior were not exercised; no desktop control, app launch, install, or restart.

## 2026-10-01 — Integrate wallpaper recovery and Steam ownership fixes with main

- Merged the latest remote main without rewriting the five local feature/fix commits; preserved both branches of verification history while resolving log conflicts.
- python3 scripts/build.py --renderer-only --configuration Release: passed; regenerated the renderer bindings required by the incoming main branch.
- python3 scripts/test.py: passed; 226 Python and 1,029 native tests passed, 0 failed, 11 skipped (9 opt-in media and 2 live Workshop tests).
- python3 scripts/check_renderer.py: passed; all renderer binaries exited 0, all 10 synthetic scenes matched between pooled and isolated runs with no diagnostics, and 8 projects passed two reload cycles.
- Renderer asset-dependent checks skipped: the two private text-scene regressions and the environment-selected native Metal project corpus. Authored visual compatibility was not established.
- python3 scripts/build.py --configuration Release: passed; strict deep codesign verification passed.
- Under prior authorization, removed the test-generated Debug extension registration and registered the rebuilt Release copy; pluginkit listed only Release.
- The user confirmed the preceding wallpaper fix works. Live desktop, lock-screen, saver, and quit behavior of the merged build were not retested; no automatic app restart was performed.

## 2026-10-01 — Keep inherited native display choices complete

- Read-only WallpaperAgent logs identified DecodingError.keyNotFound for Idle in a synthesized Space display override; macOS rejected the entire Index before launching the extension. Enabling both modes filled the missing field and succeeded.
- Synthesized individual display nodes now resolve and journal both inherited choices, preserve the inactive mode, and return to inheritance on disable/recovery unless an external edit must survive.
- python3 scripts/test.py --only LockScreenWallpaperTests --only LockScreenWallpaperServiceTests: 73 passed, 0 failed.
- python3 scripts/test.py: passed; 226 Python and 921 native tests passed, 0 failed, 11 skipped (9 opt-in media and 2 live Workshop tests).
- python3 scripts/build.py --swift-only --configuration Release: passed; codesign --verify --deep --strict also passed.
- Under existing user authorization, unregistered the test-produced Debug extension and registered Release; pluginkit confirmed only Release remained.
- Regression fixtures cover linked/individual inheritance, missing top-level and per-Space nodes, either mode alone, mode transitions, exact crash recovery, external edits, and failed reloads.
- Live standalone lock-screen playback and quit restoration on the rebuilt app remain unverified; no app restart, desktop control, or wallpaper change was performed.

## 2026-10-01 — Support the macOS linked default wallpaper

- Updated native selection to accept the built-in linked default, suppress only requested global Desktop/Idle overrides, and restore linked or inherited originals while preserving external edits.
- Focused LockScreenWallpaperTests and LockScreenWallpaperServiceTests: 69 passed after fixing metadata restoration; the added legacy-journal case also passed in the full gate.
- python3 scripts/test.py: passed; 226 Python tests and 918 native tests passed, 0 failed, 11 skipped (9 opt-in native-media tests and 2 live Workshop tests).
- python3 scripts/build.py --swift-only --configuration Release: passed; delivered the updated Release app.
- codesign --verify --deep --strict on the Release app: passed.
- Under existing user approval, unregistered the Debug extension produced by testing and registered Release; pluginkit listed only the Release extension afterward.
- Regression fixtures cover both activation orders, partial disable, crash/reload recovery, copied fallbacks, external choices and metadata, and legacy global journals.
- Live lock-screen/screen-saver rendering, idle transitions, sleep/wake, and quit restoration remain unverified; no desktop control or wallpaper changes were performed.

## 2026-10-01 — Wait for native-provider and desktop-poster restoration on quit

- python3 scripts/test.py --only DesktopWallpaperTests --only LockScreenWallpaperServiceTests — exit 0; 64 passed, 0 failed, 0 skipped.
- python3 scripts/test.py — exit 0; 226 Python tests passed; 910 native tests passed, 0 failed, 11 skipped of 921.
- Skipped: nine opt-in NativeVideoPlayerMediaTests and two live WorkshopTests. Renderer code unchanged; no renderer corpus checks.
- Fixtures cover persisted posters temporarily invisible during native reload, delayed original persistence, retained journals, failed quit with retry, external choices during the wait, and ordered Desktop/Idle plus poster restoration.
- python3 scripts/build.py --swift-only --configuration Release — exit 0; Release app built. codesign --verify --deep --strict — exit 0.
- git diff --check — exit 0. Read-only logs showed rejected desktop writes and extension copies loaded from installed and Debug apps. No live wallpaper changes, application restarts, or extension registration changes were performed.
- Visual desktop restoration with an active native provider remains unverified; the separate extension-copy conflict remains unresolved.

## 2026-10-01 — Preserve recoverable originals before desktop poster writes

- python3 scripts/test.py --only DesktopWallpaperTests — exit 0; 32 passed, 0 failed, 0 skipped.
- python3 scripts/test.py — exit 0; 226 Python tests passed; 904 native tests passed, 0 failed, 11 skipped of 915.
- Skipped: nine opt-in NativeVideoPlayerMediaTests and two live WorkshopTests; no renderer changes or renderer corpus checks.
- Regression fixtures cover effective wallpaper capture before any write, independent display and Space originals, refusal to replace unresolved originals, and repair/relaunch recovery of legacy empty journals even with unchanged frames.
- Read-only inspection confirmed empty inherited originals in the existing desktop journal; no wallpaper settings were modified. Such journals need a fresh user selection when no original survives.
- git diff --check — exit 0. Desktop appearance and actual macOS restoration remain unverified; no desktop control or Release rebuild.

## 2026-10-01 — Welcome guide Wallpaper Engine ownership check

- python3 scripts/test.py --only DownloaderLifecycleTests — exit 0; 24 passed, 0 failed, 0 skipped. Covers owned, missing and unknown license responses, complete app IDs, session reset and no downloads during sign-in.
- python3 scripts/test.py --only ControlPanelShellTests/testWelcomeOwnershipNoticeAllowsContinuingAndRecheckingAfterPurchase — exit 0; 1 passed. Offscreen guide covers purchase links, unconfirmed results, continuing setup and rechecking after purchase.
- python3 scripts/test.py — exit 0; 226 Python tests passed; native gate 901 passed, 0 failed, 11 skipped of 912. Skips: 9 opt-in media tests and 2 live Workshop tests.
- Impeccable detector on WebUI/welcome.js — exit 0; no findings. git diff --check — exit 0. Added strings cover all shipped languages.
- Live Steam authentication and license responses, desktop presentation and visual appearance remain unverified; synthetic PTY fixtures and offscreen WebKit only. Release app not rebuilt.
- python3 scripts/clean.py --dry-run — exit 0; existing shared artifacts retained to avoid removing unrelated evidence.

## 2026-10-01 — Bounded HDR and interactive scene compatibility

- User selected a general bounded bloom model rather than claiming exact proprietary Wallpaper Engine HDR parameter parity. No wallpaper-specific rendering branches or private asset edits.
- cargo test --release -p shader --features ffi with the build cargo environment: exit 0; 522 passed. Fourth-channel metadata and disabled-slot behavior covered.
- Targeted CMake build and text/script/mouse/scene/texture suites: exit 0; 60, 84, 13, 89 and 22 passed respectively; two opt-in local text cases skipped. Particle suite: 41 passed. Diagnostic dumper library compiled.
- GPU HDR filters: four passed, including real TEX bit23 emissive radiance through effects/linked layers, SDR preservation, missing-source rejection, bounded spread, live strength changes and zero halo strength.
- Installed perspective scene: both Metal and Compatibility completed 1200/2400 frames at 1/60 and 1/120 simulation steps, 1680x1050, synthetic clock click/hover entry/exit and broadband audio. Sampled script errors zero; menu and overlay transitions, moving bars/waves and numeric readouts verified.
- Full-resolution scenarios: Native Metal 1200 frames and Compatibility 2400 frames at 3840x2160 completed; sampled input transitions and script errors passed. Offscreen frames visually inspected; no desktop capture or audio hardware used.
- Native drawFrame CPU means: 0.60 ms at 1680x1050, 0.59 ms at 3840x2160. These exclude script tick/GPU/display cadence and are not FPS or power claims; HDR half-float target cost is documented, with no forced supersampling.
- python3 scripts/test.py --serial: exit 0; all 17 Python modules passed; native 883 passed, zero failed, 11 opt-in skips of 894.
- python3 scripts/check_renderer.py: isolated final run exit 0; all renderer executables passed, ten generated pooled/isolated comparisons equal with zero diagnostics, eight projects reloaded twice. Three default opt-in asset checks skipped; target scene exercised separately. Earlier concurrent run failed one baseline video-frame timing assertion; retained assertion passed on the isolated full rerun.
- Documentation links and provenance JSON checked. No Release app rebuild, launch/restart, live settings changes or desktop input. Exact Windows visual equivalence, physical presentation cadence and power effects remain unverified.

## 2026-10-01 — Lock-screen extension mismatch diagnostics

- Added revision-scoped extension identity, schema-version and configuration-load diagnostics; legacy extension copies are identified by running bundle path after readiness timeout.
- python3 scripts/test.py --only LockScreenExtensionDiagnosticsTests --only LockScreenWallpaperServiceTests: exit 0; 31 passed before the final screen-saver monitor regression was added.
- python3 scripts/test.py: exit 0; all 226 Python tests passed; native gate 898 passed, 0 failed, 11 skipped of 909. Includes all 10 new diagnostic regressions.
- Native skips: nine opt-in media/device tests and two live Workshop network tests. No asset-dependent renderer checks were run; renderer and bridge were unchanged by this task.
- Covered incompatible schema before scene decoding, missing/malformed configuration, stale revisions, same-bundle symlinks, configuration success without frame readiness, failed diagnostic writes, legacy timeout restoration and later screen-saver configuration failure.
- git diff --check: exit 0. XcodeGen regenerated the project through test.py; native localization checks passed in the gate.
- python3 scripts/clean.py --dry-run: exit 0; broad cleanup deferred to preserve the shared workspace renderer evidence under artifacts.
- No Release rebuild, app restart, registration changes or desktop tests. Live extension selection and lock-screen visuals remain unverified.

## 2026-10-01 — PR 19 backup and preset review fixes

- `python3 scripts/build.py --renderer-only` — passed; rebuilt the isolated worktree’s missing current bridge library and regenerated unchanged bindings after the first targeted run could not link.
- `python3 scripts/test.py --only WallpaperBackupTests --only WallpaperPresetStoreTests --only ControlPanelBackupFlowTests` — passed, 50 tests; an earlier run exposed volatile-default cleanup in the new fixture, corrected before this run.
- `python3 scripts/test.py` — passed once as the final gate: all Python checks passed; 1006 native tests passed, 0 failed, 11 opt-in media/network cases skipped.
- Regressions cover persistent-only preference export/conflicts/rollback, a 48 MiB preset archive, manifest rejection before payload reads while preserving an existing destination, and preset directory roundtrips with hidden Finder metadata.
- The WebUI mechanical detector reported no findings; `git diff --check` passed. No renderer source or generated-binding changes.
- No Release app build, desktop/window-driving, visual presentation, audio hardware or live-account verification. The shared main checkout’s existing commit and uncommitted edits were not changed.

## 2026-10-01 — Reusable wallpaper workflows rebased onto 1.2.1

- Implementation: local collections and named playlist plans, wallpaper property presets, staged local backup/restore, per-display still-image placement, compatibility cards, Shortcuts display selection, and Web page mute/native HTML-media gain; all four UI languages updated.
- Fetched origin and rebased feat/library-workflows-and-web-audio onto main a5200fe; preserved remote import-picker startup, screen-saver/renderer updates, localization and historical verification records. Regenerated Xcode project and UniFFI outputs rather than editing generated conflicts.
- Scene restore security: scene/scenetexture overrides and texture defaults now resolve to validated retained image files instead of unapproved original paths. A keep-existing tree without matching bytes is rejected before publication. WallpaperBackupTests: 24 passed before rebase; included again in the rebased full gate.
- python3 scripts/build.py --renderer-only — exit 0 after rebase; renderer library and Swift bindings regenerated. No Release app build.
- cargo test -p wallpaper-bridge with scripts/build.py cargo_environment — exit 0 after rebase; 363 passed, 0 failed.
- python3 scripts/check_renderer.py — rebuilt current renderer probes, exit 0; 10 generated scene pixel comparisons and 8 projects x2 reload cycles passed. Three local-asset-dependent cases skipped; no full authored-wallpaper compatibility claim.
- python3 scripts/test.py — exit 0 after rebase; all Python checks passed, 1002 native tests passed, 0 failed, 11 opt-in media/network tests skipped of 1013.
- Before rebase: six temporary real offscreen WKWebView feature flows passed and were removed after retaining focused regressions; renderer draft/metadata and synthetic pointer-capture boundaries were injected. Native WebKit output probe invoked media gain and read back mute false→true→false without audio hardware.
- Desktop/visual presentation, actual speaker output, live account services, Siri/Shortcuts UI and power remain unverified. No app launch, permission prompt, wallpaper change, install or restart.

## 2026-10-18 — Solar settings restore and automatic location

PR #56 and #57 repairs: solar backup compatibility, location lifecycle and localized permission resources.

- Rebuilt the unchanged shared PR renderer and bindings with python3 scripts/build.py --renderer-only; exit 0.
- PR #56 targeted native tests: 57 passed, 0 failed. Full python3 scripts/test.py: 3864 passed, 0 failed, 45 skipped.
- PR #57 targeted native tests: 68 passed, 0 failed. Full python3 scripts/test.py: 3877 passed, 0 failed, 45 skipped; all Python modules passed.
- New regressions exercise real backup restore and rollback, fake location source/authorization transitions, panel actions and compiled permission resources in every shipped language.
- The 45 media/device and live-network tests remain opt-in and were skipped. No desktop interaction, real location permission request, Release build or installed-app launch/replacement was performed.

