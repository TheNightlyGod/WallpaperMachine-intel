# Power benchmarking

How to make a power claim about this project believable: the configuration
record, the counters, the condition matrix, the comparison rules a measurement
has to satisfy before it may be reported, and the measurement mode that takes
one.

Test strategy and the layers around this one: [README.md](README.md).

## Configuration manifest

Two runs are comparable only when the content, the real presented frame rate,
the output geometry and the machine state match. Brightness, HDR, an external
display's own panel power, charging state and thermal history all move the
result more than most renderer changes do. `python3 scripts/power_benchmark.py`
writes that configuration to `artifacts/power/manifest-<timestamp>.json`:
workspace commit and whether the tree was dirty, requested build configuration,
chip and memory, macOS build, every online display's pixel geometry and refresh
rate, charging and low-power state, recorded thermal warnings, current host
Homebrew versions, and the pinned revisions of the vendored code in `ThirdParty/`. These
workspace and host fields do not identify the application already running.

Schema version 2 separates `workspace`, `host_renderer_libraries` and
`workspace_upstream_revisions` from `build.processes`. During a measurement, the
latter records each measured app/extension PID's executable path and SHA-256,
binary architectures, bundle version and build number. The process launch time
and file identity must remain unchanged across the read and measurement; a
bundle changed since launch, exited/reused PID or unreadable file is reported as
unknown. Source revision, build configuration and loaded renderer dylib versions
remain explicitly unknown because the running process does not expose them.
Never substitute the worktree HEAD or current Homebrew symlink for those values.
Identity hashing happens before the sample window.

Without `--measure` the script measures nothing. Every condition is written as
`"measured": false`, and `measurement_tool` stays `null`. `--print-only` emits
the document without writing an artifact.

## Measuring a window

`--measure SECONDS --condition ID` samples the processes a condition is about
and the machine as a whole before and after a window of that length and writes
`artifacts/power/measure-<timestamp>.json`: the manifest, `"measured": true`,
the sources in `measurement_tool`, the condition marked measured, and
`measurement` with the actual elapsed time, one row per role, the coalition
energy, the system power and the package power. One line per role is printed,
e.g. `app: CPU 38.2 %, GPU 65.1 %; coalition CPU 67 mW, GPU 5434 mW`, then the
total over all coalitions. The window is always the length asked for: a
powermetrics that fails or is refused at once does not shorten it.

| Role | Executable | Note |
|---|---|---|
| `app` | `WallpaperMachine` | |
| `window_server` | `WindowServer` | Composites every window, the wallpaper included |
| `core_audio` | `coreaudiod` | Runs the system audio tap an audio-reactive wallpaper asks for |
| `web_content` | `com.apple.WebKit.WebContent` | Every such process of this user, not only this app's |
| `extension` | `WallpaperMachineExtension` | Lock-screen extension, when running |

- **CPU %** is the growth of `ps -o time` (user + system) over the window.
- **GPU %** is the growth of `accumulatedGPUTime` summed over the process's
  `AGXDeviceUserClient` entries in `ioreg`: how long its command queues kept the
  GPU busy. It is utilisation, not energy. A process whose GPU client closed
  during the window reports no GPU value instead of an undercount.
- **Coalition energy** is the CPU and GPU energy the kernel charged to each
  role's resource coalition over the window, in mW, plus the total over every
  coalition, read without privileges the way the app's own Energy use readout
  reads it (`coalition_info_resource_usage`; see
  [performance](../features/performance.md#energy-use)). It is the figure to
  compare WindowServer by: its coalition is its own, while `ps` CPU time says
  nothing about energy. The app's coalition includes its XPC services and every
  WebContent process it started, so the `web_content` row counts only other
  coalitions. GPU energy is the whole GPU's energy shared out by GPU time, so
  when other coalitions keep the GPU busy for 25 % of the window or more the
  window is marked contended and the app's figure reads high.
- **System power** is the whole machine's mean draw over the window, from the
  battery controller's own running sums in `ioreg -r -c AppleSmartBattery -a`
  (`PowerTelemetryData`): `AccumulatedSystemLoad` over
  `SystemLoadAccumulatorCount` for what the machine consumes on either power
  source, and the `SystemPowerIn` pair for what the adapter delivers, charging
  included, when there is one. It needs no privileges, it is what a menu-bar
  watt meter shows, and it is the only figure here that includes memory, the
  display and everything else outside the CPU and GPU cores. It includes every
  other application too, so it is only ever compared against a paired baseline.
- **Package power**, with `--powermetrics`, is the mean of every
  `powermetrics --samplers cpu_power,gpu_power -i 1000 -n SECONDS` sample:
  CPU, GPU, ANE and combined mW. powermetrics needs root. The script runs it
  directly when it is root; with `--sudo-password-stdin` it reads one line from
  stdin and passes it to `sudo -S` on stdin only — never in arguments, the
  environment, the output or the artifact; otherwise it tries `sudo -n`. A
  refusal is recorded as `package_power.measured = false` with sudo's reason,
  and the other rows are still written.

The `app` role is every process named WallpaperMachine, and its figures are summed,
so a second copy (the installed app beside a build under test, or a copy left from an
earlier run) would be measured as part of the first. A window therefore refuses to
start while more than one copy runs. `--app-pid PID` names the copy to measure and
refuses while any other runs; a copy that starts during the window is listed under
`measurement.app_guard.appeared_during_window`, and the window is to be rejected.

`--home DIR`, the measured copy's `WALLPAPER_MACHINE_HOME`, attaches the diagnostics
report that copy logged under `DIR/Logs/<launch>/` (the launch folder named at the
process start; with `--app-pid`, never another launch's) as `measurement.diagnostics`:
the report's own `window elapsed_ms` and, per renderer surface, its counters with draws,
present requests and shown frames per second over that measured window. It waits up to
`--home-wait` seconds (60) after the window for the report, because the two windows
start independently. `--output FILE` writes the document there instead of a new file
under `artifacts/power/`.

A desktop run (which needs authorization, see [Authorization
boundary](#authorization-boundary)) is taken serially, with the display set and
power source unchanged across a comparison; [Desktop A/B runs](#desktop-ab-runs)
automates the procedure below. By hand: quit the app with an Apple Event and
wait until it has exited (`open` can fail with `-600` for a few seconds after
that; `kill -TERM <pid>` quits it the same way, but a second signal ends it at once,
perhaps before the desktop picture is restored, so wait for the exit), launch with
`open --env WALLPAPER_MACHINE_DIAGNOSTICS=60 --env
WALLPAPER_MACHINE_DIAGNOSTICS_DELAY=120`, and start a 60-second measurement 120
seconds after launch. These independently started windows approximately overlap;
the delay alone does not synchronize their boundaries. The diagnostics report's
`window elapsed_ms` gives its own measured duration, and `draws_executed` divided
by that duration is diagnostic-window draw throughput, not displayed FPS. A
same-throughput power claim needs timestamped counter deltas aligned to the
actual power window. Neither the configured ceiling nor timer-wakeup counts
provide elapsed time or displayed-frame counts; `presented_frames` over the same
duration is the rate the display showed the wallpaper's frames at (see [Present
feedback](#present-feedback)).

The app opens its control panel at launch, and animated previews add frame decoding
in the app and WindowServer work (Discover and Installed animate the tiles on screen;
with **Play Library previews only on hover** on, Installed animates only the tile under
the pointer or keyboard focus, see [control panel](../features/control-panel.md)). Launch with `--env
WALLPAPER_MACHINE_PANEL_AT_LAUNCH=0` to keep it closed, as a login launch does (read
once at launch; an unfinished welcome guide or a failed start still opens it), so the
window measures the wallpaper alone; otherwise say whether the panel was open and on
which page. With the panel closed the app's own energy recorder samples too (its
`EnergyRatings.json` in that home is a third readout). The cost of Installed's
animated tiles against the hover-only setting has not been measured: compare a run with
the panel open on Installed with the setting off and on. System power includes every other application,
so it is only comparable against a paired baseline taken minutes from the run;
the app's own CPU and GPU percentages are the steadier signal.

## Frame delivery

The frame clock decides how much work a configured ceiling turns into, so a
comparison across a clock change reports throughput separately from power.

- `ThreadTimer` anchors each cadence tick to the deadline it was due at, not to
  when the previous tick woke, so wake slack is absorbed instead of added to the
  period. A tick more than one whole interval late restarts the cadence instead
  of bursting to catch up
  (`ThreadTimerTest.CadenceKeepsItsPeriodDespiteWakeSlack`).
- `FrameTimer` suppresses a tick while the previous admitted draw has not reached
  `FrameEnd`. A completion within one quarter interval of the **observed suppressed
  tick**, including the boundary, requests immediate recovery and restarts cadence.
  A later completion loses that period; otherwise only an outstanding request
  re-arms delivery. Posting delay is not subtracted, and scheduled due time is not
  substituted for the suppression observation. The admission-contract tests cover
  the inclusive boundary, one nanosecond beyond it, and actual observation-time
  anchoring; other real-thread integration checks remain.
- A ceiling that spans two or more refreshes of its display presents each frame
  with `presentDrawable:afterMinimumDuration:` and the frame clock's hold (whole
  refreshes less a quarter refresh, 14.58 ms at 60 fps on 120 Hz), so frames
  reach the display an even number of refreshes apart
  ([scene rendering](../features/scene-rendering.md#update-only-when-the-scene-changes));
  `WALLPAPER_MACHINE_VSYNC_PACING=0` restores plain presents. It moves no frame
  of the cadence and changes no pixel, only when a frame is shown, and was
  power-neutral in the probe below ([WindowServer's share](#windowservers-share)).
  Headless, only the requested hold is observable (`PresentPacingTest.*` pins
  the hold and a model of fixed-rate and ProMotion panels honouring it,
  `MetalSceneDraw.APresentHoldsTheFrameOnlyWhilePacing` the present that asks
  for it); a layer no window owns is never shown. Whether the display honours it
  is the present gaps of a diagnostics window on the desktop: at 60 fps on a
  120 Hz panel, `present_gaps_1_vsync` should fall to about zero and
  `present_gaps_3plus_vsync` to the frames that were really late, against
  `WALLPAPER_MACHINE_VSYNC_PACING=0` in the same binary. On ProMotion a 12.5 ms
  gap is counted as two refreshes (the buckets split at 1.5 and 2.5), so there
  the three-plus bucket, not the one-refresh one, shows the uneven gaps.

`timer_delivery_benchmark`, run by `scripts/check_renderer.py`, reports a separate
single-consumer measurement: requested 60 Hz ceiling, 18 ms of steady-clock busy
work, 200 ms warmup and a nominal one-second sample. Raw counter loads lie within
the recorded outer clock window; count divided by that actual duration is a
diagnostic, not a simultaneous clock/counter observation or throughput guarantee.
No delivered-count/rate threshold gates this measurement. Invocation, timeout and
invalid-report failures still fail the tooling rather than fabricate a zero.

This acceptance change leaves production scheduling, recovery, backpressure,
atomics and process policy unchanged. It does not diagnose or retroactively pass
the historical 42–60 throughput-check failures, nor establish an energy improvement.

This is measured delivery, not presentation. Whether and when a presented frame
reached the display is the renderer's present feedback (see [Runtime
counters](#runtime-counters)), which a diagnostics window reports per surface; the
benchmark above has no display. Measurements recorded before 2026-09-28, when the
cadence was anchored, describe fewer delivered frames at a given ceiling and are
not comparable with later ones.

## App-process CPU and memory comparisons

For an app-level comparison, identify the exact executable PID and sum only its
resource coalition (the app and its XPC/WebKit helpers), not every WebContent
process on the machine. Reject windows containing another WallpaperMachine
instance or a change in the tested presentation state. A second copy opened on
the same library hands over to the first (or shows an alert when it is another
copy of the app) instead of running beside it, so only copies given separate
isolated `WALLPAPER_MACHINE_HOME` directories can run at once. A closed-panel sample
must remain without an on-screen panel throughout; it is not a playback test.

`proc_pid_rusage` supplies resident bytes and physical-footprint bytes. Report
these separately: adding process RSS can double-count shared pages, while
physical footprint is the kernel's memory charge, not free system RAM. Normalize
its Mach-absolute CPU counters with `mach_timebase_info` and cross-check totals
against `ps -o time`; on Apple Silicon the ratio is 125/3, so reading the counter
as nanoseconds undercounts. CPU percentages use one logical core as 100%.

Record window lengths, warm-up, content/cache identity, and per-build ranges.
Several windows from one app session are not independent launch repetitions.
Live Workshop prefetch can change even if the displayed page matches; disclose
that difference and avoid generalizing a single browsing comparison to playback
or claiming a CPU improvement when the observed ranges overlap.

## Per-app energy without root

Established on Apple Silicon (an M5 Pro, macOS 26.6 and 27.0.1) against
`powermetrics`; recheck when a macOS release changes the kernel structures.

- `proc_pid_rusage` `ri_energy_nj` tracks CPU energy (within 8 % of the
  `powermetrics` CPU delta for one busy core) but includes no GPU energy.
  `task_power_info_v2.task_gpu_utilisation` is only accumulated on x86_64 and
  reads 0 on Apple Silicon.
- `accumulatedGPUTime` in `ioreg` `AGXDeviceUserClient`, which this script
  reports as GPU %, varied from 2.8 to 38.6 % across five runs of the same
  saturating load. Treat it as a coarse activity signal, never as energy.
- Resource-coalition accounting (`coalition_info_resource_usage`: `energy`,
  `gpu_energy_nj`, `gpu_time`) needs no privileges, covers the app with its
  WebKit and decoder services, and summed over all coalitions matches the
  whole-GPU figure within 5–9 %. The whole GPU's energy is split between
  coalitions by busy time, so an app sharing the GPU with a heavy load is
  overstated. The in-app readout uses it; see
  [features/performance.md](../features/performance.md#energy-use). The struct
  grew from 45 to 50 fields on macOS 27; the three fields used keep their
  indexes (`gpu_time` 8, `energy` 11, `gpu_energy_nj` 41), see
  `App/Services/Diagnostics/CoalitionEnergySource.swift`.
- `gpu_energy_nj` reaches coalitions in batches every 500 ms, so a 2 s window
  can be a quarter off and the readout's 6 s window about 8 %; compare over
  windows much longer than that.
- `gpu_energy_nj_billed_to_me` and `_billed_to_others` read 0 in every
  coalition: nobody's GPU work, WindowServer's included, is billed back to the
  app it served. CPU billing is in use but nets to about 1 % for this app.
- IOReport `Energy Model` `GPU Energy` (nJ) advances unprivileged, but its mJ
  channels (`CPU Energy`, `GPU0` and the rest) did not change over 25 s on macOS
  27.0.1, so they no longer serve as a CPU reference.
- Hardware video decoding is charged to no one; see
  [features/performance.md](../features/performance.md#energy-use).
- A wallpaper switch costs energy: a first load compiles shaders (in the app and
  in `MTLCompilerService`), a warm repeat costs far less, and `WallpaperAgent`
  spends a little after each desktop picture update. How compiled Metal is
  cached per app location, and what that means for measuring a switch, is in
  [renderer.md](renderer.md#metal-compile-across-processes). A burst of
  screen-parameter changes (an EDR headroom ramp posts one per frame) is
  covered by the regression in
  [renderer.md](renderer.md#regression-areas-that-must-stay-covered).

## WindowServer's share

Findings from alternating coalition-energy windows of 40–45 s on one Mac (M3 Max,
macOS 27.2, built-in XDR at 120 Hz in a 4112x2658 scaled mode, AC power, other
apps hidden); read the magnitudes as indicative and the conclusions as the
result. The probe was a disposable desktop-level window configured like
`MWEWallpaperDesktopWindow` whose frames are one clear, so its own GPU work was
negligible.

- **It follows the present rate of a full-screen layer.** With the desktop
  exposed, WindowServer drew about 30–40 mW idle and, for the probe, about 0.2 W
  at 30 fps, 0.3–0.36 W at 60 and 0.57 W at 120. A real scene cost it the same
  for the same rate. Next to the app's own GPU work (about 5 W at 89 fps, 1.1 W
  at 26) it is about a tenth, so the renderer's frame rate is the lever for both.
- **A covered desktop still costs it.** Behind zoomed windows the strip under the
  translucent menu bar kept the wallpaper presenting; pausing that display took
  WindowServer from 365 to 23 mW (the covered-desktop setting in
  [performance](../features/performance.md#playback)).
- **No direct-to-display.** Metal System Trace's `displayed-surfaces-interval`
  table never marked a wallpaper frame `direct-to-display` in any drawable size
  or colour space: a desktop-level layer under the Finder desktop window and the
  menu bar is always composited.
- **Pacing and drawable size did not matter.** At 60 fps, plain presents,
  `presentDrawable:afterMinimumDuration:` and a `CAMetalDisplayLink` cost the
  same within the run-to-run spread, as did a drawable at the panel's size or
  half the backing size.
- **Colour space costs the probe a third, the wallpaper little.** The layer is
  tagged sRGB so it matches the sRGB desktop poster, and WindowServer
  colour-matches it to the display. The probe cost 268–290 mW tagged sRGB
  against 175–200 mW tagged with the display's own space at 60 fps; a real scene
  tagged or left untagged differed by less than the spread. Not adopted: an
  exact sRGB-to-display conversion in both renderers, a poster that stays sRGB
  and a rebuild on every display-profile change would buy at most tens of
  milliwatts next to about 3 W of rendering.
- **Not established:** whether the ProMotion panel drops below 120 Hz for a
  60 fps wallpaper. Single 6-second traces disagreed, and about 30 composited
  frames a second had no attributed process even with nothing running. Panel
  power is outside coalition energy and `powermetrics`, and battery-telemetry
  system power was too noisy to settle it. The renderer's present gaps (see
  [Runtime counters](#runtime-counters)) now show, without a trace, how many
  refreshes of the display's top rate lie between two shown wallpaper frames, and
  how many presented frames were never shown; they say when the wallpaper's own
  frames reached the panel, not at what rate the panel itself refreshed.

Two traps: with the user active an idle WindowServer drew 141–762 mW, so compare
only quiet windows; and Chrome left open triggered about 60 composites a second
on its own. A running Parallels VM is a third: its window keeps WindowServer and the
GPU busy (the "other GPU busy" figure), so suspend it before a desktop run.

## Build-to-build checks

The Wallpaper Engine 2.8.0.42 parity work (rope geometry stage, culling, rope
trails, perspective layers; built as 1.6.2 (47)) was compared against the installed
1.6.6 (51) release, which has later `main` changes and none of that work, on one
Mac (M3 Max, macOS 27.2, built-in XDR at 120 Hz, 4112x2658 scaled, AC power, VM
suspended, panel open on Installed), alternating 60 s windows 120 s after launch on
corpus scene 3615154110 (particles and bloom, no audio). Both drew about 3,600
frames a window (60 fps). Over three pairs the app's coalition was 124–706 mW CPU
and 3.3–6.9 W GPU for the new build against 196–603 mW and 3.3–4.2 W for the old;
the one high new window (6.9 W) fell in a window where WindowServer and other
processes also doubled (16.9 W GPU over all coalitions), and the clean pairs
differ by less than their spread. This is an upper bound, not a saving: the
build-to-build difference is under about 0.5 W GPU, below what these windows
resolve, and it includes whatever the two builds' other differences cost. Package
power (`--powermetrics`) was not sampled; the runs had no root. On corpus scene 3662790108 (HDR and bloom, 847 objects) the new build's Display HDR
cost 29.4 W GPU against Ultra's 25.1 W in the same session (about 3,620 frames
each, both windows marked contended, one window each), the extended-range surface
and its linear combine included.

## Headless A/B driver

`python3 scripts/perf_bench.py` turns the headless harnesses into repeatable
before/after numbers for scene wallpapers at the user's own settings. It needs no
privileges, sets no wallpaper, opens no window and writes nothing under the user's
wallpaper library, so it is safe to run unattended. It measures the renderer's own
work, not a desktop: WindowServer, the panel and the display are not in it.

- **Builds and variants.** `--bin LABEL=DIR` names the
  `artifacts/renderer/bin/tests` directory `scripts/check_renderer.py` built in any
  worktree (it needs `unchanged_present_test` and `metal_scene_draw_smoke`).
  `--variant LABEL=BIN_LABEL:ENV=VALUE,...` is that set run with extra environment,
  so a switch from [A/B comparison entry points](#ab-comparison-entry-points) is
  measured within one binary. Each set is copied into scratch bundles under
  `artifacts/perf-bench/bin/<label>/` with the bundle id
  `dev.wallpapermachine.perfbench.<label>.<binary>` (a UI element with App Nap off),
  so every set compiles its Metal source once into a cache of its own.
  `perf_bench.py clean` deletes the bundles, the scene caches and those ids'
  Metal cache folders.
- **Settings.** Read from `~/Library/Application Support/WallpaperMachine`:
  `config.toml`'s render scale, frame-rate cap, 2D scene resolution and scene
  quality, and `wallpapers/<id>.json`'s property overrides and per-display scaling,
  matched to the surfaces as the app matches them: the first surface is the main
  display, and an entry saved for a display's identity applies to the connected
  display of that surface's size with the same vendor, model and serial number.
  `--surfaces` defaults to `3840x2160@2+3456x2234@2`, drawn at once. A setting the harness does not apply (MetalFX upscaling, on-demand
  rendering, video plane sampling, drawing only the visible part of cropped scenes, the
  system audio an audio-reactive scene hears, a scaling factor other than 1) is printed
  and recorded. Video and web wallpapers are
  skipped with their reason: only a desktop run measures them.
- **`identity A B`.** Each wallpaper on each surface goes through the poster
  harness at those settings, seeded, with text settled and 40 warm-up ticks, and
  every 60th of 600 draws is hashed (`--frames`, `--hash-every`). A runs twice:
  frames that differ between A's two runs are excluded as nondeterministic (scripts
  and particles that read the wall clock), and B must match A on every other one.
  The first frame that differs is drawn again by both, its differing pixels and
  largest channel difference are counted, and the pictures are deleted.
- **`cost A B`.** The energy test runs on all surfaces at once as fresh processes:
  one unmeasured warm run per condition, then `--pairs` pairs (default 5) in ABBA
  order, each with an 8 s warm-up and a 30 s window (`--warmup`, `--window`), at
  least 20 s apart (`--cooldown`) and only once `pmset -g therm` reports no warning.
  Each run is launched with `open -W -n -g` as an app of its own, so its coalition
  figures are its own; `--launch direct` runs it as a foreground child instead,
  sharing this terminal's coalition. `--saturated` adds, per surface, the timed
  back-to-back draws of `WE_TEST_METAL_TIMING` (`sat_*` metrics: GPU and CPU ms per
  draw, the GPU's busy ms per draw counting overlapping frames once, passes, blits and
  target bytes), and `--counters` turns the renderer
  counters on in both conditions.
- **Rejected runs.** A test that failed, failed frames, a held scene, other
  coalitions keeping the GPU busy for more than 25 % of the window, a thermal state
  above nominal, or a frame rate more than 1 % off its condition's median: the run
  and its pair are left out and listed with the reason.
- **Statistics and verdicts.** Per metric, the median and IQR of each condition,
  and the paired difference B − A of each pair with its median and a 95 % bootstrap
  interval (10,000 resamples, seeded). The verdict is `saving` or `regression` only
  with at least three pairs, an interval that excludes zero and a median difference
  larger than the A/A floor; a change in frame rate is `throughput up` or `down`,
  never a saving.
- **`aa A`.** A against a copy of itself in another folder; the 95th percentile of
  |A − A′| per wallpaper and metric is recorded as `aa_noise_floor`, which
  `cost --noise-floor <report.json>` uses.
- **Output.** `artifacts/perf-bench/<time>-<kind>/report.json` (the
  [manifest](#configuration-manifest), each build's source tree, commit, SHA-256
  and Homebrew libraries, the conditions, the resolved settings, every run's record
  and metrics, identity results, rejected runs and skips) and `report.csv` with one
  row per wallpaper, surfaces, condition and metric (median, IQR, paired delta,
  interval, verdict) for charting. `perf_bench.py report <dir>` prints the table and
  writes the CSV again.

The metrics are `cpu_mw` (the process's CPU energy), `cpu_p_mw` (on performance
cores), `cpu_ms_per_s`, idle and interrupt wakeups per second, `gpu_own_busy_pct`,
`gpu_ms_per_frame`, `cb_ms_p95`, `gpu_coalition_mw` (the process's own coalition,
absent when it shares one), `gpu_all_mw`, peak and end footprint, and frames
completed and presented per second.

An app launched this way runs every thread at the QoS it asks for; a bundle marked
`LSBackgroundOnly` instead had every thread clamped to legacy QoS, render threads
included, which is why the bundles are UI elements. In a session with several
compilers running, the windowless probe launched as an app ran on efficiency cores
only, where the same probe started from a terminal also used performance cores:
compare CPU figures only between runs of one launch method, never with the app's.

## Runtime counters

Two counter surfaces answer two different questions, and a power claim needs
both. A suspend decision recorded on one side proves nothing about the work on
the other.

`Shared/RuntimeCounters.swift` holds the in-process counters for what the
application decided and what the web host did. They are **off by default**:
`record` does nothing outside a session opened with `startSession(duration:)`,
and the session expires on its own so a forgotten switch cannot keep counting.
Counts are per surface — `RuntimeSurfaceKey(kind:displayID:generation:)`, where
the generation separates two surfaces that reused one display id across a
hot-plug or wallpaper switch — and the surface table is bounded at
`RuntimeCounters.maximumTrackedSurfaces`, reporting `droppedSurfaceEvents`
rather than growing without limit.

The renderer counts its own work: the frame clock's wakeups and draw requests,
draws executed and dropped, queue submissions, present requests, frame-fence
completions, simulation ticks, frames left undrawn because they would have
repeated the picture on screen (`presents_skipped_unchanged`), what the display
did with the presented frames (below), the effective pause reasons as independent bits,
and the decoder's outputs, seeks, selected/reused/skipped frames, conversions
and imports. Those are also **off by default** — one relaxed atomic load gates
each increment — and reading them is a pull: nothing is pushed to the UI, logged
per frame or written to disk, and enabling starts no thread and no timer.

The two groups inside a renderer row are deliberately separate.
`timer_wakeups` through `present_gaps_3plus_vsync` are work a surface performs alone and
must stop when nobody can see it. The `video_*` values describe the decoded
source, which may legitimately keep running while one of its consumers is
hidden, provided another consumer still presents it. Collapsing them would make
a correctly suspended surface look busy.

`RuntimeDiagnosticsSession` opens both halves for a bounded window and produces
one aggregated report, headed by how long the window actually ran
(`window elapsed_ms=`), measured rather than assumed. The application starts
one when `WALLPAPER_MACHINE_DIAGNOSTICS=<seconds>` is set in the environment,
`WALLPAPER_MACHINE_DIAGNOSTICS_DELAY=<seconds>` after launch when that is set
too; a value that is not whole seconds starts nothing. Without the first
variable this starts nothing, counts nothing and creates no timer.

The renderer's counters have one other user: when **Send performance data** is on,
a 60 s [frame window](../features/telemetry.md#frame-windows) every four hours turns
the renderer half on and off again. A run with `WALLPAPER_MACHINE_DIAGNOSTICS` in
its environment opens no such window, so a measured window is never mixed with one.
For any other measurement, record in the manifest that **Send performance data** was
off.

The counters exist to answer one question per condition: did the work for a
surface nobody can see actually stop? A count that keeps rising for an occluded
surface falsifies the change regardless of what a CPU graph shows.

### Present feedback

`present_requests` counts requests to present. Whether the display ever showed
the frame is a different measurement: while counting is on, each present asks its
drawable to report when it was shown (`MTLDrawable` `presentedTime`, delivered on a
framework thread, possibly after the renderer is gone, so a report only ever reaches
the counters while the renderer that asked still holds them). A report of 0 is a
drawable that was presented but never shown, replaced or discarded before any refresh
(`presents_dropped`); any other is `presented_frames`, and the time since the
surface's previous shown frame, rounded to refreshes of its display, lands in
`present_gaps_1_vsync`, `present_gaps_2_vsync` or `present_gaps_3plus_vsync`
(1.5 and 2.5 refreshes are the boundaries; a still scene that presented nothing in
between lands in the last). The refresh period is the display mode's rate
(`CGDisplayModeGetRefreshRate`, the top rate of a variable-rate panel), reported as
`vsync_period_us`; while it is unknown (no display id, as for a layer no window
owns) gaps are not counted rather than guessed. A gap is never measured across a
time nothing was counted, and the reports trail the requests by the frames still in
flight when a window closes. With counting off no report is asked for: the present
path keeps its one relaxed load.

The diagnostics report carries these per surface and ends with
`presented_frames=available`; a renderer without the reports ends with
`presented_frames=unavailable` and its surfaces carry no shown-frame count. The
request count is never relabelled as shown frames, and a frame-rate claim about the
display comes from `presented_frames` over the window, never from requests. A layer
no window owns shows nothing, so in the headless tests every report is a drop
(`MetalSceneDraw.EveryPresentedDrawableReportsWhetherItWasShownOnlyWhileCounting`);
the gap and drop arithmetic is pinned in `timer_tests` (`PresentFeedbackTest.*`).

### A/B comparison entry points

These switches make a comparison measure one change in one binary rather than
two builds. All cover a strategy only: none restores a resource-lifetime or
decode-correctness defect.

| Switch | Off (default) | On |
|---|---|---|
| `WALLPAPER_MACHINE_FEEDBACK_COPIES=1` | Native Metal trades textures for a copy a layer only makes to read the image it draws into | Every such copy is made as a copy; the picture is byte-identical either way |
| `WALLPAPER_MACHINE_DESKTOP_POSTER_REUSE=0` | A wallpaper that comes back with the same look gets its settled desktop poster back: no readback, encode or new poster file ([desktop picture](../features/desktop-picture.md#when-a-poster-is-taken)) | Every return is captured again at once, after 3 s and after 15 s; the wallpaper's own frames are identical either way, only the still Mission Control shows differs |
| `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0` | Native Metal lets targets never alive together share images, and traded copies share a small set | Every target keeps an image of its own; the picture is byte-identical either way, the target memory is not |
| `WALLPAPER_MACHINE_PRESENT_FEEDBACK=0` | While counting is on, every present asks its drawable to report when it was shown | No report is asked for and the present-feedback counters stay 0: what the reports themselves cost in a diagnostics or telemetry window. Counting off, nothing differs |
| `WALLPAPER_MACHINE_VSYNC_PACING=0` | Native Metal holds each presented frame for the frame clock's hold when the ceiling spans two or more refreshes of the display, so a 60 fps wallpaper on a 120 Hz panel shows every frame two refreshes after the last | Every frame is presented at the next refresh, which shows frames ready near a refresh boundary one and three refreshes apart; the pixels are the same either way. Compare the present gaps of a diagnostics window ([Frame delivery](#frame-delivery)) |
| `WALLPAPER_MACHINE_OVERWRITE_LOAD_ELISION=0` | Native Metal opens a render pass whose draw provably writes every texel of its target (an effect pass over its buffer) with a clear, and skips a traded reader's opening copy under the same proof | Every such render pass loads its target and every traded reader opens with its copy; the picture is byte-identical either way. `WE_TEST_METAL_PROJECTS` prints render passes loading their target and opening with a copy per frame |
| `WALLPAPER_MACHINE_COPY_TRADES=0` | Native Metal leaves out a copy whose source is afterwards only read until it is written afresh (a motion blur's history copy, the bloom or colour-option result copied back into the scene's image) and trades the two images' names after the source's last reader | Every such copy is a blit again; byte-identical. `WE_TEST_METAL_PROJECTS` prints blits, MB copied and copies traded per frame |
| `WALLPAPER_MACHINE_SKIP_NOOP_DRAWS=0` | Native Metal leaves out a draw that, with the frame's uniforms, writes alpha 0 over finite colour under a blend that keeps the destination there (a black screen faded out after an intro): the shader compiler proves each channel of the colour a product of uniforms and constants, and the frame's values make the alpha 0 | Every such draw is drawn; byte-identical. `WE_TEST_METAL_PROJECTS` prints draws left out as no-ops per frame |
| `WALLPAPER_MACHINE_HIDDEN_LAYER_WORK=0` | Native Metal leaves out a clear, and a copy made only for draws after it, while no pass that reads what it leaves draws this frame (a layer a script hid keeps its effect buffers and the copy a lens reads in the graph); the next frame's passes ahead of a clear read none of it, whatever they draw. Read when a plan is built | Every such clear and copy runs every frame; byte-identical. `WE_TEST_METAL_PROJECTS` prints unread clears and copies left out per frame |
| `WALLPAPER_MACHINE_ATTACHMENT_STORE_ELISION=0` | Native Metal stores a depth or multisampled colour attachment only while a later render pass of the frame (or, for samples, the next frame) reads it | Every render pass stores them; byte-identical. Scenes without 3D models or MSAA have none |
| `WALLPAPER_MACHINE_OPTIMIZE_IMAGES=0` | Native Metal rearranges every newly uploaded plain 2D picture for sampling once, with one blit at load (`optimizeContentsForGPUAccess`), so the GPU reads it losslessly compressed | Pictures stay as the CPU wrote them and are read uncompressed every frame; the picture is byte-identical either way, the memory traffic of sampling them is not |
| `WALLPAPER_MACHINE_MUTED_VIDEO_AUDIO=1` | A plain video that cannot be heard (muted, volume 0, Mute all, a mute rule, a mirror member without the group's sound) decodes no sound and runs no audio output: the AVFoundation player switches its one enabled audio track off, the WebM player stops feeding its audio renderer and takes it off the clock | The sound is decoded and played muted, as before; the picture and what is heard are the same either way. Compare a muted clip with sound: coreaudiod CPU and whether the default output reports `kAudioDevicePropertyDeviceIsRunningSomewhere` |
| `WALLPAPER_MACHINE_SCRIPT_TICK_SKIP=0` | A property script without `update` costs no call into the script runtime on a tick with no timer due and no audio buffer registered | Every such script is called every tick; the scripts see the same things either way. `metal_scene_draw_smoke`'s local-project line `script calls/frame` counts the difference |
| `WALLPAPER_MACHINE_VIDEO_REUSE=0` | A pass that samples a scene video is reused, with everything downstream of it that nothing else moves, while the video shows the frame it drew: a 24 or 30 fps clip on a 60 Hz clock, a paused one. A frame that took no video frame and reused every pass presents nothing | Every pass that samples a video is redrawn and every frame of a scene with a video presents, as before; byte-identical. Read when a graph is compiled. `metal_scene_draw_smoke`'s local-project line `passes drawn + reused/frame` and the energy record's `scene_passes` and `presents_skipped_unchanged` count the difference |
| `WALLPAPER_MACHINE_AUDIO_REUSE=0` | A pass that reads the audio spectrum is reused, with everything downstream of it that nothing else moves, while the spectrum arrays it binds hold the bands it drew: silence (all zeros) above all, or a spectrum that repeats | Every such pass is redrawn every frame, as before; byte-identical. Read when a graph is compiled. `metal_scene_draw_smoke`'s local-project line `passes drawn + reused/frame` counts the difference; `WE_TEST_AUDIO_HZ` (silence at `0`, a tone, `WE_TEST_AUDIO_NOISE=1` for a spectrum that changes every frame) drives it in the local-project run and the poster harness |
| `WALLPAPER_MACHINE_LAYER_LOCAL_SIGNATURES=0` | A pass drawn into a layer's own buffers (its picture and every effect but the last) leaves the layer's world transform and the scene camera out of what decides its reuse unless a uniform its shader reads is derived from them, so a still chain stays reused while its layer moves or the camera shakes. The reused pass holds the same pixels, but in a scene whose objects are drawn in their own order the draws into the scene's image around the chain then share one render pass, and an Apple GPU can blend a later draw one level apart in a texel (on an M5 Pro, two pixels of a few frames of 3808922316 at 3456x2234@2): accepted, not byte-identical | Every such pass is drawn again whenever its layer or the camera moves, as before. Read when a graph is compiled. `metal_scene_draw_smoke`'s local-project line `passes drawn + reused/frame` and its render passes on the scene output count the difference (167 + 23 against 184 + 6 passes and 32 against 42 scene render passes a frame on 3808922316 with `WALLPAPER_MACHINE_SCENE_PASS_MERGE=0`; with the merge on, the chain no longer sits between the scene's draws, drawn or reused) |
| `WALLPAPER_MACHINE_SCENE_PASS_MERGE=0` | Draws into one image that only their order or their depth attachment kept apart share one render pass ([scene rendering](../features/scene-rendering.md#draws-into-one-image-share-a-render-pass)): in a scene whose layers sample another's picture (or with a planar reflection) and that does not sort transparency, passes follow what they read and write instead of running object by object, so a layer's own buffers are drawn ahead of the scene draws around them; and on Native Metal a draw without depth testing between two depth-tested draws into one single-sample image takes its depth attachment. Byte-identical on the scenes compared (`perf_bench.py identity`); where layer buffers move ahead, the joined render pass can blend a texel one level apart on an Apple GPU, as with `WALLPAPER_MACHINE_LAYER_LOCAL_SIGNATURES`: accepted. Render targets can take more memory (62 MB on 3808922316) | Every object's passes run as one block and such a draw has no depth attachment, as before. Read once; a graph takes the value it was built with. `metal_scene_draw_smoke`'s local-project line counts render passes on the scene output and those loading their target (11 against 32 and 6 against 27 a frame on 3808922316, 4 against 27 and 3 against 26 on 3662790108). Compare GPU time with `WE_TEST_METAL_TIMING`'s `gpu_busy_ms_mean`: a frame that begins with a layer's buffers can start on the GPU before the previous one ends, which lengthens its own span (`gpu_ms_mean`) without more work |
| `WALLPAPER_MACHINE_PARTICLE_UPLOAD_DELTA=0` | Rewritten geometry (particles above all) is copied into a frame slot only as far as the draw reads it and the slot lacks it: the quads a particle system drew, its index pattern once per slot | The high-water mark of the vertices and every drawn index are copied every frame; the picture is byte-identical either way. The local-project line's `bytes of rewritten geometry copied/frame` counts the difference |
| `WALLPAPER_MACHINE_SDR_FRAMING=1` (or `=0`); unset follows Settings → Performance → Advanced → Draw only the visible part of cropped scenes (`scene_display_framing` under `[experimental]`, off by default) | Native Metal draws an SDR Display-resolution scene's whole canvas-cover raster, the overhang Fill crops included | Only the window of that raster the display shows is drawn ([experimental switch](../features/performance.md#draw-only-the-visible-part-of-cropped-scenes)); `=0` draws the whole raster whatever the setting says. Not byte-identical: up to 0.6% of interior pixels move by one level, thin geometry differs in up to about 140 pixels, and a screen-space effect stops at the output's edge. Read once at launch; a running scene takes the setting at its next draw. The harness never pushes the app's setting, so a `perf_bench.py` run draws whole unless a `--variant` sets `=1` |
| Settings → Performance → Quality → 2D scene resolution (`scene_resolution` under `[quality]`) | Display resolution: a 2D scene is rasterized at the size it is presented at | Canvas size: rasterized at the authored canvas and stretched; less GPU time and memory |

`scripts/perf_bench.py` measures such a switch within one binary: `cost on off
--bin on=<dir> --variant off=on:WALLPAPER_MACHINE_FEEDBACK_COPIES=1` (see
[Headless A/B driver](#headless-ab-driver)). Changes that are not switchable
(correctness and resource-lifetime fixes) need a separate build directory or
worktree. Whichever way two versions are compared, they need isolated
`WALLPAPER_MACHINE_HOME` directories and must be measured serially, never
concurrently.

### What the native backend cannot report

Decode and present counts inside AVFoundation are not observable from outside
the framework, so they are reported as unavailable rather than invented.
`AVPlayerLooper` keeps more than one copy of its template item queued to make
the loop seam gapless, so the queued-item count is reported as the system gives
it and is never claimed to be one with no pre-buffering.

## Desktop A/B runs

`scripts/power_ab.py` runs the desktop procedure above for two arms: two copies of
the app (`--arm A <old>.app --arm B <new>.app`, built once and never moved, since
compiled Metal is cached per app location), or one copy with a switch from the
table above (`--arm A <app> --arm B <app> --arm-env B KEY=VALUE`). It is an
authorized desktop run: it quits the running app, plays a wallpaper on the real
displays and, with a password, runs `powermetrics`. `--dry-run` prints every
command, path and the generated `config.toml` and executes nothing; read it first.

- **Preconditions**: AC power, Low Power Mode off and no thermal CPU limit, or it
  refuses before changing anything. `--allow-battery` measures on battery instead:
  every window of the run then draws from it (the system figure is the battery's own
  load), so keep the Mac unplugged throughout and compare only with runs on battery. A running Parallels VM is refused unless
  `--suspend-vm` suspends it; an open Chrome is warned about. Brightness, hidden
  windows and a still pointer remain the operator's.
- **Isolated homes**: each arm gets its own home and preferences under one temporary
  folder on the same volume: APFS clones (`cp -c`) of `Library/<id>` and
  `SceneAssets`, a copy of `wallpapers/<id>.json` (saved properties and scaling),
  `Library/.starter-installed`, and a `config.toml` with the user's `[quality]`
  (and its subtables), `[power]`, `[experimental]`, `[primary_display]` and
  `[[monitors]]`, the wallpaper set on the displays asked for (`--display-uuid`,
  default all) and `""` elsewhere. A path-backed defaults suite sets `welcomeSeen`,
  English and `writeDesktopPicture` off, so the user's desktop picture is never
  rewritten. Nothing is written under the user's app-support folder.
- **Order**: the running app is quit (one SIGTERM, then a wait for the exit; never a
  second signal), each arm gets one unmeasured warm launch of `--settle` seconds,
  then `B0, A, B, B0, B, A, B0, ...` for `--pairs` pairs (3). Every launch is `open
  -n -g -a <app>` with the home, the suite and `WALLPAPER_MACHINE_PANEL_AT_LAUNCH=0`;
  a measured one adds `WALLPAPER_MACHINE_DIAGNOSTICS=<window>` and `_DELAY=<settle>`,
  and `power_benchmark.py --measure <window> --app-pid <pid> --home <home>` starts at
  launch plus `--settle` (120 s; window 60 s). A `B0` window has every copy quit.
- **Password**: read once from `--sudo-password-file` or stdin, checked with `sudo -S
  -v`, kept in memory and given only to sudo's stdin; never in arguments, the
  environment, the output or the results. Without one, package power is not sampled.
- **Results** in `artifacts/power-ab/<timestamp>/`: each window's document,
  `config.toml`, `plan.json` and `summary.json`, where each arm window's WindowServer,
  all-coalition, package and system figures are taken minus the mean of the `B0`
  windows around its pair (the app's coalition is its own), with per-arm medians
  and the paired `B - A` differences. Read them by the [comparison
  rules](#comparison-rules): an A/A run of one app is the noise floor.
- **Afterwards**, also after a failure: any copy it started is quit, the app that was
  running is opened again from where it was found (`open -g -a <app> --env
  WALLPAPER_MACHINE_PANEL_AT_LAUNCH=0`) and the temporary folder is deleted.

A fresh home has no Workshop cache, so the first launch can fetch metadata; it is the
same for both arms, and the warm launch absorbs most of it.

## Condition matrix

| ID | Condition | What it separates |
|---|---|---|
| B0 | Application quit, system static wallpaper | System and display noise floor |
| B1 | Application running, no active wallpaper, panel closed | Host baseline cost |
| B2 | Same content, static poster only | Animation cost versus image and compositing cost |
| T1 | Single display, static or low-frequency scene | Idle ticks and dirty propagation |
| T2 | 1080p/4K/ultrawide video at 24/30/60 FPS | Decode, conversion, frame rate, pool budget |
| T3 | Simple, multi-layer post-processed, particle and video-texture scenes | CPU versus GPU versus bandwidth |
| T4 | Web wallpaper with and without a cooperating pause listener, covered and paused (Play/Pause, battery Pause) | Whether host-side suspension is real; a paused page is detached after a 3 s first-frame grace, so measure after it (not yet run) |
| T5 | Two displays, one visible one occluded, then both occluded | Per-surface policy and shared consumers |
| T6 | Lock screen, unlock, display sleep, system preview | Joint app/extension presentation ownership |
| T7 | Rapid wallpaper switching, hot-plug, window and resolution changes | Reclaim, recovery, leaks |
| T8 | Broken input, unsupported format, repeated web crashes | Whether error paths keep burning power |
| T9 | One scene with Send performance data on, across a frame window, against off | What telemetry's 60 s counter window costs (not yet run) |

Every condition is measured with **Send performance data** off, or with
`WALLPAPER_MACHINE_DIAGNOSTICS` set, which keeps telemetry's frame windows closed.
The cost of those windows themselves (T9, not yet run) is the same scene with the
switch on against off, over a window that contains one.

Wallpaper material comes from the local corpus
([wallpaper-corpus.md](wallpaper-corpus.md)) or synthetic fixtures. Copyrighted
Workshop assets are never committed.

## Comparison rules

```text
incremental average power = condition average - paired baseline average
incremental energy        = ∫(condition power - paired baseline power) dt
saving                    = (old incremental - new incremental) / old incremental
```

- Compare equal content, equal output geometry, equal **real presented** frame
  rate, equal scaling and equal color contract. A change that lowers frame rate,
  resolution, animation speed or effect count is a quality tier, not an
  equal-quality saving, and must be reported as such.
- Observe the application, any renderer helper, `WebContent` and the lock-screen
  extension **and** `WindowServer`. The main process alone proves nothing.
- Report absolute differences and spread. When the old incremental power is at
  or below the noise floor, do not report a percentage.
- Warm shaders, caches and temperature first; report cold start, first decoded
  frame and first shader compile separately from the steady-state window.
- Compare wallpaper switches only between runs of the same copy of the app (the
  `executable` path under the measurement's `build.processes`). macOS keeps
  compiled Metal source per app location, so the first load of a wallpaper in
  another copy with the same bundle ID is a cold load, even when the scene's
  shader and pipeline caches are warm.
- Activity Monitor's Energy Impact is not watts, and GPU utilization is not
  energy.

## Authorization boundary

The general rule is in [README.md](README.md#authorization-boundary). Without
`--powermetrics`, `scripts/power_benchmark.py` is safe to run: it reads
configuration and the counters of processes that are already running, and
changes nothing. `scripts/perf_bench.py` is safe too: it launches its own scratch
bundles in the background, draws only into layers no window owns, and reads the
user's settings without writing them. Everything else that produces an actual power number is out of
scope for routine verification and needs explicit authorization, because it
requires controlling the desktop, changing the user's wallpaper, or elevated
sampling:

- `powermetrics` (root), Instruments/`xctrace`, Power Profiler, external meters.
- Setting a wallpaper, unlocking or locking the session, or driving Spaces.
- Screen capture and audio capture.

Until then, a power result is recorded as unverified, never as a pass. The
optional diagnostic tooling on the other side of the boundary is in
[../development-tools.md](../development-tools.md).
