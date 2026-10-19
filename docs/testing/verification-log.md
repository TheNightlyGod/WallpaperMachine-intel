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

## 2026-10-19 — Korean release notes for 1.5.7

- Release-note generation and bundled history now support English, Simplified Chinese and Korean; pre-1.5.7 sections stay unchanged and Korean falls back to English for legacy entries.
- `python3 scripts/tests/test_release_notes.py` — exit 0; 74 tests passed, covering generation, validation, legacy reuse and English-only publication.
- `python3 scripts/test.py --only WhatsNewTests --only AppUpdateTests` — exit 0; 70 passed, no failures or skips.
- The first full gate failed two playback timing assertions; the second failed a live GPU-energy assertion. Their focused reruns passed (70 playback tests, 13 energy tests); no assertions or tests were changed or disabled.
- `python3 scripts/test.py` final retry — exit 0; 361 Python tests, 3897 native passed, 0 failed, 45 opt-in network/media tests skipped.
- Checked documentation links, identical historical changelog sections, the 1.5.6 → 1.5.7 notes range, and absence of 1.5.7 banner files after the requested removal.
- No desktop smoke test, app launch, live Steam/media checks or renderer/Rust checks; visual behavior remains unverified. Release versioning and publication use CI, not hand-edited version files.

## 2026-10-19 — Korean localization (#59)

- Catalog coverage: 2,185 Korean translations across app (2,118), permission/InfoPlist (16), and extension (51) catalogs; existing languages unchanged. Reviewed all 2,146 distinct entries and corrected terminology/context mismatches.
- \`python3 scripts/test.py --only AppLanguageTests\` before implementation — expected failure: Korean system matching and Wallpaper Engine locale mapping were absent.
- Targeted \`scripts/test.py --only …\` localization, settings, properties and Korean offscreen-layout run — exit 0; 76 passed, no skips.
- \`python3 scripts/test.py\` — exit 0; 350 Python tests passed; 3,889 native tests passed, 45 opt-in media/network tests skipped, no failures.
- \`python3 scripts/build.py --swift-only --configuration Release\` — exit 0; app and embedded extension built. All 2,185 compiled Korean strings checked against their source catalogs.
- Changed documentation links resolve; \`git diff --check\` passed. No desktop or visual run, permission prompts, live account checks or renderer comparison; renderer code unchanged.

## 2026-10-19 — Media integration enabled by default

- New wallpapers and configurations without a saved media choice enable integration; saved false/true values, preview isolation and lock-screen disabling are preserved.
- Targeted cargo test --release --locked -p wallpaper-bridge --lib tests::web_audio_media: 30 passed; config::store::tests::media_integration: 1 passed, covering saved-choice round trips.
- python3 scripts/check_rust.py --output artifacts/media-integration-default/rust: exit 0 for core, bridge, core integration and shader checks; 9 desktop/corpus exclusions and 5 missing shader-asset checks remain unverified.
- python3 scripts/check_renderer.py: exit 0; all registered binaries passed, 12 pooled/isolated generated cases matched with no diagnostics, reload cycles passed; external-corpus checks skipped.
- python3 scripts/build.py --renderer-only: exit 0; regenerated Swift bindings from the bridge documentation.
- python3 scripts/test.py --only InspectorFlowTests --only PanelPropertyRowsTests --only PanelWallpaperSettingsTests: 56 passed, 0 failed.
- python3 scripts/test.py: Python script suites passed; native gate 3887 passed, 0 failed, 45 skipped.
- python3 scripts/build.py --configuration Release: exit 0; app built without launching or installing it.
- No live media player, desktop UI, permission prompt or Wallpaper Engine frame comparison was exercised.

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
