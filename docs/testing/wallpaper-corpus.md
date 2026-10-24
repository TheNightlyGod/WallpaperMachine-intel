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
| `WALLPAPER_MACHINE_ASSETS_ROOT` | `~/Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets` | Wallpaper Engine's shipped `assets/shaders` (`Renderer/Shader/tests/corpus.rs` and the sweeps under `Renderer/Shader/src/*/tests/`, `shader_corpus_test`, and the bridge at runtime) |
| `WALLPAPER_MACHINE_UNPACK_ROOT` | `Renderer/unpack` | shaders unpacked from workshop packages, one `<id>/` folder each (the on-request corpus sweep in `shader_corpus_test`; the `Renderer/Shader` tests read workshop shaders unpacked under `artifacts/p5/workshop-shaders/<id>/shaders/` instead) |
| `WALLPAPER_MACHINE_VIDEO_ROOT` | `~/Library/Application Support/WallpaperMachine/Library` | video files (`.mp4`/`.m4v`/`.mov`, `.webm`/`.mkv`) the container readers' A/B checks compare with `ffprobe` (`media_isobmff_tests`, `media_matroska_tests`; `WALLPAPER_MACHINE_FFPROBE` overrides the `ffprobe` path); `video_probe_test` reads the `.tex` files under the same root, probes every embedded video payload in memory with the project's own readers and opens each one with the native backend, printing the payloads that are declined or not played with their reason |
| `WALLPAPER_MACHINE_WORKSHOP_ROOT` | `Renderer/Engine/workshop` | packed workshop items, one `<id>/scene.pkg` each, such as the app's `Library` folder (`workshop_corpus_stamps_test`) |

A skipped case is **not** a passing case. From `Renderer/`, run
`cargo test --release --locked -p wm-shader --features ffi --test corpus -- --nocapture`
(`Renderer/Shader/tests/corpus.rs`; the same flags with `--test metal_compile` for the
Metal compile of the shipped and workshop shaders) and read the `skipped: …`
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
