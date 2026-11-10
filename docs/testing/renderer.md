# Renderer verification

Non-desktop verification of the renderer in `Renderer/`: the
Rust crates, the C++ scene engine and its GPU probes. Nothing here creates a
window, swapchain, audio device, or screenshot, and nothing here inspects or
changes the desktop. What "verified" means and which checks a change needs are
in [README.md](README.md); dated results live in
[verification-log.md](verification-log.md); this file is the working reference.

## `scripts/check_renderer.py`

```sh
python3 scripts/check_renderer.py
```

It assembles the Homebrew environment from `scripts/build.py`, then:

1. builds `cargo build -p wm-shader --features ffi --release --locked` **from
   `Renderer/`** (the Rust workspace), because rustup resolves that
   tree's `rust-toolchain.toml` (a pinned stable release) from the working directory, not from
   `--manifest-path`; running it from the repository root picks the default
   stable toolchain instead,
2. configures CMake over `Renderer/Engine` with
   `CMAKE_BUILD_TYPE=Release`, `BUILD_TESTS=ON`, `RUST_SHADER_FFI=ON`, and
   `RUST_SHADER_STATICLIB` pointing at `Renderer/target/release/libwm_shader.a`,
3. builds `offscreen_scene_probe`, `scene_reload_cycle_probe`, the separately
   reported `timer_delivery_benchmark`, and every target in `REGRESSION_BINARIES`,
   the registry that drives regression build, run and verdict,
4. runs the registered binaries, recording failures, timeouts and explicit skips,
5. runs the timer-delivery diagnostic once, preserving its raw measurements and
   reporting tooling failures without a numeric throughput acceptance threshold,
6. renders every generated case and every `--project` twice through
   `offscreen_scene_probe` — once pooled, once isolated (`WE_TEST_NO_REUSE=1`) —
   and compares `frame-2` byte for byte,
7. scans both logs for `ERROR` diagnostics (ignoring shader-cache misses),
8. checks independent known-pixel assertions for the generated cases, so two
   equally blank or corrupt outputs cannot both pass,
9. runs `scene_reload_cycle_probe` over the selected projects (the `--project`
   inputs, or the generated cases without any) twice each.

| Flag | Effect |
| --- | --- |
| `--skip-build` | Reuse the existing binaries instead of rebuilding |
| `--project PATH` | Add a local scene `project.json`; repeatable |
| `--assets PATH` | Shared assets directory for `--project` inputs (default `~/Library/Application Support/WallpaperMachine/SceneAssets`) |
| `--allow-missing-gpu` | CI fallback only: compile a Metal-device probe; its exact exit 77 skips the GPU targets flagged in `REGRESSION_BINARIES` plus the image and reload probes. Compile errors, abnormal exits and timeouts still fail. Default local runs require GPU checks. |
| `--allow-imprecise-timers` | CI fallback only: compile a timer probe that takes the median of 31 condition-variable waits of 10 ms; its exact exit 77 (median above 15 ms; a Mac measures about 12 ms, hosted VMs 18 ms and more) filters the cadence tests named in `REALTIME_TESTS` out of their binaries. Compile errors, abnormal exits and timeouts still fail. Default local runs require every cadence test. |

Reports, SHA-256 hashes, logs, the generated synthetic fixtures and private GPU
output go under a fresh `artifacts/renderer/adaptive-<timestamp>/` directory,
with `report.json` as the summary; check binaries live in
`artifacts/renderer/bin/`. Imported wallpapers are read only. A nonzero exit
means a test binary or the reload probe failed, a pooled/isolated pair diverged,
a generated case emitted diagnostics, a generated pixel assertion failed, or the
timer measurement could not be collected/validated. A low or high measured frame
count alone does not fail the check.
`report.json` records `full_compatibility_verified: false` on every case: there
is no authored-reference comparison, so rendering without a crash does not prove
all authored effects loaded.

The timer benchmark is not a GoogleTest case or regression-registry entry. Its
combined log is `timer_delivery_benchmark.log`; the corresponding report entry
retains schema-1 `measurement` fields, `actual_outer_duration_ns`,
`delivered_per_second` and `diagnostic_only: true`. It uses the existing taskpolicy
wrapper and child-only Darwin resets, with a 30-second collection timeout and no
retry. GPU/cadence allowances do not skip it. Missing, duplicate, malformed or
inconsistent data and nonzero/timeout exits remain explicit tooling failures.
The deterministic acceptance contract and measurement definition are described in
[frame delivery](power-benchmark.md#frame-delivery); runtime timer policy is not
changed by replacing the old unconditional throughput gate.

The twelve generated cases are original synthetic scenes with no workshop
identifiers; they use private synthetic compose-layer assets plus the probes'
virtual assets, so they run on a clean checkout without an installed wallpaper
library:

| Case | What it reads back |
| --- | --- |
| `generated-0` … `generated-7` | Nested compose layers: background copy on and off, visibility, sizes, transforms and declaration order; known pixels prove a first effect draws, empty or hidden nested layers leak no earlier pixels, and visible children survive their clears |
| `generated-alpha`, `generated-alpha-single-sample` | Composed coverage as RGB: alpha-MAX expects 128/128/255 over transparent, half-covered and opaque destinations; single-sample alpha-to-coverage expects 0/159/255 |
| `generated-perspective-animation` | A four-corner homography whose third corner follows a paused parent timeline: the page covers the centre and the margin stays the clear color |
| `generated-origin-animation` | A relative `origin` curve: both halves of the canvas are revealed once the curtain finishes |

Hosted CI may lack a Metal device. With `--allow-missing-gpu`, the report sets
`gpu_checks_executed: false`, lists each skipped target, and emits a CI warning.
CPU/capability tests still execute; VideoToolbox-dependent tests report their
own codec skips. A started test's failure is never converted into a
missing-device skip. A default local renderer run remains necessary evidence for
the GPU checks CI skips.

Hosted macOS arm64 runners are virtual machines that deliver a 10 ms wait
8 ms or more late (a Mac: about 2 ms) regardless of process policy, and how late
varies from run to run, so the frame-clock,
unchanged-present and audio-expiry tests that count ticks against short waits
cannot pass there. With `--allow-imprecise-timers` only the probe's exit 77
filters exactly the tests in `REALTIME_TESTS` out of their binaries with
`--gtest_filter`; every other test in those binaries still runs. The report sets
`realtime_checks_executed: false` and lists each filtered test with the measured
median under `skips`, each with a CI warning. A cadence test that fails only on
hosted runners belongs in `REALTIME_TESTS`; the harness tests check that every
name still exists. A default local renderer run remains necessary evidence for
them.

The same virtual machines differ from a real Mac in ways a few tests check for
themselves, each skipping with its reason rather than failing: their GPU is a
paravirtual Metal device whose VideoToolbox reports AV1 hardware it cannot open,
so the AV1 decoder test skips on it; they have not downloaded the PingFang font
asset, so the PingFang fallback tests skip unless FreeType reads a
`PingFangSC-Regular` face with Han from the matched file; and the particle-scale
draw test lets through an all-black compatibility frame on a paravirtual GPU
alone (seen on a runner, cause not established), running its other cases.

Test binaries and probes run through macOS `taskpolicy` with application
scheduling and latency/throughput tiers of zero. Before exec, the
single-threaded Python driver clears inherited Darwin background policy on both
the child process and its main thread using `os.setpriority`; `taskpolicy` alone
leaves that policy in place. Only test children change priority, leaving the
invoking agent and build tools untouched. This keeps inherited background
scheduling from governing real-time assertions; it does not relax their
thresholds or remove any tests. Contention can still affect wall-clock
performance checks, so run the gate without concurrent builds or benchmarks.

## Probes

All probes are explicitly invoked executables, not ctest cases or UI tests.
`offscreen_scene_probe` draws one imported scene with Native Metal through a
`CAMetalLayer` no window owns, into private render targets, and writes the scene's
own output target as PPM images (`frame-<n>.ppm`) under `WE_TEST_OUTPUT`. Use a
disposable output/cache directory. It parses the project as the app does and drives
`MetalRender` directly (without `SceneWallpaper`), so a probe result describes the same
renderer wallpapers use.

```sh
WE_TEST_PROJECT="$HOME/Library/Application Support/WallpaperMachine/Library/<id>/project.json" \
WE_TEST_ASSETS="$HOME/Library/Application Support/WallpaperMachine/SceneAssets" \
WE_TEST_OUTPUT="$PWD/artifacts/renderer/scratch" \
artifacts/renderer/bin/tests/offscreen_scene_probe
```

`metal_scene_draw_smoke` is the harness that drives the renderer the way the host does
(through `SceneRendererHandle`); "both scene probes" below means these two.

### Probe environment variables

Inputs and outputs:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_PROJECT` | `offscreen_scene_probe`, `text_object_runtime_test` | Path to a scene `project.json` |
| `WE_TEST_PROJECTS` | `scene_reload_cycle_probe` | `;`-separated project list |
| `WE_TEST_METAL_PROJECTS` | `metal_scene_draw_smoke` | Colon-separated `project.json` paths run through the production parser into the native backend offscreen. A fallback is printed with its reason and is not a failure; an accepted scene must prepare and draw every requested frame. Frames after initialization are summarised as render passes per frame (how many rendered into the scene's own image, loaded their target from memory and how many megabytes that read, opened with a traded copy's image, and stored their depth or multisampled colour), blits per frame, the megabytes the GPU's copies (blits and resampling passes) wrote, copies replaced by a trade of textures, draws left out because they leave their image as it is and clears and copies left out because nothing drawn reads them, and thread CPU milliseconds per `drawFrame`; a second line counts per frame the calls into the scripts and from them into the host, the frames of scripts without `update` left out, the vertex and index bytes of rewritten geometry copied for the GPU, and the passes scene optimisation drew and reused (`passes drawn + reused/frame`), counts that are the same in every run of a scene and clock where the CPU time is not; and one `N graph rebuild(s), M target resize(s) in F draws, X ms wall in all` line says how often the host would have built the graph again or resized its targets, how long that took and what asked for each (`text-resized-buffers`, `effect-visibility`, ...): a scene that rebuilds every few draws decodes and uploads its images each time. A scene whose graph has layer link textures read before the frame fills them (a layer sampling its own or a later layer's last composite) also prints one `[ LOCAL    ] <id>: N layer link texture(s) read before the frame fills them` line: its picture depends on the frame before, so compare it across builds with `WE_TEST_COMPARE_PROJECTS`. With `WE_TEST_OUTPUT` set, the last frame is written there. Unset, the test skips. Read any `metal translation of '…' failed` line as a failed effect, not a clean native run |
| `WE_TEST_ASSETS` | probes | Shared `SceneAssets` directory |
| `WE_TEST_OUTPUT` | probes | Output/cache directory (disposable) |
| `WE_TEST_CACHE` | `text_object_runtime_test` | Disposable shader cache directory |
| `WE_TEST_CYCLES` | `scene_reload_cycle_probe` | Reload cycles per project |
| `WE_TEST_PROPERTIES` | `offscreen_scene_probe`, `metal_scene_draw_smoke`, the energy test | Flat JSON property overrides, in memory only (the energy test hands them to the scene wallpaper as the app's saved overrides). A layer gated on a saved property draws nothing without this, so both harnesses have to be driven with the same overrides to compare one |
| `WE_TEST_RANDOM_SEED` | both scene probes | Seeds the particle random source before the scene is parsed, so the same project simulates the same particles in both harnesses and across builds |

Frames, time and surfaces:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_FRAMES` | `offscreen_scene_probe` | Number of sampled frames |
| `WE_TEST_FRAME_STEP` | `offscreen_scene_probe` | Sampling interval, to look past an intro |
| `WE_TEST_CAPTURE_LAST=1` | `offscreen_scene_probe` | Draw every requested frame but save only the last, for long intro and text-update checks without thousands of images |
| `WE_TEST_SAMPLE_FRAMES` | both scene probes | JSON array of frame indices. Saves each frame and `state-N.json` with live transforms, material values, text and script-error count |
| `WE_TEST_METAL_FRAMES` | `metal_scene_draw_smoke` | Frames the local-project Metal test draws, 1/60 s apart: 120 by default, 2–3600 accepted. Its own knob, so the probe's `WE_TEST_FRAMES` in the same environment cannot move the Metal frame's scene time. The last frame is the output; the test also prints the bytes of this scene's render targets and, separately, the device-wide Metal allocation, which includes the layer's drawables and varies between runs |
| `WE_TEST_METAL_FRAME_STEP` | `metal_scene_draw_smoke` | Simulation delta in seconds; default `1/60`. Use `1/120` and twice as many frames for a matched-duration 120 FPS scenario |
| `WE_TEST_MSAA` | native local/compare probes in `metal_scene_draw_smoke`, the energy test | Requested sample count: `0` (default), `2`, `4` or `8`. The normal model eligibility and device capability checks apply; it does not force unsupported samples |
| `WE_TEST_REFLECTION` | native local/compare probes in `metal_scene_draw_smoke`, the energy test | Reflection quality: `0` disabled or `1` enabled (default), for matching Wallpaper Engine's quality setting without changing installed preferences |
| `WE_TEST_POSTPROCESSING` | native local/compare probes in `metal_scene_draw_smoke`, the energy test | Requested post-processing quality: Disabled `0`, Enabled `2` (default), Ultra `4`, or Display HDR `5`. HDR still requires authored HDR and bloom; the setting does not force a pipeline |
| `WE_TEST_SHADOWS`, `WE_TEST_VOLUMETRICS` | the same | Shadow and volumetric quality, `0`–`4` (default `2`, medium). All five quality variables are read by one parser (`tests/support/scene_quality_environment.hpp`); a value out of range fails the test |
| `WE_TEST_METAL_WARMUP_TICKS` | `metal_scene_draw_smoke` | Runtime ticks of 1/60 s before the graph is built, as `offscreen_scene_probe` takes 40; `0..3600`. Unset, none. The scene clock is not advanced by them, here or there |
| `WE_TEST_COMPARE_PROJECTS` | `metal_scene_draw_smoke --gtest_filter='*LocalProjectsDrawAPosterPicture*'` | Colon-separated `project.json` paths drawn through `SceneRendererHandle` on a layer no window owns, the last frame's final composition written as `<scene id>.ppm` under `WE_TEST_OUTPUT` (see below), and `<scene id>: N picture upload(s), M optimized for sampling` printed for what loading the pictures cost. Unset, the test skips |
| `WE_TEST_COMPARE_SURFACE` | the same test | `<width>x<height>` of the layer drawn into; default `960x540` |
| `WE_TEST_COMPARE_RESOLUTION` | the same test | `display` rasterizes a 2D scene at the size it is presented at on the layer; `canvas`, the default, at the size it was authored at. Perspective scenes and videos ignore it |
| `WE_TEST_COMPARE_SCALE_FACTOR` | the same test | The layer's backing scale, `1`–`4` (default `1`); with `WE_TEST_COMPARE_SURFACE` it makes a laptop-panel-sized layer |
| `WE_TEST_COMPARE_SCALING` | the same test | The scaling mode the host pushes: `fill` (the default), `fit`, `fit_blurred`, `stretch` or `none`; anything else fails the test |
| `WE_TEST_COMPARE_RENDER_SCALE` | the same test | The render scale the host pushes, `0.25`–`1` (default `1`), set on the scene before its graph is built, where the scene wallpaper sets it: the picture the app's render scale setting gives |
| `WE_TEST_COMPARE_HASH_FRAMES`, `WE_TEST_COMPARE_HASH_EVERY` | the same test | Draws whose final composition is hashed: a JSON array of draw indices, or every k-th draw counting from one (`60` hashes draws 59, 119, …). Each is captured through the poster path (a draw that left the picture as it was is served from that picture, as the host serves an idle wallpaper's) and printed as `[ HASH     ] <scene> <W>x<H> frame=<n> sha256=<hex>`, the last draw too; `<scene>-frame-<n>.ppm` is written only under `WE_TEST_OUTPUT`. Asking for posters changes no picture: the last frame hashes the same with and without it |
| `WE_TEST_COMPARE_REALTIME` | the same test | Set (any value) to pace the frames in real time, so a script that reads the wall clock (`Date.now()`) sees as much time pass as the scene does on a desktop; unset, the frames run as fast as they draw |
| `WE_TEST_COMPARE_STOP_AFTER_REBUILD` | the same test | `<n>`: the run ends `n` draws after the first time the host would build the graph again (a script that shows a layer the graph left out does), `WE_TEST_METAL_FRAMES` bounding the wait, and prints the draw the rebuild came before, so a run without one can be drawn to the same scene time. A scene's own scripts cause rebuilds as it starts; `WE_TEST_COMPARE_REBUILD_FROM=<m>` leaves out those before draw `m` |
| `WE_TEST_COMPARE_COUNTERS` | the same test | Set (not `0`): the renderer counters are on for the run, as in a diagnostics window, so the picture is drawn through the counted paths (the present feedback among them), and `[ COUNTERS ]` prints the present requests, the presents skipped as unchanged and the presentation reports that arrived before the renderer closed. With `WALLPAPER_MACHINE_PRESENT_FEEDBACK=0` beside it, the same run without the reports |
| `WE_TEST_COMPARE_REBUILD_AT` | the same test | `<k>`: builds the graph again before draw `k` whether or not the scene asked, as the host does for any change of the graph, so what a rebuild leaves behind (a video's frame, the draw's length) is looked at on a scene that would not rebuild by itself at a draw of your choosing |
| `WE_TEST_RESIZE_AS_REBUILD` | `metal_scene_draw_smoke`, `offscreen_scene_probe` | Set (not `0`): a change that only resized render targets (a text card that changed size in texels) builds the whole graph again, as every build did before `ResizeRenderTargets`. The way to draw one scene both ways in one binary, for a picture or cost comparison; the targeted tests that assert the resize path skip under it |
| `WE_TEST_SETTLE_TEXT` | `metal_scene_draw_smoke` | Set (not `0`): every text layout a tick asked for lands in that frame (`WaitForTextLayoutForTests`), instead of whenever the text worker is done. Two runs of a scene whose text changes as it runs then lay out on the same frames; a scene whose scripts read the wall clock or a random source still differs between runs |
| `WE_TEST_SURFACE` | `offscreen_scene_probe` | `<width>x<height>` physical output extent; defaults to `1920x1080`. Perspective scenes use it as their full-scale raster; authored 2D canvases keep their size |
| `WE_TEST_TEXTURE_SURFACE` | `offscreen_scene_probe` | `<width>x<height>` opts into the production display-sized texture mip policy (a leading mip is dropped only while the next is still at least as long as the surface's longest side, so the level kept covers the surface) without changing raster extent; unset retains all source levels for before/after image and allocation comparisons. Native Metal uses its surface size automatically |
| `WE_TEST_METAL_SURFACE` | `metal_scene_draw_smoke` | `<width>x<height>` for the surface the native backend rasterizes; defaults to `960x540`. Screen-space shader inputs follow it, so comparing this backend's output with another's is only meaningful when both rasterize the same extent |
| `WE_TEST_METAL_RESOLUTION`, `WE_TEST_METAL_SCALE_FACTOR` | `metal_scene_draw_smoke` | `display` rasterizes a 2D scene at the size it is presented at on that surface, `canvas` (the default) at the size it was authored at; the scale factor (`1`–`4`, default `1`) is the surface's backing scale. The `render target bytes` line and `WE_TEST_METAL_DUMP_TARGETS=*` then show what the choice costs |
| `WE_TEST_METAL_SCALING` | `metal_scene_draw_smoke` local-project run | The scaling mode the host would push before the graph is built: `fill`, `fit`, `fit_blurred`, `stretch` or `none`; anything else fails the test. Unset, the renderer keeps its own default, original size (`none`), which lays a canvas larger than the surface out at one point per canvas unit, so a cost or target figure meant for the app's Fill needs `fill` |
| `WE_TEST_METAL_RENDER_SCALE` | `metal_scene_draw_smoke` local-project run | The render scale, `0.25`–`1` (default `1`), set before the graph is built; at 0.75 a display-resolution scene's render target bytes fall to about 0.57 of 1's (targets that do not follow the screen keep their size) |
| `WE_TEST_METAL_TIMING` | the same | Set (not `0`): each draw's command buffers are timed on the GPU from their own start and end, and one `[ COST     ] <scene> {json}` line reports draws after the first: `gpu_ms_p50`, `gpu_ms_p95`, `gpu_ms_mean` (a draw that committed nothing counts 0), `gpu_busy_ms_mean` (the time the GPU was busy with any of those buffers, per draw: two draws' buffers can run at once, at most two frames in flight, and their own spans then count the shared time twice, so a draw whose first passes need nothing of the previous frame can show a longer `gpu_ms_mean` for no more work; compare this one across orders), `cpu_ms_mean`, command buffers, render passes and blits per draw, the bytes those copies wrote and the copies traded per draw (`copied_bytes_per_draw`, `traded_copies_per_draw`), the draws left out as no-ops and the unread clears and copies left out per draw (`noop_draws_per_draw`, `skipped_clears_per_draw`, `skipped_copies_per_draw`), render target and device bytes. The draws run back to back, so the GPU stays near its top clock: a work figure, not paced energy |

Allocation, optimisation and dumps:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_NO_REUSE=1` | `offscreen_scene_probe` | Isolated target allocation: sets `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0` before the renderer exists, so no two targets share an image, and turns static-result reuse off. `check_renderer.py` draws every generated fixture pooled and isolated and requires equal pixels |
| `WE_TEST_NO_SCENE_OPTIMIZATION` | `offscreen_scene_probe` | Any value forces the unoptimised path (no static-result reuse) for a direct A/B; the probe reports whether scene optimization was on |
| `WE_TEST_SCENE_OPTIMIZATION=0` | `metal_scene_draw_smoke` | Turns static-result reuse off around the local-project loop, to compare a scene that looks wrong under it with the same scene drawn every frame. Process-global, restored afterwards |
| `WE_TEST_DUMP_SOURCE=1` | `offscreen_scene_probe` | Write the packaged scene JSON beneath `WE_TEST_OUTPUT`; `nodes.txt` also records per-node visibility, translate and scale, which diffs layer placement between builds without comparing pixels |
| `WE_TEST_ASSET_PATH` | `offscreen_scene_probe` | Copy one asset from the mounted package to `asset.txt` under `WE_TEST_OUTPUT` for shader diagnosis; keep private asset output uncommitted |
| `WE_TEST_DUMP_TARGETS` | `offscreen_scene_probe` | Render target names, or `*` for every target the scene declares; the last frame of each is written as `target-<name>.ppm`. Names carry a per-run suffix, so `*` is the only way to name one across two processes |
| `WE_TEST_METAL_DUMP_TARGETS` | `metal_scene_draw_smoke` | Same selection as above. Each target is reported with its size and mean luma and, with `WE_TEST_OUTPUT` set, written as a PPM. Target names carry a per-run suffix, so `*` is the only way to name one across two processes. After a frame, targets that share an image show its last user's pixels and a copy trade's source (a motion blur's accumulation, the bloom combine) a stale image; `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0` and `WALLPAPER_MACHINE_COPY_TRADES=0` give every target its own |
| `WE_TEST_DUMP_ALPHA=1` | both scene probes | Writes each dumped target's alpha channel separately as grey. Effects that weight by coverage (the bokeh downsample divides by the sum of its taps' alpha) make different color from the same RGB when alpha differs |
| `WE_TEST_DUMP_POSES=1` | `wpdump` | Dump sampled bone transforms |
| `WE_TEST_EXPECT_WARM=1` | `text_object_runtime_test` | Assert zero shader compilations on a second run |
| `WALLPAPER_MACHINE_GPU_LABELS` | Native Metal, in the app and every harness | `1`: names every command buffer and encoder after what it runs, for [GPU time per pass](#gpu-time-per-pass); `split` as well gives each pass a render pass of its own. Read once; unset or `0`, no label is built |

Synthetic input, media and audio (none reads the desktop, a media player or an
audio device):

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_CLICK_LAYER` | `offscreen_scene_probe` | Image-layer ID to click |
| `WE_TEST_CLICK_COUNT` | `offscreen_scene_probe` | `1..10` synthetic clicks |
| `WE_TEST_CURSOR_PATH` | `offscreen_scene_probe` | A scripted cursor before the captured frames: `x,y[,down];…` in world units, one entry a 1/60 s tick, press and release dispatched where `down` changes; the scene clock moves with each tick. Drives a script's drag (`cursorDown`/`cursorMove`/`cursorUp`) the same way every run |
| `WE_TEST_CURSOR_TRACE` | `offscreen_scene_probe` | With `WE_TEST_CURSOR_PATH`: a puppet layer name whose bones' world origins are printed every tick |
| `WE_TEST_CLICK_OFFSET` | `offscreen_scene_probe` | World-space `"dx dy"` added to the click layer's origin, to hit a covered or transparent texel instead of the centre |
| `WE_TEST_CLICK_VIEWPORT` | `offscreen_scene_probe` | `"<px_w>x<px_h>@<scale>:<fill\|fit\|stretch\|none>"`; maps the click the way a desktop does — the presented viewport is published and the cursor arrives window-normalized — instead of handing the runtime a world position, so hit testing is exercised against a real display's geometry |
| `WE_TEST_INPUT_JSON` | both scene probes and the poster harness (`*LocalProjectsDrawAPosterPicture*`) | Ordered synthetic pointer events: `[{"frame":600,"layer":42,"inside":true,"buttons":1},{"frame":601,"buttons":0}]`. `layer` follows that parsed node's projected centre; `x`/`y` supply normalized coordinates instead. An exit uses `inside:false` |
| `WE_TEST_MEDIA_EVENTS` | both scene probes | JSON array of SceneScript media event objects, dispatched in order after the warm-up ticks. Enables media integration for the run, so a wallpaper that only draws its player while something is playing can be rendered without a system media source or Automation permission. Without events a scene hears no media event, as in the app with no player |
| `WE_TEST_MEDIA_ARTWORK` | both scene probes | `<width>x<height>:<rrggbb>`; publishes one opaque cover through the same path the app uses, so `$mediaThumbnail` and `$mediaPreviousThumbnail` carry a color that is legible in the rendered frame. Without it a background drawn from the current cover renders flat grey and a comparison says nothing |
| `WE_TEST_MEDIA_JSON` | `offscreen_scene_probe` | A JSON array of media events dispatched right after the parse, before the warm-up ticks |
| `WE_TEST_AUDIO_HZ` | both scene probes and the poster harness (`*LocalProjectsDrawAPosterPicture*`) | Synthetic PCM at `0..24000` Hz; `0` means silence. Each frame submits one analysis window (1,600 frames at 48 kHz) through the same service the desktop tap feeds, and the Metal gate enables audio response for the run. The 64 bands follow Wallpaper Engine's layout: one ~23 Hz bin each up to about 400 Hz (band 0 ≈ 23 Hz, band 3 ≈ 95 Hz), then widening to ~15 kHz, so a shader reading only the lowest bands needs a bass tone, not 440 Hz |
| `WE_TEST_AUDIO_FILE` | both scene probes and the poster harness | Raw float32 mono PCM at 48 kHz played instead of the synthetic tone, continuing across frames and looping; `WE_TEST_AUDIO_HZ` must still be set to enable audio. A music-like signal is the only way to judge a visualizer's look: a tone lights one band and white noise lights all of them |
| `WE_TEST_AUDIO_AMPLITUDE`, `WE_TEST_AUDIO_NOISE=1` | both scene probes and the poster harness | Amplitude `0..1` (default `.025`) and optional deterministic broadband PCM instead of a sine, with `WE_TEST_AUDIO_HZ` set. A single tone cannot exercise scripts averaging several frequency bands |
| `WE_TEST_AUDIO_ENABLED=0` | `offscreen_scene_probe` | Exercise the disabled audio gate |

Audio is submitted after GPU setup so shader compilation cannot expire its
live-input timeout. These options never initialize audio hardware. Keep all
probe output outside Git. If IDE ignore rules block reads under the repository's
ignored directories, write to a system temporary directory instead. Judge
perspective scenes by the ordinary final frame, not by a single dumped target.

### Probe behavior

`offscreen_scene_probe` reports `startup parsed`, `prepared` and `first-frame`
timings. Use a fresh `WE_TEST_OUTPUT` for a cold shader-cache run and repeat the
same directory for a warm run. It resolves each project's entry/package version
and render dimensions and discovers text nodes instead of using fixed layer IDs.
It tests scene rendering only — not video or web projects, and not AppKit
presentation. Like production it builds the render graph again on every graph
mutation (a layer a script creates or shows later).
Local-asset probe sound managers use the null backend: not calling `Play()` alone
does not prevent `MountStream()` from initializing a system audio device.

The probe keeps two clocks, and a frame's time is not `N * WE_TEST_FRAME_STEP`.
The runtime clock (timelines, camera shots, scripts) takes 40 warm-up ticks of
1/60 s before frame 0, then one `Tick(step)` before each frame, so frame N is at
about `0.667 + (N + 1) * step` seconds. The scene clock (`elapsingTime`: puppet
poses, shader `g_Time`, effects such as a spinning planet) skips the warm-up and
advances `step` after each frame, so frame N draws at `N * step`.
`metal_scene_draw_smoke` ticks and advances both clocks by 1/60 s for
`WE_TEST_METAL_FRAMES` frames (120 by default) and writes the last one at
(frames − 1)/60 s on both, 119/60 s by default. Comparing the two harnesses, or
one render with a crop of another, therefore needs matched scene time: the probe
run with `WE_TEST_FRAMES=4` and `WE_TEST_FRAME_STEP=0.6611111` (119/180) draws
frame 3 at the default Metal frame's scene time. A puppet posed at a different
scene time reads as a camera fault. Seed both with the same
`WE_TEST_RANDOM_SEED`.

The poster harness is `MetalSceneDraw.LocalProjectsDrawAPosterPicture` with
`WE_TEST_COMPARE_PROJECTS`: each project is parsed exactly as a wallpaper loads it,
seeded and clocked as asked (`WE_TEST_METAL_FRAMES`, `WE_TEST_METAL_FRAME_STEP`,
`WE_TEST_METAL_WARMUP_TICKS`, `WE_TEST_RANDOM_SEED`), given the scaling the host
pushes to the renderer, and drawn through `SceneRendererHandle` on a layer no
window owns. The last frame's final composition returns through the poster path
and is written as `<scene id>.ppm` under `WE_TEST_OUTPUT`. It asserts nothing about
the picture: it is a diagnostic for comparing two builds (two runs with the same
seed, clock and properties give byte-identical pictures, so a difference is what
the build changed) or a build with a reference from outside the harness, such as
Wallpaper Engine's own frames. With `WE_TEST_COMPARE_HASH_EVERY` or
`WE_TEST_COMPARE_HASH_FRAMES` it hashes the final composition of sampled draws as
well, at the render scale and scaling mode the host pushes
(`WE_TEST_COMPARE_RENDER_SCALE`, `WE_TEST_COMPARE_SCALING`): that is the pixel-identity
check `scripts/perf_bench.py identity` runs (see
[power benchmarking](power-benchmark.md#headless-ab-driver)). It hears nothing unless
`WE_TEST_AUDIO_HZ` is set: then audio response is on and one window of synthetic sound is
analysed before every draw, as in the local-project run, so an audio-reactive scene can be
compared with a tone or noise playing (a `perf_bench.py identity` variant passes it, e.g.
`--variant tone=new:WE_TEST_AUDIO_HZ=60,WE_TEST_AUDIO_AMPLITUDE=0.5`). A difference found by comparing
`offscreen_scene_probe` with the poster harness is not yet a renderer
difference: the two harnesses differ in the ways below.

To put both clocks on the same second, give the poster harness
`WE_TEST_METAL_WARMUP_TICKS=40` and both runs the same frame count and step
(`WE_TEST_FRAMES` with `WE_TEST_FRAME_STEP`, `WE_TEST_METAL_FRAMES` with
`WE_TEST_METAL_FRAME_STEP`). The probe's default surface is 1920x1080 and the poster
harness's 960x540, and a canvas that is not 16:9 is cropped by the fill mode, which
reads as a zoom, so give both a surface of the canvas's own aspect
(`WE_TEST_SURFACE`, `WE_TEST_COMPARE_SURFACE`). A scene still inside its camera fade
at the sampled time is black in both and compares equal.

`scene_reload_cycle_probe` parses every selected project twice in one process,
each parse on a fresh thread with fresh VFS mounts, the way a wallpaper switch
builds a new `SceneWallpaper`. It catches per-process state that survives a
scene teardown and stalls the next load; a stall is reported as a probe timeout.
It covers scene parsing and script compilation only, not presentation.

### GPU time per pass

`WALLPAPER_MACHINE_GPU_LABELS=1` makes Native Metal name each frame's command buffer
(`scene frame <scene image WxH> on <surface WxH>`) and every render and blit encoder the
renderer makes in it (the video conversion and the blurred backdrop always carry fixed names;
MetalFX encodes its own, unnamed), so Instruments' Metal System Trace shows the GPU time of
each pass. A pass
reads `<shader or step> -> <target> <WxH> <format>[ x<samples>] [<layer name> #<id>]
{load|clear|dontcare|opening copy}`: an effect pass names the layer whose chain it is in, a
copy `copy <source> -> <target>`, and the composition `composition <scene image> -> <surface>`.
Draws that share one render pass (consecutive draws into one target) show as
`[<n> passes] <first> + <shader> [<layer>] x<count>, ...`, cut at 250 characters; with
`WALLPAPER_MACHINE_GPU_LABELS=split` each pass gets a render pass of its own instead, so each
is timed apart (the picture is the same; the total rises by the loads and stores the split
adds). Instruments records no label that holds a character outside ASCII, so each run of
such characters in a layer name becomes `?`. Unset (the default), nothing is named and no
label string is built.

A recording of the local-project run at the user's settings (any `WE_TEST_*` variable from
the tables above can be added the same way):

```sh
xcrun xctrace record --template 'Metal System Trace' --output artifacts/<task>/<id>.trace \
  --env WALLPAPER_MACHINE_GPU_LABELS=1 \
  --env WE_TEST_METAL_PROJECTS="$HOME/Library/Application Support/WallpaperMachine/Library/<id>/project.json" \
  --env WE_TEST_ASSETS="$HOME/Library/Application Support/WallpaperMachine/SceneAssets" \
  --env WE_TEST_METAL_SURFACE=3840x2160 --env WE_TEST_METAL_SCALE_FACTOR=2 \
  --env WE_TEST_METAL_RESOLUTION=display --env WE_TEST_METAL_RENDER_SCALE=0.75 \
  --env WE_TEST_METAL_FRAMES=240 --env WE_TEST_METAL_WARMUP_TICKS=40 --env WE_TEST_RANDOM_SEED=1 \
  --launch -- artifacts/renderer/bin/tests/metal_scene_draw_smoke \
  --gtest_filter='*LocalProjectsNamedByTheEnvironment*'
xcrun xctrace export --input artifacts/<task>/<id>.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]' > intervals.xml
```

Each row of `metal-gpu-intervals` is one encoder's work on one GPU channel (`Vertex`,
`Fragment`, `Compute`; blits run on `Compute`) with its start, duration, command buffer id
and `event-label` (`<command buffer label>:<encoder label>  (<process>) <id>`); the export
writes repeated values once and refers back to them by `ref`. The draws run back to back, so
a frame's command buffer is about as long as its GPU work. Render passes of one frame overlap
on the GPU, so their durations add up to more than the frame: share each instant among the
intervals running then to attribute a frame's time. A scene with an intro (a layer whose
animation plays once) needs enough frames to be past it. Keep traces under `artifacts/`;
they hold the scene's layer names.

### Metal compile across processes

macOS keeps compiled Metal code under
`$(getconf DARWIN_USER_CACHE_DIR)/<bundle id>/com.apple.metal/`, in a
`libraries*` pair (compiled Metal source) and a `functions*` pair (compiled
pipelines); the folder names above them differ by machine and macOS version. A
bare executable has no bundle id and uses `com.apple.metal/` directly under that
directory. Library entries are scoped by location — the bundle's path, or a bare
executable's folder — while pipeline entries are keyed by content and shared.
For measurements this means:

- A probe run twice from the same folder compiles once. A byte-identical copy
  in another folder compiles the Metal source again; renaming, re-signing,
  touching or replacing the binary in the same folder does not.
- To behave like the app, put the probe in a minimal bundle
  (`Contents/MacOS/<name>` plus an `Info.plist` with a scratch
  `CFBundleIdentifier`) so it gets a cache of its own. Never use
  `app.wallpapermachine`, and delete only a scratch identifier's folder.
- Measure per process, not per coalition: a probe started from a terminal
  shares the terminal's coalition. `proc_pid_rusage` with `RUSAGE_INFO_V6`
  (`ri_energy_nj`, CPU only) needs no privileges; read the probe's from its
  zombie before reaping it, and poll each `MTLCompilerService`, of which macOS
  starts one per client process.

What a later launch compiles again:

| Condition | Compiled again |
| --- | --- |
| First load, every cache cold | Metal source and pipelines |
| Next process, same location | Nothing |
| Same location, new `LC_UUID`, new `CFBundleVersion` or bundle replaced | Nothing |
| Same bundle id, another location | Metal source (the larger share); pipelines are shared |
| Compiled source missing only | Metal source |
| Compiled pipelines missing only | Pipelines (the smaller share) |

A Metal binary archive would hold only the pipeline row's share. Measured energy for
these conditions is in [performance](../features/performance.md).

## Regression areas that must stay covered

Each entry names the test that guards a behavior and the invariant or trap it
protects. Every C++ test binary these pages name is in the `REGRESSION_BINARIES`
registry and runs in `scripts/check_renderer.py` (see
[C++/CMake test binaries](#ccmake-test-binaries)). Rust tests
(`module::test_name`) run through `python3 scripts/check_rust.py`; Swift tests
(`TestClass.testName`) run through `python3 scripts/test.py`. Tests that need
shipped Wallpaper Engine shaders or assets skip with a printed reason.

- [Scene regressions](scene-regressions.md) — cameras, parallax and cursor
  mapping, scene scripts and property bindings, layers, textures and
  compositing, alpha, text and clocks, animation and puppets, and the shader
  pipeline.
- [Runtime regressions](runtime-regressions.md) — the native Metal backend,
  video decode and import, continuous-playback work, frame timing and idle,
  audio, host, bridge and display behavior, and startup and staging buffers.

## Rust crates

`python3 scripts/check_rust.py` is the release-CI entry point. It supplies the
Homebrew Cargo environment, uses a temporary `WALLPAPER_MACHINE_HOME`, disables
the desktop, media and network opt-ins, and runs, all with `--release --locked`:
the `wallpaper-core` and `wallpaper-bridge` library tests, six device-free
`wallpaper-core` integration targets (`core_audio_api`,
`project_override_json`, `wallpaper_background`, `first_frame_scaling`,
`audio_response_capture_lifecycle`, `scene_audio_volume_validation`) and `wm-shader` with `ffi`: its unit,
corpus, GPU-probe and C-ABI tests, warnings denied by the crate. It prints and records the five explicit
desktop exclusions (`CORE_EXCLUSIONS` in the script) and any
emitted skip reasons. A nonzero command or missing tool fails the check. Full
logs and the JSON verdict go under `artifacts/rust/` (`--output` redirects them);
CI uploads them on failure. This does not certify skipped corpus inputs or
authorize a desktop run.

Generated bindgen output can differ in formatting between machines; tests must
exercise the FFI behavior instead of parsing a formatted declaration. Mouse
monitor-gap tests wait for the fake engine's sample barrier and observed probe
progress before comparing counts, so a busy CI worker is not mistaken for a
dropped cursor update. Close the gap while the sample is blocked before checking
that probes stop; otherwise an in-flight probe can race the final count.

A `wallpaper-bridge` test bridge keeps its actor runtime's threads (about one per
CPU core, and the actor's own) until the test process exits, unless the test lets go
of its engine: the bridge registers a callback with the engine that holds the actor
and its runtime, and the actor holds the engine. A test that builds a bridge over a
`FakeEngineFacade` keeps an `EngineRelease` for it (`tests/engine_release.rs`), which
drops that callback when the test ends and leaves about one thread behind instead of
twenty. Only a few tests do so far, so on an 18-core Mac the library suite peaks near
5,800 threads against the 6,144 a process may hold (`sysctl kern.num_taskthreads`).
A new test that builds a bridge keeps an `EngineRelease`, and shares one bridge
between the phases of a property instead of building one per assertion. A failure of
an unrelated test with `Resource temporarily unavailable (os error 35)` from `kameo`
or a tokio worker is that cap, not the change under test; it also turns up when other
builds on the same Mac hold the per-user process limit.

Run individual commands from `Renderer/` with the Homebrew environment
from `scripts/build.py`. The first `cargo test` after that environment changes
fails in its CMake configure step and succeeds on an unchanged retry, so a single
configure failure is not a result:

```sh
cargo test --release -p wallpaper-core --lib
cargo test --release -p wallpaper-core --test wallpaper_background
cargo test --release -p wallpaper-bridge --lib
cargo test --release -p wallpaper-core --lib audio
```

The shader layer (`wm-shader`) runs from `Renderer/` too, because rustup reads the
workspace's `rust-toolchain.toml` from the working directory: `cargo test --release --locked -p wm-shader --features ffi`, with
`--test corpus -- --nocapture` appended for the shipped-shader sweep (a case that finds
no assets prints `skipped: …` and is not a pass).

- `wallpaper-core` audio coverage: capture ownership and failures,
  mono/multichannel conversion, resampling including sample-rate changes.
  `capture_controller_tests` includes non-scene consumers sharing one tap with
  scenes, cleanup, suspension, permission and failed-transition rollback, and the
  rebuild after an output device change (`restart_*`); `device_watch::tests`
  covers its debounce and subscriber table with real timers of a few tens of
  milliseconds, never the CoreAudio listener. `capture::lifecycle_tests::recovery_tests`
  drives the tap stall watch through the real I/O callback with one injected
  `Instant` per check: silence, an idle output device and suspension never rebuild,
  a tap without callbacks is rebuilt once after 3 s, and the rate limit and its
  re-arm on a demand change hold. The
  bridge's `tests::web_audio_media` replays web capture decisions through the
  production demand handler and real controller with a device-free backend:
  checking only the fake engine's suspension flag cannot prove capture starts.
  Its `output_device_change` tests also rebuild a stalled tap through the stall
  handler and let a device change supersede that rebuild's retries; the capture
  lane's `aw25` test proves the worker's once-a-second check runs only while a
  counted tap is wanted.
- `wallpaper-core` framing coverage (`cargo test --release -p wallpaper-core --lib
  framing`): a scene's position (`SceneFraming`, two fractions from 0 to 1, centred
  at 0.5 by default) is refused when an axis is NaN, infinite or outside 0..1 by
  the descriptor and template builders, both `validate()` methods and
  `WallpaperEngine::set_framing` (which refuses before it asks the actor, so
  nothing reaches the renderer); it counts toward `SceneDesc::same_wallpaper`, so
  only a different position forces a renderer rebuild and `paused` or `display`
  alone do not; it survives the descriptor-template round trip and the stored direct
  assignment the bridge compares; and it moves between wallpapers like the scaling
  factor (the live position stays for the same wallpaper, the next descriptor's is
  taken for a different one). These are pure state tests: none opens a renderer or a
  window, so `SceneRuntime::set_framing` against a live renderer is covered only by
  a desktop run.
- `wallpaper-bridge` framing coverage (`cargo test --release -p wallpaper-bridge
  --lib -- config::wallpaper tests::activation_plan`): a display's saved position
  (`FramingCfg` in the wallpaper config's `monitors` entry) is written only when it
  is not centred and round-trips; a hand-edited value is clamped or read as centred
  without losing the file's other settings, because a file that fails to parse is set
  aside whole; the scene built for a display carries that display's position and no
  other display's, whichever selector (Primary or identity) addresses it; a mirror is
  centred even when its source is positioned; and a position reaches the
  native video descriptor as `framing` (centred for a mirror) but never its admission key, so moving a clip never restarts the
  native player.
- `wallpaper-bridge` position setter (`cargo test --release -p wallpaper-bridge --lib
  -- display_position wallpaper_options_draft drafts::`): `set_display_position`
  tells the fake engine once with the display's live handle and never reopens the
  scene; the position survives a restart; repeating it, naming neither axis or
  centring a display nobody positioned neither writes the file nor calls the engine;
  an axis left out keeps its value; NaN, infinite and out-of-range axes are refused
  whole with nothing saved or sent; Cancel keeps the position and Apply reopens no
  scene for it, yet a reopening Apply carries it; a refused engine update leaves the
  position saved for the next reconcile, and a failed save leaves nothing saved so
  asking again saves it; two displays keep their own positions.
  The engine here is the fake one, so the move on a live renderer is a desktop check.
- `wallpaper-bridge` position reports (same filter): the options snapshot carries each
  display's position, only a moved display offers Restore defaults, the reply to a move
  already carries it and a restart loads it; the lock-screen export carries a scene's
  and a natively played video's saved position, centres a web page and a mirror, and
  follows a position at once while an unapplied scale factor stays out of it.
- `wallpaper-bridge` reduced-quality request (`cargo test --release -p wallpaper-bridge
  --lib -- tests::quality_throttle tests::quality_settings tests::performance_settings
  tests::settings_intents`): `set_quality_throttle` lowers every open scene live through
  the same `set_render_scale` and `set_fps` calls the battery profile uses, never rebuilds
  the scene list, and an empty list hands the saved scale and the display's own rate back.
  It only ever lowers: a scale or cap already below the profile stays, and a table over
  saved scale, saved cap, battery profile and request pins the stricter-of rule, including
  that the battery profile alone still returns the profile's scale as is. The request is
  deduplicated and reported sorted, one cause ending keeps the others in force, it is
  never written to `config.toml` and a new bridge starts without one, a wallpaper applied
  under it opens at the lowered rate and scale, web, lock-screen and native-video
  descriptors follow it (a native-video descriptor carries no rate and its admission key does not
  change), playback is never touched, and asking again after a refused renderer update re-applies it.
  A native clip stays with the native player and a refused one stays with the scene engine through
  every change of the ceiling (a throttle, the cap, the rate or mode of the battery profile, the
  power source): a refusal describes the file, never the frame rate. The engine is the fake one, so a live Metal
  scene following the change and any power effect are desktop checks.
- `wallpaper-core` and `wallpaper-bridge` drag previews (`cargo test --release -p
  wallpaper-core --lib framing`; `cargo test --release -p wallpaper-bridge --lib
  display_position`): `WallpaperEngine::preview_framing` refuses an invalid position
  before it asks the actor and forwards a valid one. `preview_display_position` tells
  the fake engine's preview call once per step with the display's live handle, and
  writes no file, changes neither the lock-screen export nor the options, leaves nothing
  for a display refresh to rebuild, and a restart still opens the scene centred; an axis
  left out follows the saved position, not the last step; a position outside 0 to 1, NaN,
  an infinity and an unknown wallpaper are refused with nothing shown, while a display
  no engine scene draws (a native video, a disabled display, a web page, a mirror or an
  unknown display) is not an error. The release is an ordinary `set_display_position`
  that saves and clears the preview mark; a drag that ends at the saved position puts the
  scene back once without writing, a scene on another display is not told, and a
  refused release keeps the mark for the next try. These are fake-engine tests:
  `SceneRuntime::preview_framing` leaving the runtime's descriptor and stored template
  alone (so an abandoned drag leaves nothing to rebuild) is by construction and is
  covered, with the picture itself, only by a desktop run.
- `wallpaper-core` property previews (`cargo test --release -p wallpaper-core --lib
  property`; `--test core_audio_api`): `WallpaperEngine::preview_property_override`
  refuses a document that is not a JSON object (an array, a number, a string, `null`,
  text that is not JSON, nothing at all) or has an array leaf before it asks the actor,
  with the message `set_property_override` gives for the same document, and forwards
  an empty, a flat and a nested one to the actor; the document the renderer receives is
  one flat object (nested keys joined with underscores, `null` as the empty string, key
  order and spacing normalised). `OweScene` sets a property of its own, not the
  override's, the reset's or the shader refresh's, and refuses a document with a NUL
  byte and a closed scene (also one it was last shown the document) without reaching
  the renderer. Through an allocated, never initialised renderer object, which takes
  property updates like a running one: it remembers the document it was shown until the
  scene is loaded again by `set_property_override` or `reset_property_override`, a
  refused document leaves what it shows alone, and `preview_on_scene_of` hands a
  document made for another wallpaper to nothing (`OtherWallpaper`, the renderer's record
  unchanged) and one made for the scene's own to the renderer. `SceneRuntime` itself
  has no test, because it needs a window: it leaving the runtime's saved override,
  descriptor and stored template alone (so an abandoned edit leaves nothing to rebuild)
  is by construction, like `preview_framing`, as is passing its own `scene_path` to
  `preview_on_scene_of`, and the picture is covered only by the renderer tests above and
  a desktop run.
- `wallpaper-bridge` property previews (`cargo test --release -p wallpaper-bridge --lib
  property_preview`, and `--lib state::drafts` for the document builder):
  `preview_wallpaper_properties` tells the fake engine's
  preview call once per scene that draws the wallpaper, on two displays and a mirror,
  with the whole document, and writes no file, changes neither the lock-screen export
  nor the draft and leaves nothing for a display refresh to rebuild. The document equals
  the one Apply loads byte for byte, a restored property or restore all defaults sends
  the saved document (host-supplied defaults included), and a texture waits for Apply
  while a picked file, which is saved at once, stays in every later document. An untouched
  wallpaper sends nothing, and a document a scene already shows is not sent to it again;
  Revert and `show` false put the saved look back once and keep the draft; a refused update
  or a refused restore is repeated, the restore leaving the draft dirty; Apply drops the
  mark. The fake engine follows the real engine's rules, which the bridge relies on: it
  remembers per display what it was shown, forgets it when a reconcile gives the display a
  scene that is not the same wallpaper (the shader cache clear is one), and
  `rebuild_renderer_of` forgets it as an engine-internal recovery does, so a scene the
  engine kept is not told again, one it opened afresh or rebuilt is, and the bridge keeps no
  copy of its own. A document made for a wallpaper that a reconcile has just moved off a
  display (the apply held after the engine switched it, before the bridge committed) is
  declined for that display only, never recorded as sent to the scene that now draws another
  wallpaper, and a display still showing the wallpaper follows the edit and is the only one
  Revert puts back afterwards. A preview that lands while an Apply is loading does not make
  the Apply stale. A video, a web page and a wallpaper no display shows are a silent no-op, and an
  unknown wallpaper is refused. A value still being dragged (`pending`) goes on top of the
  draft for the document of that call alone, in order and the last for a property winning,
  without making a clean wallpaper dirty or writing a file; the next call that does not name
  it shows the draft, committing the value last shown sends nothing more and another value
  does, dragging back to the authored value puts the saved look back, a texture among the
  steps changes nothing, a drag with one refused step (unknown id, out of range, `NaN`, wrong
  kind, a colour channel, an option that is not offered, in the same words as the edit's
  refusal) sends nothing, and a video is not asked about its steps. `tests::wallpaper_preview`
  holds the same list for the preview export: the step wins over the draft, the draft and its
  dirty marks do not move, a Web page follows too and a refused step exports nothing. These
  are fake-engine tests: what a real scene does with the document is covered by the renderer
  tests above.
- `wallpaper_background`: renders unattached production Metal layers over a white
  bitmap with no drawable, before and after a resize and after recreation. Every
  pixel must be opaque black. Its harness runs on the process's main thread; no
  window, GPU drawable, or desktop access is needed. It does not establish
  physical sleep/wake compositor timing.
- `first_frame_scaling`: opens a still scene through `OweBackend::open_scene` on an
  unattached square layer, with Fill on a 3:2 canvas, unchanged frames skipped and
  on-demand updating on, and requires exactly one present. A scaling mode, zoom or
  framing sent after the configuration reaches only the second frame, so the first
  is drawn fit and centred and a corrected one follows: the jump from fit to fill
  right after a wallpaper appears. It uses the GPU offscreen; no window or desktop.
- `wallpaper-bridge`: live audio toggle errors, rollback/persistence,
  nonblocking selection and mirror behavior; scene lifetime,
  presentation/manual pause precedence, failure rollback, disabled destruction,
  stalled single-flight mouse scenarios, and live handles remaining after
  reconciliation/audio errors; the lock-screen export regression for
  committed-versus-draft scaling, pause/resume and ejection; and
  `tests::property_snapshot` for combo selection, conditional rows after
  edits/default restoration/discard, a rule-hidden row staying in the snapshot
  (not enabled, with its value and modified state), hidden-value preservation, the visibility
  grammar (groups, constants, quoted text, `===`, list membership) deciding row
  visibility with synthetic ids, and fail-open behavior for unreadable rules,
  and a wallpaper's own `general.localization` tables following the language the
  host sets (whole-label matches only, English fallback, no change to the draft,
  no effect on a project without a table), and the staged Restore all defaults
  (every default shown but not committed, a chosen file kept, a value behind a
  hidden row reported as modified and then cleared, Revert bringing every value back, Apply persisting the
  defaults, an unknown wallpaper refused);
  `project::condition` also pins the input bounds (length, nesting, list size) and
  that hostile input returns an error instead of recursing, and
  `project::localization` pins the table bounds (languages, tokens, text size,
  overall bytes) and the language-list cleaning in the same way; `power::tests`
  for the power-source watcher: a sleeping or just-started watcher stops promptly
  when dropped (the old five-second wake would fail it), a wake signalled before
  the run loop starts is not lost, a delivery the actor rejected is offered again,
  and a resample requested by the host delivers a changed source once, leaves an
  unreadable one alone and does not delay shutdown (`tests::power_settings` applies
  the battery policy from such a change through the bridge). They use the real run
  loop and `IOKit` source but fake the read and the actor, and prove the
  sleep-until-signalled structure, not a measured saving.
- `wm-shader`'s corpus sweeps (`Renderer/Shader/tests/corpus.rs` and the sweeps
  under `src/*/tests/`) skip with a printed `skipped: …` reason when the shipped
  shader folder or the unpacked Workshop shaders are absent; read those lines
  before claiming shader coverage. See
  [wallpaper-corpus.md](wallpaper-corpus.md) for the asset roots.

## C++/CMake test binaries

CMake test binaries are built under `artifacts/renderer/bin/` (executables in
its `tests/` folder). The authoritative routine build/run list is
`REGRESSION_BINARIES` in `scripts/check_renderer.py`, covering the parsers
(`scene_schema_tests`, `mdl_schema_tests`, `mdl_parse_tests`, `puppet_pose_tests`,
`tex_schema_tests`, `tex_container_tests`, `workshop_snapshot_test`,
`workshop_corpus_stamps_test`),
SceneScript, input and the media protocol (`script_runtime_compat_test`,
`mouse_input_test`, `cursor_input_state_test`, `scenescript_media_event_smoke`, `scenescript_behavior_test`,
`media_thumbnail_texture_smoke`, and the `*_behavior_test` executables below), the shader
compiler (`rust_shader_bridge_behavior_test` for the C++ bridge and the parser's compile entry,
`shader_program_cache_behavior_test` for the program cache, `shader_dialect_compat_test` for
constructs real shaders use, `shader_preprocessor_compat_test`, and `shader_corpus_test` for
compile-job building and the path guards), video playback-state merging
(`video_texture_submission_smoke`), and the texture/cache/lifetime, audio, video,
graph, particle (`particle_billboard_size_test`, `particle_control_point_test`,
`particle_override_test`, `particle_rope_pieces_test`, with the older
`particle_mouse_controlpoint_test`, `particle_rope_geometry_test` and
`particle_parity_test`), timer and Metal checks; a non-zero exit from any registered
binary fails the check. A test binary that is not registered fails unnoticed, so a
new one joins the registry in the change that adds it. The few executables in
`tests/CMakeLists.txt` that are neither registered nor one of the two probes are
listed in `MANUAL_BINARIES` beside the registry with the reason, and
`tests.test_check_renderer` fails on any other. Every registered binary
runs on each check, in CI too, so it has to stay fast and headless: no Metal
device unless its registry flag says so, no window, and no audio device. A test
that mounts a sound layer passes `SoundManager::OutputBackend::Null`, because a
mount opens the system output device even when nothing plays. Temporary files
carry the process id, because other checkouts run the same binaries at the same
time and share the temporary directory, and are removed when the test ends.

Timer admission tests in `tests/timer/request_admission_contract_test.cpp`
control the real timer callback before and after request-latch consumption. A
batch whose requests all precede consumption must coalesce; requests made after
a draw is posted must survive a suppressed tick. Post-tick barriers inspect the
actual idle/pending state rather than sleeping to infer that no more frames will
arrive. The recovery-window tests use real suppressed ticks and explicit render
begin/end timestamps; they are not throughput measurements. Declaration-only
friends give the test access to the normal linked timer objects without adding a
production hook or changing their layout or scheduling.
The reset and suspension cases are independently authored in that same translation
unit. They prove fresh draw admission through a real callback and preserve the
explicit next-frame elapsed-time check after suspension. The math, bounded-stream
and video-state composition cases also use real retained operations; none requires
an audio device, video decoder, desktop surface or private corpus.

The old wall-clock 42–60-completion assertion is retired. Its unchanged-scheduler
40–41-frame failures remain historical failures, not results cleared by a later
focused pass. `timer_delivery_benchmark` separately records completed draws and its
actual observation window for 18 ms work at a 60 fps ceiling; that measurement has
no acceptance threshold. Deterministic admission/reset/suspension contracts and the
diagnostic benchmark are separate evidence, not interchangeable cadence claims.
For timer diagnostics use `scripts/check_renderer.py`'s `run` helper and its
existing child scheduling policy, not direct execution of the binary; avoid
concurrent builds/benchmarks. Do not infer a particular frame count from a passing
test whose successful output prints no count.

Two registered binaries (`workshop_corpus_stamps_test` and `unchanged_present_test`) and the media binaries' corpus A/B tests described above also read a local corpus when there is one; the roots
and their defaults are in
[wallpaper-corpus.md](wallpaper-corpus.md#pointing-the-tests-at-your-local-corpus).
`workshop_corpus_stamps_test` dumps every `<id>/scene.pkg` under
`WALLPAPER_MACHINE_WORKSHOP_ROOT` once and creates one test instance per package,
texture (`texv`, `texi`, `texb`, pixel format) and model (`mdlv`, `mdls`, `mdla`) stamp it
finds, so a stamp nobody has seen before appears on the next run without an allow-list.
Each instance checks every item that carries the stamp (a package needs a parsed scene, a
texture needs a size, a parsed model needs geometry; it may have no bones, which the renderer
draws as a static mesh). Without a corpus it generates no cases and
`CorpusSmoke.CorpusFolderHoldsItemsWithStamps` skips, naming the folder it looked in and the
variable that sets it. The index itself and the dump it is built from have no corpus
dependency: `workshop_snapshot_test` (always on, CPU only, about half a second) builds its items in a
scratch folder and covers the `wpdump` command line (exit codes, usage and error text, the
output file), the package, scene, object, texture and model blocks of the JSON, the pose
sampling switch, loose files beside the package, determinism, and the index (root lookup,
which folders count, the skipped id, harvested stamp sets, slices, a missing root).
`shader_corpus_test`
checks its compile-job building (a scene's combos on an effect's passes included) and
path guards on every run. The compiler-dependent shader binaries fail, rather than skip,
when the Rust shader library is not linked, because the shipped build always links it.
The corpus sweep (`ShaderCorpusSweep.DISABLED_ParsesCorpus`) compiles every shader-bearing material of
every scene under `WALLPAPER_MACHINE_UNPACK_ROOT`, with `WALLPAPER_MACHINE_ASSETS_ROOT`
mounted and an effect's passes under the combos the scene sets on them, and took 5 to
6 minutes for 60 scenes, so it is disabled and runs only on request:

```sh
WALLPAPER_MACHINE_UNPACK_ROOT=<folder of id/scene.json> \
  artifacts/renderer/bin/tests/shader_corpus_test \
  --gtest_also_run_disabled_tests --gtest_filter='*ParsesCorpus*'
```

Run by hand only (`MANUAL_BINARIES`): `wpdump <workshop folder> [out.json]` prints (or writes)
the snapshot `workshop_corpus_stamps_test` checks for one item (package, scene, object,
texture and model versions and fields) as JSON, to inspect what the parsers make of it. It exits
2 on a wrong argument count, 1 when the folder has no `scene.pkg`, the package is rejected or
the output file cannot be opened. With `WE_TEST_DUMP_POSES` set (to anything) each bone and
animation track also lists its bind pose and sampled frames.

To iterate on one test, build and run its binary in the Homebrew environment from
`scripts/build.py`, once `check_renderer.py` has configured the build directory:

```sh
cmake --build artifacts/renderer/bin --target scene_schema_part10_test
artifacts/renderer/bin/tests/scene_schema_part10_test --gtest_filter='*SceneZoom*'
```

Scene MSAA defaults to Off. An eligible scene contains a non-null `model` entry;
visibility and object order do not change that load-time gate. Only an eligible request
asks the host for a supported sample count. The default target then owns MS color and
matching depth attachments, while ordinary readers use its resolved image. Feedback
texture trades keep the original MS samples; post-processing and later fades continue
in the single-sample image, so a post-process copy cannot be overwritten by old samples.
Off and model-free scenes allocate no MS attachments, and **Quality in force** reports
the count actually drawn (0 for one sample).

`BACKBUFFER_MS` follows that selected scene mode. Wallpaper Engine's default framebuffer
reader has a one-sample `Texture2DMS` view after resolve: its sample-zero lookup is an
unfiltered integer read. The shader request's physical `sample_count=1` maps this to a
Metal 2D texel read; true MS slots retain their MS declarations. `SceneMsaa.*`,
`MetalMultisampling.*`, the `MetalSceneDraw.Multisampl*` tests, the early-read and
post-copy/fade tests, and the quality binding test cover selection, storage, matching
depth, resize/rebuild, feedback, A2C and readback. A reference eligibility comparison
must cold-start Wallpaper Engine for each scene: switching from a model to cards can
retain the previous device's MSAA even though a cold card scene uses one sample.

The video suites (`video_source_input_test`, `unchanged_present_test`, `metal_scene_draw_smoke`) decode H.264 clips written by `Renderer/Testing/synthetic_video.mm`, which is this project's own code and uses Apple frameworks only: a `VTCompressionSession` encodes one group of pictures per binary (640x360, 30 fps, no B-frames, a 200 Mbit/s noise group and a 600-frame single-keyframe bar clip), and an `AVAssetWriter` passthrough input re-times the compressed samples for as many repeats as a test needs, with the salt as iTunes comment metadata and the display matrix as the input transform. The clips carry no colour tags, so the decoders infer the matrix from the picture size and the absolute colours the tests expect depend on that. `EncoderAvailable()` is the guard (a machine with no VideoToolbox H.264 encoder reports it instead of failing on a missing file). `synthetic_video_test` (CPU only, no decoder under test) reads the files back with AVFoundation: frame times, one keyframe per repeat, the eight orientations, no colour extensions and the luma the encoder was given. The same file also writes 10-bit clips (`WriteTenBitVideo`, guarded by `TenBitEncoderAvailable()`): `kTenBitFrames` flat 640x360 frames of HEVC Main10 from `VTCompressionSession`, one keyframe, no B-frames, tagged PQ, HLG or BT.709 in both the bitstream and the container (and optionally a content light level). `synthetic_video_test` checks them with AVFoundation alone (the `hvcC` record says Main 10 and 10 bits, each tag, frame times, the decoded codes), and `vt_frame_decoder_test` requires that the project's reader plus VideoToolbox decode them to `x420` IOSurface frames carrying the curve, primaries and matrix as attachments, which is where the scene import reads them. `Renderer/Testing/hdr_reference.hpp` is the header-only, double-precision CPU reference for the 10-bit kernel (BT.2100, ST 2084, BT.2390, primaries derived from chromaticities), shared by `metal_video_texture_test` and `metal_scene_draw_smoke`. `video_source_input_test` drives the one decoder, the native backend: the input and clock cases (`VideoSourceInput`, `VideoSourceClock`), and the cases about how an embedded payload reaches it (`NativePayloads`: memory or an anonymous file, never a visible one, a stream that breaks part way, a fragmented MP4 and an AVI refused with their reason and nothing staged, a VP9 WebM and an H.264 Matroska with B-frames, the VP8 refusal). `Renderer/Testing` also writes a 60-frame clip with B-frames (`WriteReorderedVideo`) and embeds small clips made once offline (`embedded_clips.hpp`: VP9 128x96 in WebM, since VideoToolbox's VP9 decoder refuses 64x48, H.264 64x48 with B-frames in Matroska, and full-range H.264 and HEVC 64x48 ramps in MP4 with no colr box). The tests that used to count open .mp4 descriptors count `OpenVideoDecoderCount()`.

`scene_schema_tests` also compiles `tests/utils_known_answer_tests.cpp`, which pins the `Random` draws that `WE_TEST_RANDOM_SEED` replays and the `genSha1` digests that key the shader and script caches, so replacing either implementation cannot change them silently. It also compiles `tests/linalg_tests.cpp`, which pins `Utils/Linalg.hpp`, the engine's own linear algebra, bit for bit against `tests/linalg_golden.inc` (results captured once from the library it replaced; the cases that call libm trigonometry are checked only where the host's libm still rounds like the capture host's, and are reported skipped otherwise) and checks the behaviour the engine's call sites rely on. The 4 x 4 inverse and determinant are held to a tolerance there, and a singular matrix with rounding noise may invert differently from the replaced library (see `sceneEngine.linalgChanges` in `ThirdParty/provenance.json`). The rest of the engine's tests use `Utils/Linalg.hpp` types directly, so every other test binary also exercises the library through the engine.

The scene-schema behaviour tests (what `scene_schema_tests.cpp` used to hold beyond its independent remainder) are written in parts, each part in its own executable `scene_schema_partNN_test` built from its own `tests/scene_schema_partNN_*.cpp` files and linked against one shared static library, `scene_schema_support` (`tests/support/schema_fixtures.{hpp,cpp}`). The library is plain headless test data and a thin driver: a read-only `fs::Fs` over a map of path to bytes (mounted at `/assets`), a little-endian byte writer, the binary model and video-texture files, the asset sets (basic image/particle objects, a skinned puppet in its variants, a leaf model layer, the LDR/HDR bloom stand-ins), the scene-file skeletons (quiet canvas, perspective, canvas with a camera object, camera-path clips), `ParseRig`, which parses a scene document through `WPSceneParser` with a null-output sound manager, and a few helpers for reading the parsed tree. `scene_schema_fixtures_selftest` checks the library against the production readers, so a part can rely on it. A new part adds one `add_scene_schema_behavior_test(scene_schema_partNN_test ...)` line to the marked list in `tests/CMakeLists.txt` and one name to `REGRESSION_BINARIES`; it never edits another part's sources or the library (what it needs beyond the library it writes in its own files). Test names say what behaviour they pin, and a part states the behaviour (not a count) in its comments.

`tex_schema_tests` and `tex_container_tests` link `PkgConfig::TEST_LZ4` themselves
(`tests/CMakeLists.txt`): the
renderer links LZ4 `PRIVATE`, so the include directory does not propagate to a
test that builds its own compressed `.tex` fixtures. Run them when touching
`WPTexImageParser`.

`mdl_parse_tests`, `puppet_pose_tests` and `tex_container_tests` build every input byte by byte
(`tests/mdl_fixtures.hpp`, `tests/tex_fixtures.hpp`, on the writer and in-memory file space of
`tests/support/byte_fs.hpp`), so they need no wallpaper, device or environment variable; the only skip is
one `.tex` permission row when run as root. They cover `.mdl` mesh records for versions 13-23, the skeleton
and optional blocks and the generated submeshes (`MdlMesh.*`, `MdlGeometry.*`, `MdlSkeleton.*`), puppet
layer blending and playback state (`Puppet*.*`), and `.tex` containers, loose pictures, packages and
scene sources (`Tex*.*`; host files live in a per-process folder under the system temp directory).
`PuppetMorph.*` covers activation, animation sampling, instance isolation, shader packing,
bone modifiers and the distinct image/model texture layouts. `PuppetBones.BlendShape*`
in `scenescript_puppet_bones_test` exercises the public script methods. The offscreen
`PuppetMorphGpu.*` cases in `metal_scene_draw_smoke` check position and alpha pixels,
animated models, immutable texture reuse across layers/displays and changed bytes under
the same model path, including playback without repeated delta uploads.
`PuppetIkLinks.*` checks the resulting end pose for position/full-transform target
rules, stored curve indices, ordered multiple links, clip/additive weights, disabled
curves, first-layer reset rules and the available source-bone pose. It also preserves
the loader's first-target binding, the chain's explicit target list and the observed
Euler angle adjustment. `PuppetGrounding.*` covers the high-bit reach clamp,
behind-plane rotation preservation, first-sweep reflection at zero blend, and the
source-distance gate. `PuppetBoneLinks.*` covers ordinary full-TRS rules, file order,
child composition, per-instance previous poses for later sources, model FK isolation
and the absence of per-bone solver arrays for an ordinary-only consumer.
`MdlSkeleton.LinkCurveHeadersKeepTheDisabledBit` covers that MDLA metadata.
`SceneForces.*` in `puppet_pose_tests` checks the actual rope pose after scene gravity
and wind, mass and squared-second units, world-space transforms, the wind field's
time/position/width inputs, property/script updates and isolation from ordinary bone
physics. The attachment cases use the host's `FrameBegin`/runtime order and prove
that adding a visual child does not change its spring or rope parent's pose,
including standalone rendering without a runtime. `ScriptSceneForces.*` in `scenescript_behavior_test` covers the five native
members, parsed bindings, repeated writes and a static scene with no force consumer.
Other useful filters:

```sh
audio_tests --gtest_filter='AudioResponseMonoTest.*'
script_runtime_compat_test --gtest_filter='AudioResponseCompat.*'
shader_updater_behavior_test --gtest_filter='ShaderUpdaterAudio.*'
```

The `*_behavior_test` executables build scenes and runtimes in memory and call the
runtime, the material parser or the shader value updater directly: no package, window,
GPU or audio device, and none reads a local asset. `sound_layer_cursor_behavior_test`
(scripts that play native sound layers; which script hears hover, click, enter, leave
and release), `media_event_behavior_test` (media events, video playback clocks, settings
bound to project properties, aligned scripted transforms), `script_host_behavior_test`
(wrapper identity, text layers, timers, cursor payload, `sortLayer`),
`create_layer_behavior_test` and `material_constant_behavior_test` (constants bound to
properties, scripts and template copies), `texture_slot_behavior_test` (user-texture
slots, `constantshadervalues`, the runtime image store) and `shader_updater_behavior_test`
(pinned sprite frames, compose-layer matrices, audio-spectrum arrays, per-slot reflection
and render-target sizes). A new behaviour of those areas gets its test in the matching file.

`rendergraph_smoke` uses always-active GTest
checks in Release builds. `sprite_animation_test` checks elapsed time across
cadences and long loops. `stb_image_regression_test` decodes ordinary generated
JPEG/PNG/BMP images, checks cleanup under controlled allocator refusal, and
compares scalar versus arm64 NEON JPEG pixels (arm64 production decoding enables
NEON). The disabled `Arm64NeonJpegDecodeBenchmark` is explicitly opt-in; its
first-decode and warm in-memory decoder timings are not disk-cold startup,
whole-app performance or energy measurements. `miniaudio_failure_paths_test`
covers allocation failures without opening audio hardware.

`surface_health_test` (CPU only, in the check) pins the always-on surface health
reading with an injected clock: completed and presented frames advance
independently, a graph failure and a frame failure latch different reasons,
clearing the stop never clears the failure count, and the present age is unknown
before the first present.

`wallpaper_scaling_test` (CPU only, in the check) pins the presentation layout
function: the default position reproduces an in-test copy of the old centring
arithmetic bit for bit in every scaling mode, a position of 0 and 1 puts the picture
against the leading and trailing edges for an overflowing and a letterboxed picture
alike, non-finite values fall back to the centre and out-of-range ones clamp, and the
pointer mapping follows the position.

`backdrop_geometry_test` (CPU only, in the check) pins the arithmetic of Fit with blurred
backdrop: for several shapes (16:9 on an ultrawide, on 16:10, on a portrait display, the
same shape, a one-pixel rounding gap) the layout's rectangle is Fit's for every factor,
position and display scale, `backdrop_px` is Fill at a factor of 1, centred, and `backdrop`
is true exactly when the picture leaves more than a pixel of room; every other mode reports
none and keeps its rectangle; a mode value past the last is refused. The bands cover the
display minus the picture exactly (checked by area and by sampled points) without
overlapping the picture or each other, including a picture moved past an edge, larger than
the display or absent. The reduction plan takes two steps for a 3840x2160 picture (through
an 8-bit 480x270 image) and one for 1000 texels, always ends 128 texels on the longer side
and keeps its taps at most four texels apart.

`backdrop_scene_test` (native Metal, headless, in the check) runs a canvas-filling gradient
through the scene harness as Fit and as Fit with blurred backdrop, with bars left and
right, above and below, mirrored, and for a picture longer than 1024 texels: the picture
is Fit's byte for byte, Fit's bars are black, the copy's are not, neighbouring pixels of
the copy differ by at most four steps, the copy equals the gradient Fill-sized at 70% of
its brightness within five steps, and each side is darker than the strip of picture beside
it. Further tests pin that hard edges in the picture come out soft in both blur
directions, that the copy carries exactly one step of dither, that two runs give the same
bytes, that moving or scaling the picture leaves the copy where it is, that a picture
fitting the display exactly draws no copy and Fit's bytes, that Fit and Fill hold the
same render-target bytes while this mode holds more (more again with the 8-bit image for a
large picture) and goes back to Fit's number when there is no room or another mode is
chosen, that switching between Fit and this mode presents again while a repeated frame is
still skipped (which also fails if the presentation key outgrows its capacity), and that
Fit's per-frame pass count is the mode's. The drawable composition itself is not read
back: the harness sees the poster, which runs the same composition code. `WE_TEST_KEEP_PICTURES`
keeps the pictures.

`metalfx_upscale_test` (native Metal, headless, in the check) draws a hard-edged canvas
through the scene harness at 100%, at 50% stretched, and at 50% with
[MetalFX upscaling](../features/performance.md#metalfx-upscaling): the upscaled picture
keeps the display's size, differs from the stretch, and is closer to the 100% picture
than the stretch is (mean channel error); the upscaled draw holds one extra full-size 8-bit image;
in one running scene, turning upscaling off lets that image go on the next drawn frame and
turning it on again makes it again; a GPU without MetalFX's spatial scaler (simulated with
`SetMetalUpscalerUnsupportedForTests`, so any machine runs it) composes the stretch byte for
byte and holds no more memory; the tests that need MetalFX itself skip on a GPU without it;
and at 100% the switch changes neither the bytes nor the
memory. `WE_TEST_KEEP_PICTURES` keeps the pictures.

`horizontal_flip_pointer_test` (native Metal on a detached layer, in the check) drives a
`SceneWallpaper` built through the C bindings with a parsed synthetic scene and reads the
pointer the frame loop hands the scene: untouched by default, mirrored left to right (y
unchanged) once the `horizontal_flip` property is set through
`owe_scene_wallpaper_set_property_bool`, back to normal when it is cleared, applied when the
flip was set before any surface existed, and kept across a graph rebuild; the other
property kinds are refused for that name. What the flip does to the drawn picture is
`backdrop_scene_test` and `metal_scene_draw_smoke`.

`audio_tests` also holds `SpectrumExport128Test.*`, which pins `owe_audio_current_spectrum_128`
against the snapshot the audio-response service publishes for audio the test submits: the
left channel fills the first 64 values and the right the second 64, every value is clamped
to [0, 1] (a tone far beyond full scale reads exactly 1), the generation is the one of the
analysis the levels came from (and is optional), a null or shorter-than-128 buffer is
refused with a reason and left untouched, a longer buffer keeps its extra entries, and a
service that has analysed nothing exports silence at generation 0.

`project_property_preview_test` (CPU only, in the check) pins what a property
document means to a running scene: the project's declared defaults with exactly the
given values over them, whatever the scene loaded with, which properties a
scene reads only while it loads (a preview holds those at the loaded value), that a
sound layer's volume follows its slider, and that a flag bound to a string property
(a combo's choice) without a condition reads the string as a flag. It also sends
documents through the engine's `project_property_preview_json` command to a scene
running on its render thread: the newest document of a burst wins at the cost of
one queued command, a bad document or one with no scene yet changes nothing, and
nothing is replayed to the next scene. `layer_texture_reference_test` pins the one
graph rebuild a preview that reveals a hidden layer asks for, and
`metal_scene_draw_smoke` the pixels: a preview draws what a fresh load with the same
values draws and the empty document restores the first frame byte for byte;
`unchanged_present_test` shows on a live surface that a previewed slider presents
once and that an on-demand scene wakes for exactly one frame. See
[scene regressions](scene-regressions.md#scene-scripts-and-property-bindings).

`unchanged_present_test` exercises the frames Native Metal leaves out because they
would repeat the picture, through the real frame clock and drawable loop on a
`CAMetalLayer` no window owns (the counters it reads are draws executed, presents
requested and presents skipped). The engine is never given a
plain video, and Native Metal's repeat-frame behaviour is pinned in
`metal_scene_draw_smoke` (`AFrameThatWouldRepeatThePictureTakesNoDrawableAndPresentsNothing`
and its neighbours); for a scene's video layer by
`AVideoFrameShownAgainIsReusedAndANewOneRedrawsOnTheConvertedPath` and
`...OnTheDirectPlanePath` (a 30 fps clip on a 60 Hz clock, drawn beside a renderer with
scene optimisation off: every tick that took no video frame draws and presents nothing,
every tick that took one draws and presents, and every picture equals the other
renderer's for the same decoded frame) and `APausedVideoSceneStopsDrawingOnlyWhileVideoReuseIsOn`
(`WALLPAPER_MACHINE_VIDEO_REUSE=0` keeps drawing and presenting a paused video's frame).
`MetalVideoTexture.AFrameSaysWhetherItTookAVideoFrameAndEveryImportIsNumberedAnew`
pins what that rests on: a frame that imported nothing says so, and every import, a
re-import for a changed demand and a directly sampled one included, is numbered anew. In
`AStaticSceneStopsPresentingOnceEveryPassIsReused` it also reads
`surfaceHealth()` across the 1000 ms window: with the skip on, frames completed
tracks the draws that ran while frames presented stays flat and no stop is
latched. That is the semantic a liveness check relies on: skipped frames are
completed, not presented. `ADrawFailureAfterTheFirstFrameIsReportedOnceAndASurfaceRebuildHealsIt`
runs the renderer's own failure routine through a test-only seam
(`SceneWallpaperInputTestAccess::InjectFrameFailure`, compiled only with
`WESCENE_BUILD_TESTS`) on a scene that has drawn: the render-failure callback
fires once, the stop latches as `FrameFailed`, the clock stops, a surface
reconfigure like the host's clears the stop and frames resume with the failure
count kept, and the next failure reports again.
`ADrawFailureBeforeTheFirstFrameIsCountedButNotReported` pins that a scene that
has not presented yet counts the failure and does not call back. The seam
replaces only the failure, not its consequences; a real swapchain failure is not
produced. A frame whose final composition fails (no output target, no present
pipeline for a new drawable format, no encoder) is such a failure: it presents
nothing, counts no present request and records nothing as shown, so the next
frame draws the picture again rather than skipping it as unchanged
(`MetalSceneDraw.AFrameThatCannotBeComposedIsNeitherPresentedNorRememberedAsShown`,
through the test-only `RefuseNextCompositionForTests`).

`LocalProjectEnergyIsMeasuredHeadlessly`, in the same binary, is the headless
energy measurement: it skips unless `WE_TEST_ENERGY_PROJECT` names a local
`project.json` (with `WE_TEST_ASSETS`), then runs the production
`SceneWallpaper` (Native Metal, the only renderer; `WE_TEST_ENERGY_RENDERER` is no
longer read) with its own frame clock into unattached layers, waits
`WE_TEST_ENERGY_WARMUP` seconds (default 5) after every surface's first frame and
samples a `WE_TEST_ENERGY_SECONDS` window (default 20). It takes the settings the app
applies, in the app's order: `WE_TEST_ENERGY_SURFACES` (`3840x2160@2,3456x2234@2`)
draws one scene wallpaper per display in the one process, each on a layer of that
pixel size and backing scale (unset, one surface of `WE_TEST_ENERGY_WIDTH` x
`WE_TEST_ENERGY_HEIGHT`, default 1920x1080, at `WE_TEST_ENERGY_SCALE_FACTOR`, default 1);
`WE_TEST_ENERGY_SCALING` (`fill`, `fit`, `fit_blurred`, `stretch` or `none`, one for all
surfaces or one per surface, comma-separated) is pushed as the host's scaling mode
(unset, none is pushed and the scene keeps the renderer's own, Fit);
`WE_TEST_ENERGY_RESOLUTION` (`canvas`, the default, or `display`) picks the 2D scene
resolution; `WE_TEST_ENERGY_FPS` (default 60) is the frame rate;
`WE_TEST_PROPERTIES` are the saved property overrides; the five quality variables
above are set before the configuration; and `WE_TEST_ENERGY_RENDER_SCALE` is sent
after it, as the app sends any scale below 1 (unset, none is sent). It prints one
`ENERGY {...}` line: the backend actually used, this process's CPU seconds and CPU
energy (`ri_energy_nj`), the GPU time of this process's own Metal command buffers and
how many there were (`gpu_own_s`, `command_buffers`: the test wraps the device's
command-buffer `commit`, `tests/support/command_buffer_gpu_time.hpp`, to read each
buffer's GPU start and end, which counts every buffer the process commits), the whole
GPU's energy and busy time over all resource coalitions (other processes included;
only coalitions present at both ends of the window are differenced, and one whose
counters went down is left out, so a coalition that ends during the window can no
longer make the figure wrap), frames completed and presented summed over surfaces,
the passes scene optimisation drew and reused over every surface (`passes_executed`,
`passes_skipped`) and the physical footprint. `WE_TEST_ENERGY_OUTPUT=<path>` also writes the run's
schema-2 record there: the settings; per surface its size, scaling, backend, frames
and failures (and, with `WE_TEST_ENERGY_COUNTERS=1`, the renderer counters' timer
wakeups, draws, presents and presents skipped as unchanged, counted the same in both
builds compared); `cpu` from `RUSAGE_INFO_V6` (user, system and P-core seconds
normalized from Mach ticks, CPU and P-core energy, package-idle and interrupt
wakeups per second, instructions, cycles, milliseconds per QoS class); `gpu` (own
busy seconds, command buffers, ms per frame, the 50th/95th/99th percentile of the
per-buffer GPU time from a 0.1 ms histogram, the process's own coalition's GPU and
CPU energy and busy time with `coalition_shared` when the parent process is in the
same coalition, the all-coalition figures and `other_busy_share`, the GPU busy share
of every other coalition); end and lifetime-peak footprint; the thermal state
before and after; and `scene_passes`, the passes drawn (`executed`) and reused
(`skipped`) over every surface. `EnergyAccounting.*` pins the coalition differencing, the
histogram quantiles and the surface list. Counting is off unless asked for and
scene optimisation on, as shipped; `WE_TEST_ENERGY_CACHE` keeps the shader and
pipeline caches between runs. Run one scene per process, warm the caches with an
unmeasured run first and alternate the settings under comparison:
`scripts/perf_bench.py cost` does all of that
([power benchmarking](power-benchmark.md#headless-ab-driver)). A process launched from
a terminal shares a coalition with that terminal, so its coalition figures are the
terminal's; one launched as an app of its own has its own. GPU time is workload, not
energy. It changes nothing on
the desktop and needs no privileges; it is not a power measurement in the
sense of [power benchmarking](power-benchmark.md), which observes the app and
WindowServer. The native
Metal backend adds `metal_backend_test` (capability and graph gate, no device
needed), `metal_scene_draw_smoke` (author shaders and same-frame intermediates
drawn and read back, plus target reuse, dynamic-geometry upload, sprite-sheet
stepping, text layers and their update dedup, direct video plane sampling end to
end and Metal program reuse across renderers), `metal_poster_capture_test`
(on-request poster readback, busy coalescing, invalidation) and
`metal_video_texture_test` (BGRA import and NV12 conversion against the CPU
color reference, and 10-bit `x420` import with HDR tone mapping against `hdr_reference.hpp` plus the proof that an 8-bit video never builds the 10-bit pipeline, all from synthetic frames; `metal_scene_draw_smoke` additionally draws real HEVC Main10 PQ, HLG and BT.709 clips). All four run in the check and draw only
into private textures; the three that draw skip visibly without a Metal device. The run is muted before the scene loads (the scene's default sound manager would otherwise open the real audio device for any scene with sounds), and the `ENERGY` line carries no decoder field because the native backend is the only decoder.

The project's own container readers in `Renderer/Media` ([container-readers.md](../container-readers.md)) add three headless binaries built by the same CMake tree into `tests/` and registered in `REGRESSION_BINARIES`: `media_core_tests` (error, checked arithmetic, fractions, byte cursor, memory and file byte sources), `media_isobmff_tests` (the MP4 reader on files assembled in memory by `Renderer/Media/tests/mp4_builder.hpp`: sample tables and layouts, every codec entry, composition offsets, edit lists, all eight orientations, keyframe seeking, fragmented, junk, truncated, oversized and randomly mutated input) and `media_matroska_tests` (the Matroska/WebM reader on files from `mkv_builder.hpp`: the frame index, SimpleBlock and BlockGroup, Xiph/EBML/fixed lacing, unknown-size Segment and Clusters, Cues present or absent, codec and encoding refusals, limits, truncation at every length, mutations, and the VP9 header parser on real libvpx frames). They need no GPU, window or audio and take about a second. Their corpus A/B tests read the bundled starter wallpaper (recorded expectations) and the local library or `WALLPAPER_MACHINE_VIDEO_ROOT`, compare with `ffprobe` when installed (`WALLPAPER_MACHINE_FFPROBE` overrides the path) and skip with a printed reason when no file exists. Their mutation loops are meant to be run under sanitizers too: `cmake -S Renderer/Media -B artifacts/media/asan -G Ninja -DWM_MEDIA_SANITIZE=address,undefined`, then build and run the three binaries from that tree's `tests/` (not part of the routine check; the option instruments the library as well as the tests). `tests.test_check_renderer` also reads `Renderer/Media/tests/CMakeLists.txt` (`wm_media_test()`), so an unregistered media test binary fails it. `video_probe_test` (a headless engine test binary, registered like them) checks the in-memory size/length probe the texture parser uses on the fixtures and on every video payload in the local library's .tex files (each one is read or declined with a reason, and opened with the native backend). `vt_frame_decoder_test` (source `Renderer/Media/Apple/tests`, built with the engine's tests because the fixture library is) covers the native decoder headlessly on real VideoToolbox: display order on a B-frame clip and on H.264 in Matroska, a VP9 clip from WebM, seek epochs, drain, bounds, cancellation under two seconds, in-band parameter sets, range and 10-bit pixel formats, stream-stated full range (embedded yuvj420p H.264 and HEVC clips with no colr box; the decoded ramp must keep 0-255), the refusal of a sample table that reorders more than 16 frames, and every format refusal; its opt-in `ALocalClipDecodesWholeAtSpeedWithinItsMemoryBounds` takes `WALLPAPER_MACHINE_VIDEO_FILE` and prints frames per second and peak footprint. `media_core_tests` also covers `ReorderDepth`, `IsDisposableSample` (`DisposableSample.*`: H.264 and HEVC pictures nothing refers to, from hand-built NAL headers; HEVC only on the highest temporal sub-layer; anything unreadable or of another codec is kept), the anonymous spill byte source and the AV1 sequence header reader (`Av1SequenceHeader.*`: SVT-AV1 vectors and hand-written headers). A footprint check cannot show a freed payload leaving the process on macOS 27 (a freed 100 MB block stays counted in phys_footprint), so the payload-release behaviour is asserted through ownership instead.

`Renderer/Media/Apple` and `Renderer/Sound/Matroska` add two more headless binaries registered the same way: `webm_reader_test` (source `Renderer/Media/Apple/tests/webm_reader_test.mm`, built by the engine's tests CMake beside `vt_frame_decoder_test`: `WebMReader` on the embedded VP9 WebM, H.264-in-Matroska and Opus WebM clips: properties, sample buffers with timing, key frames, time offset and seeking, every sample decoded by a VideoToolbox session, the audio buffers with limit and offset, VP8/junk/cut refusals, the quarter-turn maths and the poster) and `sound_matroska_tests` (`Renderer/Sound/tests/matroska_audio_tests.cpp`: Opus, AAC, MP3 and Vorbis tracks of real encoder output, Opus trimming, the Ogg framing). Neither needs a GPU, window or audio device.

`audio_tests` gains `SoundStreamTest.*`, which pins what a scene sound decodes to through `CreateSoundStream`, whichever decoder serves it: WAV in every sample format, remix levels, resampled lengths and tone, loop seams, end of file, refused and cut-short input, tiny MP3, Ogg Vorbis and FLAC fixtures (`tests/audio/sound_fixture_data.hpp`), and the output worker on the null backend. It needs no GPU, window or audio device. The project's own sound path in `Renderer/Sound` ([sound-decoding.md](../sound-decoding.md)) adds two headless binaries registered in `REGRESSION_BINARIES`: `sound_core_tests` (the resampler's exact output lengths, tone, anti-alias cut, chunk independence and which ratios are supported, the remix coefficients, and the loop pipeline over synthetic decoders) and `sound_apple_tests` (the AudioToolbox decoder over a generated WAV and two tiny MP4 files: layout, chunks, rewind, a video's audio track, refused input, and the audio-optional rule). `tests.test_check_renderer` reads `Renderer/Sound/tests/CMakeLists.txt` (`wm_sound_test()`), so an unregistered sound test binary fails it. `sound_vorbis_tests` (also in `REGRESSION_BINARIES`) runs the Ogg Vorbis decoder over a tiny generated file: exact granule length, chunks, rewind, files cut off in the headers and in the audio, comment headers of several shapes that must open and ones that lie about their lengths (two billion comments, a vendor string longer than the file) that must be refused, 4600 damaged variants that must neither crash nor produce a non-finite sample, sample rates no format uses, channel order, and streams written from the Vorbis specification (one that plays, a floor chosen by a sparse codebook with no codewords, a mapping of sixteen submaps).

`scene_capability_probe_test` (CPU only, in the check) reads synthetic scenes the way
`owe_scene_capability_probe` does, without a device: a whole scene is read and not refused, a
material and a texture a layer names and nobody installed are listed with that layer's name
and object id, a shader cache entry is never listed, a project that cannot be read says why,
and the JSON answer survives a layer name that is not UTF-8. The probe shares the scene host's
own file-space mounting and property reading (`Scene/SceneProjectLoading`), so it reads what a
load reads.

`scene_failure_policy_test` (registered, GPU-gated like `unchanged_present_test`) drives the whole scene wallpaper on a `CAMetalLayer` no window owns and forces the failures a real GPU almost never produces through `SceneBackendFaults` (compiled into tests only): the admission gate, creating the native renderer, compiling its graph, a frame after the scene runs and a replacement surface. Each must leave the failure logged exactly once (read through `SetWallpaperLogCallback`), the frame loop stopped without presenting again, the host's first frame settled once, and either the last frame (a layer that drew carries no sublayer) or the project's preview picture (one sublayer) in place; a retry creates the native renderer and draws, a rebuilt surface heals a failed frame and re-arms the report, and a surface with no Metal layer is a prepare failure. A scene whose effect has a fragment shader that does not compile is not held: as in Wallpaper Engine (`sub_1400D5070`, probe T9), the stage that failed is replaced by the `dx11fallback` stage, the pass keeps its own blending, depth and cull state and draws dark red (0.5, 0, 0, 1), the scene presents real frames, and the shader is named in the log once (`AnEffectWhoseShaderCannotBeCompiledDrawsTheFallbackShader`, `ASceneWhoseShadersAllCompileIsNotHeld`; `Scene::shader_fallbacks` keeps the sentences). A scene refused on a reload while another scene was drawing releases the outgoing renderer: a following resize leaves the refused scene failed, presenting nothing, with the last frame held. There is no other renderer to hand a scene to, so there is nothing else to count; the test that armed the same faults under the old preferred mode and expected the Compatibility backend, and the counters of Vulkan renderers created, are retired with it. `surface_path_tests` (pure C++: which file is a project's preview and that none outside the project folder, through a symbolic link, absolute, with `..`, empty or over 32 MB is read) and `surface_still_tests` (the `preview` key lookup, decoding, one replaceable sublayer, a replaced layer, an unreadable file) cover `Renderer/Surface` on a plain `CALayer`. `tests.test_check_renderer` reads `Renderer/Surface/tests/CMakeLists.txt` (`wm_surface_test()`), so an unregistered surface test binary fails it.

`scene_load_sound_test` (registered, GPU-gated) drives the same kind of unowned layer with the scene's sound on miniaudio's null backend (`SceneWallpaperInputTestAccess::UseNullSoundOutput`) and counts its output starts (`SoundManager::OutputStarts`), so a start that a mute stopped again a moment later still shows: a wallpaper configured muted never starts its music while it loads ([runtime regressions](runtime-regressions.md#audio)).

`text_object_behavior_test` (registered, headless) states what the parser, the runtime and the text worker do with a text layer, next to the older `text_object_runtime_test`. Its sources are `tests/text_parse_scene_test.cpp` (the node, state, glyph mesh and atlases a text object parses into, layer keys and parenting, how a font reference resolves, visibility bindings, which keys place the text), `text_effect_chain_test.cpp` (an effect chain following the card as it grows, is cut to whole texels or reaches the 4096 limit; frame time reaching the effect; the default textures a shader contributes to a material), `text_runtime_cache_test.cpp` (a text change being recorded at once and shaped into glyphs and atlases by the worker later, dirty flags, cache revision and identity, unreferenced hidden layers waiting) and `text_script_raster_test.cpp` (scripts on text, user-bound origin and scale, headless glyph-raster checks and a clock-like scene built in memory). Production text draws glyph quads through the font shader; the test raster helper does not create a layer bitmap in that path. The scenes come from `tests/support/text_scene.{hpp,cpp}` (`TextWorld`: scratch `/assets` and `/provided` mounts, the built-in assets and the parser; `SceneDocument`, `TextObject` and the mesh measuring helpers) and `tests/text_fixture.hpp`; no test reads a wallpaper package, a Steam folder or an environment variable. The worker finishes a change on its own thread and a later pump applies it, so a test that changes text pumps `PumpTextLayerCache()` until `NodeTextDirty` clears (`PumpUntilClean`). Tests that need an installed font assert a non-empty font path on macOS only.

### Synthetic scene harness

Tests that need to see what a scene draws (the pixels of the final picture, the contents of a
named intermediate target, how many passes a frame opened) use the shared support under
`Renderer/Engine/tests/support/` instead of building their
own loader. It is test support only and changes no production behaviour. The CMake target
`scene_test_support` (a static library) carries it; a test executable links it and includes
`support/gpu_scene.hpp`, `support/scene_package.hpp` and `support/pixels.hpp`. The harness
checks itself in `scene_harness_selftest`, which is registered and GPU-gated; read it first
for working examples.

- **Fixtures** (`scene_package.hpp`, no GPU). A `ScenePackage` is a scratch loose project
  folder in the system temp directory, removed when it goes out of scope. `Put` and
  `PutJson` write any file; `AddImageModel`, `AddTexture`, `AddPngTexture` and
  `AddTintEffect` write the common ones against a small set of harness shaders
  (`shaders/harness_image`, `harness_tint`, plus the white `util/white` texture);
  `AddShader` installs a test's own pair. `MakeTex` encodes an `Image` as the engine's
  texture container (uncompressed RGBA8, nearest and clamped by default, optional box
  filtered mip levels, or explicit levels with `MakeTexWithLevels`), `MakePng` as a loose
  PNG. `SceneJson`, `ImageLayerJson`, `GroupJson`, `EffectUse`, `PropertyBinding`,
  `ScriptedValue` and the property declarations (`ColorProperty`, `SliderProperty`,
  `BoolProperty`) build the JSON; `SceneGeneral` sets the canvas, the clear colour and the
  parallax. A canvas-sized layer on the default 256x144 canvas needs no geometry.
  `MakeSolidScene(colour)` is the shortest scene.
- **Running** (`gpu_scene.hpp`). `GpuScene scene(package, options)` loads the package as the
  host does (project properties, saved values over them, a scratch shader cache and an
  empty shared-assets folder, the scene parser), asks the backend gate, starts the native
  renderer on a `CAMetalLayer` no window owns and compiles the graph. Check `ok()` and
  print `error()`. `Step(n)` advances n frames in the order the host's frame handler runs
  them, with a fixed time step (1/60 s by default) and the random source seeded from the
  options; `Picture()` composes the last frame into the renderer's own poster texture and
  reads it back as RGBA8, so nothing is read from a drawable or the desktop. `Run(n)` is
  both. `SetPointer` moves the cursor and the parallax, `SetProperty` changes a user
  property the way the live property preview does (it shows on the next `Step`),
  `TickRuntime` runs scripts without drawing, `Rebuild` compiles the graph again the way
  the host does after a scene-graph change, and `Release` (also the destructor) hands the
  renderer back. The surface is 256x144 at backing scale 1 unless the options say otherwise.
- **Looking inside.** `FirstFramePasses`, `LastFramePasses` and `FramePasses` report the
  render and blit passes a frame opened. Static reuse is on by default, so a frame that
  changes nothing opens none; set `scene_optimization = false` in the options (restored
  when the scene is destroyed) to count every pass of every frame. `RenderTargetNames`,
  `RenderTargetsOfLayer(id)` and `ReadRenderTarget` or `RenderTarget(name)` read a target
  after the last frame; `scene()`, `runtime()` and `renderer()` reach the engine objects for
  anything else.
- **Pixels** (`pixels.hpp`). `Image` is RGBA8, row 0 on top. `ExpectPixel`,
  `ExpectRegionAverage` and `ExpectSamePicture` return a `::testing::AssertionResult`
  (use them as `EXPECT_TRUE(ExpectPixel(...))`) whose message names the first differing
  pixel and the counts; `MaxChannelDifference`, `CountDifferingPixels` and `RegionAverage`
  are the plain functions. No picture is written to disk unless `WE_TEST_KEEP_PICTURES`
  names a directory, in which case `KeepPicture(name, image)` writes `<name>.png` there.
- **Skipping.** Begin a fixture's `SetUp` or a test with `WE_SKIP_WITHOUT_METAL()`. With
  `WE_TEST_SIMULATE_NO_METAL=1` the harness behaves as on a machine without a device:
  `GpuScene` reports `ok() == false` and nothing runs.

The surface is a detached layer and the renderer's own drawable path still acquires and
presents a drawable to it, as it does in the app; nothing is shown, because no window owns
the layer. Shaders written for a test use the engine's dialect (`mul`, `texSample2D`, the
`g_ModelViewProjectionMatrix` and `g_Color4` uniforms the image layers set); see
`ScenePackage::InstallStandardAssets` for the working pair.

## Known limitations

- **Scene clock and built-in texture uniforms (E-D9/D10).** A frame advances the scene by
  `SceneFrameStep`: elapsed time held to [1e-4, 0.25] s, times the rate, held again, as
  Wallpaper Engine does (`sub_140110630`); its clock wraps to 0 after 432000 s and ours does
  not. A sampled slot nobody bound reads Resolution (2,2,2,2) and Texel (0.5,0.5,2,2) like
  Wallpaper Engine's; `g_Texture<N>MipMapInfo` of a file texture stays unwritten (Wallpaper
  Engine writes its mip count; shipped shaders read it only for render targets) and
  `g_TextureReductionScale` stays 1. Notes: `artifacts/we-parity/decompiles/E-D9-D12.md`.
- **Fallback stage selection (E-D11).** When a program does not translate, the fragment is
  replaced first, then the vertex, then both; a broken vertex under a fragment that reads
  varyings the fallback vertex does not write falls back to both stages (dark red), where
  Wallpaper Engine draws the real fragment with whatever those varyings hold.
- Local scenes can emit MDLA, Rust `light_map` compile and shader-value alias
  errors that are independent of a given change; compare against a baseline run
  and verify only that no *new* diagnostics appear. A material constant that names no
  uniform of its shader is an authored leftover, not a binding failure: Wallpaper Engine
  keeps a constant in the material after its uniform is renamed, removed or compiled out by a
  combo, and ignores it. A scene parse gathers them (`UnmatchedConstantTally`) and logs one
  informational line, `material constants that name no uniform of their shader, ignored as
  authored leftovers: Alpha x493, Color x493`, naming the first twelve keys with their counts
  and counting the rest, where it used to log an error for every material (986 lines for one
  scene of 493 models). A constant loaded outside a scene parse, as for a layer a script
  creates, is still reported on its own as `ShaderValue: … not found in glsl`.
- **A video opened under a running clock shows the head of its clip until a seek to the scene's
  clock has landed.** An open waits for no seek: one that did would hold the render thread for
  the seek, 0.3 to 1.1 s on 1080p and 4K clips with a keyframe every 250 frames and more than the
  two seconds an open waits on a 4K 60 frame clip with one every 600, so every open starts at
  the head. A render graph built again under a playing video is not such an open: the renderer
  keeps the scene's decoders for the compile that follows (`clearLastRenderGraphForRebuild`,
  `MetalVideoTextures::hold`, `TextureCache::ClearForRebuild`), as Wallpaper Engine's video is
  untouched by what a scene changes, so a property that shows or hides a
  layer or a render-scale change on Native Metal neither shows the head of a kept video's clip
  nor reads,
  copies and hashes a packaged video again. What is still opened with the clock some way into
  the clip is a decoder that failed while it was kept, and the video
  layer that a property shows again (the rebuild that hid it left the video out of the graph and
  closed it). The seek is made once, by the first call that has the clock, and lands however often
  frames are drawn; the head of the clip is on screen while the seek and the catching up to the
  clock take, 0.35 to 1.5 s on the clips with a keyframe every 250 frames and up to 4.2 s on the
  one with every 600 ([video clock](../features/scene-rendering.md)). The open of a video
  packaged in a scene reads, hashes and writes the whole file (`WriteVideoPayloadToTemp`, staged
  from the parser's buffer, which the source shares rather than copies; about 7 ms a megabyte:
  0.2 to 0.4 s on a 53 MB clip, 2 s on a 319 MB one, measured before the copy was dropped), which
  every open of one pays. A text card's buffers are resized in place, as Wallpaper Engine does:
  a card that changes size in texels asks the renderer to allocate its targets again under the graph
  it has (`ConsumeRenderTargetResizeFlag`, `MetalRender::ResizeRenderTargets`, about 0.8 ms on a scene
  of 42 render passes a frame) and never to build the graph again, which compiled every pass, decoded and uploaded
  every image and copied every vertex buffer (about 54 ms on that scene; the figures are measured on 3589454154 in
  the entry on text cards that change size under scene-regressions). The Wallpaper Engine frame this
  was found against is a still one, so no frame of Wallpaper Engine's shows a video moving
  through a rebuild.
- **An image layer's brightness is applied where its colour is, ahead of its effects.**
  Wallpaper Engine multiplies it into the `g_Color4` of the layer's final composite and
  gives the effect chain's own passes a white one. Here the colour, the alpha and the
  HDR-only brightness go into the pass that draws the layer's image, the first of its
  chain, as the colour and alpha always have; the two agree for effects that scale
  linearly and can differ where an effect clamps or thresholds its input. A later pass
  whose shader takes `g_Color4` itself takes them a second time, because the layer's
  first pass has applied them already (a workshop effect that reads `g_Color4` or
  `g_Alpha` does; no core effect does). The passthrough that blends a layer onto the
  screen and the one that stands in for a chain whose effects a script has all switched
  off are given white and do not (the latter took them twice before, squaring the colour
  and the alpha); on a compose layer, whose first pass reads no `g_Color4`, that
  passthrough is where the colour and alpha land once. A puppet with bones under
  effects is the exception to "once": the layer's own pass draws its texture sheet,
  the effects run over that and a skinned pass of the layer's material, appended to the
  chain, draws the result, and both of them carry the layer's colour, HDR brightness and
  alpha, so an alpha of 0.5 draws 0.25, whether it is authored, bound, keyed or written
  by a script (a script's write reached only the skinned pass before it reached every
  material, and now draws as the authored one does). Wallpaper Engine's rule above would
  put them on the skinned pass, the final composite, alone, as the lighting of such a
  layer already is (applied once, after assembly); no Wallpaper Engine frame has been
  measured against this shape, so it is left as authored (the local scenes with an
  authored alpha under a puppet's effects are 3444535389 and 3808922316). An effect's
  own `g_UserAlpha` is left alone by a driven alpha, and an effect that sets none
  starts from the layer's authored alpha and keeps it; whether Wallpaper Engine starts
  such an effect from its shader's default instead has not been measured either. A
  bound, keyed or script-owned alpha therefore does not fade a layer whose effect
  replaces its picture and sets no alpha of its own (an effect that ignores its input,
  or one with `copybackground` off): the layer's own pass, which carries that alpha, is
  not what reaches the screen, while an authored alpha still does through the effect's
  seed. No local scene has such a layer with a driven alpha. A script bound to
  `brightness` and a direct `thisLayer.brightness` write both update
  the image layer's material brightness; the HDR-only gate and the effect placement
  described above still apply.
- **Shadow filtering differs at some edges.** Volumetric point and spot lights use
  their shadow atlas and cookie textures. Spot cookies also project their image in
  the existing lighting pass, including scenes
  with no shadow atlas; the last eligible packed cookie spot selects the texture
  shared by all cookie spots. Shadow and cookie subsets occupy Wallpaper Engine's light-array slots;
  point, spot and directional model shadows use the depth atlas. The directional
  cascade texel snap remains an inference from the shipped routine. The tested WE
  directional probe agrees in its lit and shadowed regions; exact edge filtering is
  not a pixel-identical match across the point/spot/directional probes.
- **A `lightconfig` whose shadow or cookie subsets exceed their kind's count is not
  packed as Wallpaper Engine packs it.** Its packer keeps writing past the kind's
  array into the next one (`sub_140190C80`); here a slot past the array is dropped.
- **Whether a layer under effects gets a lit closing pass is read from its combos.**
  Wallpaper Engine decides it from material flags its loader builds (`sub_1401515B0`:
  0x10 when the compiled program reads lights, 0x08 from a table keyed by the names of
  the textures it samples). Here `LIGHTING` or `REFLECTION` on, after shader defaults,
  stands for them; a shader that reads lights without a `LIGHTING` combo is lit in its
  card instead.
- **A vertex input the mesh does not provide is bound to the position, silently.**
  The renderer looks each reflected vertex input up in the mesh's attributes by
  name and, for a name that is not there, read the first buffer at offset 0 (the
  native renderer refuses only a puppet's bone indices and weights). That is
  right for an input a shader declares and never reads, and it hid a shader that
  reads one: a written input was reflected under another name until pipeline
  revision 16 ([Shader pipeline](scene-regressions.md#shader-pipeline)), and a
  model's tangent was named `a_Tangent` where Wallpaper Engine's shaders declare
  `a_Tangent4` ([Layers, textures and compositing](scene-regressions.md#layers-textures-and-compositing)).
  A picture that looks like a layer sampling at its vertex positions is this
  fallback. Reporting the miss, or binding zeros instead, cannot be done from
  reflection alone: a shader may declare an input it never reads (`flat` declares
  `a_Color` and reads it only under `VERTEXCOLOR`, so a layer drawn with it and no
  vertex colours has no mesh attribute for that input), reflection lists such an
  input like any other, and nothing in it says whether the shader reads it. That
  needs the use information first.
- **Texture containers: what is not settled against Wallpaper Engine.** `TEX<N>FORMAT` is
  defined for every file texture in slots 0-9 (the format code, 0 for a decoded picture);
  Wallpaper Engine's `sub_1401A5C40` writes it only for a sampler whose annotation passes a
  test at byte +128 of its slot record (`"formatcombo":true` is necessary, not sufficient:
  the texshader probe's T4 cells with `formatcombo` alone did not get it). Every shipped
  shader reads it only on such slots, so they see the same values; a custom shader testing
  `#ifdef TEX<N>FORMAT` on another slot differs. The in-memory texture flag 8
  (`sub_14015E580`, fewer than two mip levels) has no traced reader and changes nothing
  here. The choices a TEXB0004 variant record makes are kept (`ImageHeader::variantChoices`)
  but no reader of them was traced. Notes: `artifacts/we-parity/decompiles/E-D*.md`.
- **Planar reflection coverage.** `PlanarReflection` checks literal exclusion,
  hidden model admission, active drawn material slots, quality-off clearing,
  view-forward binding and HDR framing. `PlanarReflectionGpu` checks both sides
  of the world plane, moving cameras and sources, sorting across both phases,
  effects with MSAA, opaque output alpha, zero-valued self sampling, world/clip
  winding, bounded storage, shared geometry and idle frames. An active model
  sampler requests the raster-sized RGB8 colour picture; depth is needed only
  when reflection quality is enabled. Quality-off consumers retain the cleared
  colour picture. Image-only consumers do not activate reflection.
- **Other scene composition.**
  Custom sort order has a draw-order consumer, and `camerafade` applies to the
  top-level `camera.paths` queue.
  Post-processing quality selects no bloom, LDR bloom or HDR bloom. Display HDR
  encoding and output capability negotiation are implemented and were checked once on
  a built-in XDR panel by capture: only the overbright core leaves SDR (peak about 53
  against Ultra's 1.0, same median); perceived brightness was not compared with
  Wallpaper Engine.
- **Fog reaches an effect layer only where its own material takes fog.** The pass
  that fogs an effect layer where it sits (`effectpassthrough_4`, ending the chain)
  stands in for the fog the layer's own material (its `FOG` combo) would have taken,
  so a layer whose material has none (`genericimage2`, a custom shader) draws
  unfogged under effects as it does without them. Wallpaper Engine gates it the
  same way: the setup that builds a layer's composite (`FUN_140206ae0`) gives it
  `FOG_COMPUTED` and takes `FOG` and `FOG_COMPUTED` out again unless the layer's
  material has `FOG` on (absent or 0 removes them). The pass is added whether or not
  the layer's own pass is drawn, so a layer an effect generates (`copybackground`
  off) is fogged too. Compose, fullscreen and puppet layers, and a layer that blends
  onto the screen by colour blend mode, keep the fog of their own first pass, which
  measures it in the layer's card and not where the layer sits (the vignette an
  effect layer used to have). A text layer of a fogged scene is a composite whose chain ends
  in the same fogging pass, which matches the WE probe probetext-fog (text and a card at one
  place take one fog); its glyph passes are unfogged (G-F11), and which pass of Wallpaper
  Engine's fogs the composite was not read from the binary. A
  layer another layer samples (`_rt_imageLayerComposite_<id>`) also draws its last
  pass into that composite, from the layer-local camera, so the picture the other
  layer reads carries fog measured in the card, for a plain layer as for an effect
  layer and as it did before the fogging pass existed; what Wallpaper Engine puts in
  that composite is not known. A wallpaper assets folder without
  `materials/util/effectpassthrough_4.json` leaves an effect layer fogged in its card
  too. Established against one wallpaper's frame (the moon of the local corpus,
  within half a percent of Wallpaper Engine's tone in every ring of its disc) and the
  decompiled setup. Fogging a layer an effect generates is the decompile's alone: the
  setup checks one bit of the object's flags and never the `copybackground` bit, and
  the one local fogged scene has no such layer, so no Wallpaper Engine frame shows it.
- **Some timeline options are not followed.** A layer's `origin`, `scale` and `angles`
  and an image layer's `color` play their `animation` (loop, single, relative,
  start-paused with the first frame applied, named for `getAnimation`, keyed together
  through `options.parent` on one clock); the rest of the option set is not read. The
  `mirror` play mode plays to the end, back to the start and over again
  (`ScalarAnimationMode::Mirror`): the clock's position stays inside the timeline with a
  direction beside it, so component curves, `getFrame` and markers see real frames on the
  way back, and a marker is met on the way out and again on the way back (once at either
  end). Whether Wallpaper Engine shows the end frame once or twice at the turn was not
  compared with its frames (the local scenes use mirror on origin, alpha, light intensity,
  shader constants and bloom strength). A timeline on `alpha` keeps a clock of its own even when it is keyed
  under another setting, so a paused parent does not hold it. A text layer's or a light's
  `color` timeline holds the authored colour, and a timeline on a setting that also has
  a script or a user property is dropped (the script or property is its only writer),
  even when the script is only an event handler that calls `getAnimation().play()`: that
  start-paused timeline is neither shown at its first frame nor played, and with no
  timeline of its own the script's no-name `getAnimation()` finds the layer's first
  unnamed clock. A shader constant keeps its timeline beside its script, and there the
  no-name call is the constant's own timeline. A constant's script without `update`
  leaves that timeline the value and plays its clock, as Wallpaper Engine 2.8 does in a
  generated probe (2026-10-30). A script with `update` is still the constant's only
  writer: in the same probe, `update(value) { return value; }` beside a timeline its
  `init` played showed the timeline's end in Wallpaper Engine and the authored value here,
  and whether `value` arrives animated or the timeline overrides the script was not
  separated.
  That a start-paused timeline shows its first frame before anything plays follows the
  origin and shader-constant timelines here and the editor's start-paused flag being a
  play state beside the curves; no frame of Wallpaper Engine showing a paused scale or
  angles timeline has been compared.
- **A compose layer drawn with the `perspective` flag** still copies the screen behind it
  as the orthographic view places its card.
- **Object kinds not drawn or not modelled.** A `shape` object draws only an effect of
  a single pass: its last effect is drawn onto the scene as a mesh, so a multi-pass
  last effect, which would draw into buffers first, is left out (the editor's
  light-shaft effect has one pass). Its effects' visibility is read once: one a script
  switches keeps the value the scene file stores. A `sprite` object is read as a plain group and
  draws nothing. A simulated bone with a rotation
  spring but no tip (`tp` 0) is not turned, where Wallpaper Engine's normalised zero tip gives NaN;
  no library bone has one. Sound `spatialization`, `attenuation` and
  `mindistance` are not read, so every sound plays unpositioned.
- **Morph reference scope.** Image position/alpha morphs, model position/normal morphs,
  MDLA mesh curves and the blend-shape script methods drive the rendered picture. The
  image path uses the first mesh, as its reference composer does. The model tangent flag
  (`0x800`) preserves the reference loader's zero-filled texture branch; it does not add
  tangent deformation. More than 64 shapes and locale-dependent name matching beyond
  ASCII have not been verified. Unknown weight lookups retain the native float wrapper's
  numeric-zero result; the empty-name and negative-index cases have a WE control.
  A controlled WE probe confirms positive and negative model deltas, the position/normal
  layout, the zero-weight control, and no deformation on bone-free models with either
  automatic or explicitly authored `MORPHING`. A known-valid image-puppet container with
  one added shape and a mixed-case script weight shows the same visible displacement in
  WE. These controls do not establish general pixel parity for modifiers, alpha morphs,
  larger animation stacks or prelighting.
- **Image-puppet IK scope.** Explicit MDLS chains solve their animated position and pole targets;
  target reference poses, additive weights, clip offsets, stored neighbour directions and
  planar `ikce` limits are consumed. The solver's ten-sweep limit can leave a reachable target
  outside its squared-distance tolerance of 0.1 on that frame. Ordinary target blend rules
  (`sub_14026F4C0`, flags 0/1) consume their MDLA weight curves and source-bone transforms.
  Axis-projection target rules (flag 2, including flag 3) blend the closest point on
  the source bone's local X line for every matching stored segment endpoint; source
  axis scale does not change the result. Weight curves, rotated/scaled axes, ordered
  rules, repeated endpoints, unmatched owners and preserved target orientation have
  CPU coverage. A constant-weight 0/1 image-puppet axis control shows the same visible
  limb displacement in WE and the native renderer, improves the fixed arm/chest-region
  comparison, and leaves the zero-weight native frame pixel-identical. High-bit
  grounding rules now clamp targets and reflect joints on the first sweep;
  ordinary non-IK image bones consume their full-transform blend rules. The
  correction is gated by iteration 0 and `0x10000`, independently of blend weight;
  ordinary flags 0/1 do not enter it. Targeted CPU regressions and five WE controls
  cover these consumers; sampled world bone positions agree within 0.0002 canvas
  units, including six consecutive frames of a zero-weight alternating solution.
  Full-pose frame parity is not established. A near-collinear signed-side diagnostic
  is sensitive to one float ULP and is not used as a branch-equality assertion. A position-only 0/1 control
  shows the linked limb moving toward its source in WE and the native renderer, while
  zero-weight native output stays pixel-identical. The control scene retains existing
  placement/shape residuals. Full-transform and weight-mixing boundaries have CPU
  coverage, not a general WE frame-parity claim. Rope Verlet points, distance constraints,
  free endpoints and stretch are implemented. The scene force interface is connected for gravity and wind: its second
  query is the wind field (`sub_140198910`), not a collision query. The bone's authored
  `gd` remains separate. The local
  comparison scene, 3799253558, contains planar single-link chains. Moving only its target
  matrix and target-track positions gives a visible image-puppet control in WE. Its captured
  Windows Update dialog obscures the centre, so only the unobstructed arm region supports
  that comparison, not full-frame colour equality. Three-dimensional `model` layers keep
  forward kinematics: both their separate compositor and a visible model control leave IK
  inactive. Controlled rope variants of the same valid image container show no force,
  downward scene gravity and upward scene wind through repeated SceneScript writes in
  WE. These direction controls do not establish exact constraint/recovery timing or
  general trajectory parity. Out-of-plane image-rope layers (the same gravity control
  with the layer turned 60 degrees about x or about y, probes p5rope-tilt/-yaw) place
  the rope and figure as WE does, and the remaining differences are the existing pose
  residuals of the untilted control. Branched ropes: none of the local workshop puppets
  has one (four rope chains across 3292361861, 2998757800, 3799253558, all single), so no
  branched control exists to build from a real file.
- **Texture mips are chosen from the display, not from each layer.** A 2D scene's
  packaged chains are cut at the display's longest edge (a level is dropped only
  while the next is still that long), so a texture about the size of the screen keeps
  its full-size level, as Wallpaper Engine samples it. A layer drawn larger than the
  display, such as a scaled-up one or a layer on a canvas wider than the display,
  still samples a level that only covers the display, softer than Wallpaper
  Engine's. Choosing each layer's level from its projected extent at graph compile
  would fix that and keep the full-size chain for those layers only, at the price of
  more texture memory for them than the display rule; the figures from the mip
  headers of one machine's library are in `ThirdParty/provenance.json`
  (`textureMipBudgetChanges`).
- **Ordered layer resources have a bounded cost.** Transparent sorting permutes
  complete object groups while keeping prepared pipelines, geometry and uniforms.
  Temporary targets used by several sorted objects retain separate images because
  a depth crossing can overlap lifetimes that were initially disjoint. Targets
  confined to one object still share normally. Earlier composite readers sample
  retained previous pixels; later readers sample current pixels, including when
  transparent sorting is disabled. These dependencies can split render batches.
  The storage is bounded by the scene's declared targets and prepared sample-count
  variants; a depth change does not allocate textures or rebuild the graph.
  `TransparentSortingGpu` and `TransparentSortingLifetimeGpu` cover effects,
  shared FBOs, history catch-up, self-links, first-use loads, MSAA, setting changes
  and resize. The direct video path prepares each reachable sample-count variant
  before adoption rather than adding a conversion on every depth crossing.

- **Texture sampling.** Shadow receivers bind a linear, border-zero, GREATER comparison
  sampler to the depth atlas. File textures are sampled as Wallpaper Engine samples
  them: anisotropic 8x unless the header asks for point sampling, render targets and clips
  linearly (`sub_140099980`, `TexContainer.FileTexturesAskForEightfoldAnisotropyUnlessPointSampled`;
  `artifacts/we-parity/decompiles/E-D6-D7.md`). Runtime glyph atlases are linearly sampled
  and clamped to their edges. A slot naming an `_alias_*` texture reads
  transparent black outside 0..1, as Wallpaper Engine's alias wrapper does. Its GPU cost on scene 3662790108 is measured
  by `LocalProjectEnergyIsMeasuredHeadlessly` (A/B pending).
- **Text details not matched.** Text is shaped with HarfBuzz as the
  reference shapes it (OpenType and AAT kerning, ligatures, complex scripts); like the
  reference it has no bidi algorithm (decompile `G-F2.md`), so a right-to-left word in the
  same face as Latin text around it keeps logical order. A glyph the layer's font lacks is
  drawn from the first face of Wallpaper Engine's list that has it (Arial, Segoe UI Emoji,
  Segoe UI, Twemoji, Segoe UI Symbol, Microsoft YaHei, Malgun Gothic, Arial Unicode), here
  Arial, Apple Color Emoji, PT Sans, the assets' Twemoji, Apple Symbols, PingFang SC, Apple
  SD Gothic Neo and Arial Unicode MS. Apple Color Emoji is a bitmap font, so its glyphs are
  drawn from the strike nearest the layer's size and scaled (Wallpaper Engine leaves the
  choice to FreeType on a scalable Segoe UI Emoji), and a COLR v1 glyph, which FreeType does
  not render in colour, is drawn as a monochrome outline. Arial Unicode MS is last and not
  third, because that font is Office's and not Windows' (on a stock install the reference
  draws Chinese in Microsoft YaHei, whose Simplified Chinese punctuation PingFang SC shares;
  Arial Unicode MS in the third place would draw it in its own forms). That order of the
  reference is read from the decompile; what a Windows machine with Office does with it
  is not. The font files are macOS's, not the Windows fonts a scene was authored with: of
  the eight keys a text object honours, four are on every Mac as the same fonts (Arial,
  Comic Sans MS, Microsoft Sans Serif, Verdana) and four are stood in for, fitted to the
  real font's digit advance and line. Consolas is Andale Mono, whose digits stand 0.643 em
  tall as Consolas's do (87 of 87 pixel rows in the clock of 3299228616 against
  Wallpaper Engine's frame, and the digits within a pixel of its baseline). Cambria is
  Charter (lining digits, the same cap height) and Segoe UI and Calibri are PT Sans:
  their glyph shapes and widths other than the digits are those of the stand-in, so a
  heading in them is a few percent off, and the ascender and descender of those three
  are the fonts' as remembered, with only the sum of the two (the saved cards' line)
  checked. The web host has the same fonts under the same names and the same fits, set
  per page (see [web wallpapers](../features/web-wallpapers.md)), but its generic families
  and its line metrics are not. The glyphs are Wallpaper Engine's quads from atlases through
  its `font` shader; the plain coverage atlas is rendered with the FreeType hinting the old
  raster used, which the decompile does not settle (`FUN_1401ae080` was read for the
  distance-field path only). That a colour blend makes a text layer a seeded composite is
  read from the decompile (`G-colorblend-composite.md`), not seen in a frame: no probe of a
  translucent text with a colour blend has been captured, and the colour blend Darker Color
  (5) or Lighter Color (10) over a seeded composite is not compared either.
  An `opaquebackground` is drawn by the `fontbackground` quad before the glyphs (straight onto
  the scene) or as the composite's seed fill. A synthetic reference confirms the ordinary
  opaque card and its use as a particle donor; an opaque background through an effect chain
  is not compared. Text donor references also confirm hidden plain and MSDF text, the
  squared-alpha threshold and outline and shadow colours. The colour-emoji donor probe's
  visible control was blank, so it provides no evidence for that case. The screen `anchor` of a text layer
  shifts its draw by the margins of the area the display shows, as a translation in the
  scene's axes that its children do not inherit; that the shift is made in the scene's
  axes is read from the decompile, and that its margins are those of the visible area
  is inferred, with no frame of a display whose shape differs from the canvas to
  check either. Where the right edge of a right-aligned text lies is the ink's own
  (the last glyph's bearing is not added): the probe frames agree to a unit on every
  glyph measured, which does not settle an italic or a glyph with a large right
  bearing. A script's unknown alignment word takes the registry default, `left`
  horizontally and `center` vertically. A WE getter probe confirms both, anchor's
  `none` default, vector/boolean member types and signed `maxrows` readback; the depth
  enum's default is `disabled`. `ScriptRuntimeCompat.TextAlignmentUnknownWordsUseTheRegistryDefaults`
  covers the alignment behavior. A text layer's `brightness` follows the active HDR
  pipeline: `hdr`, `bloom` and Ultra or Display HDR post-processing, the same predicate
  that gives the scene its 16-bit targets. The quality gate is implemented, but no WE
  text frame has been compared across those quality levels; the earlier brightness
  observation was on an image layer of one local HDR scene. Text effect buffers apply
  the same scale, explicit width/height and fit rules as image effects. Buffers without an explicit
  extent follow text changes at their authored ratio; explicit extents stay fixed.
  They are still the text layer's own: Wallpaper Engine shares
  a non-`unique` buffer between every effect that names it at the same size and scale
  (`sub_1401EA500`), which image layers do here, but a text card's buffers follow the card as
  the text changes, so they are never shared. A text layer's composite is Wallpaper Engine's in what
  its probes show: the card is seeded with the scene behind it and its glyph pass writes
  the alpha squared (the translucent blend's alpha rule, `TranslucentBlendAlpha`), so text
  through an effect stands at
  the alpha cubed (`TextCompositeReach`; probetext4's `opacity` effect and the clock of
  3819684521; the `blurprecise` heading of the same scene, at alpha 1, shows the seed). **Open:** whether an effect that leaves alpha alone gives the same.
  The cube is measured for `opacity` chains only (probetext4 and the clock); the one frame of
  another chain that is measured at an alpha below 1 says it differs: the VHS timestamps of
  3465215190 through `skew` and `pulse` stand at the alpha squared in Wallpaper Engine and
  at the alpha cubed here. Most translucent text layers with an effect in the local corpus
  go through other chains (`blurprecise` the most, `opacity` about a third of them), so the
  exponent decides how they look. The alternative that fits every measurement is a glyph pass
  that keeps a single alpha and an `opacity` effect that takes the layer's
  alpha for its own whatever its constant says; that is a rule about effect passes that this
  change does not make (the tests derive their expectations from `TextCompositeReach`). A capture of black text over white at alpha 0.65, 0.5 and 0.8
  through each of `opacity` (the control), a no-op `transform`, a no-op `skew` and two
  `transform`s settles it: the cube in every column is this model, the square in all but the
  `opacity` column the alternative. The seed is sampled
  where the card lies without the camera's parallax, so under parallax it lies a few
  pixels from the scene it is drawn over. An LED source or an opaque background without an
  effect pads the card but is no composite here: Wallpaper Engine seeds a composite for an
  effect pass or its composite flag (`sub_140258900`), and which object bit besides a colour
  blend sets that flag (`sub_1401E6F50` also tests 0x100 of the object's flags) was not traced. A card past 4096 texels on
  a side is drawn into buffers cut to 4096, where Wallpaper Engine has no limit of its own.
  Scene-file bindings for style switches and layout keys remain load-time choices;
  direct assignments through `thisLayer` are supported separately. They cover layout,
  background, MSDF, outline/blur/shadow, anchor and depth-test members. Uniform-only
  writes do not lay text out or rebuild its graph; a material variant changes once per
  event, after a matching replacement atlas is ready when its kind changed. WE pairs
  compare authored values with script-written values for padding, spacing, limits,
  styles, MSDF and background. Actual depth occlusion after a setter and preservation of
  tint/alpha bindings have private GPU regressions; the orthographic reference's depth
  member is a readback/equivalence control, not proof of perspective occlusion.
  Only one text write
  is compared with Wallpaper Engine: a text script that writes `thisLayer.text` from
  `update()` and returns nothing keeps the write. Not established, and kept as the
  renderer had it: a script that writes and also returns a string shows the returned
  string; a write from a script that does not own the text property (a visibility
  script, a scene script, a cursor or media handler, another layer's script) lasts
  until the property's own value is applied on the next tick, and a text script's write
  from a handler does the same. Which of two scripts writing one text Wallpaper Engine
  shows depends on the order it runs a layer's scripts in, which was not read from the
  binary. The one frame that covers it, a media widget whose text script returns an
  empty title while its visibility script writes the sound layer's name, shows the
  text script's value.
- **Layer colour writes.** An image layer's colour that a script or a user property
  decides takes what a script writes to `thisLayer.color` as its value, on every
  material the layer draws with. Not matched: a write to an image layer whose colour is
  bound to nothing reaches only the layer's own material, not its effect passes; and a
  write from a script that does not own the colour (a handler, a scene script, another
  layer's script) lasts until the owning script's `update()` returns a value or the
  property changes, so which of two scripts writing one colour Wallpaper Engine shows
  was not read from the binary. A text layer's `color` is bound to its own material
  constant, which is applied every tick, so a script that only writes `thisLayer.color`
  there (one local scene's song-title text does) keeps the scene file's colour; a text
  script that returns the colour is followed. That gap was seen in a probe, not
  against a Wallpaper Engine frame.
- **Cursor walk details.** Layers are walked in the scene's layer order, and the quad
  test keeps a coverage mask for layers whose scripts handle the cursor, which
  Wallpaper Engine's does not have. Wallpaper Engine lets no blocker stop the walk while
  a button is held with a captured set; here a blocker that comes in front of a pressed
  layer before the release cancels its click. Both fire the click on release over the
  layer that took the press, and the order of `cursorUp` and `cursorClick` here (up
  first) was not read from Wallpaper Engine.
- **Perspective cursor point.** `input.cursorWorldPosition` in a perspective scene is worked
  out when the cursor is sampled, through the camera as the last tick left it, before this
  tick's scripts and camera shake move it, so a camera moved in the same tick shows in the
  value one frame later. Wallpaper Engine unprojects when the script reads; whether its
  scripts run before or after it rewrites the view each frame was not established. The
  cursor callbacks' `position` and `worldPosition` (and `input.cursorLocalPosition`) carry
  the same far-plane point. A program of a layer also gets `localPosition`, where the cursor
  is on that layer's box from its lower-left corner, 0 to the layer's size on each axis while
  over it, as Wallpaper Engine's reference describes it (`SceneRuntimeContext::CursorLocalPosition`,
  from the same plane point the hit test uses; a held button's release can be off the box and
  is not clamped); a program of the scene itself gets none. That the vertical axis runs up
  from the bottom, as the world's does, was not compared with a Wallpaper Engine frame, and
  the event's `hitBox` (a puppet's hit box) is not given. The
  pointer maps over the presented frame, so a cropped window looks through the picture's
  interior and a letterboxed presentation extrapolates the ray past the frustum, as hit
  tests already do. A camera without a usable view (a far plane or aspect that is not
  positive) leaves scripts the canvas point.
- **Model utility flags.** A project layer is sized by the canvas. Like every passthrough
  layer with effects it draws its children into its own buffer (Wallpaper Engine
  `sub_1401E8AA0` tests the object's passthrough flag, not the model's path), but it has no
  composite-only mode. `autosize` alone, which sizes a layer by its texture, and
  `solidlayer` are read and not applied.
- **A string property bound to a setting without a condition.** A flag (a layer's
  or effect's `visible`, and every other bool bound by name) reads the string as
  `true` or `1` and is false for every other string, which covers a combo's
  choice and also a text input, file, directory or texture property; a number
  reads 0 whatever the string. A combo that `project.json` declares as a number is
  a number until the app sends a choice (a string): on for any whole number but 0,
  so `2` is on as the authored default and off once picked. Wallpaper Engine's
  frame shows the flag only at the combo's default `1`, and nothing shows what it
  does with another choice, with a text property or with a number, so those
  readings are this engine's own.
- **A lone `pixels_equal=false` on a large scene is not by itself a regression.**
  On an unmodified build a 4K scene's `frame-2` has been seen once to differ from
  its isolated twin by a few levels everywhere (no clock, label or single layer),
  in a pooled run only, so allocation reuse is not ruled out. Re-run it, and
  investigate if it repeats.
- **A target a parallax layer draws into is never reused.** The
  static pass sample (`MetalRender::Impl::frameSample`) does not include the parallax offset
  `WPShaderValueUpdater::UpdateUniforms` adds to a layer's model matrix (a plain
  text layer's too: it follows the cursor like an image layer of its depth, and so
  is the first pass of a compose layer with effects, which reads the screen where
  the layer's card is drawn), so
  `FrameVaryingUniforms` reports such a pass as `kParallax`, which becomes
  `PointerUniform` and keeps the whole target out of the cache
  (`StaticSubgraphCache::Compile`), whether or not the cursor moves. With
  on-demand rendering off, a scene whose only motion is parallax redraws its whole
  frame at the frame cap, as it would with scene optimisation off. Without the
  report the cache would reuse those targets while the cursor moved and parallax
  would stop following it. Folding the offset itself into the sample would allow
  reuse while the cursor is still.
- **On-demand rendering stops parallax partway.** A scene that sleeps wakes for
  one frame per pointer event (`wakeForPointer`), but nothing asks for frames
  while the layers are still easing toward the cursor, so after the pointer stops
  they rest partway and catch up at its next movement. Parallax eases as Wallpaper
  Engine eases it, closing `(1 - cameraparallaxdelay / 3) * 10 * frametime` of the
  remaining way each frame (`WPShaderValueUpdater::FrameBegin`), which approaches
  the cursor without reaching it; a correct demand needs a threshold on the offset
  still to travel.
- **An animated material constant keeps a scene awake after its timeline ends.**
  `DescribeTimeAdvancingWork` reports `NodeBinding` for every material-constant
  binding that has an animation, playing or not. The timeline's clock is a
  registered playback (`RegisterScalarAnimation` in the parser), which the
  `Animation` reason already counts while it plays, so with on-demand rendering
  on, a scene whose only motion was such a single-play timeline keeps ticking
  after it ends.
- **Layer-image source coverage.** `layerimage` reads CPU-backed RGBA8, BC1/2/3,
  R8/RG8 images and on-demand text glyph samples; encoded video payloads are never
  interpreted as image pixels, and video/render-target donor pixels have no CPU emission
  source. Colour-emoji donor frame parity is not established: the probe's visible emoji
  control did not render, so its empty particle output is inconclusive. Puppet points use their UV triangle and the most recently
  evaluated skin palette. Ordinary particle emission precedes the runtime's pose
  update; visual attachments consume that pose after its evaluation rather than
  advancing their parent during `FrameBegin`. Cross-object emission timing has not
  been compared with Wallpaper Engine.
- **Particle differences from Wallpaper Engine 2.8.42 that remain.** Not
  implemented: a `remapvalue` that
  outputs `controlpoint` (the engine moves the control point from the particles; this port
  writes nothing, including when a nested child would consume that per-instance output), the blended kernels of `vortex_v2`, `remapvalue` and `inheritvaluefromevent`
  (opcodes 37, 39, 40 did not decompile: the blend window lerps the particle between its old
  and new state, `vortex_v2` weighs its whole velocity change), and the arguments of
  `remapinitialvalue`'s noise transforms (it calls the engine's 1D simplex; this port feeds
  it the transformed input). `positionbetweentwocontrolpoints` reads the output control
  points, as the kernel does. `boids` steers a slice of the particles each step by the
  subsystem's own step count, where the engine counts frames (`artifacts/we-parity/decompiles/F-D9.md`
  to `F-D12.md`). Rope-trail `fadealpha`/`fadesize`, the thin vertex layout and
  history recording after a sprite renderer now follow the engine, and so does the
  recording clock (whole frames, first frame due, no prewarm recording); trails in
  the synthetic probe are as long as Wallpaper Engine's within one recording period.
  The `0x1402309B5` count/target-FPS product belongs to the plain-rope texture length,
  not the trail history. Rope texture coordinates follow WE's writer (probe rope-uv-v3/v4),
  including `uvsmoothing` once a rope holds its steady count (probe rope-uv-v5: within
  0.01 of v at the matched frame) and the `TRAILSCROLLALPHA` branch of a scrolling rope
  trail. Ropes are drawn through the shader's geometry stage, as on WE's DX11
  path, one record per pair subdivided by the stage; the synthetic trail probe is
  straight and untextured, so curved ribbons and their texture spacing have not been
  compared with Wallpaper Engine. A rope shader whose geometry stage does not translate
  keeps the vertex-only path, with its fixed eye direction and its half-width offset
  (an operator-precedence slip in the shipped `.vert`). Child-entry flag 1's live-parent-particle feed and
  remap-written control points are implemented; the start index does not shift emitter
  indices. The blended operator kernels (opcodes 28-40) decompile once the
  interpreter's jump table (`0x14023FBC0`) is read to all 40 entries; IDA stops at the
  empty opcode-27 slot. The blended remap and inherit kernels lerp from the old value to
  the unblended result by the window weight, as implemented.
  Control-point flag 4 and raw flag 8 now copy registered parent frames. The old
  emitter-only probe did not register the referenced parent point, so its no-op was
  the missing-source fallback and did not establish the general rule.
  World-space remap inputs now distinguish absolute positions/control points from
  relative distance/direction inputs. The blend window (`blendin*`, `blendout*`) weighs what the blended kernels weigh:
  `angularmovement`'s force, turn and clamped drag, `controlpointattract`'s pull after flag 2
  caps it, the oscillators' amplitude, the maintain-distance operators' displacement,
  `reducemovementnearcontrolpoint`'s reduction and `capvelocity`'s cut. The engine computes the
  weight and the life position with approximate reciprocals (`rcpps`), which this port
  evaluates exactly. `alphafade` divides exactly where the engine
  uses approximate reciprocals (`rcpps`). Restarting flagged children at a periodic window, the audio
  emitters' burst and silence rules (a burst waits for sound and is scaled by it), and an `eventspawn` child's emitters
  outliving its particle are unchanged. The force step's frame interval is taken as one over the
  scene's frame-rate cap (`artifacts/we-parity/decompiles/F-D5.md`: the engine divides by a field
  whose writer was not found; at a steady cap the two agree), and a start-time prewarm runs before the
  cap is known, with full steps. The app's default cap is 15 frames a second, so a default-configured
  scene's drags, attraction, turbulence and vortex act over about half of each step and its
  operators run in two half steps, as Wallpaper Engine's do at that cap. A particle's size is held at twice Wallpaper
  Engine's (the generators draw half of it, so the size initializers start from 1 where
  the engine starts from 0.5). A single `sizerandom` and an inherited `setsize` come out
  the same, and an inherited `multiplysize` multiplies by half of the parent's size, as
  the engine multiplies its own (from the decompile; no frame shows it). A scene
  object's `size` override reaches every `sizechange` ramp, as the binary's loader binds
  it to each size record, but it multiplies the finished size once where the binary
  scales each `sizerandom` draw: the same for a file with one size initializer, but
  the override squared for one with two and no scaling at all for one with none
  (no local preset with an override has either, so no frame shows it). Turbulence,
  `positionoffsetrandom` and `turbulentvelocityrandom` use the engine's own simplex functions
  (3D, 2D and 1D, read off the decompile; `artifacts/we-parity/decompiles/F-D1.md` to `F-D4.md`)
  in single precision; the 3D one keeps the engine's corner masks, which pick no second corner
  where two cell offsets tie, so its value can pass 1 on those planes. `maxcount` is still capped at 20 000
  particles per file. A `worldspace` file is simulated and drawn in scene units from its
  layer's origin, as the binary's draw replaces the model matrix with the scene's own
  for it: the layer's turn and scale shape the offset an emitter or a control point
  places a particle at (the emitter's origin is added after, unscaled) and the
  velocity a `velocityrandom` or `turbulentvelocityrandom` initializer draws (an
  emitter's own `speed` follows the stretched offset at its authored value), while
  size and the operators' forces do not follow the layer; a control point pinned to
  the world keeps its authored matrix, so an emitter on it, and the velocity
  initializers its particles meet, are not stretched; live particles stay in
  place when the layer moves, turns or is rescaled. The system's child systems still
  draw through the layer's matrix times their own, as the binary draws a child that
  is not itself `worldspace`; what the draw's base matrix is while a layer draws its
  own child objects was not traced, so a `worldspace` layer there keeps the scene
  origin. A child system's origin scales with the layer
  unless its parent is `worldspace`, in which case it stays in world units; an event
  child follows its parent's flag alone, whatever its own file says. The worldspace
  parent and the event child rules are read from the 2.8.42 binary's child matrix
  composition; no reference frame shows either. A static child whose own file is
  `worldspace` is not settled (the binary builds it from its bare local matrix and
  the spawn matrix that follows was not traced) and keeps its offset in world units.
  Emitter defaults for a scene without a pixel canvas (sphere `distancemax`, box
  `directions`) are still the pixel set. A scene that names no `orthogonalprojection`
  is still drawn here as the default orthogonal canvas, while Wallpaper Engine's
  scene starts without an orthogonal projection; its particle defaults follow what
  is drawn (the pixel set), not the engine's scene-unit set. An event child's
  instance is prewarmed at the moment it spawns, inside the frame, as Wallpaper
  Engine does:
  a start time of 15 s costs about 300 steps of that child file's own system per
  spawned instance (about a millisecond on the local library), so a burst of
  many spawns with a long start time in one frame costs that many times as much;
  spreading the work over frames is not done, because it would change what the
  instance looks like when it first appears.
- **A cover layer while nothing plays.** The layer colour of a layer that binds a
  cover stays white (`WPImageObject`), so the art, or the engine's own white
  placeholder a layer leaves in the slot, draws untinted while nothing plays; whether
  Wallpaper Engine tints it with the layer's colour is not established, and no local
  scene sets a colour on such a layer. A cover layer that hides itself through a
  `mediaPlaybackChanged` script stays visible with no player, here as in Wallpaper
  Engine, which sends no media event until a player reports.
- **Layer transforms and attachment coverage.** `setParent`, attachment lookup/world
  queries and `transformAttachmentToTexture` have native consumers alongside the
  existing transform methods. Parent adjustments retain WE's component rules and
  attachment snapping. Nested composition-depth rejection and degenerate projection
  inputs have not been fully compared with WE.
- **Image layer members a script writes after load.** `colorBlendMode`, `perspective`,
  `nointerpolation`, `clampuvs` and `ledsource` read back what a script wrote and change nothing
  drawn: Wallpaper Engine reads them only when it builds the layer and its setters only write the
  field. A `perspective` write does move where the
  layer is hit, as Wallpaper Engine's cursor ray (`sub_1401EDB20`) reads it on every event.
  Image-layer `castshadow` produces no caster, as in Wallpaper Engine; model-layer
  `castshadow` controls its shadow draw live.
- **`sortorder` does not order the draw yet.** A layer's `sortorder` is read and a script can
  write it, and with `general.customsortorder` a write rebuilds the graph, but the graph builder
  does not sort by it: Wallpaper Engine draws a custom-sort-order scene's objects in ascending
  `sortorder` (stable, `sub_14018AAC0`), which is the draw-order work still to come.
- **The end of a video that does not loop.** Wallpaper Engine hands `loop` to its decoder
  (`sub_1401FA700`) and what the decoder does at the end was not read: here the clip holds its
  last frame, `isPlaying()` reads false, `addEndedCallback` listeners run once on the next tick,
  and `play()` starts the clip again from its first frame.
- Unimplemented non-audio scene features, including some script outputs, can
  still affect wallpaper compatibility even when every renderer check passes.
- No renderer check proves desktop presentation, AppKit behavior, live audio
  capture, real input capture, or visual equivalence. Those need the authorized
  manual checks in [manual-smoke.md](manual-smoke.md).
