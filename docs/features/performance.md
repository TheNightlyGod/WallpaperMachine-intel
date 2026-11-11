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
another app in front, display sleep, app rules) are stored in `PlaybackPreferences` and published on the
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
- **Plain video.** A plain video is decoded by the media engine and drawn by WindowServer,
  so almost none of its cost reaches the app. While the engine's **In use now** report lists a
  video, readings carry `nativeVideo`, the row reads **Video not counted** with a
  note, and there is no grade, battery share or comparison; a comparison in
  progress is dropped, since starting a video would otherwise read as a near-total
  saving. A window that held a video sample stays flagged until it has aged out.
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
  the battery is low, and the scene and
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

- **When a sample is credited.** Every 30 seconds (a tick may come up to 5 s late,
  so the system can share the wakeup) the recorder asks the app delegate for a
  `WallpaperEnergyContext`. While presentation is suspended or unloaded the app
  delegate parks it (`setParked`): no tick runs at all, so a locked Mac or sleeping
  displays get no wakeup from it, and the first interval after the resume starts a
  full interval later. There is none, and no sample is taken,
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
  read from the engine's `effectiveFrameRateCap`) and the effective render scale,
  and for a scene (or a wallpaper of unknown kind) the scene settings that change
  what drawing it costs (`WallpaperEnergySceneSettings`): the 2D scene resolution
  (display or canvas), the saved scene quality (MSAA, shadows, volumetrics,
  reflections and post-processing, levels the renderer does not draw yet included)
  and MetalFX upscaling. A video or web page leaves them out, since they change
  nothing it draws. A measurement under other conditions replaces the rating rather
  than being averaged in, so the line always names the settings it describes; the
  line itself names only the displays, frame rate and render scale. A Mac that moves in and
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
  rating carries `version` (`WallpaperEnergyRating.currentVersion`, 3); one from
  another version is still read and shown, and is replaced by the next measurement,
  not averaged with it. Ratings saved without a version (1) may have credited native
  video playback, so a video wallpaper's is not shown. Versions 1 and 2 left the
  scene settings out of the conditions, so a scene's rating may average measurements
  taken at different scene resolutions, qualities and upscaling; telemetry sends only
  ratings of the current version.
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

### MetalFX upscaling

**MetalFX upscaling** (off by default, saved as `quality.metalfx_upscaling_enabled`)
changes how a scene drawn below 100% is brought back to its size on screen. Off, the
composition stretches the lowered picture with a bilinear sample, as it always has. On,
each presented frame of a scene whose render scale is below 1 first runs Apple's MetalFX
spatial scaler on the scene's final output, writing an image the size that output has at
100%, and the composition then samples that image exactly as it would at full resolution;
scaling mode, zoom, framing, flip and the poster are unchanged. It applies to the
effective scale, so the battery or a reduced-quality condition's lower scale is upscaled
too. At 100% it does nothing and costs nothing. A running scene picks it up at its next
presented frame; nothing is rebuilt or reparsed.

The cost while it is in force is one MetalFX pass per presented frame (a frame skipped
as unchanged runs none) and one extra image the size of the scene's full-resolution
output, which is let go on the first frame that no longer needs it, and when the scene's
graph is released. The pass is priced by the output size, not the render scale: on an
M2 Pro it took about 1.1 ms of GPU per frame for a 3024×1964 output and about 2.6 ms
for 5120×2880, against 0.1–0.3 ms for the stretch, at 75% as at 50%. A lightweight
wallpaper can need little more than that per frame at a lowered scale, so on a real
machine one such wallpaper used about 50% more power with it on than at the same scale
with it off, and 50% with MetalFX can cost more than plain 100%. The gain is small: it
sharpens hard edges (PSNR against the 100% picture 24.5 dB instead of 22.9 dB for a
synthetic pattern at 50%), cannot add detail that was never drawn, and on soft wallpaper
art and photos the stretch is already as close or closer. That is why it is off by
default. 8-bit outputs use MetalFX's perceptual mode and half-float ones its HDR mode. An
output MetalFX cannot take is logged once and composed the old way. Web wallpapers
(WebKit draws them) and videos are not affected. FSR is not offered: FSR 1 is the same
kind of spatial upscaler, and MetalFX's temporal scaler or FSR 2 and later need motion
vectors, depth and jittered rendering that scene passes do not provide.

### 2D scene resolution

**2D scene resolution** (**Display resolution**, the default, or **Canvas size**) is
how many pixels a 2D scene is rasterized with before the internal render scale takes
its share; the scale multiplies whichever is chosen. A 2D scene is one with an authored
canvas, drawn with an orthographic camera.

- **Display resolution** rasterizes the canvas at the size it is presented at on the
  display: the Fill layout's scale times the display's backing scale, which is what
  Wallpaper Engine does. The 1920×1080 canvas of a scene on a 3456×2234 panel is drawn
  into a 3972×2234 image (Fill crops the part that overhangs the panel, but it is
  rasterized unless the experimental [**Draw only the visible part of cropped
  scenes**](#draw-only-the-visible-part-of-cropped-scenes) is on) instead of 1920×1080
  stretched to that size at the last step, so edges and grain keep the panel's own
  pixels. Text layout and atlas sizes stay in canvas
  units, while glyph shaders draw at the target resolution. Coverage atlases gain
  no source detail; MSDF edges are evaluated at that resolution. At the Low and
  Medium presets the render scale then applies to that size (50% is half of it in
  each direction).
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
resizes its targets in place, with no reparse and no timeline
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
| Bloom and an effect chain | Compatibility (retired) | 1.91 → 3.27 ms | not read | 399 → 480 MB |
| 26 layers, author-sized effect buffers, no bloom | Native Metal | 1.76 → 2.33 ms | 132 → 160 MB | 515 → 555 MB |

The cost follows how much of a scene is screen-sized, so a scene of mostly
author-sized buffers pays little and a bloom or full-screen effect chain pays for
every level. At 60 fps the first scene's extra 1.8 ms is about a tenth of a frame.
CPU time per frame did not move, and the energy effect has not been measured: the
whole-GPU energy figures of the probe are not usable on a machine that is also doing
other work. Peak footprint carries about ±30 MB of run-to-run noise. The Canvas figures
are what the app drew before the setting; choose **Canvas size** to keep them.

### Scene quality

Five rows under **Quality** are Wallpaper Engine's own scene settings, with its words in
`config.toml` under `[quality.scene]`:

| Row | Key | Choices (saved words) | Default |
| --- | --- | --- | --- |
| **Antialiasing (MSAA)** | `msaa` | Off, 2×, 4×, 8× (`none`, `x2`, `x4`, `x8`) | Off |
| **Shadows** | `shadows` | Off, Low, Medium, High, Ultra (`disabled` … `ultra`) | Medium |
| **Volumetrics** | `volumetrics` | as Shadows | Medium |
| **Reflections** | `reflection` | on or off | on |
| **Post-processing** | `post_processing` | Disabled, Enabled, Ultra, Display HDR (`disabled`, `enabled`, `ultra`, `displayhdr`) | Enabled |

The defaults are Wallpaper Engine's first-run **Medium** preset (its welcome dialog
selects Medium; its preset table writes msaa `none`, post-processing `enabled`, shadows
and volumetrics `medium`, reflection on). A word this build does not know reads the way
Wallpaper Engine reads it (`wallpaper64.exe` `sub_14010DF40`): MSAA none, lighting
medium, post-processing enabled; the file still loads and the word is logged.

- **Post-processing.** Disabled draws no bloom. Enabled draws LDR bloom only. HDR bloom
  (a scene with `bloom` and `hdr`) needs Ultra or Display HDR; Display HDR also asks for
  HDR output: an EDR-capable display gets an extended-range surface (see
  [scene rendering](scene-rendering.md)), any other display stays SDR. Before this
  setting HDR scenes always drew HDR bloom; at the default they now draw LDR bloom, as
  Wallpaper Engine does at Medium.
- **Reflections.** Off stops refreshing the frame copy reflective materials read
  (`_rt_MipMappedFrameBuffer`); it keeps its first, cleared contents. A model whose
  active material samples `_rt_Reflection` also gets a planar reflection: the scene
  drawn once more through the camera mirrored across `y = 0` into a raster-sized RGB
  picture (about 32 MiB at 3840 × 2160, 64 MiB with the depth it needs while
  Reflections is on) and one extra render pass per changed frame. Off keeps that
  picture cleared and draws no reflected pass; a scene without such a material
  allocates nothing for it.
- **Shadows.** Point, spot and directional lights cast model shadows. Low and Medium
  use 256-pixel tiles, High 512, and Ultra 1024. Off, a scene without a visible shadow
  light, or a scene without a visible model caster allocates no shadow atlas and draws
  no shadow pass. **Quality in force** reports the requested level while shadows are
  drawn, and follows live visibility and `castshadow` changes back to Off.
- **Volumetrics.** Point and spot lights that cast volumes draw light shafts, including
  spot cookies and model shadows. Low and Medium use one-eighth-size accumulation
  with two blur passes; High and Ultra use one-quarter-size accumulation without
  blur. Off or no active casting light adds no volume targets or passes. **Quality
  in force** follows activation and removal. Enabled volumes add bounded targets and
  two geometry draws per light; a static volume does not demand continuous frames.
  When the scene writes multisampled depth, volumes additionally need one resolved
  full-resolution 32-bit depth image (about 31.6 MiB at 3840×2160, before allocator
  alignment). The existing scene encoder resolves it without a separate copy pass.
- **Antialiasing** is saved and sent to the renderer; **Quality in force** reports
  the sample count negotiated for the scene's model target.

A change reloads each running scene wallpaper once (these settings change how a scene is
built), and its shaders compile again: the shader cache is keyed by the quality. Videos
and web wallpapers are untouched. Reduced quality (battery, Low Power Mode, heat, low
battery) never changes these settings; Reset all settings returns them to the defaults.
**Quality in force** under Advanced › Scene wallpapers › Live diagnostics lists, per
running scene, what the renderer actually applies, and exported diagnostics append
`quality msaa=… shadows=… volumetrics=… reflection=… post=…` to each running scene line.
The lock screen and screen saver use the saved quality.

### Default per-display frame rate

A display with no saved rate runs at its refresh rate up to 60 fps
(`DEFAULT_FRAME_RATE_CEILING` in the bridge's `config` module): 60 on a ProMotion
MacBook Pro, a MacBook Air or a 60 Hz external display, 48 on a 48 Hz one. A
scene's cost follows its frame rate, and so does WindowServer's compositing share
([power benchmarking](../testing/power-benchmark.md#windowservers-share)). A higher
rate is one choice away: the per-display slider still goes up to the display's
refresh. Web wallpapers draw near 60 fps below that refresh and at the full
refresh once the rate reaches it ([frame rate](web-wallpapers.md#runtime-shape)).
A scene at 60 on a 120 Hz display shows each frame two refreshes after the last
rather than one or three when its frames are ready near a refresh boundary
([scene rendering](scene-rendering.md#update-only-when-the-scene-changes)).

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

A display can resume as soon as AppKit reports its wallpaper visible during a
Mission Control transition, including before the incoming desktop becomes the
active Space. A full-screen window still pauses the wallpaper while it covers it.

Each display follows its own visibility even when both use the same wallpaper.
Waking or unlocking re-evaluates every display in the same pass: one that is visible
again resumes without a click or refresh, while one still covered stays paused.
Reapplying a wallpaper or changing the display arrangement also reconciles the live
scene's pause with the current playback policy, so a pause retained by a rebuilt
renderer cannot hold a visible display still. The user's own Pause remains in force.
After each reconcile that succeeds, including one that found nothing to rebuild, the
bridge compares every live scene's pause with the policy as it stands then and sends
a pause or resume only to the displays that differ; a covered or suspended display
stays paused while a visible one resumes. A reconcile that a newer change overtook
leaves this to the reconcile that replaces it, so a Pause or Play pressed meanwhile
wins. There is no timer and no per-frame check (bridge `tests::playback_reconciliation`).

| Setting | Values | Default |
| --- | --- | --- |
| Mute all wallpapers | On, Off | Off |
| When windows cover the desktop | **Pause**, **Keep running** | Pause |
| When another app plays sound | **Keep running**, **Reduce volume**, **Mute**, **Pause**; Reduce volume plays wallpapers at **0%** to **100%** of their own volume | Keep running, 30% |
| When another app is in front | **Keep running**, **Mute**, **Pause**, **Pause on battery** | Keep running |
| When displays sleep | **Pause**, **Stop (free memory)** | Pause |
| When the Mac is inactive | **Keep running**, **Pause**, **Stop (free memory)**; inactive after **5**, **10**, **15** or **30 minutes** or **1 hour** without input | Keep running, 10 minutes |
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
this wallpaper** and volume or a display's. The two name each other instead of
disagreeing: while Mute all is on, the inspector's **Mute this wallpaper** shows on and
locked, with a note that Mute All is on; while it is off, the Quick Settings tile reads
**Off · N muted separately** when N installed wallpapers are muted on their own (the
bridge's `muted_wallpaper_count`). It is one more reason, in
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
wallpaper change and a scheduled rule for it wait until it plays again, a playlist
step is made behind it once ([Playlists](playlists.md#when-a-change-happens)), and
its energy counts as not playing. The settle and periodic captures of its Mission Control picture skip it while it is paused; a new wallpaper still asks it for
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

**Reduce volume** keeps wallpapers playing and turns them down while another app
plays sound. Choosing it shows **Reduce volume to**, a slider from 0% to 100%
(default 30%): each wallpaper plays at that share of its own saved volume, so one
saved at 80% plays at 40% with the slider at 50%, and it returns to its own volume
when the other sound ends. The level is a gain the bridge multiplies every saved
volume by (`set_audio_gain`, from `PlaybackPreferences.otherAudioVolume`). It is
kept for the run only and never rewrites a wallpaper's or a display's saved volume:
a volume changed meanwhile is saved whole and plays reduced, a wallpaper applied
meanwhile starts reduced, and a slider moved while the other app still plays
applies its new level when it is let go. Scene and video wallpapers change live, without
reloading. A Web wallpaper follows it as far as its own Volume reaches: the audio
and video it plays through media elements, where WebKit exposes that control, and
not Web Audio, which only **Mute** silences
([Page sound](web-wallpapers.md#page-sound)); at 0% the page is muted, as it is at
zero volume. It does not stand in for a mute: **Mute all wallpapers**, a mute app
rule and a Focus filter still silence a wallpaper that is turned down, and when they
end it is still turned down for as long as the other sound lasts. Only this row
offers it; **When another app is in front** and the app rules mute or pause as
before. A [backup](backup-restore.md) carries the choice and the level, and **Reset
all settings** puts them back on **Keep running** and 30%. Whether the lower volume
is heard as expected on a real output has not been checked by a test: the tests
follow the gain to the engine's volume call and to the web and video descriptors.

Another app counts as playing sound while Core Audio reports it running audio
output (`kAudioProcessPropertyIsRunningOutput`). This app and the processes it is
responsible for, such as the WebKit processes playing a web wallpaper, are
excluded, and so are the Mac's own feedback sounds: alerts and interface sounds
(`systemsoundserverd`, `audiomxd`), the login sound (`loginwindow`), the
volume-change click (`ControlCenter`) and Siri listening (`corespeechd`,
`corespeechd_system`), which keeps an output stream running while it waits.
These are matched by their full path on the system volume
(`OtherAudioMonitor.systemSoundServices`), so a program elsewhere with one of
those names still counts. Sound must last 0.5 s before it counts and silence 2 s before it clears,
so a gap between tracks does not restart the wallpaper. Nothing is observed while
the choice is **Keep running**.

**When another app is in front** mutes or pauses every wallpaper while any app
other than the desktop is the active one, the way Wallpaper Engine's choice for
another application being focused does. Finder counts as the desktop, because clicking
the desktop brings it to the front (a Finder window in front therefore counts too), and
so does this app, whose panel and menus are about the wallpapers. A moment with no app
in front is not another app. **Mute** and **Pause** behave as they do for other-app
sound above, and the user's own Play/Pause is untouched. It is the frontmost-app check
of the app rules applied to every app: `AppRuleMonitor` adds the chosen action to the
rule actions it publishes (`AppRuleMonitor.defaultDesktopBundleIDs` names the desktop
apps), so it composes with the app rules, Focus filters and the user's mute instead of
replacing them. Workspace activation notifications are observed only while it or an app
rule can do something; there is no polling. A full-screen app needs no choice: its
display already pauses because the wallpaper cannot be seen.

An app stays in front after its last window is minimized or closed, and macOS posts no
activation for that, so the app in front counts only until a window change shows it has no
window left on screen. The change is the occlusion of this app's own windows: the
coverage probes (`WallpaperCoverageProbes`, above) over each working area, which the policy keeps while this
choice is not **Keep running** even when a covered desktop keeps running (kept for that alone,
they pause nothing), and the wallpaper windows. On each change, while another app is in front,
`AppRuleMonitor.showsWindow(processID:)` asks the window server once whether that app has a
window on screen in the current Space (normal windows up to floating panels, visible, larger
than one point); one that has none stops counting until it is activated again or a later
change finds a window. Minimizing a window that covered the working area, a zoomed one, plays
the wallpaper at once. Minimizing a smaller window changes no occlusion, so that wallpaper
plays again only at the next activation (clicking the desktop), as before. An activation always
counts at once, so an app launching is in front before its first window opens.

**Pause on battery** is **Pause** limited to battery power, for the case the covered-desktop
pause leaves alone: a wallpaper animating in the gaps between windows that do not cover the
working area while you work in other apps. While the Mac runs on battery and another app is
in front, every wallpaper pauses exactly as with **Pause**: it holds its last frame and plays
again the moment you click the desktop or return to this app. On mains power it does
nothing, and an unknown power source counts as mains. Plugging in resumes at once and
unplugging with another app in front pauses at once: `AppRuleMonitor` reads the source the
app's `PowerSourceMonitor` last reported (an injected closure, read only while this choice is
made and another app is in front) and is worked out again from the app delegate's
power-source change, which also receives the reads after a wake that find a different source.
Activations stay observed on mains power so that an unplug finds the app in front already
known. The row's note says it applies only on battery. It is off unless chosen, like every
other choice of the row; a [backup](backup-restore.md) carries it and **Reset all settings**
puts the row back on **Keep running**. The menu bar's **On Battery** submenu offers it as
**Pause While Using Other Apps** ([control panel](control-panel.md#menu-bar-one-display-at-a-time)),
and the [battery question](first-run.md#the-battery-question) as **Pause while I use other
apps**. A paused wallpaper draws nothing, so for the time another app is in front on battery it
saves the wallpaper's whole cost: headless, at 60 fps on the 3456x2234@2 built-in panel of an M5
Pro, two ordinary scenes (3802900973 and 3413921910) drew 1.6 and 2.3 W of GPU power
(`perf_bench.py cost`), to which WindowServer adds its share for presenting them
([power benchmarking](../testing/power-benchmark.md#windowservers-share)). How much battery
that keeps depends on the wallpaper and on how much of the time other apps are in front.

**Stop** on display sleep frees renderer memory. The wallpaper is reloaded when the
display wakes. **Pause** keeps it loaded.

**When the Mac is inactive** pauses or stops every wallpaper once the Mac has had no
keyboard, mouse or trackpad input for the time chosen under **Inactive after**, and
resumes them at the next input. It covers the time between walking away and the
displays going to sleep, which many people set long or never. The time row appears
once an action other than **Keep running** is chosen. Input is what macOS counts for
the whole login session (`CGEventSource.secondsSinceLastEventType` with the combined
session state): typing, the pointer, clicks and scrolling, and the events other apps
post into the session too. Reading it needs no permission. **Pause** keeps the last frame; **Stop (free memory)** unloads
the wallpapers and reloads them at the next input, as the other Stop choices do. Like
the other conditions of the Mac it never changes your own Play/Pause, a playlist
change that falls due meanwhile waits for the wallpapers to play again
([Playlists](playlists.md#when-a-change-happens)), and an inactive Mac does not count
as nobody being at it, so an automatic update still waits for the displays to sleep or
the session to lock ([Updates](updates.md#automatic-updates)). The row adds `In effect
now. Wallpapers are paused.` (or stopped) while the rule holds, and Quick Settings' **On
battery** module names it as it names the other conditions below.

`UserInactivityMonitor` watches only while an action other than **Keep running** is
chosen. While the Mac is in use its only work is one one-shot timer, armed for the
moment the time runs out if no input comes; when it fires the count is read again,
and input since then arms it again for the time left. Once the Mac is inactive it
waits for the first input with one global and one local event monitor for the
pointer, clicks and scrolling, which need no Accessibility or Input Monitoring grant,
and a read of the count every two seconds on a timer that tolerates a second's delay,
which is what notices typing alone: a global keyboard monitor would need
Accessibility, so there is none. That read waits while the displays sleep or another
user's session has the screens, since no input can reach this session then. Both are
asked of the system, not remembered from the last notice: the displays
(`DisplayPowerProbe`) each time the read would be armed, and the session's console
state, a window-server round trip, only when a run of reads begins (watching starting,
the deadline, a pointer event, the read after a notice), since the session cannot
leave or return without a notice. So an app relaunched by an automatic update while
the displays sleep arms no read at all. The displays sleeping or waking, the session
leaving or returning, the Mac's wake and an unlock read the count at once and arm one
read whatever the system says then, because a notice can come before the state it
announces has settled; that read asks both again, so a real sleep stops it after one
turn and a wake or return the system had not yet shown still lets typing end the
inactivity. The first input removes the monitors and the timer and arms the deadline
again. While this app is the
active one the global monitor sees no pointer events and the local one only those its
own windows receive, so a pointer moved over the desktop then is noticed by the
two-second read.

A display with a [different wallpaper for each desktop](spaces.md#keeping-each-desktops-wallpaper)
keeps the wallpaper of each desktop the person visited loaded and paused, so coming back runs it
on instead of loading it again. A kept wallpaper draws nothing; its cost is the memory it holds,
plus whatever timers a kept web page that ignores the pause still runs under WebKit's inactive
scheduling. Every **Stop (free memory)** choice and the Mac's memory pressure let go of them.

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
changes nothing. The same three choices are in the menu bar's **On Battery** submenu
and in the one-time [battery question](first-run.md#the-battery-question); both set it
through the engine as this row does (`BridgeStore.setBatteryModeAsync`).

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
pause, and heat, then Low Power Mode, then a low battery, then an inactive Mac among
equals, for example
`Low Power Mode is on. Wallpapers are stopped.` What the choice already does is not an
override, so **Pause** beside a rule that pauses says nothing, while one that stops is
named. Plugged in, the choice does nothing and nothing is said. Heat on Reduced quality
reads as a pause once it is critical.

Focus filters and app rules stay on their own rows and are not named under **On
battery**: they act whatever the power source, so they override every choice on the
page alike, and they are things the user turned on for the moment (a Focus, an app
in use) rather than a state of the Mac's power. The **Focus** row says which filter is
in effect now; the **App rules** rows do not yet say which rule is engaged. A rule's minus
button asks before it removes the rule: it turns into **Cancel** and **Remove**, and
VoiceOver names the app the rule is for.

**Pause on battery** is the one app-in-front choice scoped to the battery, and it is
presented as a choice of its own row, **When another app is in front**, whose label and
note say it applies only on battery, rather than as a fourth **On battery** choice: it
combines with any of them (Reduced quality on battery while the desktop is in view, a pause
while other apps are in front), and **On battery** stays the engine's one setting. Quick
Settings' **On battery** module does not name it as in effect, because it never is while
the panel can be seen: this app in front counts as the desktop. Where the battery choices
are gathered for someone who has not found this page, they come together: the menu bar's
**On Battery** submenu holds the three **On battery** choices and **Pause While Using Other
Apps**, and the [battery question](first-run.md#the-battery-question) offers both kinds.

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
- **Saving.** The renderer's half was measured headlessly (`perf_bench.py cost`, the
  default profile of 30 fps and 75 % against 60 fps and 100 %, as a `--variant` setting
  `WE_TEST_ENERGY_FPS` and `WE_TEST_ENERGY_RENDER_SCALE`, 3 pairs, on the 3456x2234@2
  built-in panel of an M5 Pro): the GPU power of 3802900973 fell from 1.60 to 0.41 W and
  that of 3413921910 from 2.27 to 0.56 W, about three quarters, and the app's CPU power
  about halved. It is a quality tier, not an equal-quality saving
  ([comparison rules](../testing/power-benchmark.md#comparison-rules)). WindowServer's
  share, which follows the
  present rate, and the desktop as a whole need an authorized desktop session
  ([condition matrix](../testing/power-benchmark.md#condition-matrix)).
  Whether a change made while the Mac is locked behaves as intended has not been
  exercised on a Mac.

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
filter); nothing is polled. An inactive Mac is reported by `UserInactivityMonitor`
(above), which runs only while its rule is chosen.
The battery adds IOKit's power-source notification
(`IOPSNotificationCreateRunLoopSource`, wrapped by `SystemBatteryLevel`), registered
only while a low-battery action is chosen and removed when it is not, and read again
when the Mac wakes in case a plug or unplug during sleep was never reported. The
decision itself is `LowBatteryGate`, fed by one `BatteryReading` of the internal
battery. Web mute uses the same availability boundary as above.
Wallpaper and playlist selections instead reach `WallpaperAutomationScheduler`;
they never become pause/mute/stop actions or change the user's own Play/Pause. The
[different wallpaper for each desktop](spaces.md) mode uses the same eligibility gate,
keeps a wallpaper chosen by hand as the current desktop's own, and defers Focus exit
while the current desktop cannot be identified. It runs one renderer per display, like
any other mode: desktops that are not on screen show a still picture. Animated lock-screen ownership
conflicts with that mode; screen-saver-only ownership does not.

### App rules

The **App rules** row on Playback & Power opens an inline list, for a rule about one app;
**When another app is in front** above is the same check for every app. Each row is an app name, a condition (**Running**
or **In front**), an action (**Pause**, **Mute** or **Stop**) and **Remove**. **Add
app…** opens a native panel for one `.app` bundle. An app with no bundle identifier
is refused. The same bundle is not added twice. Rules pause, mute or stop
wallpapers while the chosen app matches. They do not change the user's own
Play/Pause. Web mute uses the same output channel and availability boundary as
above, without disabling its system-audio response.

## Advanced

Collapsed by default, with a **Diagnostics & experimental options** preview. Inside,
three flat sections separate **Video playback**, **Scene wallpapers** and
**Experimental**. The video section holds only its collapsed **Live
diagnostics** disclosure (there is nothing to choose); the scene section has one too: video lists each running video by display and wallpaper; scenes show the renderer
and video path, whether optimisation is in force, and what is keeping the scene
updating. These reports continue to update from snapshots, and their open state
survives setting changes. **Renderer compatibility** remains beside the scene
diagnostics: what Native Metal draws, and what it does with a scene it cannot.
**What these settings change** belongs to Playback & Power, not Advanced.
What the two scene controls do (**Scene render optimisation**
and **Update only when the scene changes**) is described in
[scene rendering](scene-rendering.md#scene-wallpapers). There is no renderer to choose:
Native Metal is the only one, and a scene it cannot draw is held on its last picture with
the reason under **Drawn by**
([scene rendering](scene-rendering.md#when-native-metal-cannot-draw-a-scene)).
The **Scene renderer** setting that chose between Compatibility, Native Metal preferred
and Native Metal only is gone: `config.toml` files that still hold `scene_renderer` (and
its `native_metal_default_applied` marker) load, the keys are ignored and are not
written back.

## Video playback

Every plain video wallpaper is played by the app's own players: AVFoundation for the containers
macOS opens (MP4, MOV and the like), and the WebM player below for WebM and Matroska. There is
no other player. The scene engine is never given a plain video on the desktop; it used to be the
fallback for any video the native player refused, and a **Video backend** setting chose between
the two. The setting is gone from Settings and the config: `config.toml` files written by earlier
builds that still hold `video_backend` (and the older `experimental.native_video_backend`) load and
the keys are ignored, and not written back. **In use now** lists the display and wallpaper of each
running video, and it names a problem only when the project's media file cannot be found. It reads `No video wallpaper is running.` when
nothing is playing video. A video the player cannot play is not handed to anything else: its
display is reported as failed with the reason (below) and keeps the picture it had. The lock screen
and screen saver do the same: a clip their own players cannot play is held on its last frame with the
reason as a note ([lock screen](lock-screen.md#plain-video-wallpapers)).

**Wallpaper Engine options on a video.** The inspector's **Wallpaper Engine options** reach both
players, the desktop, the preview and the lock screen (which shows the saved values). The
**Playback rate** is the player's rate (`rate` / 100, `wallpaper64.exe` `sub_1400FFCB0`;
`AVPlayer.defaultRate`, the WebM player's synchronizer rate). **Flip horizontally** mirrors the
picture's layer about its centre and the poster with it. The colour adjustments and the image
filter run Wallpaper Engine's `ccsimple` formulas in Core Image (`Shared/VideoColorPipeline.swift`,
the `wallpaperEngineColor` kernel in `Shared/WallpaperEngineColor.ci.metal`; the `.tex` LUT is
decoded once per file by the renderer). They cost nothing at the identity: no composition is
attached and the WebM layer is fed the compressed samples. Otherwise AVFoundation runs a
per-frame `AVVideoComposition`, and the WebM player decodes each sample itself
(`VTDecompressionSession`) and filters it before handing it to its layer — a CPU/GPU cost per
frame for as long as the options are not the identity. The colour kernel unpremultiplies before
adjusting RGB and premultiplies afterward; LUT sampling and strength mixing operate on the
explicitly encoded RGB values without a second colour-space conversion. Moving a slider changes the next frame;
switching the colour options or the filter on or off reopens the item at its current time, which
does not count against the repair allowance. In Fit and Original size the room around the
picture takes the project's `schemecolor` property (Wallpaper Engine's border colour), black when
the project has none; Fill and Stretch stay black. Desktop posters and lock-screen snapshots keep
those same borders. A preview at the identity has no video composition, and edits received while
an item is being prepared are reconciled before it starts. Filtered WebM samples use the decoder's
presentation timestamps; invisible reference frames update the decoder without being displayed.
The filtered feed reuses one output format description while it matches the next pixel buffer's
layout and colour attachments, replacing it when they change instead of allocating a description
for every frame. Filtering, pixels and presentation timing are unchanged; power savings have not
been measured.
Decode or filter failures are reported through the player's recovery path instead of passing an
unfiltered packet to the display.
A mirror display plays its source's clip with a player of its own, and each mirror group is
heard from one member (`MirrorAudioOwnership`, the rule [web pages](web-wallpapers.md) follow):
the source while it is in sight and not paused or muted, otherwise the lowest-numbered mirror that
is, at that display's own volume. The others play silently, so the sound is never heard twice,
and a covered source hands the sound to a mirror still in sight. The same clip chosen for two
independent displays is two wallpapers, and both are heard.

A plain video that cannot be heard does not decode its sound at all ([below](#background-work-only-while-it-has-a-consumer)):
one that is muted or at volume 0, muted by **Mute all wallpapers** or a rule (another app in front,
other-app sound, Focus), or a mirror member that does not carry its group's sound. The
AVFoundation player switches the clip's audio track off on every copy of the item the loop
plays, before the platform prepares it; the WebM player stops feeding its audio renderer and takes
it off the clock. Being heard again switches the same track back on, or feeds the WebM sound from
where the clock is, without reopening the clip. A clip with several audio tracks the file marks
enabled keeps its sound running muted, because which of them the platform plays is its own choice.

Applying a video checks that its entry is a readable, nonempty file. A file that is
missing or empty fails with the usual error. It also checks that the format can be played,
on both **Apply** and **Apply changes** (and on Reapply), before any display changes. A
file nothing can play is refused with a message that names its format, for example "This
video's format isn't supported (AVI), or the file is damaged. Convert it to MP4 or MOV with
H.264 or HEVC, or import a complete copy, then apply it again.", and the display keeps what
it showed. The format check (`VideoFormatSupport`) asks AVFoundation whether the file is
playable and has a video track, reads the container from the file's first bytes (MP4, MOV,
WebM, Matroska, AVI, Ogg, WMV, FLV, MPEG; the file extension only names a file whose bytes
show none), and refuses AV1 on a Mac with no hardware AV1 decoder, with its own message,
because software AV1 decoding of a wallpaper that runs all day is a cost the app does not
take on. Matroska and WebM, which AVFoundation never opens, are opened with the app's own
reader and played by the WebM player (below) when it plays them (H.264, HEVC and VP9 in them,
and AV1 on a Mac with hardware AV1 decoding); every other codec in them (VP8, an encrypted
track, 4:2:2 or 4:4:4 pictures) and a damaged file are refused with the container and codec
named ("WebM (VP8)"). An MP4 or MOV whose HEVC is tagged `hev1` is not refused when its sample
descriptions carry the parameter sets: it plays from a copy retagged `hvc1` ([below](#hevc-tagged-hev1)).
A file that could not be read at that moment (a busy volume, a file
still being written) says nothing about its format, so the apply goes on and the host tries
it. Importing never checks the format: an `avi` or a VP8 file is imported and refused only
when it is applied. Decoder failures after this check still go through the engine's apply
recovery.

A file already assigned to a display that is found to be in such a format when the
wallpaper loads (a library item applied before this check existed, or a migrated
config) is refused the same way. The display keeps the picture it
had, no window covers it, and the wallpaper's state in the panel reads **Wallpaper
could not load** with the same message. The verdict is kept under the file's key, so
the file is not read again until it changes, and a replaced file is judged afresh.

<a id="hevc-tagged-hev1"></a>**HEVC tagged `hev1`.** macOS decodes HEVC in an MP4 or MOV only when
its sample entry is tagged `hvc1`; for `hev1`, which says the parameter sets (VPS, SPS, PPS) may
also come inside the stream, AVFoundation calls the track not playable. Encoders such as FFmpeg
write `hev1` files that still carry all three in the `hvcC` record, so the four characters of the
tag are all that stand in the way. When AVFoundation refuses the `hev1` track of an MP4 or MOV, the
format check reads the file's sample descriptions (`HevcSampleEntryRetag`: box headers and `stsd`
only, wherever `moov` lies) and, when every `hev1` entry's record carries a VPS, an SPS and a PPS,
the wallpaper plays from a copy whose entries say `hvc1`; nothing is decoded or re-encoded. A clip
whose `hev1` entries lack one of them has its parameter sets only in the stream, and is refused
with the usual message as before. The file in the library is never written (a Workshop update
would undo it, and its hash, its backup and the update check would see another file). The copy
(`DerivedVideoCache`, in `Cache/DerivedVideos` in the app's support folder) is an APFS clone of
the clip, which costs the one block that differs and is made at once. When the library is on
another drive than this Mac's startup disk (where the app keeps its caches), or on a volume that
cannot clone, it is a full copy. That copy is made in the background, outside the metadata read's
time limit and outside the pass that opens the displays: meanwhile the wallpaper's state reads
**Loading wallpaper content…** with a message that the corrected copy is being made, and the clip
opens when the copy is done. A copy that fails (a read error on the library's drive, a file that
changed while it was copied) is logged, and the wallpaper fails with that reason as a read that did
not finish: it is copied again on the next offer of the clip (from any apply or reconcile, which
carries a newer startup revision), never on its own. A full copy is made only while the full copies
stay within 2 GB together and the startup disk keeps 5 GB free, both checked before any other copy
is removed to make room. A clip larger than 2 GB is refused for good, with a message that it is too
large for a full copy; one that does not fit now (the copies of clips playing on other displays fill
the 2 GB, or the startup disk is nearly full) fails with a message that there is no room for it now,
and opens by itself when copies are let go or cleared. It is asked again whenever copies change, and
an answer that has not changed is not logged or counted again. Both messages suggest moving the
library to this Mac. The copy is kept only after AVFoundation says it plays (one that does not is
refused with the usual message, and is not copied again for the same file). It is named after the
file's path, size, modification date and identity, so a replaced file gets a new copy and the old
one goes when the new one is made.

A copy is held for as long as something reads it: a desktop window (a rebuild or a poster opens
the file again), the wallpaper preview, the library's poster of an imported clip and the
inspector's black-bar check. Only deleting its wallpaper removes a copy that is held, which stays
even while its file cannot be read (a library drive that was ejected). Any other copy may go:
**Clear unused caches…** in Settings → Storage removes every copy nothing holds, a
full copy makes room for itself by removing the least recently used full copies nothing holds,
and beyond eight copies the least recently used go first. A clip that played from a copy is never
played from its file: when its copy has gone (cleared, made room for, removed with its wallpaper
that was then put back from the Trash, or its file changed), the next time it opens it is judged
again and the copy made again. The desktop, the preview, the poster and the black-bar check read
the copy (the poster and the check only when AVFoundation refuses the file as it is, as the
format check decides); the lock screen and the screen saver play the same
retag, written on the project's copy in their exchange folder
([lock screen](lock-screen.md#plain-video-wallpapers)). A diagnostic recording counts each desktop
surface opened from such a copy as `nativeVideoHev1Retagged`, and the log says when a copy was
made and whether it is a clone or a full copy.

**WebM and Matroska.** AVFoundation does not open them, so the desktop plays them with
`WebMPlayer` (`Shared/WebMPlayer.swift`) in a window of its own (`WebMVideoWallpaperWindow`,
`MWEWebMVideoDesktopWindow`). The project's own Matroska reader (see
[container readers](../container-readers.md)) hands compressed samples to an
`AVSampleBufferDisplayLayer`, and the system decodes and shows them (VP9 through
VideoToolbox's supplemental decoder), so the process does no per-frame work beyond feeding
the next sample when the renderer asks for it. The picture and the sound run on one
`AVSampleBufferRenderSynchronizer`. A loop is gapless by timestamps: at the end of the
file the reader goes back to the first key frame and its times rise by one duration, so
the clock runs on with no flush; the sound wraps the same way and is cut where the picture
wraps. A single-frame file is shown and held. Opus, Vorbis, AAC and MP3 are played (Opus
above stereo and more than two channels in the others are left out, with a log line); the
sound follows the wallpaper's volume and mute, and is not decoded while it cannot be heard
(above). The player handles scaling, scale factor,
position and the file's own orientation with the same layout rule as the AVFoundation
player, pauses by stopping the clock (the renderers fill and stop asking for samples), and
keeps a poster for the desktop-picture sync from one decoded key frame. Its health check
(after a wake, a session change or a pause of five seconds or more) compares the clock with
the renderer's frame count and, when pictures stopped, flushes and feeds again from where the
clock is, at most as often as the recovery allowance permits, before reporting the clip
unplayable. The renderer asking to be flushed (the system took the decoder back) restarts the
feed the same way, and so does the system flushing the sound when the output device changes.

A clip on the native player plays at **its own frame rate**. An `AVPlayerLayer` cannot
be capped without copying every frame through the CPU, so the frame-rate limit
(**Frame rate limit**, a quality preset, **Reduced quality** on battery or in Low
Power Mode, a hot Mac or a throttle) and a display's own frame rate apply to scenes,
and web wallpapers, not to a plain video. The player never refuses a clip because it is faster
than a target, and changing a target does not reopen a running clip: its identity is its
file. The inspector hides **Frame rate** on a display a plain video plays on, because the
field would do nothing there.

The loop is bounded by the picture: `AVPlayerLooper` is given the video track's own time
range (`NativeVideoPlayer.loopRange`, also used by the preview window), so each pass ends
with the last frame. Left unbounded, a pass ends where the item ends, which for a clip
with sound is only once its audio has drained: even muted, and with both tracks the same
length, a 4K clip held its last frame for about a quarter of a second at every seam.

The end of a pass is reported only to a playlist that
[waits for the video to finish](playlists.md#waiting-for-a-video-to-finish), and only while
its change waits: `NativeVideoWallpaperHost.watchClipEnd` asks the display's own surface
(`watchNextLoop`), never a mirror's copy. The AVFoundation player observes the looper's
`loopCount`, which rises each time it starts the item again, and observes the looper of a
rebuilt item afresh; the WebM player puts one boundary observer on its synchronizer at the end
of the pass the clock is in, which a held clock never reaches. Each is told once and removed.
A clip that fails, or leaves the display for another wallpaper or desktop, ends the wait as
well, so a broken clip cannot hold a playlist. Nothing is sampled, and without a waiting
change nothing is observed.

Playback honours the wallpaper's scaling mode and scale factor by the renderer's own
layout rule, so a clip sits where the scene engine used to put it: **Fill**,
**Fit** and **Stretch** scale it to the display, **Fit with blurred backdrop** places
it as Fit but keeps Fit's black bars, because the native player has no blurred fill
(the inspector says so; a mirror of a natively played display gets the same bars and
no note), **Original size** shows one video
pixel per point (a 1920x1080 clip covers 1920x1080 points of a Retina display, not
1920x1080 device pixels), and the scale factor multiplies whichever applies, with
the picture centred and anything outside the display cropped. A factor that is not a
positive number counts as 1. Changing the mode or factor moves the running picture;
it does not reopen the clip or read the file again. The desktop picture shown in
other Spaces and Mission Control is drawn with the same layout. The wallpaper's
position on the display is honoured too: the layer is placed by the same layout with the
saved Position of the wallpaper on that display, and the desktop picture shown in other Spaces
is drawn with it ([display position](wallpaper-properties.md#display-position)). The lock
screen and screen saver apply the position the same way: a plain video there is played by an AVFoundation
layer (or the WebM player) in the lock-screen extension, placed by the same layout with the
position the app publishes ([lock screen](lock-screen.md#plain-video-wallpapers)).
A mirror is centred. One known difference:
the players apply a clip's pixel aspect ratio to the picture's size (the scene
engine ignored it), so an anamorphic clip is laid out by its displayed size. Layer placement is in `NativeVideoLayout`; its expected rectangles come from
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
runs out of time reports the display as failed like any other refusal, and
the wallpaper's state in the panel says the metadata read did not finish and what kind of
storage it was waiting on. It is not retried within the pass and is not remembered as a
verdict on the file: the failure stands for the offer it was made under, and the next offer of
the clip (from any apply or reconcile, which carries a newer startup revision) reads the file
afresh; but while the first read is still blocked, that file is not read a second time, so one
stuck file never holds more than one blocked call. A diagnostic recording counts these as
`nativeVideoProbeTimeout`; a count on the internal drive means the read is stuck, while on a
share or a cloud file it may only be slow. The same bound applies to a read that fails and is retried: each of the
three attempts gets the whole limit.

A clip that never shows a picture is reported as failed too. A player can reach ready with
its clock running and still produce no frame (an HEVC clip tagged `hev1`, handed to the player
as it is, does this on macOS 27; the app plays such a clip from its [retagged copy](#hevc-tagged-hev1)),
and nothing reports a failure, so the
display would stay black and the wallpaper's startup never finish. Playback therefore waits
for the first picture: 10 seconds on the internal drive, 30 seconds on an external drive or
when the volume cannot be identified, and 90 seconds on a network volume or a cloud-backed
file, the same storage classes as the metadata read. If none arrives, the player is rebuilt
once and given the same time again. If that fails as well, or the player has no rebuild left
(two per ten minutes for a display's clip, given back after a minute of uninterrupted
frames), the display is reported as failed and the wallpaper's state says that no first frame
arrived, after one restart or not, with the state of the pipeline (item status, the picture
size it reports, whether the clock runs, whether the layer has a frame). The wait does not
run while the display is hidden or asleep: it starts again with a full deadline when the
display returns. The user's own pause does not stop it, since a paused clip still shows its
first frame. The failure is not remembered as a verdict on the file: the next offer of the
wallpaper, from any apply or reconcile, opens it afresh. A diagnostic recording counts every
deadline that passed without a frame as `nativeVideoFirstFrameTimeout`: a single count with no
failure means the rebuild brought the picture, and on the internal drive any count means the
pipeline stalled.

A clip that has shown a picture is checked, and repaired if need be, after anything that
can cost it its decoder. The system may reclaim the decoder while nothing is playing (a
covered desktop for hours, display sleep, Low Power Mode, a locked session), and a clip
that carries on afterwards can report that it is playing, with its clock running, while no
picture comes out. A check starts when a clip is resumed after at least 5 minutes paused
(by the user's Pause or because its display was hidden), and when the displays wake, the
Mac wakes or the session becomes active again (an unlock, or a switch back to this user).
A wake waits one second first, so the system can hand the decoder back, and the
notifications that arrive in a burst make one check, taken after the last of them. Only
clips that are playing are asked: a clip the user paused stays paused, and a hidden
display is not looked at. With no plain video open, a wake starts no wait at all.

A check waits half a second and then, for up to 2 seconds, looks every tenth of a second
at the playing item. It needs both signs of life in that time: a new picture handed over by
a video output attached to the item for the check, and a clock that moved by about a frame.
The clock alone is not enough, because a pipeline that decodes nothing keeps its clock
running. A healthy clip is proven within a couple of samples. Attaching the output makes
the item reconfigure its pipeline, which holds the picture for 80 to 160 ms (measured on a
1080p and a 4K clip; taking it off does the same), so a check is not free: with a 5-second
threshold every short cover (a full-screen app, Mission Control) ended in a visible flash
(issue 110), hence the
5 minutes, which still covers a desktop left covered for long. The output stays on the item
it sampled until the loop retires that item, and comes off then, out of sight, rather than
holding the picture a second time. When no picture comes out, the check works up a ladder
of repairs, looking again after each:

1. The clip is kicked: a seek to where it already is, with no tolerance, and `play()`. It
   restarts an output that is stuck, costs nothing visible when it works, and never starts
   a clip the user paused. The look after it settles for half a second and lasts 2 seconds.
2. If pictures are still missing, the clip's item and looper are rebuilt from the file. The
   layer stays blank until the new item shows its first picture, which is why this comes
   second. It spends the surface's recovery allowance, the same one the first-frame wait
   uses (two rebuilds per ten minutes, given back after a minute of uninterrupted
   pictures), and its look lasts 5 seconds, since the new item has to load first.
3. If pictures are still missing, or no allowance is left for a rebuild, the display is
   reported as failed like any other player failure, and the wallpaper's state says that playback
   stalled after the trigger (`the displays woke`), what was seen, what was tried and how much of
   the allowance was spent. Nothing takes the clip over. The host does not remember the failure
   as a verdict on the file, unlike a decoder failure: a decoder the system took back during a
   long sleep says nothing about the clip, so the next offer of the same wallpaper opens it again.

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
real Mac. The check's output reads the clip's own pixel format and is read only while the
check samples; left on until its item is retired, it is never more than one pass of the
loop on one copy.

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
start), AVFoundation fails the whole clip and reports only `AVErrorUnknown`; muting the
player does not prevent it, and neither does pausing it, because the output is started when
an item with an audio track switched on is prepared. A clip that cannot be heard has its
audio track switched off before that (above), so it starts no output and this cannot happen
to it until it is heard again. Native playback then rebuilds the clip from its video track alone
and keeps playing it natively without sound, logging the original failure against
the wallpaper's load. A clip without audio, or one whose picture fails too, is reported as failed. Failure
reasons include each error's domain and code, so a report shows which part of playback failed.

## Experimental switches

Both experimental switches are off by default.

| Setting | Notes |
| --- | --- |
| Direct video plane sampling | Lets a Native Metal scene's own shader read the decoder's two video planes instead of a colour image converted for it each frame |
| Draw only the visible part of cropped scenes | Lets an SDR 2D scene at Display resolution whose canvas the display crops draw only the part the display shows, instead of its whole layout |

Content pacing and Shared video decode, the two other switches this page once
listed, are gone. Both only reached a plain video that the scene engine played,
and the app's own players play every plain video now; a configuration file that
still holds `content_pacing` or `shared_video_decode` loads, and the keys are not
written back.

Memory a running wallpaper holds is kept to what it shows. Displays showing one scene
share the pictures they have in common instead of each holding a copy, a destroyed
layer's script state and a let-go pipeline-archive store are released, and a scene's
video is decoded from its file where it lies instead of being read whole into memory (a
clip packed into the scene's package is read where the package left it, and a large
one moved into an unnamed file); the details are in [renderer
memory](scene-rendering.md#renderer-memory). None of it adds per-frame work, a render
pass or render-target memory, and the pictures are unchanged.

A scene's video texture, a file or a clip packed into a `.tex` payload, is decoded
once for each surface that shows it: every display's scene opens its own decoder on its
own playback clock, and two displays never share one.

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
directly, converted once per frame, both for a scene whose materials differ,
converted while the direct program is still being prepared (the wallpaper is playing
normally and a second program is on its way), or 10-bit video converted once per
frame. A material whose shader the
translation cannot reproduce — an explicit level-of-detail sample, a size query, a
texel fetch, two video slots in one material — keeps converting and says nothing; so
does any frame that is not 8-bit NV12, which is what a software decoder produces for
the same file. A 10-bit video is always converted, with HDR tone mapped to SDR in the
same pass ([10-bit and HDR video](scene-rendering.md#10-bit-and-hdr-video-textures)),
whatever this switch says, and costs no more per frame than an 8-bit conversion
plus the extra arithmetic of the curve; an 8-bit video is untouched by it.

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

### Draw only the visible part of cropped scenes

At [Display resolution](#2d-scene-resolution) a 2D scene whose canvas is not the
display's shape is laid out to cover the display, and **Fill** (or **Original size**,
for a canvas larger than the display) crops what overhangs it. By default that overhang
is still drawn, effects and all, and thrown away when the picture is composed. Wallpaper
Engine's frame is the window's size, so it never draws that part. With this switch on
(`scene_display_framing` under `[experimental]` in `config.toml`), Native Metal draws an
SDR scene only over the part of its layout the display shows, on the same pixel grid,
and composes it where the whole layout would have put it. Off, every scene draws
exactly as it did before the switch existed.

It applies only to an SDR scene at Display resolution with a zoom of 1 or more, under
Fill or Original size, and only when the scene is not upscaled by
[MetalFX](#metalfx-upscaling): MetalFX would upscale the visible part on another grid
than the whole layout's, and its filter reads across that part's edge, so a scene it
upscales keeps drawing its whole layout. Fit, Stretch and Fit with blurred backdrop
show the whole canvas and are untouched; an HDR scene is already drawn over the
display's own rectangle. A scene whose layout cannot be cut on the grid of its
screen-sized buffers (a quarter-size bloom buffer needs cuts at multiples of 4; a
mip-mapped one, or a layout that is not a multiple of that grid, cannot be cut) is
not framed either. A running scene takes the switch at its next frame by sizing its
render targets again in place: nothing is reloaded. A paused wallpaper, or one waiting
for events with **Update only when the scene changes**, takes it when it next draws, and
until then its Mission Control picture is not captured again. The mechanism is under
[scene rendering](scene-rendering.md#2d-scene-resolution).

**What it saves.** Measured on an M5 Pro: Hoshimi Miyabi (3784370784, a 5120×2160
canvas) on a 3840×2160 display at backing scale 2 and render scale 0.75 held 437 MB of
render targets instead of 508.5 MB (−14%), with GPU time about 6 to 16% lower. A 16:9
scene on the 3456×2234 built-in panel held 3 to 5.5% less render-target memory, with GPU
time within noise. A scene the display does not crop saves nothing.

**What it changes.** The picture is not byte-identical to drawing the whole layout,
which is why the switch is opt-in. The GPU does not rasterize the shifted picture to the
same sub-pixel positions: up to 0.6% of interior pixels move by one level, and thin
geometry such as rain streaks can differ more, in a few dozen to about 140 pixels of a
frame. A screen-space effect that reaches across the edge of the screen (bloom, a blur)
now stops at that edge, as in Wallpaper Engine; near the edges the picture comes about
0.4% closer to Wallpaper Engine's own frame. No power measurement has been taken.
`WALLPAPER_MACHINE_SDR_FRAMING=1` or `=0` overrides the setting either way for a
comparison in one build ([power benchmark](../testing/power-benchmark.md#ab-comparison-entry-points)).

## Background work only while it has a consumer

These change no setting, frame rate, render scale or sound; they stop work that
nothing could see or hear.

- **Wallpaper sound output.** The Core Audio output a scene's sound layers or a
  video's own audio track play through starts only while something is mounted, the
  wallpaper is playing and it is not muted. A paused, muted or silent wallpaper, a
  wallpaper that arrives paused, and the lock-screen extension (always muted) start
  no output, so Core Audio runs no output cycle for them and holds no idle-sleep
  assertion on their behalf. Resuming or unmuting costs one device start.
- **Plain video sound.** A plain video that cannot be heard (muted, at volume 0, muted by
  **Mute all wallpapers** or a rule, or a mirror member that does not carry its group's
  sound) decodes no sound and starts no audio output: muting the platform player only
  turned the decoded sound down. See [Video playback](#video-playback). Being heard again
  restarts the output without reopening the clip. A WebM clip that opens silent may decode
  its first audio buffers before the host's mute reaches it. No power measurement has been
  taken; `WALLPAPER_MACHINE_MUTED_VIDEO_AUDIO=1` restores the old behaviour for a comparison
  ([power benchmark](../testing/power-benchmark.md#ab-comparison-entry-points)).
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
- **Tap stall check.** While a tap runs and capture is wanted, the audio worker wakes
  once a second to read the tap's callback count, one atomic load; the tap's own
  callback adds one atomic increment per call. It asks whether the output device is
  running only while calls are missing. Without a running tap, while suspended, or once
  the check has given up, the worker sleeps without a timer
  ([audio response](audio-response.md#output-device-changes)).
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
- **Lighting data.** Lit scene passes share packed light arrays within a draw, after
  simulation has updated the lights. Reflection camera changes repack the arrays whose
  ordering depends on the camera. The next draw reads fresh light state; shader values
  and frame cadence stay the same ([scene rendering](scene-rendering.md)).
- **Media fallback.** When neither Music nor Spotify is running, the AppleScript fallback
  waits for application launch notifications with no polling timer. A running player is
  still queried once a second ([media integration](media-integration.md)).
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
- **Inactivity watch.** Nothing runs while **When the Mac is inactive** keeps running.
  Chosen, it costs one one-shot timer while the Mac is in use, armed again only when it
  fires and finds that input came meanwhile; the pointer monitors and the two-second read of the
  input count exist only while the Mac counts as inactive, and that read waits while
  the displays sleep or another session has the screens. Each turn asks whether the
  displays sleep (`CGGetOnlineDisplayList` and `CGDisplayIsAsleep`); the session's
  console state (`CGSessionCopyCurrentDictionary`) is asked only when a run of reads
  begins, including the one read a sleep, wake, session or unlock notice arms
  ([Playback](#playback)). No power saving is claimed.
- **Renderer counters.** They count only inside a bounded window: a
  [diagnostic window](../testing/power-benchmark.md#runtime-counters) asked for
  through the environment, or, when **Send performance data** is on, one 60 s
  [frame window](telemetry.md#frame-windows) every four hours. Outside one, each
  counted event costs one relaxed atomic load.

The regression coverage for these is in
[renderer verification](../testing/renderer.md#regression-areas-that-must-stay-covered).
Those tests prove the work stopped; they are not power measurements, which still
need the matched conditions in [power benchmarking](../testing/power-benchmark.md).
