# Web wallpapers

Wallpaper Engine projects with `"type": "web"` are HTML pages (`"file"` names the
entry page, usually `index.html`) that talk to their host through
`window.wallpaperPropertyListener`. WallpaperMachine renders them in a
`WKWebView` hosted by the app; the vendored scene renderer never opens a window
for them.

## What the user sees

- [Live preview](wallpaper-properties.md#live-preview) runs an installed project in its
  own window and temporary website data store, with independent playback and
  default mute. It never replaces the desktop page or its stored state.
- Web wallpapers import, download and apply like scene and video wallpapers, and
  their user properties (combos, sliders, colors, text, booleans) are edited in the
  same inspector. Apply pushes the committed values into the running page.
- Switching to a web wallpaper does not show a black or empty page while it loads: the
  picture of the wallpaper it replaces stays over the new page's window until the page has
  loaded and had half a second to paint, then fades out (no fade under Reduce Motion). See
  [wallpaper switching](wallpaper-switching.md).
- Play/Pause, the presentation policy (occluded desktop, display sleep, session
  lock), display assignment, mirroring, and Space posters
  ([desktop picture](desktop-picture.md)) apply to web wallpapers
  the same way they apply to renderer wallpapers. Occlusion is per display: a
  window covering the wallpaper on one screen suspends that page and leaves the
  page on another screen running.
- The Workshop badge reads *Web · built-in web view*; the inspector notes that
  mouse input and audio response reach the page while keyboard input does not.
- Mouse input reaches the page: hover, clicks, drags, right clicks and scrolling
  over the desktop are mirrored into the wallpaper. Finder keeps its icons and
  the desktop keeps every system behavior, so a click on an icon also reaches
  the page. Settings → Desktop & Lock Screen → *Keep windows in place when clicking the
  wallpaper* turns off macOS's "Click wallpaper to reveal desktop" option (the
  same value System Settings → Desktop & Dock writes) so a click no longer
  slides every window aside.
  Pointer moves reach the page no more often than it draws (60 a second near
  WebKit's default cadence, the display's refresh for a page that draws at it), or as
  often as the [frame-rate limit](#frame-rate-limit) when that is lower (never below
  10), always ending on the position where the pointer stopped; presses, drags, releases,
  scrolls and exits are never delayed or dropped.
- A page can be debugged in Safari. **Settings → Storage → Troubleshooting → Allow
  inspecting web wallpapers** lets Safari's **Develop** menu list the wallpaper
  pages running on this Mac (turn on *Show features for web developers* in Safari's
  settings first) and open the Web Inspector on one. It is off in a release build
  until the user turns it on, takes effect on running pages without a reload and is
  not part of a backup. See [inspecting a web wallpaper](diagnostics.md#inspecting-a-web-wallpaper).
- On macOS 26+, **Use wallpaper as screen saver** can present web and still-image
  projects through the native extension. It uses committed properties and isolated
  file copies, without audio, capture or interaction. See
  [Screen saver](lock-screen.md#use-wallpaper-as-screen-saver) for activation,
  independent selection and verification limits. **Animate lock screen** does not
  support web projects; that combination is reported as not applicable, never as a
  failure.

## Host protocol

The page is loaded from `file://` with read access to its project folder, matching
Wallpaper Engine's CEF host: ES modules, `fetch()` and media inside the project
folder work, and `location.protocol` is `file:`. The top frame cannot navigate away
from the entry page; subframes and network requests are unrestricted (macOS ATS
applies, so plain `http://` requests fail).

Four scripts are installed at document start, built in one place
(`Shared/WebWallpaperUserScripts.swift`) for the desktop page, the preview and the
screen-saver web surface alike; desktop and preview pages get a copy built for each
document. The host script (`Shared/WebWallpaperProtocol.swift`) is the author API and
everything in the table below, and runs in the main frame only. The other three close
gaps between WebKit and Chromium: one in file requests, one in idle callbacks
([below](#idle-callbacks)) and one in fonts ([below](#windows-fonts)). The first one is
described here. WebKit
answers a `fetch()` or `XMLHttpRequest` of a project file with status 0 and no
headers, where Chromium answers 200 with a `Content-Type` taken from the extension. The script gives a found `file://` GET/HEAD response that status and
type, so loaders that check `ok`, and WebGL exports (Unity, Emscripten) that call
`WebAssembly.instantiateStreaming`, start. Served `.wasm` responses are compiled from
their bytes rather than by WebKit's streaming compiler, which was slower to boot a
large module. Missing, failed and aborted requests, non-file responses and all
bodies stay native: nothing is copied, retried or run per frame.

That file-request script runs in every frame, so a page that hosts its player in an
iframe of a project file, or in a `srcdoc` or script-created frame, gets the same
answers as the page itself; it installs once per document and marks it with a
non-enumerable `window.__mweFileCompat`. A subframe gets nothing else but
[idle callbacks](#idle-callbacks) and the [font aliases](#windows-fonts): no
`wallpaperPropertyListener` delivery, no audio, media or random-file registration,
and the host drops any message on the host channel that does not come from the main
frame, so a frame (a remote embed included) cannot subscribe to audio or ask for
files on the wallpaper's behalf. A frame served over http(s) keeps its own `fetch` and `XMLHttpRequest`.
Web workers are out of reach of a user script, so a worker's own `fetch` of a project
file still sees WebKit's status 0.

### Idle callbacks

Chromium has `requestIdleCallback` and `cancelIdleCallback`; WebKit on macOS has neither, so a
page written for Wallpaper Engine that calls `window.requestIdleCallback` without checking
threw a `TypeError` there. A visualizer that asks for an idle callback in its start-up, just
before its first `requestAnimationFrame`, stopped at that line and drew nothing while its
audio listener still received the spectrum. The idle-callback script
(`Shared/WebWallpaperIdleCallbacks.swift`) runs in every frame, whatever its protocol, and
defines both functions where the browser lacks them; a WebKit that has its own keeps it.

It follows the specification's idle periods with the longest one Chromium gives, 50 ms. A
callback runs in the next period, which starts on a timer once the previous one has ended;
callbacks requested from inside a period wait for the next one, so a callback that asks
again from its own body runs at most 20 times a second, not at the timer clamp.
`timeRemaining()` counts down to the end of the period, and callbacks still waiting when it
reaches zero move to the next one. A `timeout` runs a callback that is still waiting with
`didTimeout` true and no time remaining. A callback that throws is reported, and the rest of
the period's callbacks still run. Nothing runs while nothing is waiting.

### Windows fonts

Wallpaper Engine runs a web wallpaper in Chromium on Windows, which finds the fonts a stock
Windows has; WebKit on a Mac finds none of them, so a family it lacks falls to the page's
next family or the standard font, and CoreText's cascade takes Chinese from Songti, a serif
capped at bold. A heading set in `900 26pt SimHei` was a thin Song face where Wallpaper
Engine draws a heavy sans, and a stack that starts with `Segoe UI` set its separators a third
wider. The font script (`Shared/WebWallpaperFontAliases.swift`) runs in every frame of a
page served from a file or the app, before the page's own style, and declares for each
Windows font this Mac does not have an `@font-face` per name of the font that maps it to the
macOS face standing in for it: `SimHei`, `Microsoft YaHei` and `DengXian` (and their Chinese
names) to PingFang SC, `Microsoft JhengHei` to PingFang TC, `SimSun` to Songti SC, `KaiTi` to
Kaiti SC, `Yu Gothic`, `Meiryo` and `MS Gothic` to Hiragino Sans, `MS Mincho` to Hiragino Mincho
ProN and `Malgun Gothic` to Apple SD Gothic Neo, regular for weights below 550 and the heavy
face from there (`SimHei` and `KaiTi` answer the Han range only, since stock Windows has
neither and their Latin goes to the page's next family); `Segoe UI`, `Calibri`, `Cambria` and
`Consolas` to PT Sans, PT Sans, Charter and Andale Mono, scaled by `size-adjust` (98.7, 93,
99.6 and 91.6 percent) to the real fonts' digit advance, the same stand-ins and numbers
as the scene renderer's text. A font is left alone when it is installed, which is told for
the four Latin fonts by the width of their digits (macOS answers `Calibri` with a
Helvetica-width substitute of its own, and Office for Mac installs the real fonts) and for
the others by text set in the name measuring other than the fallback; a font the page
declares for the same name later in its own style takes precedence, since the script's
style is first in the document, and a page served over http(s) is left as it is. The script
installs once per document and marks it with a non-enumerable `window.__mweFontAliases`.

| Call into the page | When |
|---|---|
| `wallpaperPropertyListener.applyUserProperties({ id: { value } })` | Once after load with every property, then after an Apply with only the properties whose values changed; colors are `"r g b"` floats in 0–1 as in `project.json` |
| `wallpaperPropertyListener.applyGeneralProperties({ fps })` | Once after load, then when the display's target FPS changes; below the rate the page draws at (60 by default) the host also [enforces the limit](#frame-rate-limit) |
| `wallpaperPropertyListener.setPaused(bool)` | Play/Pause, battery Pause, presentation suspension; the page's cooperative half, the host suspends it as well ([Suspension](#runtime-shape)) |
| `wallpaperPropertyListener.userDirectoryFilesAddedOrChanged(property, files)` / `userDirectoryFilesRemoved(property, files)` | A watched `fetchall` folder gained or lost files |

Combo values reach the page with the selected option's authored JSON type: a
numeric option stays a number, a boolean a boolean, and `"3"` a string. The
inspector and saved overrides still use string selection keys; conversion happens
only when the Web payload is exported, so strict comparisons and `switch`
statements in the page keep working. Property `order`/`index` values are ordering
hints, not identity: fractional values are preserved and properties that share one
all stay, in declaration order.

Values are replayed in full to a listener that registers after the first push, so
pages that install the listener from a deferred module still start.

`applyUserProperties` and `applyGeneralProperties` follow Wallpaper Engine's
contract: the first delivery a listener takes in carries every property, and every
later one only the properties whose values differ, in any key order; nothing is
called when nothing differs. The host resends the whole committed set on each
apply (the screen saver on every reconcile, pause toggles included) and the shared
host script works out the difference per listener, so a page that tests each key
sees the same calls on the desktop, in the preview and on the lock screen. A
listener assigned late or again, a reloaded document and a content-process restart
start from the whole set; a handler that is missing or throws has not taken a
delivery in, so the next call is measured against what it last accepted. A `file`
property the host stages again counts as changed once even though its value reads the
same: the staged path is built from the property and the file's name, so a file
reselected after it was edited, or another folder's file of the same name, arrives
under the path the page already has, and the desktop host passes the restaged property ids
along with the payload (`restagedFiles` of `WebWallpaperHost.stageAssets`). A paused
page draws that change like any edit, and a handler that threw on it is sent it
again. A page
that rebuilt itself from the payload on every edit has to keep its earlier values,
as it must under Wallpaper Engine. `setPaused` is not deduplicated.

### Frame-rate limit

WebKit gives a page no frame-rate control, and a page is free to ignore the `fps`
it is told, so a limit below the rate the page draws at (60 unless noted below) is
enforced on the page's own `requestAnimationFrame`
(`Shared/WebWallpaperFramePacer.swift`, evaluated inside the host script). Callbacks
are held to the limit and run on the first display frame at or after their slot,
with that frame's own timestamp, so the page's time arithmetic is unchanged and
only the number of callbacks falls. Slots advance by one interval from the previous
slot, so a limit that does not divide the display cadence still averages its rate
(40 on a 60 Hz cadence runs two callbacks in three frames), and a stall longer than
one interval resumes at the limit instead of catching up in a burst. A callback
that throws is reported as an error of the page and does not stop the others, one
that requests again runs on a later frame, and cancelling inside a frame skips a
callback that has not run yet. With no limit, or one that reaches the rate the
page draws at, the page keeps WebKit's own function: native handles, native
timestamps, native errors. That rate is near 60 by default, because WebKit prefers
about 60 rendering updates per second even on a faster display; the display's own
refresh on one that refreshes slower than 60 Hz; and the full refresh for a page
`WebWallpaperHost` created to draw at it ([frame rate](#runtime-shape)), where the
descriptor's `fps` has reached the refresh, so nothing is held. The pacer itself
never works above 60. The host tells each page its display's refresh on every apply
(`WebWallpaperPage.applyDisplayRefreshRate`, from the same reading that decides the
full refresh), so a display moving to another refresh retunes the limit of a
running page without a reload.

The limit is the descriptor's `fps`, which already includes the Reduced-quality
frame rate (from the battery, Low Power Mode, heat or a low battery) and the Performance cap ([frame-rate limit](performance.md#quality)).
It is part of each document's script, so even the first `requestAnimationFrame`
call of a page, a reload and a content-process restart are paced; a change on a
running page (a Performance or power-source change) is sent together with
`applyGeneralProperties` and applies from the next frame without reloading, and
callbacks already waiting are kept. It is logged at debug level
(`frame limit <n|none>`). The native screen-saver surface does not get the wrapper.

### Render scale

WebKit has no render target the host can shrink, so the **Internal render scale**
setting ([performance](performance.md#quality)) reaches a page as a multiplier of
`window.devicePixelRatio`. The shared host script
(`Shared/WebWallpaperProtocol.swift`) installs an accessor for the property only
while the scale is below 1 and puts WebKit's own descriptor back when it returns to
1, so a full-scale page runs on the native property. The scale is
`BridgeWebWallpaper.renderScale`: the saved scale; the battery profile's while
Reduced quality is selected and the Mac is on battery; or the lower of the saved scale
and the profile's while a reduced-quality request from Low Power Mode, heat or a low
battery holds (and the stricter of the two when both do). It is held to 50-100% for a page.
Like the frame-rate limit it is part of each document's script, so the very first
read of a page, a reload and a content-process restart already see it. A change on
a running page (a Performance or power-source change) is delivered without a reload
and raises one `resize` event on the window, however many changes share a turn, so
pages that rebuild their canvas or WebGL buffers on `resize` pick it up; the
value a document starts with raises none. Changes are logged at debug level
(`render scale <n>`). A page that assigns `devicePixelRatio` itself keeps its own
value. The preview and the native screen-saver surface are never scaled.

The page may call `wallpaperRegisterAudioListener`, the five
`wallpaperRegisterMedia*Listener` functions (status, properties, thumbnail,
playback, timeline) and `wallpaperRequestRandomFileForProperty`.
`window.wallpaperMediaIntegration` exposes the playback constants under both
documented spellings, `PLAYBACK_PLAYING` / `PLAYBACK_PAUSED` / `PLAYBACK_STOPPED`
and `playback.PLAYING` / `.PAUSED` / `.STOPPED`, with values 0, 1 and 2.
Registering a listener replaces the previous one, and each listener fires only when
its own part of the state changed. A page that registers after load is given the
current state. Audio, media and directory delivery all stop while a page is
suspended (covered, or paused once it has drawn) and resume when it comes back:
media state is re-derived on resume, and directory additions and removals are held
across the suspension and replayed in order.

The wallpaper web view has exactly one `WKScriptMessageHandler`, named
`mweWallpaper`, carrying listener registration and random-file requests; it is
removed when the page stops.

## Runtime shape

- Rust (`upstream/renderer/crates/bridge`): `WallpaperProjectType::Web` entries are
  `supported`. `ActivationInputs::build()` routes web projects away from the scene
  engine and `build_web()` yields one `WebWallpaperDesc` per assigned display
  (mirrors included). The uniffi call `web_wallpapers()` exposes them as
  `BridgeWebWallpaper` (display id, project path, entry file, fps, effective render
  scale, paused, volume, mute, audio and media consent, and the effective property
  values as the `applyUserProperties` payload). A running web wallpaper makes the
  render-scale control applicable. The same web descriptors are exported to the
  native screen saver as lock-screen scenes with a web entry file.
- Swift (`App/Services/WebWallpaper/`): `WebWallpaperHost` re-reads
  `webWallpapers()` on every snapshot and diffs it against one `WebWallpaperWindow`
  (`MWEWebWallpaperDesktopWindow`, desktop level, all Spaces, mouse-transparent) per
  display. `WebWallpaperPage` owns the `WKWebView`, the user scripts (installed again
  with the committed frame-rate limit and render scale on every `load()`),
  property/pause delivery,
  host-side suspension and content-process recovery.
- **Suspension** does not rely on the page cooperating. `setPaused` is an optional
  listener callback, so a page can ignore it; alongside it the host suspends all
  media playback (suspend and unsuspend, so media the user had paused is not
  started by a resume) and removes the web view from the window tree, which is the
  documented condition for `WKPreferences.inactiveSchedulingPolicy` (`.suspend`).
  A snapshot taken before detaching stays on screen as a placeholder inside the
  window's container view, so the Space poster sync keeps identifying the surface
  by the same content layer, and a suspended page receives no pointer events. The
  document is never reloaded to suspend it, so its JavaScript state survives.
  Two reasons suspend a page and they compose, so clearing one leaves the other in
  force. The presentation policy suspends at once when no pixel can reach the display
  (asleep, locked, a full-screen app, a covered working area). A display that the
  user can see but that is paused only because they chose to play on the display
  they are using ([performance](performance.md#playback)) is not hidden: the
  policy tells the host (`WallpaperPresentationPolicy.isSuspendedInPlainSight`,
  `WebWallpaperHost.setPresentationSuspended(_:forDisplay:stillVisible:)`), and its
  page waits for the first frame like a paused one, including a page created on a
  display that is already paused, so a wallpaper set there is not left black.
  A paused wallpaper suspends once its first frame has had time to draw:
  `BridgeWebWallpaper.paused` is the bridge's composed flag (Play/Pause, battery
  Pause, and the bridge's own presentation and per-display suspension), and
  `WebWallpaperPage.Timing.firstFrameGrace` (3 s, the first settle capture of the
  poster sync) starts when the document has finished loading and its view is in the
  window; time spent covered does not count, and it starts over each time the view
  is put back. The grace exists because
  `didFinish` fires before the first meaningful paint, the bridge defers a battery
  pause until the host reports startup, and a wallpaper can be applied while
  paused; detaching at once would snapshot a blank view and WebKit may not finish
  loading a detached one. A reload or a crash restart puts a paused page back in
  the window tree for its load and suspends it again after its next first frame. The
  grace expiring has no host call behind it, so the page reports it
  (`onHostSuspensionChanged`) and the host drops the global pointer monitor and
  re-elects audio owners; each transition is logged at debug level
  (`host suspension on|off`) so resume latency can be read from the log. Because
  `paused` includes the presentation, a presentation resume also waits for the
  descriptors to be read again, and a presentation change returns no snapshot to
  carry them: `AppDelegate` reconciles the web and native video hosts once the bridge has
  committed the change (or failed to), and the pause that came from the covered
  desktop ends with it. The battery Pause starts and ends with the power source,
  which the renderer applies without a snapshot as well: `PowerSourceMonitor`
  notices the change and the app reads a snapshot again
  ([performance](performance.md#playback)), so the page is detached when the Mac is
  unplugged and runs again when it is plugged in. Values applied while a page is suspended reach it when it
  resumes, not before, with one exception: a changed property payload (the
  inspector's Apply, an image's fit or placement) reaching a page that only its
  pause holds still puts the page back in the window for another first-frame
  grace, so the edit draws, and detaches it again with the frame it drew; the
  host then reads the Space posters again (`onSuspensionPosterRefreshed`). A page
  that is also covered waits for the cover to end. The frame limit and the render
  scale do not wake a paused page: they change how it draws, not what it shows,
  and apply when it plays.
  The frame taken at detach is kept (`suspensionPoster`) and answers the desktop
  poster sync's requests, because WebKit does not promise a snapshot of a detached
  view ([desktop picture](desktop-picture.md#when-a-poster-is-taken)). With its view
  detached, a page that implements no pause listener runs no animation frames, no
  timer callbacks and no CSS animation iterations
  (`WebWallpaperSuspensionTests.testUserPauseStopsFramesTimersAndCSSOfAPageWithoutAListener`
  counts them by wall-clock time inside the detached interval). The energy effect
  on a real desktop is the power benchmark's T4 and has not been measured.
- **Occlusion** is left to `WallpaperPresentationPolicy`. A guarded per-view WebKit
  selector (`_setWindowOcclusionDetectionEnabled:`) disables WebKit's independent
  window-occlusion check; otherwise even a brief Space or Show Desktop transition
  can stop animation frames before the host's settling delay expires. If the
  selector is unavailable, the page keeps WebKit's default scheduling and the
  limitation is logged. This does not change the native screen-saver web
  surface.
- **Frame rate.** The page is told the display's effective frame rate through
  `applyGeneralProperties({ fps })`, and many pages pace their own loop by it.
  WebKit draws a page near 60 fps even on a faster display, and it hands the page
  one pointer move per drawn frame, so hover is held to that rate too. When the
  effective rate reaches the refresh of a display above 60 Hz (the user chose, for
  example, 120 on a 120 Hz display), `WebWallpaperHost` creates the page with
  WebKit's `PreferPageRenderingUpdatesNear60FPSEnabled` feature off, and the page
  then draws, and receives the pointer, at the full refresh. WebKit reads that
  feature only when a web view is created, so a rate change that crosses the
  refresh (the slider, the battery frame rate taking over, or Reduced quality for
  Low Power Mode, heat or a low battery beginning or ending) rebuilds the page;
  a change that stays on one side keeps the document. Those three conditions come
  and go on their own. A page drawing at the full refresh of a fast display reloads,
  and loses whatever it kept in memory, each time one of them lowers its rate below
  that refresh and again when it ends, and a Mac that hovers at the serious thermal
  boundary does so at every crossing. Nothing holds the page at the cadence it was
  created with or delays the rebuild, and the cost has not been measured. At the
  default rate nothing changes. If the running WebKit no longer offers the feature,
  the page keeps the default cadence and the limitation is logged once. The rebuilt
  page is a new page like any other: it takes in the render scale, the pause, the
  frame limit and the pointer rate of its cadence from the descriptor before it loads.
- **Recovery.** A content process that keeps terminating is restarted on a windowed
  budget with exponential backoff rather than forever; the budget returns only
  after a document has run without interruption for the stable-run threshold.
  Committed host state (properties, fps, pause) is replayed in full on every new
  document, so a reload after a crash restores the page.
- **Host state in the inspector.** Each display reports loading, ready or failed. A
  failed live Web page offers **Retry wallpaper**; project validation and file-scan
  failures show their error without a retry that cannot reload a page, so fix the
  project and refresh or reapply it. Late callbacks from a replaced surface are
  ignored, and the host echoes the bridge's startup revision only after loading
  finishes or fails, so accepting an assignment does not imply ready content.
- **Library refresh** checks active project file identities on a background actor.
  Replacing HTML or resources at the same path reloads the page even when an
  intermediate empty assignment was coalesced away; an unchanged revision keeps the
  existing document.
- **Mouse input** (`WebWallpaperMouseForwarder`): the windows stay mouse-transparent
  and nothing is consumed, so no Accessibility or Input Monitoring grant is needed.
  The global `NSEvent` monitor exists only while at least one page is loaded and not
  host-suspended (`WebWallpaperHost.refreshPointerMonitor`).
  `WebWallpaperMouseRouting` forwards events only while the window the system would
  hit is below layer 0 (Finder's desktop, the system wallpaper, widgets), keeps a
  forwarded press's drags and release, and sends one exit when the pointer leaves
  the desktop. The hit window is the one the window server recorded in the event
  (`mouseEventWindowUnderMousePointer`), so routing makes no window-server call per
  move: a synchronous per-move query stalled the main thread during Show Desktop
  and froze the page. Only a press or scroll without the field still asks; a move
  without it is dropped. Events are rebuilt in wallpaper-window coordinates and
  replayed through the responder methods. Hover has no public entry point on
  `WKWebView`, so it uses `_simulateMouseMove:`/`_simulateMouseExit:` when the
  running WebKit responds to them, and `WebWallpaperWindow` reports `isKeyWindow` as
  true because WebKit hit-tests hover only for active windows (it still cannot
  become key, so keyboard focus is never taken). The host script cancels
  `contextmenu` defaults so WebKit's own menu never opens, and every frame of every
  web surface cancels `dragstart` (`WebWallpaperProtocol.noDragScript`): the events
  belong to Finder, so a drag WebKit started from an image, link or selection would
  drop a copy onto the desktop and break Finder's selection rectangle. The page's
  own handlers still see the event, and mouse-driven dragging inside a page is
  unaffected.
  Moves are paced per window by `WebWallpaperMoveThrottle`, because a 1000 Hz mouse
  otherwise costs the main thread a rebuilt event and a WebKit hit test per report.
  The first move after a quiet stretch is delivered at once, moves inside the interval
  are held with only the newest kept, and one timer per window delivers it when the
  interval ends (`WebWallpaperMoveCoalescer`). The interval comes from the page
  (`WebWallpaperPage.pointerMoveInterval`): one over the rate the page draws at (60;
  the display's refresh for a page created to draw at it, or when that is below 60), or
  1/limit s when a frame-rate limit applies, with a floor of 10 a second. WebKit hands a
  page one pointer move per drawn frame, so a faster interval could not reach the page. A press, drag, release, scroll or exit first delivers the held move
  so a gesture never sees a stale pointer and an exit always follows the last move;
  removing the monitor drops anything held. `RuntimeCounters.pointerDelivered` counts
  deliveries, so it shows the reduction.
- `DesktopClickRevealPreference` (`App/Services/Desktop/`) reads and writes
  `com.apple.WindowManager EnableStandardClickToShowDesktop` for the Settings toggle.
- `WallpaperPresentationPolicy` counts both window classes when deciding whether a
  wallpaper pixel is visible; `DesktopWallpaperSync` asks a web surface for a
  `WKWebView` snapshot through the same poster request it sends to Metal layers.

## Audio response

Per wallpaper, off unless the user turns it on in the inspector's *General
configuration* (consent and capture are described in
[audio-response.md](audio-response.md)). The switch is consent to capture, not a
promise of delivery: the page receives nothing until it calls
`wallpaperRegisterAudioListener`, and a wallpaper that never asks stays silent
however the switch is left.

The panel reports this wallpaper's state from the running host: requesting a
connection, confirmed subscription, or successful delivery of a valid frame to its
JavaScript listener. A frame older than two seconds no longer counts as current
delivery. A failed subscription tells the user to toggle and retry; another
wallpaper's subscription never changes this one's status. With no running surface,
delivery stays unknown, and a page that has not registered a listener is reported
separately.

The listener receives a 128-float array: indices 0–63 the left channel, 64–127 the
right, low index first within a channel. Delivery is capped at 30 Hz, skips
generations the analyser did not recompute (the exception is silence, below), and
happens only while the page has a registered listener, the user has audio response
enabled for that wallpaper, and the page is not suspended. One shared poller (`WebWallpaperAudioPump`) serves every
display and does not exist while nothing is subscribed; the system capture tap is
opened and closed from that same demand, and a page counts as a consumer only once
it has subscribed. Mute and volume do not affect it: a silenced wallpaper still
analyses what the system is playing. Values are clamped to 0.0–1.0 by the renderer's
spectrum entry point (`owe_audio_current_spectrum_128`); the official protocol says
values may occasionally exceed 1.0 and tells pages to clamp themselves, so this is a
documented deviation. How the spectrum is computed is in
[audio-response.md](audio-response.md#what-wallpapers-receive).

**Silence.** When the sound stops, the analyser publishes one all-zero spectrum and
then no more, so a visualizer that smooths in its callback would freeze part-way
through its decay. The pump therefore repeats an all-zero spectrum
(`WebWallpaperSilenceCadence`): on every poll for 1.5 s after the last new spectrum
(at most 45 extra calls, enough for a decay to finish), then once a second until sound
returns, the pages leave, or the wallpaper is paused or suspended. The one-second beat
also gives a page that starts listening during silence its first frame within a
second. Only exactly-zero spectra repeat, because the renderer maps everything at or
below -48 dB to 0; a spectrum with signal is delivered once, never replayed. While the
repeats flow, **Audio and media status** keeps saying the page is receiving frames:
they are valid frames, and the status counts a frame as current for two seconds. If the
capture tap keeps delivering silent audio, the analyser produces a new all-zero
spectrum on every cycle and nothing changes. Whether Wallpaper Engine keeps calling a
listener through silence is not documented (its page says about 30 callbacks per second
and says nothing about silence), so parity is claimed only for pages that smooth per
callback.

## Media integration

On by default, per wallpaper; saved choices are preserved. Web pages register
`wallpaperRegisterMedia*` listeners as above. The now-playing source is shared through `DesktopMediaSession`
and also feeds Scene wallpapers that have the same toggle on; sources, lifetime and
lock-screen policy are in [media-integration.md](media-integration.md).

The status listener describes the user's setting, independently of provider
availability. With integration enabled but no data, properties are empty, playback
is stopped and there is no timeline. An empty thumbnail string clears the previous
cover. Pages must tolerate absent metadata and timelines.

## User-selected files and folders

`file` and `directory` properties let the user give a page a picture, a clip or a folder of
them from anywhere on disk. The app keeps its own copy and stages it where WebKit lets the
page read it; the storage, the value the page receives, folder watching and the inspector
control are in [user-files.md](user-files.md).

## Page sound

Mute and Volume reach the page's output, independently of Audio response.
`WebWallpaperAudioOutput` resolves WebKit's native interfaces at runtime:
`WKPageSetMediaVolume` controls HTML audio/video media elements, while
`_setPageMuted:` with only the audio bit controls whole-page output, including
WebAudio. Nonzero Volume is **not** a WebAudio gain control. Zero volume also mutes
the page; neither control pauses media timelines or disables system-audio analysis.
The official general-property payload remains `fps`, not an invented `volume`
protocol.

User mute and temporary app/Focus/other-audio mute compose in the existing bridge
configuration; ending a rule does not clear user mute. Mirrored pages elect one
presenting audible owner per actual source assignment (`WebWallpaperAudioOwnership`);
independent assignments of the same project stay independent, and a hidden owner
hands off to a visible mirror without duplicate sound.

These are private WebKit interfaces and may be unavailable on another macOS version.
**Audio and media status** in the inspector reports the observed availability and
never substitutes Pause for an unavailable mute.

## Limits

- Keyboard input is not forwarded; the wallpaper window never becomes key.
- Pointer events are mirrored, not captured: Finder still selects icons and
  rubber-bands, and a click on an icon reaches the page too. The middle button
  arrives without its button number.
- A page sees at most one pointer move per frame it draws. Below a fast display's
  full refresh, WebKit's own cadence near 60 fps applies (60 on a 120 Hz display,
  whatever rate between 60 and 120 is chosen). A page that cannot keep up, such as
  a heavy WebGL scene on a slower GPU, slows its pointer with its frames.
- The frame-rate limit is enforced on `requestAnimationFrame` of the main frame
  only. `setInterval` and `setTimeout` loops, video frame callbacks, CSS and Web
  Animations, workers and subframes run at their own pace, and a page that
  interpolates by frame count rather than by time may judder at 30. The effective
  cadence snaps to the display's: 30 on a 60 Hz cadence is exactly every second
  frame, 40 averages 40 with uneven spacing.
- The render scale only helps a page that sizes its canvases or WebGL buffers from
  `devicePixelRatio` and reads it again on `resize`. A page that reads the ratio
  once at start keeps full resolution until it reloads, `matchMedia` resolution
  queries and subframes see the display's own ratio, and a page that mixes the
  ratio into CSS pixel math can lay out differently at a lower scale. The image
  softens by design, like a scene's.
- The `fetch`/`XMLHttpRequest` fixes for project files reach the page and every frame
  it embeds, not web workers: a `fetch` made inside a worker still gets WebKit's
  status 0 and no `Content-Type` for a local file.
- [Idle callbacks](#idle-callbacks) cannot see frames: Chromium ends an idle period at the
  next frame of a page that animates, but here every period lasts 50 ms, so a page that
  fills `timeRemaining()` with work while it animates can hold back a frame for that long.
- The [Windows font names](#windows-fonts) are a table of the families the local wallpapers
  name, not every Windows font. The generic families (`sans-serif`, `monospace`, `system-ui`),
  which differ between Chromium on Windows and WebKit, and the real fonts' line metrics
  (`ascent-override` and its siblings, whose support in the shipped WebKit is not
  established) are not matched, so a stand-in's lines can stand a little apart from the
  real font's. A page that ships only a regular face under a Windows name and asks for bold
  draws the stand-in's bold, since the script's heavy face matches that weight better than
  the page's one face does. Only the digit advance of the Latin fonts is fitted, so a heading
  in one is a few percent off; no frame of Wallpaper Engine's of a Latin interface font was
  compared. The Chinese families were checked in a page, canvas text at weight 900 equal to
  PingFang SC Semibold, and PingFang SC, Kaiti SC and the Hiragino faces are downloadable
  system assets that a Mac may not have (the alias then does nothing).
- Inspection covers the desktop pages and the live preview only. The screen saver
  and the lock-screen extension are never attachable through this setting, and an inspected page's JavaScript is open to anyone using this Mac's
  Safari while it is on.
- **A page's `<video>` is colour-managed by WebKit; Wallpaper Engine's Chromium shows the
  decoded values as sRGB.** WebKit passes the stream's colour tags to CoreVideo and the
  system converts them to the display's colour space. A stream that is untagged or tagged
  BT.709 has its transfer curve read as gamma 1.96 and shown through sRGB's 2.2, so
  mid-tones come out lighter: on a limited-range ten-step grey ramp 80 reads 90, 110 reads
  120 and 160 reads 169 while black and white stay, a mean error of 6.5 levels. An
  untagged VP8 WebM is also decoded with BT.601 coefficients (skin 200/150/120 reads
  199/157/132); untagged H.264, HEVC and VP9 use BT.709. The same clip tagged with the
  sRGB transfer, BT.709 primaries and BT.709 matrix reads back as the decoded values
  (mean error 0.9) for VP8, VP9, H.264 and HEVC, which is what Wallpaper Engine's frame
  matches. In an MP4 the `colr` box and the H.264 VUI each work alone, and `colr` wins
  when they disagree. A project's files are loaded straight from disk, so the host cannot
  retag them, and it applies no compensation: a filter on the `<video>` would be a
  full-resolution software pass for every frame (about 160 ms more per 3456 x 1944
  snapshot, 60 ms at 1920 x 1080) and would have to know each stream's tags to undo
  them. Measured on offscreen snapshots; see [Verification](#verification) for what was not.
- Nonzero WebAudio gain is not controlled by the native media-volume interface;
  whole-page Mute still applies where WebKit exposes it.
- A paused wallpaper's WebAudio is muted (`WebWallpaperAudioOwnership` gives a paused
  page no audible output) but not suspended: the host has no `AudioContext`
  handling, and what WebKit's own throttling does to a detached page's audio graph
  is unmeasured.

## Verification

The page host is tested against a real offscreen `WKWebView` with no desktop window
(`Tests/Unit/WebWallpaper/`: module loading, late-listener replay, local request
metadata in the page and in iframe, `srcdoc` and script-created frames, pause
composition, suspension by presentation and by pause with its
first-frame grace and edits shown while paused, navigation lockdown, forwarded pointer events, mouse routing
policy and move pacing, changed-only property delivery, frame pacing against a fake display
cadence and in a real page with the rate a slow or full-refresh page draws at, the page
rebuilt when a frame rate crosses a fast display's refresh with its render scale, pause,
limit and pointer rate carried over, render scale on `devicePixelRatio` including the
resize rebuild of a canvas page, the audio pump with its silence cadence on a
hand-moved clock, the inspection switch on running, new and preview pages,
`WebWallpaperIdleCallbackTests` (a page that asks for an idle callback before its first
frame gets to its frame, a self-repeating callback runs once per 50 ms period, order,
cancellation, a throwing callback and the timeout, a native function kept, and every frame
of every surface given the script), and `WebWallpaperFontAliasTests`: SimHei and Microsoft YaHei draw their Han in PingFang SC
and not Songti, Segoe UI's digits are PT Sans's at 98.7 percent and the four Latin fonts have the
real fonts' digit advance, a page's own `@font-face` of the same name wins, the style comes first in the
document, subframes get it, an https document does not, and every surface's user scripts hold it) and the bridge contract in
`upstream/renderer/crates/bridge/src/tests/` (`apply_options.rs`,
`quality_settings.rs`, `web_audio_media.rs`); file and directory properties are
covered under [user files](user-files.md#verification), and the domain inventory is in
[coverage](../testing/coverage.md). The held picture over a replacement page is covered
there with a fake window; whether 500 ms after `didFinish` is enough for a real project's
first paint, and how long the system picture shows while a page's window is replaced, need
an authorized desktop run, listed in [manual smoke](../testing/manual-smoke.md#wallpaper-switching).
Show Desktop and Space transition smoothness,
real hover and window-server routing on a desktop, how flicks and parallax pages feel
with a real high-rate mouse, that the hover exit still lands after the last move,
audible output and mirror audio handoff need an authorized manual run. So do judder on pages that interpolate by
frame count at 30 fps, the real CPU and GPU change of a Low-preset web wallpaper
(`scripts/power_benchmark.py`), and whether WebKit really caps `requestAnimationFrame`
near 60 on a ProMotion display (measured for pointer moves and a page's own loop when
full-refresh pages were added, not for the pacer on a limit set on such a page), as
does a pass over real Workshop pages from the
[local corpus](../testing/wallpaper-corpus.md) for any that assumed a full property
object on every edit. How soft a page looks at 75% and 50%, the real GPU and
WebContent savings on WebGL, Spine and three.js pages (an A/B with
`scripts/power_benchmark.py`), pages that read `devicePixelRatio` once, and pages
that mix it into CSS pixel math also need an authorized desktop run. So does a real
smoothing visualizer (bars that decay per callback) after the system audio stops, and
a comparison with Wallpaper Engine's own behavior in silence if a Windows reference is
ever available. Whether the on-screen compositor lifts a page's `<video>` the way the
offscreen snapshot does (see Limits), and what the native video backend's `AVPlayerLayer`
does with the same clips, need an authorized desktop run. A real Workshop page that hosts
its player in an iframe needs an authorized
desktop run, as does a page that makes its local requests from a worker. That
Safari's Develop menu lists a desktop wallpaper page and attaches to it in a release
build, and drops it again when the switch goes off, also needs one.
