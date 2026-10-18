# Local wallpaper regression corpus

A selection checklist for the private wallpapers that catch renderer regressions
synthetic fixtures cannot. The corpus is optional and machine-specific: it is
**not a test suite**, a case with no asset is unverified, and offscreen results
say nothing about desktop behavior (see
[README.md](README.md#what-verified-means)). The generated scene matrix in
`scripts/check_renderer.py` needs no private assets; the checks themselves, the
probe environment variables and known shader limitations are in
[renderer.md](renderer.md). What has actually been run is in
[verification-log.md](verification-log.md).

## Keeping private assets out of Git

Two paths are Git-ignored for this purpose:

- `wallpaper-corpus/` — copies of the assets you own or have permission to use.
- `docs/testing/wallpaper-corpus.local.md` — your inventory: local paths, hashes,
  provenance, usage restrictions.

Do not keep the inventory under `artifacts/`; `python3 scripts/clean.py` deletes
it. Local paths, SHA-256 hashes and diagnostics never go into this public
document or a tracked doc. `scripts/check_renderer.py` writes the paths and
hashes it saw to `artifacts/renderer/<run>/report.json`, which is disposable.
Do not reuse real imports for destructive or invalid-input tests; use copies.

## Pointing the tests at your local corpus

Corpus-dependent tests resolve their roots from the environment and **skip with
a printed reason** when the assets are absent, so a clean checkout runs green on
any machine. Never hardcode a home directory in a test.

| Variable | Default | Used by |
| --- | --- | --- |
| `WALLPAPER_MACHINE_ASSETS_ROOT` | `~/Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets` | Wallpaper Engine's shipped `assets/shaders` (`crates/shader/tests/pipeline.rs`, `unpack_shader_compile_smoke`, and the bridge at runtime) |
| `WALLPAPER_MACHINE_UNPACK_ROOT` | `upstream/renderer/unpack` | shaders unpacked from workshop packages, one `<id>/` folder each (`pipeline.rs`, and the on-request corpus sweep in `unpack_shader_compile_smoke`) |
| `WALLPAPER_MACHINE_WORKSHOP_ROOT` | `upstream/renderer/external/open-wallpaper-engine/workshop` | packed workshop items, one `<id>/scene.pkg` each, such as the app's `Library` folder (`version_tests`) |

A skipped case is **not** a passing case. From `upstream/renderer`, run
`cargo test -p shader --test pipeline -- --nocapture` and read the `skipping …`
lines to see exactly which files are missing before claiming shader coverage.
Scene projects go through `python3 scripts/check_renderer.py --project
<path/to/project.json>` (repeatable; `--assets` points at the shared scene
assets), which compares pooled and isolated allocation pixel for pixel.

## Cases

The table is what to select and what to check, not a record of what passed.

| Case | Asset to select | Expected checks |
| --- | --- | --- |
| video-basic | Short ordinary video, known dimensions and colors | Playback, fill/match/stretch, orientation, pause/resume |
| scene-basic | Acheron Black Hole | Pooled/isolated allocation pixel equality |
| scene-effects | Sparkle multi-character scene | Pooled/isolated equality; paused effect timeline; blink geometry |
| scene-text-script | Lonely Cat | Fonts, clock/date, pooled/isolated allocation pixel equality |
| generated-composites | The generated scenes built into `check_renderer.py` | Transparent input, nested children, hidden parents, transforms, order, pixel assertions; no private assets |
| scene-audio | Audio-responsive scene | Response to authorized test audio, quiet-input behavior |
| invalid-input | Disposable malformed package and missing-resource copy | Useful error, no crash, subsequent valid apply succeeds |

## Inventory entry per asset

- Stable case ID, source URL or provenance, usage/license restrictions.
- Package hash (or a file-hash inventory for directory assets) and asset version.
- Local project path and required scene assets; never account credentials.
- Expected appearance, playback behavior, known unsupported features.
- Reference evidence source: a previous build is a baseline, not proof of
  correctness.

## Record of an authorized desktop run

Desktop runs require explicit authorization; the boundary is in
[README.md](README.md#authorization-boundary) and the checklist in
[manual-smoke.md](manual-smoke.md). The verification-log entry for a run states:

- Date, source revision and dirty state, app version, macOS and hardware.
- Case IDs, displays and Spaces, scaling, FPS settings, audio and power
  conditions.
- Cold/warm cache state, load time, frame timing, CPU/GPU/memory observations.
- Pass, fail or unverified per check, what was exercised, and the restoration
  outcome. Describe the run; do not cite `artifacts/` or `build/` paths.
