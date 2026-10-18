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

## 2026-10-18 — Resume each display from the current playback policy

The presentation policy reconciles per-display visibility during global transitions and retries pending delivery once per evaluation. The bridge corrects retained runtime pause on its actor using current policy, including unchanged refresh and Apply paths.

- Before the fixes, the retained per-display pause regression failed in Rust; three wake/unlock/settlement regressions and the mixed-visibility retry regression failed in native tests.
- `python3 scripts/test.py --only WallpaperPresentationPolicyTests --only PlaybackPolicyCompositionTests` — final run: 63 passed, 0 failed, 0 skipped; bridge `display_presentation` targeted tests: 13 passed.
- `python3 scripts/build.py --renderer-only` — exit 0; renderer library and generated bindings rebuilt. No public API or schema changed; no Release app build.
- `python3 scripts/test.py` — final unchanged rerun: 350 Python tests passed; 3,856 native passed, 0 failed, 45 opt-in skips.
- The first full native run had 3,855 passed, 1 failed and 45 skipped: `WebWallpaperPageTests/testRefusedOrReplacedNavigationDoesNotFailTheWallpaper` reported “Cannot open file”. The unchanged targeted rerun passed, then the unchanged full rerun passed. Cause not established; the initial failure is not treated as a passing run.
- `python3 scripts/check_rust.py --output artifacts/multi-display-playback/rust` — exit 0: core 315, bridge 604, integrations 16, shader 580; nine desktop/corpus exclusions and five emitted shader-asset skips remain unverified.
- `python3 scripts/check_renderer.py` — exit 0: 47 registered binaries passed, 12 pooled/isolated pixel cases matched with expected pixels and no diagnostics, 8 projects × 2 reload cycles passed; GPU and realtime checks executed. Nine external-corpus cases skipped.
- Changed documentation links, provenance JSON and `git diff --check` passed. No desktop control, real multi-monitor playback check, Wallpaper Engine frame comparison, installation or app restart; task logs, result bundles and generated probe output removed after review.

## 2026-10-17 — Steam Community sign-in kept and subscriptions import

- python3 scripts/test.py: 3843 passed, 0 failed, 45 skipped (Python, XcodeGen, native).
- New: SteamWebSessionTests, WorkshopSourceTests (keychain round trip with a memory store, renewal before a read, refused renewal), SupportPromptStoreTests (subscriptions offer), PanelWorkshopSubscriptionsTests (import, guide card, offer).
- Renewal endpoint shape probed once with a dummy token: form-encoded POST accepted, refusal is an empty response with x-eresult 15.
- Gap: no live Steam Community sign-in; that WebKit exposes steamRefresh_steam and that GenerateAccessTokenForApp accepts a browser token are unverified. Without the refresh cookie the saved session lasts as long as steamLoginSecure.
- Gap: guide card and offer sheet not checked visually; the real keychain store is not exercised by tests.

## 2026-10-17 — Wallpaper Engine reference frames from the Parallels VM

New scripts/we_reference.py (capture, render, compare) and the rule that a wallpaper fix is judged against Wallpaper Engine's own frame. Checked end to end on the developer's Parallels Desktop Standard VM (Windows 11, arm64) on 2026-10-17.

- `python3 scripts/test.py` — exit 0; 3877 tests: 3832 passed, 45 skipped, 0 failed (10 new in `scripts/tests/test_we_reference.py`)
- `we_reference.py capture 2850003448 2440387496` in the VM — both captured: Wallpaper Engine started and muted by the worker, two 3456x2024 shots each with recorded times (10.2/30.0 s and 8.0/15.3 s after opening)
- `render` + `compare` with a freshly built `metal_scene_draw_smoke` — mean difference 1.0 (2850003448) and 2.7 (2440387496, whose monitor screen we draw smaller than Wallpaper Engine; not fixed here)
- Same scenes, Wallpaper Engine frames of 2026-10-14 vs 2026-10-17 — mean difference 0.2 to 1.0, brightness correlation 0.98 to 0.99 (the noise floor in the doc)
- Not run: `check_renderer.py`, `check_rust.py` (no renderer or crate change); no Release build (no app change)

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
