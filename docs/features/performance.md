# Performance

Two Settings sections hold the playback and quality controls: **Settings →
Performance** (Energy use, Quality and Advanced) and **Settings → Playback & Power**
(the [Playback](#playback) rules). Quick Settings, the section Settings opens on,
repeats a few of them as tiles and segmented controls (the Quality preset, **On
battery** and **When windows cover the desktop**) that change the same preferences.
While a condition lowers quality, the Quality module says so under its segments in
place of its hint, and so does **On battery** while the Mac runs on battery (`The
battery is low. Reduced quality is in use.`), so **Keep running** that the
low-battery, Low Power Mode or heat rule overrides never reads as the choice in force.
On battery also names one of those rules that pauses or stops wallpapers (`The battery
is low. Wallpapers are paused.`), ahead of any quality cause, since a pause outweighs
it ([below](#low-battery-low-power-mode-heat-and-focus)).
Every engine control is applied through the bridge and the page re-renders from the
snapshot the engine returns, so the page never shows a setting the engine did not
accept. Playback choices that the app owns (muting everything, other-app audio,
display sleep, app rules) are stored in `PlaybackPreferences` and published on the
same snapshot.

Nothing in these sections promises a measured power saving. A lower frame rate or
render scale is a quality tradeoff the user chooses. The **Energy use** readout
shows what the app draws now and, after a change, what it drew before; it is a
measurement, not a promise about any setting.

How scene wallpapers are drawn and kept cheap (renderer choice, render
optimisation, update-only-on-change, renderer memory) is in
[scene rendering](scene-rendering.md).

## Energy use

The first group, placed directly above **Quality** so a change and its effect sit
together, leads with the total power, a named energy grade, and separate **CPU**
and **GPU** readings. The breakdown sits beside the total when space allows and
below it in a narrow settings container. Battery share and any before/after
comparison follow the readings.

**How it’s measured** opens the accounting scope, GPU attribution, grade
thresholds and comparison guidance. It starts collapsed and keeps its open state
and keyboard focus across energy pushes and snapshot updates. Periodic readings
are not live announcements.

Readings cover this app, averaged over the last few seconds (four samples two
seconds apart, so up to six seconds). They are read without privileges from the
kernel's resource-coalition accounting (`CoalitionEnergySource`,
`EnergyUsageMonitor` in `App/Services/Diagnostics/`):

- **What is counted.** The app's own coalition, which macOS also charges for the
  XPC services the app starts: the WebKit processes of web wallpapers and the
  preview, the video decoder service's CPU work and the audio helper. The lock-screen extension runs in a
  coalition of its own and is added when a process from this bundle's
  `Contents/Extensions` is running.
- **What is not.** WindowServer compositing the wallpaper, the hardware video
  decoder, DRAM and the display panel: macOS charges none of them to any app.
  WindowServer's share follows the wallpaper's present rate; see
  [power benchmarking](../testing/power-benchmark.md#windowservers-share).
- **Native video.** A video on the native player (**Native video preferred**) is
  decoded by the media engine and drawn by WindowServer, so almost none of its cost
  reaches the app. While the engine's **In use now** report lists a `native` video,
  readings carry `nativeVideo`, the row reads **Native video not counted** with a
  note, and there is no grade, battery share or comparison; a comparison in
  progress is dropped, since switching a video to the native player would
  otherwise read as a near-total saving. A window that held a native-video sample
  stays flagged until it has aged out.
- **Loading.** The row's note says that right after a wallpaper is applied the
  figures include loading it (shader compilation can dominate for a few seconds;
  see [Metal compile across processes](../testing/renderer.md#metal-compile-across-processes)),
  so for a moment the figures and grade describe the load, not the wallpaper. The
  readout does not detect switches: it samples only while Settings is open, so a
  switch made from another page has already started when it begins.
- **How GPU energy is shared out.** The kernel splits the whole GPU's energy
  between coalitions by GPU time. When other apps keep the GPU busy, this app's
  frames run at their clock and share the GPU for longer, so the figure charged to
  it rises without the app doing more work. When other coalitions together occupy
  25 % or more of the window (`EnergyUsageReading.contentionThreshold`), the
  readout says the GPU figure reads high and gives no grade, battery share or
  comparison until the GPU is free (`EnergyUsageReading.isComparable`). Below the
  threshold a figure can still read high.
- **Grade.** `EnergyLevel` in Swift owns the thresholds: **Low** under 0.5 W,
  **Medium** under 2 W, **High** at 2 W or more, of CPU plus GPU. A MacBook Air
  doing light work draws roughly 3–5 W in total, so these read as about a tenth
  and about half again on its battery drain. The page only names the grade it was
  sent.
- **Battery share.** On a Mac with a battery, the row adds **About N% of a full
  battery charge per hour** (or less than 1%). `BatteryCapacity` reads today's full
  charge in mAh from the `AppleSmartBattery` registry entry, once per activation:
  `AppleRawMaxCapacity`, or `BatteryData`'s `FullChargeCapacity` on macOS 27,
  which dropped the top-level keys. It multiplies that by 3.85 V per cell, counting
  cells from `BatteryData`'s `CellVoltage` or, where macOS 27 no longer lists it,
  from the pack voltage (a 99.6 Wh MacBook Pro reads about 98.5 Wh). A desktop Mac
  has no such entry and shows no line.
- **Before and after.** A setting on Performance or Playback & Power that changes rendering work
  (`RenderingSetting` in `PanelController+Settings.swift`: presets, frame-rate limit, render scale,
  2D scene resolution, battery mode and quality, what to do in Low Power Mode, when the Mac is hot and when
  the battery is low, video backend, scene renderer and the scene and
  experimental switches) calls `EnergyUsageMonitor.settingChanged()` once the
  engine has accepted it. The window restarts, the row reads **Measuring…** with
  the last settled figure as **Before it**, and once four uncontended samples under
  the new setting exist it reads **Before your change: … Now: … (−N%)**. A second
  change before the first settled keeps the original "before". Without a settled,
  uncontended figure at the moment of the change there is no comparison. Leaving
  Settings drops it. The three condition choices are stored, not sent: the renderer
  hears of a change a moment later, when the presentation policy delivers it, so the
  restart can land just ahead of the change. The restart only discards the old window,
  and the figure compared is the window that follows, so that moment is a small part
  of it.
- **Cost.** One sample is about 3 ms of kernel calls (every coalition on the Mac
  is read for the contention check), taken off the main thread. Sampling runs only
  while the panel window is visible with Settings open (`PanelController`'s
  visibility-gated work); otherwise no timer exists. The sampler does not know which
  Settings section is open, so every section samples. Each reading bumps one counter
  (`PanelStoreRevisions.energy`), and only the Energy use rows read it, so a two-second
  update redraws those rows and nothing else. The rows show an `EnergyReadout`: the
  figure, its grade, the battery share and the before-and-after comparison when they
  apply.
- **Unavailable.** The interfaces are private libsystem exports resolved with
  `dlsym`. If a macOS release removes one, the row reads **Unavailable on this
  Mac**.

How the accounting was validated against `powermetrics` and IOReport, and what it
cannot see, is in
[power benchmarking](../testing/power-benchmark.md#per-app-energy-without-root),
which also remains the way to compare builds; this readout is for users.

## Per-wallpaper energy rating

The inspector of an installed wallpaper shows, once measured, a line such as
**Medium energy use, about 1.2 W. About 1% of a full battery charge per hour.
Measured while it played alone on 1 display at 60 fps, 75% render scale, with this
window closed.** It is measured in the
background by `WallpaperEnergyRecorder` and kept by `WallpaperEnergyRatings` (both
in `App/Services/Diagnostics/WallpaperEnergyRatings.swift`), owned by the app
delegate and reachable from the panel as `BridgeStore.wallpaperEnergyRatings`:

- **When a sample is credited.** Every 30 seconds the recorder asks the app
  delegate for a `WallpaperEnergyContext`. There is none, and no sample is taken,
  unless presentation is running and playback is playing (no display sleep, lock,
  app rule, other-audio, Focus-filter or battery pause, and no Low Power Mode, heat or
  low-battery pause or stop: choosing Reduced quality for those three keeps the
  wallpaper playing, so its samples are credited under the lower ceiling and scale), the
  control panel is not on screen, no live preview window is open, no download is
  running SteamCMD or fetching a pixiv original, exactly one wallpaper is assigned
  across the displays that are not suspended (hidden, covered, or not the one in
  use), and none of those
  displays plays a video on the native player
  (`NativeVideoWallpaperHost.activeDisplayIDs`), whose cost macOS does not charge
  to the app. Stable `primary` and `identity:` selectors are resolved to connected
  physical display IDs first; an unknown mapping prevents attribution for that
  interval. Energy is charged to the whole app, so two different wallpapers cannot
  be told apart. An interval is credited only when both ends saw the same context
  and the GPU was not contended; any engine snapshot or presentation change in
  between invalidates it, so a pause and resume inside one interval is not
  counted. A sample taken within 8 s of such a change does not start an interval
  either, so a switch's shader compiling and texture decoding are not rated as
  playback.
- **Conditions.** The context records the displays showing it, the frame-rate
  ceiling in force (the reduced-quality one included, whichever reason holds it,
  read from the engine's `effectiveFrameRateCap`) and the effective render scale. A
  measurement under other conditions replaces the rating rather than being averaged
  in, so the line always names the settings it describes. A Mac that moves in and
  out of Reduced quality therefore replaces a wallpaper's rating each time, as
  unplugging does.
- **Averaging.** Intervals combine as a time-weighted mean. History is weighted as
  at most 30 minutes, so a rating follows a wallpaper whose cost changed. A rating
  is shown after two minutes of credited time.
- **Battery share.** On a Mac with a battery the snapshot adds
  `batteryPercentPerHour`, the rated power as a share of a full charge, and the line
  states it as the readout above does. `BatteryCapacity` is read when the first
  rating is shown and kept for the app's run, since the panel asks for every
  wallpaper's rating in each snapshot. A desktop Mac's line has no share.
- **Storage.** `<support>/EnergyRatings.json`, keyed by wallpaper id. It is saved
  when a rating first appears or changes grade, at most every ten minutes
  otherwise, and on quit. An unreadable file is logged and starts empty. Each
  rating carries `version` (`WallpaperEnergyRating.currentVersion`); one from
  another version is replaced by the next measurement, not averaged with it.
  Ratings saved without a version may have credited native video playback, so a
  video wallpaper's is not shown.
- **Cost.** One coalition sample (about 3 ms of kernel calls) every 30 seconds while
  a single wallpaper plays; only a state check otherwise.
- **What it is not.** The figure includes everything in the app's coalition at the
  time, as the readout above does. Discover items have no rating.

## Quality

Presets set the frame-rate limit and the internal render scale together.

| Preset | Frame-rate limit | Render scale |
| --- | --- | --- |
| Low | 30 fps | 50% |
| Medium | 60 fps | 75% |
| High | No limit | 100% (native) |

High is the default. **Custom** is shown, and is not clickable, when the current
frame-rate cap and preferred render scale match none of those pairs. The welcome
guide's Performance page offers the same presets and slider before its
Preferences page; see [First run](first-run.md#first-run).

**Frame rate limit** is a slider from 10 to the highest display refresh the
snapshot reports (`frameRateCapMax`, or 60 when no display publishes one), plus one
extra top position. Every value up to the refresh (for example 119 and 120 on a
120 Hz display) is a cap. The extra top position reads **No limit** and sends null
(no cap): each display then runs at its own rate, 60 fps by default (below). The
effective rate on a display is the minimum of the saved per-wallpaper rate, that
display's refresh, the global cap, and the reduced-quality frame rate while reduced
quality is in force, whatever the reason: the battery, Low Power Mode, heat or a low
battery. Saved per-wallpaper frame rates are never rewritten. When the ceiling the
engine reports in force (`effectiveFrameRateCap`, which already holds all of that)
is below the saved rate, the inspector and **Settings → Displays** say so and name
the setting that set it (`FrameRateCeiling`): `Limited to N fps by Performance
settings` with **Open Performance** while the saved cap holds it, or `Limited to N fps
while the battery is low` (`on battery`, `in Low Power Mode`, `while the Mac is hot`)
with **Open Playback & Power** while a Reduced quality choice does. A ceiling below the
saved cap, or with none saved, can only be the reduced-quality profile's, so it is put
down to the cause named first; one equal to the saved cap is the cap's, since the
profile then lowers nothing.

For Web wallpapers a limit below the rate the page draws at (60, or the display's
refresh when that is lower) is enforced on the page's `requestAnimationFrame`, so
Low (30 fps), a lower cap, the reduced-quality frame rate and a per-wallpaper rate cut
the page's drawing callbacks; a rate that reaches it is left to WebKit and a No limit
page keeps its native frames. It applies to a running page without a reload, except
where a fast display's refresh is crossed and the page is rebuilt (below). Timers,
video and CSS animation are not limited, and the energy effect has not been
measured ([limits](web-wallpapers.md#limits)).

**Internal render scale** (100% / 75% / 50%) is the internal rasterization size
only. Output size, placement and composition are unchanged; a lower scale
rasterizes fewer pixels and draws the result into the same area, so detail softens
as the scale drops. It is a quality tier and is not part of any same-quality
backend comparison. For 2D scenes 100% is the raster the
[2D scene resolution](#2d-scene-resolution) below picks; perspective
scenes with no authored canvas use the physical output size instead of a fixed
1920×1080 fallback, and the camera aspect follows the surface. This is native
resolution, not supersampling. For Web wallpapers the scale multiplies the page's
`window.devicePixelRatio` (never below 50%, whatever the saved scale), so a page
that sizes its canvas or WebGL buffers from the ratio and rebuilds them on `resize`
draws fewer pixels and WebKit stretches the result over the same area. It applies
to a running page without a reload (the page gets one `resize` event) and is part of
every new document from its first line, the reduced-quality scale included. A page that
reads the ratio once keeps full resolution until it reloads, resolution media
queries and frames the page embeds see the display's own ratio, and a page that
mixes the ratio into its CSS pixel math can change layout; the energy effect has
not been measured ([limits](web-wallpapers.md#limits)). When no running wallpaper
can honour a scale (plain videos, or nothing) the control is disabled and reads
`Not applicable to the wallpapers currently running`.

The engine clamps a render scale to `0.25...1.0` (values from a stale page are
clamped the same way) but does not quantize it to these tiers, so a hand-edited
`config.toml` can hold a value between them. The control then carries that value as
an extra leading option labelled `60% (from configuration)` and keeps it selected,
rather than displaying a neighbouring tier the user never chose. Picking a tier
replaces it. Whenever the effective `renderScale` differs from the saved
`preferredRenderScale`, **Effective now** shows the scale the engine published. It
names the cause only while reduced quality is actually in force: heat, Low Power
Mode, a low battery or the battery, in that order when several hold. Otherwise it
says only that the saved setting is not in effect. Above that line it also names a
frame-rate ceiling that a Reduced quality choice sets (`Limited to 30 fps while the
battery is low`), which the **Frame rate limit** slider cannot show because it shows
the saved limit, perhaps **No limit**; a ceiling the saved limit sets gets no line.
While a cause is in force the row offers **Open Playback & Power**, where those
choices are made.

### 2D scene resolution

**2D scene resolution** (**Display resolution**, the default, or **Canvas size**) is
how many pixels a 2D scene is rasterized with before the internal render scale takes
its share; the scale multiplies whichever is chosen. A 2D scene is one with an authored
canvas, drawn with an orthographic camera.

- **Display resolution** rasterizes the canvas at the size it is presented at on the
  display: the Fill layout's scale times the display's backing scale, which is what
  Wallpaper Engine does. The 1920×1080 canvas of a scene on a 3456×2234 panel is drawn
  into a 3972×2234 image (Fill crops the part that overhangs the panel, but it is
  rasterized) instead of 1920×1080 stretched to that size at the last step, so edges
  and grain keep the panel's own pixels. Text layers are still laid out and
  rasterized at the canvas's size, so text gains no detail from it. At the Low and Medium presets the render
  scale then applies to that size (50% is half of it in each direction).
- **Canvas size** rasterizes at the size the author made the canvas, as the app did
  before this setting existed, and stretches the picture to the display when it is
  presented. It costs the least GPU time and memory and is the softest on a display
  with more pixels than the canvas.

Only the pixel sizes of the images a scene is drawn into change: its own picture, and
the targets that follow the screen (bloom and the other effects' mip levels
among them, as the same fraction of it). The canvas stays the source extent of
everything else: layout, the cursor mapping, `engine.canvasSize` and every other
coordinate a script sees, parallax and camera zoom. The buffers an effect's author
sized (ping-pong buffers, fixed-fraction scratch buffers) keep their authored size and
follow the render scale alone, so a screen-sized effect buffer is not made larger by a
finer raster. Screen-space shader inputs, the texel size a blur steps by among them,
describe the image actually drawn, as they do under a lower render scale.

Display resolution does not apply to perspective scenes, which already rasterize at the
output size, or to video wallpapers, whose frames keep their own size, and is
capped at the largest texture the GPU can create (16384 pixels on a side on every Mac
this app runs on), keeping the canvas's aspect. The raster is sized for the placement
every display starts from, Fill at the display's scale: the **Zoom** slider, which
moves while it is dragged, does not change it, so a wallpaper zoomed in is magnified
from that raster, and a display shown with Fit, Stretch or Original size is drawn
from the same Fill-sized raster. The aspect handling itself is unchanged: a canvas that is not the
display's shape is filled and cropped.

The choice reaches a running scene as a render-scale change does: the renderer
resizes its targets in place on both renderers, with no reparse and no timeline
reset, and a pause is kept; the scene's own video layers stay open and carry on, on Native Metal
too, where the graph is compiled again but its decoders are kept for it. Every scene opened
afterwards, a display change that rebuilds a scene's graph included, sizes its targets from the
choice and the display it is then on. The battery profile and a quality throttle still lower
the render scale on top of it, and **Effective now** describes that scale only. The
setting is saved as `scene_resolution` under `[quality]` in `config.toml`.

**Cost** (headless, the production `SceneWallpaper` at 60 fps for 20 seconds on a
3456×2234 surface backed at 2×, 1920×1080 canvases, alternating Canvas, Display,
Display, Canvas; [`LocalProjectEnergyIsMeasuredHeadlessly`](../testing/renderer.md#probe-environment-variables)):

| Scene | Renderer | GPU time per frame | Render targets | Process footprint (peak) |
| --- | --- | --- | --- | --- |
| Bloom and an effect chain | Native Metal | 1.62 → 3.42 ms | 35 → 94 MB | 380 → 455 MB |
| Bloom and an effect chain | Compatibility | 1.91 → 3.27 ms | not read | 399 → 480 MB |
| 26 layers, author-sized effect buffers, no bloom | Native Metal | 1.76 → 2.33 ms | 132 → 160 MB | 515 → 555 MB |

The cost follows how much of a scene is screen-sized, so a scene of mostly
author-sized buffers pays little and a bloom or full-screen effect chain pays for
every level. At 60 fps the first scene's extra 1.8 ms is about a tenth of a frame.
CPU time per frame did not move, and the energy effect has not been measured: the
whole-GPU energy figures of the probe are not usable on a machine that is also doing
other work. Peak footprint carries about ±30 MB of run-to-run noise. The Canvas figures
are what the app drew before the setting; choose **Canvas size** to keep them.

### Default per-display frame rate

A display with no saved rate runs at its refresh rate up to 60 fps
(`DEFAULT_FRAME_RATE_CEILING` in the bridge's `config` module): 60 on a ProMotion
MacBook Pro, a MacBook Air or a 60 Hz external display, 48 on a 48 Hz one. A
scene's cost follows its frame rate, and so does WindowServer's compositing share
([power benchmarking](../testing/power-benchmark.md#windowservers-share)). A higher
rate is one choice away: the per-display slider still goes up to the display's
refresh. Web wallpapers draw near 60 fps below that refresh and at the full
refresh once the rate reaches it ([frame rate](web-wallpapers.md#runtime-shape)).

The wallpaper config stores the rate as `frame_rate` in each `monitors` entry, and
a mirror display stores it as `frame_rate` in its `[[monitor_settings]]` table. The
key is omitted for the default, so the rate keeps following the display if its
refresh changes; any other rate, the full refresh of a display above 60 Hz
included, is saved as chosen. The legacy keys `fps` (wallpapers) and `target_fps`
(mirror displays) are read once on load — a legacy `60` is indistinguishable from
the old default and becomes the default; any other legacy value is kept — and are
never written again.

## Playback

These rules are on **Settings → Playback & Power**.

A wallpaper nobody can see — behind a full-screen app, on a hidden Space or under
windows that leave no pixel of it — pauses automatically, per display. There is no
control for that part.

Each display follows its own visibility even when both use the same wallpaper.
Waking or unlocking re-evaluates every display in the same pass: one that is visible
again resumes without a click or refresh, while one still covered stays paused.
Reapplying a wallpaper or changing the display arrangement also reconciles the live
scene's pause with the current playback policy, so a pause retained by a rebuilt
renderer cannot hold a visible display still. The user's own Pause remains in force.

| Setting | Values | Default |
| --- | --- | --- |
| Mute all wallpapers | On, Off | Off |
| When windows cover the desktop | **Pause**, **Keep running** | Pause |
| When another app plays sound | **Keep running**, **Mute**, **Pause** | Keep running |
| When displays sleep | **Pause**, **Stop (free memory)** | Pause |
| Only play on the display I’m using | On, Off; shown with two or more displays | Off |
| On battery | **Keep running**, **Reduced quality**, **Pause** | Keep running |
| When the battery is low | **Keep running**, **Reduced quality**, **Pause**, **Stop (free memory)**; the level is **10%**, **20%** or **30%** | Keep running, 20% |
| In Low Power Mode | **Keep running**, **Reduced quality**, **Pause**, **Stop (free memory)** | Keep running |
| When the Mac is hot | **Keep running**, **Reduced quality**, **Pause**, **Stop (free memory)**; Reduced quality still pauses when the Mac is very hot | Keep running |

**Mute all wallpapers** is the user's own switch for silencing every wallpaper at
once. The same switch is **Mute Wallpapers** in the menu bar (ticked while it is on,
and offered while it is on whatever is playing, so it can always be turned off),
`wallpapermachine://mute`, `unmute` and `togglemute`, the **Mute Wallpapers**,
**Unmute Wallpapers** and **Mute or Unmute Wallpapers** actions in the Shortcuts app,
and a shortcut key ([automation](automation.md)); all of them set
`PlaybackPreferences.wallpapersMuted`. It never rewrites a wallpaper's saved **Mute
audio** and volume or a display's. It is one more reason, in
`WallpaperPresentationPolicy`, for the bridge's single audio-suppression flag, which
the engine combines with each wallpaper's own mute, so a wallpaper plays only if
neither says mute. It therefore composes with the mute app rules, the Focus filter and
**When another app plays sound** instead of replacing them: turning it off while one
of those still applies leaves the wallpapers silent. Turning it on changes nothing
about presentation, so playback and playlists carry on, and a wallpaper applied while
it is on starts silent. Turning it off lets each wallpaper play as it was saved. The
choice is kept across relaunches and is local to this Mac, so a
[backup](backup-restore.md) neither carries nor restores it: restoring one never
silences a Mac. For Web wallpapers it has the same boundary as **Mute** below, and the
lock-screen extension is always muted.

**When windows cover the desktop** handles the case AppKit never reports as
hidden. A zoomed (not full-screen) window leaves the strip under the translucent
menu bar and its own rounded corners showing, so the wallpaper window stays
"visible" and a scene keeps drawing at the full frame rate for that strip. With
**Pause** the display counts as covered once other windows hide its working area —
the screen minus the menu bar and a shown Dock, inset by 32 pt — and that display
pauses after the usual one-second settle; the strip and the edges keep the last
frame, and exposing any of the working area resumes it at once. A translucent
window does not cover, because macOS decides what covers what. **Keep running**
leaves the wallpaper animating in the gaps. `WallpaperCoverageProbes` measures this
with one fully transparent, mouse-transparent window per display just above the
wallpaper; see [architecture](../architecture.md#desktop-wallpaper-windows-and-private-api-handling).

**Only play on the display I’m using** is for a Mac with two or more displays. The
display the pointer is on keeps playing; every other display pauses once the pointer
has been away from it for 3 seconds, and resumes the moment the pointer returns, so
skimming across a display, or going back to it, never pauses it. It is one more
reason a display counts as hidden in `WallpaperPresentationPolicy`, beside occlusion
and a covered working area: it never changes **Play** and **Pause**, nothing has to be
restored when it ends, and the usual one-second settle applies before a display
pauses. The policy never darkens every display for it: while the display in use cannot
show its wallpaper (a full-screen app on it or, with **Pause**, windows covering its
working area), that display pauses on its own and the others keep playing, and they
pause again once it shows its wallpaper. A pointer on a screen the app has no wallpaper
on pauses nothing. `ActiveDisplayTracker` follows the pointer
with one global and one local event monitor, installed only while the option is on and
two displays are connected; the global monitor needs no Accessibility or Input
Monitoring grant, and a pointer event that stays on one display costs one rectangle
test. While this app is the active one, such as after you click its control panel,
AppKit sends pointer events to the app: the global monitor sees none of them and the
local one sees only motion over this app's own windows. So for as long as the app is
active the tracker also reads the pointer four times a second on a timer that
tolerates coalescing, and reads it once when the app becomes or stops being active,
so moving onto another display's desktop is noticed without a click. The row appears
once two displays are enabled, and stays while the option is on so it can be turned
off. Turning it off, or unplugging down to one display, resumes everything.

A display that is paused this way is treated like a covered one: an automatic
wallpaper change, a playlist step and a scheduled rule for it wait until it plays
again, and its energy counts as not playing. The settle and periodic captures of its
Mission Control picture skip it while it is paused; a new wallpaper still asks it for
a frame, and so does a Space change or a wake when its picture is not fresh
([Desktop picture](desktop-picture.md)). A web wallpaper set on such a display, or
rebuilt there, loads and draws its first frame before it is paused, as one paused with
**Pause** does ([Web wallpapers](web-wallpapers.md#runtime-shape)); a covered display
needs no frame and its page stops at once. Turn the option off if you watch one display
while working on another. The display is judged only by the pointer, so a video
playing on a display the pointer is not on pauses too.

**Mute** affects scene and video wallpapers and, where WebKit exposes its native
output channel, Web wallpapers. Availability is shown in the wallpaper's details;
see [Page sound](web-wallpapers.md#page-sound). **Pause** applies to every
wallpaper and does not change the user's own Play/Pause.

Another app counts as playing sound while Core Audio reports it running audio
output (`kAudioProcessPropertyIsRunningOutput`). This app and the processes it is
responsible for, such as the WebKit processes playing a web wallpaper, are
excluded. Sound must last 0.5 s before it counts and silence 2 s before it clears,
so a gap between tracks does not restart the wallpaper. Nothing is observed while
the choice is **Keep running**.

**Stop** on display sleep frees renderer memory. The wallpaper is reloaded when the
display wakes. **Pause** keeps it loaded.

**After the Mac wakes** the app checks that every scene wallpaper is drawing again
(`SystemWakeRevalidator` asks, the bridge's `revalidate_scene_presentation` answers). It
reads each scene's frame counter, waits three seconds, reads it again, and rebuilds the
drawing surface of only a scene whose counter did not move, or one that had already
stopped itself after a rendering failure
([a scene that stops drawing](scene-rendering.md#a-scene-that-stops-drawing)). On a Mac
that woke well nothing is rebuilt: the check costs two counter reads and the wait.

- **What it leaves alone:** a display that is paused for any reason (the user's pause,
  battery, a covered desktop, sleeping or locked displays), a scene that updates only on
  events or at a deadline (its counter standing still is how it saves power), a scene
  the renderer could not be read for, web pages and native video. The signal is frames
  *completed*, never frames presented: a frame that would repeat the picture completes
  without presenting, so a healthy, still scene presents nothing for as long as it
  likes.
- **When it runs:** about 0.65 s after the wake, whichever of the system's and the
  displays' wake notifications arrives first; the second notification for the same wake
  is not a second check. It waits behind a wallpaper change that is being applied. A wake
  that lands on the lock screen is checked once the unlock lets wallpapers draw again,
  not at the wake itself, when every scene is suspended on purpose. Nothing polls.
- **How it repairs:** through the same rebuild ladder a failed frame uses (a surface
  reconfigure, then renderer rebuilds), so a check cannot loop: three attempts in a
  minute per scene, and a scene the budget is spent on stays marked as stopped in
  Settings, where **Retry** reloads it. A check never starts a fresh budget.
- **What it writes:** one line per display and a summary in the
  [application log](diagnostics.md#wake-check).

Whether a scene surface ever stops producing frames across a real sleep and wake, and
whether the reconfigure restores it, is not established here: the tests drive the check
with scripted frame counters.

**On battery** is one choice. **Keep running** leaves quality alone. **Pause**
stops wallpapers until the Mac is plugged in. The low-battery, Low Power Mode and heat
rules below apply on top of it whatever it says, so with **Keep running** here a low
battery set to Reduced quality still holds wallpapers to the reduced frame rate; the
On battery module in Quick Settings and the frame-rate notes say when that happens, and the
module says so too when one of them pauses or stops wallpapers. **Reduced quality** is the choice
that makes the page show **Render scale when reduced** (100% / 75% / 50%, default
75%) and **Frame rate when reduced** (1–240 fps, default 30) underneath, plus a
**Reduced quality** line that says why quality is lower right now. This is one
profile, shared: the same two fields serve **On battery** and the three conditions
below, and the rows show whenever any of the four selects is on Reduced quality (the
low-battery one only on a Mac with a battery). Those two fields are sent together:
changing one resends the other as the engine currently reports it. For **On
battery**, Reduced quality is in force only while that mode is selected and the Mac
is on battery. A configuration saved with the former pause-on-battery switch maps to
**Pause**, otherwise the former battery profile switch maps to **Reduced quality**.
The power source is also read when the Mac wakes and again two seconds later,
because a plug or unplug during sleep may not be reported; a change found that way
applies the same rule, and a read that finds the same source as the one last applied
changes nothing.

The renderer applies all of this itself when the power source changes, and reports
nothing back. The app watches the source too (`PowerSourceMonitor`: the system
notification, and the same two reads after a wake) and then reads the snapshot again,
repeating a few times until the renderer reports the source the system did, so the
web pages and native video it hosts take in the pause, frame rate and render scale at
once instead of at the next unrelated snapshot. The notification itself has not been
exercised by unplugging a Mac in a test.

### Low battery, Low Power Mode, heat and Focus

**In Low Power Mode** applies while macOS reports Low Power Mode
(`ProcessInfo.isLowPowerModeEnabled`), and **When the Mac is hot** while it reports
the thermal state as serious or critical, the states in which macOS starts
throttling itself. Both are off until chosen. Each row's note says whether the
condition holds right now, and adds a line while its rule is engaged: `In effect now.
Wallpapers are paused.` (or stopped, or `Reduced quality is in use.`).

**When the battery is low** applies while the Mac runs on its internal battery at or
below the **Low battery level** (10%, 20% or 30%; 20% unless you choose another). The
level row appears once an action other than **Keep running** is chosen, and both rows
appear only on a Mac with an internal battery; the note shows the charge when the
page was drawn. The rule ends when the charge is 5 points above the level, so a charge
that hovers around it does not pause and resume the wallpapers over and over, and it
ends at once when you plug in, whatever the charge. Only the internal battery counts,
never a UPS, and a reading that fails counts as not low. Like the other conditions it
pauses or stops wallpapers without touching your own Play/Pause; **Stop** frees
renderer memory and reloads the wallpapers when the rule ends. Because the rule ends
only above its margin, the charge in the note cannot tell whether it is engaged; the
**In effect now** line can.

Whether a rule is engaged comes from `SystemConditionMonitor`, the one place that
evaluates the conditions (the low-battery margin included). It publishes which
condition holds and what its rule does (`EngagedSystemConditions`) to
`SystemConditionState`, which the control panel reads; the panel never works the
conditions out again. While the Mac runs on battery, Quick Settings' **On battery**
module names the strongest of them that pauses or stops wallpapers: a stop before a
pause, and heat, then Low Power Mode, then a low battery among equals, for example
`Low Power Mode is on. Wallpapers are stopped.` What the choice already does is not an
override, so **Pause** beside a rule that pauses says nothing, while one that stops is
named. Plugged in, the choice does nothing and nothing is said. Heat on Reduced quality
reads as a pause once it is critical.

Focus filters and app rules stay on their own rows and are not named under **On
battery**: they act whatever the power source, so they override every choice on the
page alike, and they are things the user turned on for the moment (a Focus, an app
in use) rather than a state of the Mac's power. The **Focus** row says which filter is
in effect now; the **App rules** rows do not yet say which rule is engaged.

All three conditions also offer **Reduced quality**, which keeps the wallpapers
playing instead of pausing them. While a chosen condition holds, the app asks the
engine for the reduced-quality profile (the scale and frame rate described under
**On battery**) on top of whatever the power source already asks, and hands your
usual settings back when the last condition ends. The request is runtime-only: it
is never saved, a restart begins without one, and nothing is polled for it (the
conditions are observed as above).

- **It only lowers.** The frame-rate ceiling is the lowest of your global cap and the
  profile's rate, and with a condition holding the render scale is the lower of your
  saved scale and the profile's, so a cap or scale you already set below the profile
  stays where it is. When a condition and the battery profile hold together, the
  stricter rule wins and quality never rises. On battery alone the profile's scale
  is used as it is, as it always was, so a saved scale lower than the profile's is
  raised to it there; that difference from the conditions was left as it is.
- **Heat escalates.** Serious reduces. Critical reduces and also pauses the
  wallpapers, because reducing is no longer enough; choosing Reduced quality is not
  a promise never to pause, and the row's note says so. The fair ("warm") state is
  ignored, as it is for **Pause** and **Stop**, which act from serious.
- **It follows the cause.** **Effective now**, the **Reduced quality** line and Quick
  Settings' Quality and On battery modules name the cause (heat, Low Power Mode, a
  low battery or the battery, in that order when several hold), and the frame-rate
  note on **Settings → Displays** and in the inspector counts the reduced-quality
  frame rate whichever reason lowered it, names that reason and opens Playback &
  Power rather than Performance.
- **Cost.** Each change of the render scale rebuilds a scene's render graph, the
  same cost as unplugging the Mac with **On battery** set to Reduced quality, and
  there is no hold-down: a Mac whose thermal state flaps at the serious boundary
  would pay it each time, which is not measured. A Web wallpaper drawing at the full
  refresh of a display above 60 Hz pays more: its cadence is fixed when the page is
  created, so the lower rate reloads the page, with the loss of what it kept in
  memory, and the end of the request reloads it again
  ([frame rate](web-wallpapers.md#runtime-shape)). Nothing is added per frame.
- **Saving.** The power saving of Reduced quality, here or on battery, has not been
  measured, and nothing in the app or these docs claims one. The planned comparison
  is a [power benchmark](../testing/power-benchmark.md#condition-matrix) of the same
  content with the profile on and off. The matrix has no row for it yet and the
  benchmark script no scenario, and the
  [comparison rules](../testing/power-benchmark.md#comparison-rules) call a lowered
  frame rate or scale a quality tier, not an equal-quality saving. It needs an
  authorized desktop session.
  Whether a change made while the Mac is locked, and a native-video clip whose target
  rate changes (it may be offered natively again, as for any changed target rate),
  behave as intended has likewise not been exercised on a Mac.

A Focus can act on wallpapers through a Focus filter (`WallpaperFocusFilter`, an
App Intents `SetFocusFilterIntent`): in System Settings → Focus → a Focus → Focus
Filters, add WallpaperMachine and choose **Keep running**, **Mute**, **Pause**,
**Stop (free memory)**, **Use wallpaper** or **Use saved playlist**. The latter two
temporarily select content on an optional display; restoration and manual-choice
behavior are described in
[Automation](automation.md#focus-selection-and-restoration). macOS performs the
filter with that value when the Focus turns on and with the default, Keep running,
when it turns off; `FocusFilterState` keeps the last value across launches, and the
app reads the filter in force again at launch. **Open Focus Settings…** on the Focus
row opens that pane; the app cannot add a filter itself. Adding the filter needs no
permission.

`SystemConditionMonitor` turns the playback conditions into rule actions that join
the app rules' in `WallpaperPresentationPolicy`, so they pause, mute or stop
wallpapers exactly as an app rule does and never change the user's own Play/Pause.
A condition set to Reduced quality is not a rule action: the monitor reports it
separately (`qualityReductions`) and the policy delivers it to the engine on its own
channel (`setQualityThrottle`), so wallpapers keep presenting under the lower ceiling
and scale ([architecture](../architecture.md)). Heat is the one exception, since a
critical thermal state also contributes a pause.
It only observes notifications (`NSProcessInfoPowerStateDidChange`,
`ProcessInfo.thermalStateDidChangeNotification`, the preferences and the Focus
filter); nothing is polled. The battery adds IOKit's power-source notification
(`IOPSNotificationCreateRunLoopSource`, wrapped by `SystemBatteryLevel`), registered
only while a low-battery action is chosen and removed when it is not, and read again
when the Mac wakes in case a plug or unplug during sleep was never reported. The
decision itself is `LowBatteryGate`, fed by one `BatteryReading` of the internal
battery. Web mute uses the same availability boundary as above.
Wallpaper and playlist selections instead reach `WallpaperAutomationScheduler`;
they never become pause/mute/stop actions or change the user's own Play/Pause. The
experimental [desktop Space mode](spaces.md) uses the same eligibility gate,
retains manual overrides for the current visit, and defers Focus exit while the
current desktop cannot be identified. Animated lock-screen ownership
conflicts with that mode; screen-saver-only ownership does not.

### App rules

The **App rules** row on Playback & Power opens an inline list. Each row is an app name, a condition (**Running**
or **In front**), an action (**Pause**, **Mute** or **Stop**) and **Remove**. **Add
app…** opens a native panel for one `.app` bundle. An app with no bundle identifier
is refused. The same bundle is not added twice. Rules pause, mute or stop
wallpapers while the chosen app matches. They do not change the user's own
Play/Pause. Web mute uses the same output channel and availability boundary as
above, without disabling its system-audio response.

## Advanced

Collapsed by default, with a **Renderers & experimental options** preview. Inside,
three flat sections separate **Video backend**, **Scene wallpapers** and
**Experimental**; scene renderer selection comes before the optimisation and
update-only-on-change switches. Each renderer section has a collapsed **Live
diagnostics** disclosure: video shows the backend in use; scenes show the renderer
and video path, whether optimisation is in force, and what is keeping the scene
updating. These reports continue to update from snapshots, and their open state
survives setting changes. **Renderer compatibility** remains beside the scene
diagnostics. **What these settings change** belongs to Playback & Power, not Advanced.
What the three scene controls do (**Scene renderer**, **Scene render optimisation**
and **Update only when the scene changes**) is described in
[scene rendering](scene-rendering.md#scene-wallpapers).

## Video backend

| Setting | Values | Default |
| --- | --- | --- |
| Video playback | **Compatibility**, **Native video preferred** | Compatibility |

Native is a preference, not a guarantee: the engine selects a backend per running
wallpaper and keeps anything that does not qualify on Compatibility. **In use now**
lists the backend each running video wallpaper actually got, and names the
fallback reason when the user asked for native and did not get it. It reads `No
video wallpaper is running.` when nothing is playing video. An unrecognised backend
name is refused rather than silently mapped to Compatibility, so a stale page cannot
report a choice that was never applied.

Applying a video checks that its entry is a readable, nonempty file. Container and
codec support are decided by the playback backend: AVFoundation's native admission
check must not block a file the Compatibility backend can decode, including H.264
in Matroska. This applies both to **Apply** and **Apply changes**, with either
backend preference. Missing or empty files fail before display settings change;
decoder failures still go through the engine's apply recovery.

Native playback honours the wallpaper's scaling mode and scale factor the way
Compatibility does, so switching backends does not move the picture: **Fill**,
**Fit** and **Stretch** scale it to the display, **Original size** shows one video
pixel per point (a 1920x1080 clip covers 1920x1080 points of a Retina display, not
1920x1080 device pixels), and the scale factor multiplies whichever applies, with
the picture centred and anything outside the display cropped. A factor that is not a
positive number counts as 1. Changing the mode or factor moves the running picture;
it does not reopen the clip or read the file again. The desktop picture shown in
other Spaces and Mission Control is drawn with the same layout. The wallpaper's
position on the display is not honoured: the native player always centres, and the
inspector's Position block says so ([display position](wallpaper-properties.md#display-position)).
The lock screen and screen saver always use Compatibility and do apply it. One known difference:
the native player applies a clip's pixel aspect ratio to the picture's size and
Compatibility ignores it, so an anamorphic clip is laid out by its displayed size
here. Layer placement is in `NativeVideoLayout`; its expected rectangles come from
the renderer's own layout code (see [coverage](../testing/coverage.md#nativevideo)).
How a very large factor affects composition cost on a real display has not been
measured.

Reading a clip's metadata before it plays is bounded in time, because a file on a
disk that has gone to sleep, a share that stopped answering or an iCloud or File
Provider file that was evicted can keep a read waiting indefinitely, and that read
runs in the same pass that opens, closes and pauses every other display's video. The
limit follows where the file lives: 8 seconds on the internal drive, 30 seconds on an
external drive or when the volume cannot be identified (long enough for a hard disk
to spin up), and 60 seconds on a network volume or a cloud-backed file. A read that
runs out of time hands the wallpaper to Compatibility like any other refusal, and
**In use now** says the metadata read did not finish and what kind of storage it was
waiting on. It is not retried within the pass and is not remembered by the app as a
verdict on the file, so a clip that is offered natively again is read afresh; but
while the first read is still blocked, that file is not read a second time, so one
stuck file never holds more than one blocked call. The hand-off itself lasts for the
session: the bridge records the refusal against the clip's file and target frame rate
and does not offer them natively again, so a clip handed over by a slow disk stays on
Compatibility until its file or its target frame rate changes, or **Video playback**
is switched to Compatibility and back to **Native video preferred**. Nothing retries
it on its own, since the bridge never passes a wallpaper back and forth between
backends. A diagnostic recording counts these as `nativeVideoProbeTimeout`; a count on
the internal drive means the read is stuck, while on a share or a cloud file it may
only be slow. The same bound applies to a read that fails and is retried: each of the
three attempts gets the whole limit.

A clip that never shows a picture is handed back too. A file the platform calls
playable can reach ready with its clock running and still produce no frame (an HEVC
clip tagged `hev1` does this on macOS 27), and nothing reports a failure, so the
display would stay black with Compatibility excluded and the wallpaper's startup
never finishing. Native playback therefore waits for the first picture: 10 seconds on
the internal drive, 30 seconds on an external drive or when the volume cannot be
identified, and 90 seconds on a network volume or a cloud-backed file, the same
storage classes as the metadata read. If none arrives, the player is rebuilt once and
given the same time again. If that fails as well, or the player has no rebuild left
(two per ten minutes for a display's clip, given back after a minute of uninterrupted
frames), the wallpaper goes to Compatibility and **In use now** says that no first
frame arrived, after one restart or not, with the state of the pipeline (item status,
the picture size it reports, whether the clock runs, whether the layer has a frame).
The wait does not run while the display is hidden or asleep: it starts again with a
full deadline when the display returns. The user's own pause does not stop it, since
a paused clip still shows its first frame. As with a slow metadata read, the app does
not remember this as a verdict on the file, so an offer of the same wallpaper would
open it again, but the bridge keeps its refusal for the session: a clip handed over by
a slow volume stays on Compatibility until its file or its target frame rate changes,
or **Video playback** is switched to Compatibility and back. A diagnostic recording
counts every deadline that passed without a frame as `nativeVideoFirstFrameTimeout`:
a single count with no refusal means the rebuild brought the picture, and on the
internal drive any count means the pipeline stalled.

A clip that has shown a picture is checked, and repaired if need be, after anything that
can cost it its decoder. The system may reclaim the decoder while nothing is playing (a
covered desktop for hours, display sleep, Low Power Mode, a locked session), and a clip
that carries on afterwards can report that it is playing, with its clock running, while no
picture comes out. A check starts when a clip is resumed after at least 5 seconds paused
(by the user's Pause or because its display was hidden), and when the displays wake, the
Mac wakes or the session becomes active again (an unlock, or a switch back to this user).
A wake waits one second first, so the system can hand the decoder back, and the
notifications that arrive in a burst make one check, taken after the last of them. Only
clips that are playing are asked: a clip the user paused stays paused, and a hidden
display is not looked at. With no native clip open, which is every Mac on the default
Compatibility backend, a wake starts no wait at all.

A check waits half a second and then, for up to 2 seconds, looks every tenth of a second
at the playing item. It needs both signs of life in that time: a new picture handed over by
a video output attached to the item for the check, and a clock that moved by about a frame.
The clock alone is not enough, because a pipeline that decodes nothing keeps its clock
running. A healthy clip is proven within a couple of samples, so its cost is one short-lived
video output and no visible change. When no picture comes out, the check works up a ladder
of repairs, looking again after each:

1. The clip is kicked: a seek to where it already is, with no tolerance, and `play()`. It
   restarts an output that is stuck, costs nothing visible when it works, and never starts
   a clip the user paused. The look after it settles for half a second and lasts 2 seconds.
2. If pictures are still missing, the clip's item and looper are rebuilt from the file. The
   layer stays blank until the new item shows its first picture, which is why this comes
   second. It spends the surface's recovery allowance, the same one the first-frame wait
   uses (two rebuilds per ten minutes, given back after a minute of uninterrupted
   pictures), and its look lasts 5 seconds, since the new item has to load first.
3. If pictures are still missing, or no allowance is left for a rebuild, the wallpaper goes
   to Compatibility like any other player failure, and **In use now** says that playback
   stalled after the trigger (`the displays woke`), what was seen, what was tried and how
   much of the allowance was spent. The bridge keeps the refusal for the session, so the
   clip stays on Compatibility until its file or its target frame rate changes or **Video
   playback** is switched to Compatibility and back. The native host does not remember the
   hand-off as a verdict on the file, unlike a decoder failure: a decoder the system took
   back during a long sleep says nothing about the clip, so when the bridge does offer the
   same wallpaper again it opens natively once more.

A clip whose player said throughout that it was waiting for data is looked at again, twice
at most, before it is treated as stuck, so a disk that is still spinning up is not nudged;
one that keeps waiting for six seconds is kicked like a stalled one. A clip that never
showed a picture is left to the first-frame wait above. Pausing again, hiding the display
or switching the clip ends a check in flight, and a rebuild started by the first-frame wait
ends it too. A trigger that arrives while a check is still only looking replaces it; one
that arrives once the check has started repairing is absorbed, so nothing is kicked or
rebuilt twice for one suspension.

A diagnostic recording counts the first look that finds no picture as
`nativeVideoPlaybackStalled`, and the repairs as `nativeVideoPlaybackKick` and
`nativeVideoPlaybackRebuild`: a kick for every stall means the cheap repair is enough, and
a rebuild for most of them means it is not. Each look and each repair is also a line in the
diagnostics log under the wallpaper's load (`playback did not advance after the displays
woke: the clock advances but no frame is produced`). A clip that shows fewer than one
picture in two seconds can be reported as stalled, and kicked, while it plays. Whether a
kick or a rebuild really brings back a decoder the system reclaimed has not been seen on a
real Mac, and neither has the cost of the check's video output on a 4K clip; the output
exists only while the check samples, normally a fraction of a second after the settle, and
reads the clip's own pixel format.

Switching wallpapers quickly does not put the ones in between on the desktop. Reading
a clip's metadata can take a moment, and the next switch may be committed meanwhile.
When one has, native playback asks the bridge again before it builds a window, and
builds one only if the display still wants that wallpaper with the settings the read
checked; otherwise nothing appears and the next pass opens what is wanted now. A burst
of changes to the same wallpaper (dragging its volume, say) does not hold the clip
back, and it starts with the latest values. A display that was unplugged during the
read gets no window, and one that moved gets its current frame. If the bridge cannot be
asked, the clip is shown as it was offered and the next pass corrects it. **In use
now** is unaffected: an abandoned open is only a line in the diagnostics log
(`superseded while its metadata was read`).

A video the bridge offers for a display that the app's own screen list does not contain
gets no window, since there is no screen to put it on. The engine reads the active displays
from CoreGraphics and the app reads AppKit's screens, and a hardware mirror set, an AirPlay
or Sidecar screen or a closed lid can make the two differ. That used to leave the display
without a wallpaper and without a word in the log; the diagnostics log now says once, per
wallpaper and display, that it is offered for a display the host cannot see and lists the
screens it does see. The video opens by itself once the lists agree, because the bridge
offers it again and a real screen change refreshes the displays. A display that is only
missing for a moment is logged the same way. Whether real mirror sets, AirPlay and a closed
lid produce the disagreement has not been checked on a desktop
([display layouts](display-layouts.md#mirror-sets-airplay-and-a-closed-lid)).

When the clip's audio output cannot start (no output device, or one that will not
start), AVFoundation fails the whole clip, muted or not, and reports only
`AVErrorUnknown`. Native playback then rebuilds the clip from its video track alone
and keeps playing it natively without sound, logging the original failure against
the wallpaper's load. A clip without audio, or one whose picture fails too, falls
back to Compatibility for the session. Native fallback reasons include each error's
domain and code, so a report shows which part of playback failed.

## Experimental switches

All three switches are experimental and off by default.

| Setting | Notes |
| --- | --- |
| Content pacing | Drives presentation from the content's own frame cadence instead of the display refresh |
| Shared video decode | Lets equivalent display surfaces showing the same video share one decode session |
| Direct video plane sampling | Lets a Native Metal scene's own shader read the decoder's two video planes instead of a colour image converted for it each frame |

When shared decode is actually merging work, **Shared decode in use** reports the
live session and surface counts the engine publishes. Sharing is reported only
where it genuinely happens: surfaces still submit and present separately.

### Direct video plane sampling

An 8-bit NV12 frame is two planes — full-resolution luma and half-resolution
chroma — and turning it into one colour image is a full-frame pass the GPU runs
before any layer samples it. Where a layer's own shader can do that conversion
while it samples, the pass is not needed at all.

The renderer does not rewrite anything at run time to achieve this. While the scene
is parsed, a material with exactly one video texture records everything a second
translation of the same author source would need; nothing is compiled then, and the
wallpaper loads and draws with its ordinary program first. Only if the switch is on
is the second program produced, on a background worker, and its Metal pipeline
built off the frame thread; the scene adopts it between frames when it is ready.
With the switch off nothing is prepared at all, and no shader is ever compiled
inside a frame either way.

**Drawn by** reports per scene what each running scene actually did: sampled
directly, converted once per frame, both for a scene whose materials differ, or
converted while the direct program is still being prepared (the wallpaper is playing
normally and a second program is on its way). A material whose shader the
translation cannot reproduce — an explicit level-of-detail sample, a size query, a
texel fetch, two video slots in one material — keeps converting and says nothing; so
does any frame that is not 8-bit NV12, which is what a software decoder produces for
the same file. Nothing here changes which renderer draws a scene
([scene renderer](scene-rendering.md#scene-renderer)).

**Where the two differ.** At a one-to-one mapping between video texels and output
pixels the two paths produce the same picture, to within the single code value the
converted intermediate's own 8-bit quantisation can introduce. Where the layer is
resampled they are not identical, for a structural reason: the converting path
clamps each texel to the range the stream declares and quantises it before the
layer's sampler filters, while the direct path filters first and clamps the result.
The transform between those two clamps is affine, so the two orders agree exactly
wherever the clamp does nothing — every sample a conforming stream carries. Where a
stream carries codes outside the range it declares they can differ by up to the
excursion that clamp removes, at most 24 code values for 8-bit limited range. This is
a real difference, not floating-point noise, and it is why the setting is opt-in.
No power measurement has been taken: what is claimed is only that a conversion is not
encoded and its destination is not allocated when nothing asks for one.

## Background work only while it has a consumer

These change no setting, frame rate, render scale or sound; they stop work that
nothing could see or hear.

- **Wallpaper sound output.** The Core Audio output a scene's sound layers or a
  video's own audio track play through starts only while something is mounted, the
  wallpaper is playing and it is not muted. A paused, muted or silent wallpaper, a
  wallpaper that arrives paused, and the lock-screen extension (always muted) start
  no output, so Core Audio runs no output cycle for them and holds no idle-sleep
  assertion on their behalf. Resuming or unmuting costs one device start.
- **System audio capture.** Runs only for a presenting wallpaper that actually reads
  the sound; see [audio response](audio-response.md). A wallpaper that reads audio
  still runs the tap, and no drop in coreaudiod cost is claimed for it.
- **Output device watcher.** The app listens for a change of the default output device
  only while a tap is wanted (a presenting scene reads the sound, or a page listens, and
  nothing is suspended), to rebuild that tap
  ([audio response](audio-response.md#output-device-changes)). With none wanted there is
  no watcher thread or subscription, so switching to a Bluetooth or USB device wakes
  nothing and writes nothing. The system-wide device-change listener is registered the
  first time a watcher starts and stays registered; between watchers it finds nobody to
  wake.
- **Pointer sampling.** Scenes receive the cursor from a sampler that runs when
  macOS reports pointer motion or a button, when an interactive scene appears or
  resumes, or when its pointer delivery is reset, at most once per 16 ms, with a
  move after a quiet stretch delivered at once. A still pointer causes no wakes, and
  a scene that is paused or covered is not a consumer. While this app is frontmost,
  where macOS routes pointer events past the monitors, the sampler checks the cursor
  every 16 ms and does engine work only when it moved. No new permission is needed.
- **Frame clock.** A wallpaper's frame clock starts when its scene is loaded, not
  when the renderer is created, so a surface still parsing or whose load failed has
  no clock thread. A global resume applies each display's own pause in one step, so
  a display that is still covered is never briefly resumed. A pointer sample that
  cannot move the next tick does not wake the clock, and a burst of samples while it
  is idle coalesces into one frame; the configured frame rate stays the ceiling
  ([update only when the scene changes](scene-rendering.md#update-only-when-the-scene-changes)).
- **Video decode.** The decode thread is woken when a frame is actually ready, not
  on every tick that has nothing new, and per-tick counter bookkeeping runs only
  while renderer counters are on.
- **Discover previews.** Animation sources exist only for visible tiles in a visible
  document ([tile thumbnails](workshop-downloads.md#tile-thumbnails)).
- **Installed previews.** Tiles show small still covers, and one animation exists
  only for the tile under the pointer or keyboard focus in a visible document
  ([control panel](control-panel.md#layout)).
- **Power source watcher.** The thread that follows plugging in and unplugging
  sleeps until macOS reports a change or the app quits. It used to wake every five
  seconds only to read a stop flag, and quitting could wait for that wake; it now
  stops at once. A power change the app could not apply is offered again at the next
  change instead of being dropped. The app can also ask it to read again when the Mac
  wakes ([Playback](#playback)), which wakes the thread once before it sleeps again.
  No power saving is claimed.
- **Renderer counters.** They count only inside a bounded window: a
  [diagnostic window](../testing/power-benchmark.md#runtime-counters) asked for
  through the environment, or, when **Send performance data** is on, one 60 s
  [frame window](telemetry.md#frame-windows) every four hours. Outside one, each
  counted event costs one relaxed atomic load.

The regression coverage for these is in
[renderer verification](../testing/renderer.md#regression-areas-that-must-stay-covered).
Those tests prove the work stopped; they are not power measurements, which still
need the matched conditions in [power benchmarking](../testing/power-benchmark.md).
