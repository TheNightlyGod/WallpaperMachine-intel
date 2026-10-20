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

## 2026-10-20 — Cover slots over another layer's picture; effect and keyed-constant script objects

A cover slot whose authored texture is another layer's composite now shows that composite until a cover is published, on both renderers, and property scripts get Wallpaper Engine's thisObject for an effect's visibility and for a keyed shader constant's own timeline. Found on a local music-player wallpaper whose blurred cover background rendered as the clear colour.

- `python3 scripts/check_renderer.py` — exit 0; every registered binary exit 0, the new MetalSceneDraw.ACoverOverAnotherLayersPictureShowsThatPictureUntilACoverArrivesOnBothRenderers, SceneSchema.AnEffectsVisibilityScriptSwitchesTheEffectAndNotItsLayer and .AKeyedConstantsScriptPlaysTheConstantsOwnTimeline included; generated cases pixel-equal pooled and isolated; reload probe 0
- `python3 scripts/build.py --renderer-only` — exit 0; App/Bridge/Generated unchanged
- `python3 scripts/test.py` — exit 0; 3944 tests: 3899 passed, 45 skipped
- The three new tests fail with the fixes reverted: the idle, cleared and first-track cover cases draw nothing on both renderers, a cover published mid-run is never shown without the pass marked as reading a runtime image, the effect's script hides its layer, and the keyed constant stays on its first key
- Headless Native Metal probe of the wallpaper at 1720x720, display resolution, with media events and a published cover: the background is a blurred, darkened copy of the cover; with nothing playing it is the default art blurred and the player shows that art; the 21:9 layout option fills the width; the 16:9 option leaves dark side bars on a 21:9 surface, as authored
- Local library: the 14 effect-visibility scripts in 16 scenes use thisObject only for visible
- Not compared with Wallpaper Engine's own frame: the reference VM is unavailable

## 2026-10-20 — Layer composites carry what their effects made

Fixes an audio-visualizer media player whose bars never moved: its spectrum buffer is a hidden layer 64 wide and 0 high whose composite stayed empty. A card with no area that draws into targets of its own now fills them and draws only there, and a chain's last pass writes into its layer's own composite instead of blending into it.

- `metal_scene_draw_smoke --gtest_filter=*NoAreaFills*` — new case fails with either change removed (empty composite, then colour times 0.25), passes with both
- `python3 scripts/check_renderer.py` — first run exit 1: `UnchangedPresent.APlainVideoPresentsEveryNewFrameAndNothingElse` at load average 108; the case alone passed 3/3 at load 12; `--skip-build` rerun exit 0, 24 asset or environment skips
- `python3 scripts/build.py --renderer-only` — exit 0; bindings unchanged
- `python3 scripts/test.py` — exit 0; 3899 passed, 0 failed, 45 skipped of 3944
- Local audio-visualizer scene, 240 frames at 1720x720 with synthetic noise and the app's media events: the buffer layer's composite went from empty to the accumulated spectrum; the bars on the cover now move with audio; nothing else on the frame changed under the same input
- Not compared with Wallpaper Engine's frame: the Parallels reference VM could not be resumed (activation expired)
- Gap: the scene's blurred cover background still draws as the clear colour in the probe; not investigated further. Gap: no desktop run; the app was not rebuilt for Release

## 2026-10-20 — SceneScript start-up order, init values and sound layers

Fixes a music-player widget that sat misaligned and then faded out. Four general script mechanisms: authored names of layers under generated keys are recorded before any script compiles; every property script runs init before any is told the user properties; what init returns becomes the property's value (same kind only); sound objects are layers scripts list and play.

- `scene_schema_tests` — 5 cases (LayersWithScriptsOfTheirOwnCarryTheirAuthoredNameUnderGeneratedKeys, EveryScriptRunsInitBeforeAnyIsToldTheUserProperties, WhatInitReturnsIsThePropertysValue, ScriptsListSoundLayersInTheScenesOrderAndPlayThem, plus the existing authored-name case) pass; the four new ones fail with the source changes removed
- `python3 scripts/check_renderer.py` — exit 0; generated scenes pixel-equal pooled/isolated, 8 reload cycles clean; 24 asset- or environment-dependent cases skipped
- `python3 scripts/build.py --renderer-only` — exit 0; generated bindings unchanged
- `python3 scripts/test.py` — exit 0; 3899 passed, 0 failed, 45 skipped of 3944
- `metal_scene_draw_smoke` on a local music-player scene, 600 frames at 1920x1080: script errors 1 → 0; the cover moves with the player, the player stays shown at 10 s (it had faded out), the track plays, the drag handle is hidden
- Not compared with Wallpaper Engine's frame: the Parallels reference VM could not be resumed (activation expired)
- Gap: with nothing playing, the first-tick idle media state (empty title) makes the widget's title read "-"; unchanged and unverified against Wallpaper Engine
- Gap: no desktop run; the app was not rebuilt for Release

## 2026-10-20 — Issue #61: height fog, model rotation and blur parity

- Generic height-fog pixel regression failed before the fix and passed afterward; property-selected ambient/skylight pixels and three local-rotation regressions pass.
- Scalar swizzle and nested texture-to-scalar shader regressions compile for SPIR-V and Metal; obsolete duplicate scalar sampling rewrite and source-wording tests removed.
- python3 scripts/check_renderer.py — final exit 0; GPU and real-time checks enabled, all twelve generated pixel comparisons and reload cycles pass. Optional local-corpus checks skipped.
- python3 scripts/check_rust.py with installed SceneAssets — exit 0; core, bridge, integration and shader checks pass. Two unavailable private shader fixtures skipped; desktop/corpus exclusions remain explicit.
- python3 scripts/test.py — Python checks pass; native verdict 3897 passed, 0 failed, 45 skipped.
- scripts/we_reference.py capture/render/compare — Wallpaper Engine in Parallels versus native Metal, 3456x2092 at 8.04 s and 15.26 s, identical assembled preset; work-area mean pixel errors 74.80 -> 1.84 and 64.44 -> 1.99 (0-255).
- Both comparison sheets inspected: shading, animated geometry and blur restored; residual moving-edge offsets and Windows activation watermark remain. Final native runs have no shader compilation, translation, effect-load or SceneScript failures.
- Wallpaper Engine kept muted; VM suspended after capture. Native verification was offscreen; Mac desktop presentation was not exercised. Release app not rebuilt.

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
