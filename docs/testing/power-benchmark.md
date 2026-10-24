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

A desktop run (which needs authorization, see [Authorization
boundary](#authorization-boundary)) is taken serially, with the display set and
power source unchanged across a comparison: quit the app with an Apple Event and
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
provide elapsed time or displayed-frame counts.

The app opens its control panel at launch, so each such run includes it, and
animated previews add frame decoding in the app and WindowServer work (Discover animates the
tiles on screen; Installed shows still covers and animates only the tile under
the pointer or keyboard focus, see [control panel](../features/control-panel.md));
say whether the panel was open and on which page. The saving from Installed's
still covers has not been measured: compare a run with the panel open on
Installed against a build before the change. System power includes every other application,
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

This is measured delivery, not presentation: whether and when those frames were
displayed is not observable. Measurements recorded before 2026-09-28, when the
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
  system power was too noisy to settle it.

Two traps: with the user active an idle WindowServer drew 141–762 mW, so compare
only quiet windows; and Chrome left open triggered about 60 composites a second
on its own.

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
repeated the picture on screen (`presents_skipped_unchanged`), the effective
pause reasons as independent bits,
and the decoder's outputs, seeks, selected/reused/skipped frames, conversions
and imports. Those are also **off by default** — one relaxed atomic load gates
each increment — and reading them is a pull: nothing is pushed to the UI, logged
per frame or written to disk, and enabling starts no thread and no timer.

The two groups inside a renderer row are deliberately separate.
`timer_wakeups` through `presents_skipped_unchanged` are work a surface performs alone and
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

### What the platform cannot report

`present_requests` counts requests to present. Whether the compositor ever put
a frame on a display is a different measurement, and this renderer, drawing into a
`CAMetalLayer`, has no presentation-feedback source for it.
The report says `presented_frames=unavailable`; the request count is never
relabelled as displayed frames, and no frame-rate claim may be derived from it.

### A/B comparison entry points

These switches make a comparison measure one change in one binary rather than
two builds. All cover a strategy only: none restores a resource-lifetime or
decode-correctness defect.

| Switch | Off (default) | On |
|---|---|---|
| `WALLPAPER_MACHINE_FEEDBACK_COPIES=1` | Native Metal trades textures for a copy a layer only makes to read the image it draws into | Every such copy is made as a copy; the picture is byte-identical either way |
| `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0` | Native Metal lets targets never alive together share images, and traded copies share a small set | Every target keeps an image of its own; the picture is byte-identical either way, the target memory is not |
| Settings → Performance → Quality → 2D scene resolution (`scene_resolution` under `[quality]`) | Display resolution: a 2D scene is rasterized at the size it is presented at | Canvas size: rasterized at the authored canvas and stretched; less GPU time and memory |

Changes that are not switchable
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
changes nothing. Everything else that produces an actual power number is out of
scope for routine verification and needs explicit authorization, because it
requires controlling the desktop, changing the user's wallpaper, or elevated
sampling:

- `powermetrics` (root), Instruments/`xctrace`, Power Profiler, external meters.
- Setting a wallpaper, unlocking or locking the session, or driving Spaces.
- Screen capture and audio capture.

Until then, a power result is recorded as unverified, never as a pass. The
optional diagnostic tooling on the other side of the boundary is in
[../development-tools.md](../development-tools.md).
