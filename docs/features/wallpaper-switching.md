# Switching wallpapers without a black gap

Choosing another wallpaper tears the old renderer down before the new one has drawn a
frame, and the window between the two is black. The **switch hold** covers that gap: it
takes a still of what the display shows just before the switch, carries it over the window
that shows the new wallpaper, and fades it out once the new wallpaper has drawn. There is no
setting; it applies whenever the conditions below hold and costs one picture in memory per
display while a switch loads.

The pieces are `WallpaperSwitchHold` (the per-display state and its timers) and
`SwitchHoldVeil` (the layer that carries the still), both in `App/Services/Desktop/`, and
three hooks on `BridgeStore` that tell the hold when a switch starts, settles or fails.

## What the user sees

- The previous wallpaper stays on screen while the new one loads, then fades out over 0.2
  seconds. A scene that takes seconds to load, or a cold shader compile, no longer shows a
  black screen first.
- **Reduce Motion** (System Settings › Accessibility › Display) removes the fade: the
  previous picture is replaced at once when the new wallpaper has drawn.
- The held picture is a still taken up to a quarter of a second before the switch. An
  animated wallpaper may therefore jump a little at the moment the new one appears.
- With the native video player (the default for videos) the same picture covers the new clip's window
  until the clip shows its first frame, then fades out. That fade is the dissolve from the
  old wallpaper to the clip, whether the old one was a clip or a scene.
- With a web wallpaper the same picture covers the new page's window until the page has
  loaded and had half a second to paint, then fades out; a page that fails to load lets the
  picture go at once, so the error and its retry are not left behind it.
- When no still can be taken, the switch behaves as it always did.

## Which switches are held

Held: any activation that goes through `BridgeStore.activateWallpaperAsync` (a tile or
menu choice, a hotkey, a link, a Shortcuts action, a playlist or rule, a rotation on unlock,
**Back**, **Random Wallpaper**, a wallpaper applied to every display, a saved display layout,
**Copy or swap**) on a display that is showing a wallpaper, when the new
wallpaper is drawn by the scene engine (a scene), by a native video window (a plain video)
or by a web page window (a web wallpaper). A display mirroring the switched display is held with it.

Not held, because the old picture is not available or the successor is not a scene:

- A display with no wallpaper window yet (the first wallpaper, or one just ejected), a
  display that is suspended (display sleep, a covered desktop, a pause rule, a lock), and
  any display whose surface does not answer within 250 ms (a paused or stalled renderer
  may not).
- A desktop whose wallpaper the display keeps paused for it
  ([different wallpaper for each desktop](spaces.md#keeping-each-desktops-wallpaper)): that
  wallpaper runs on in the window already on the desktop, so there is no gap to cover. A kept
  window is never the picture held for another switch either.
- **Reapply wallpaper**, Retry for a scene that stopped, and the reload after an update:
  all three take the wallpaper off the display first, so there is no picture left to hold.
- A host window that does not come: a still that no host picks up is released 8 seconds after
  the engine has finished. That is what happens to a clip whose file takes longer than 8
  seconds to read (a sleeping external drive or a share that is slow to answer), and to a
  web page whose project takes that long to check and stage; the window opens without the
  picture.
- A page with a bad entry file, a display that lost its web wallpaper to another backend and
  a display that was disconnected while the page loaded: there is no web window to show the
  picture on.
- First launch, quit, display reconfigures and wake rebuilds, and the rebuild a host does
  when an admission or a setting changes.

Known gaps with host windows. When the old wallpaper is a scene, the engine closes its window
as soon as the switch is applied, and the successor's window opens only after its host has
done its own work: the clip's metadata read for the native backend (milliseconds from the
internal drive, seconds from a slow volume), the bridge read, the project check and the asset
staging for a web page. The system picture can show between the two. A clip replacing another
clip has no such gap, see below. A web page replacing a web page has a short one: the host
closes the old page's window before it stages the new page's files (the close reads the
descriptor that staging then replaces, so it cannot move later), and the veil is only on the
window that follows. The gap is the staging of a project's file properties, which is
nothing for a page without any.

## Limits

| Limit | Value | Why |
|---|---|---|
| Waiting for the still | 250 ms | Every switch waits this long at most before it applies |
| Holding a display | 30 s | A cold compile can outlast it, which only restores the black gap |
| Waiting for a host window | 8 s | After the engine finished with no scene to carry the still |
| Fade | 0.2 s | None under Reduce Motion |

The still is the renderer's final pixels at the display's pixel size, four bytes per
pixel: about 60 MB on a 5K display, held for at most the ceiling. A second switch while a
host successor (a web page or a clip) is still loading keeps the still it has and restarts
the ceiling; it never takes another. A scene is different: its switch finishes when it has
drawn, so the next switch finds the veil fading or gone and takes a fresh still of the new
scene.

## How it works

1. **Before the apply.** `BridgeStore.performActivation` calls `willSwitchWallpaper` with
   the live display ids the switch changes (`switchHoldDisplays(for:)`: the display and every
   display mirroring it) after every check that could refuse the activation, and before the
   display config is enabled. An activation that finds its wallpaper already active and
   clean returns earlier and announces nothing.
2. **The still.** For each display the hold asks the frontmost wallpaper window for a frame
   with `DesktopPosterNotification.request` on its content layer, the same request the
   [desktop picture](desktop-picture.md) sync uses, so scene, web and native surfaces all
   answer it. The request carries the context `switch-hold:<uuid>`. The hold takes the first
   frame the layer reports, whatever it was asked for. `DesktopWallpaperSync` ignores a
   frame whose context is not the one it asked for, so a held still can never become the
   desktop poster. Several displays are asked at once.
3. **The veil.** The still becomes `SwitchHoldVeil`, a plain sublayer named `MWEHandoffVeil`
   with a high `zPosition`, never a window: occlusion tracking, hit testing, the poster sync
   and web snapshots see the window as before.
4. **A scene successor.** The Rust window code posts `WallpaperMachine.wallpaperLayerInstalled`
   for every content layer it gives a window, synchronously on the main thread before the
   layer is first composited (see [architecture](../architecture.md#desktop-wallpaper-windows-and-private-api-handling)).
   The hold moves the veil onto the new layer for the reasons `open` and `replace`. A
   `reconfigure` (a display change that gives the window a fresh layer) moves it only while
   the veil sits on a scene successor that has not presented yet: that renderer has no
   picture to keep, and the veil would go with the layer it replaced. Before a successor has
   a layer, or on a host's window, a `reconfigure` is ignored: the renderer that shows a
   picture keeps it. It never restarts the 30 second ceiling, because the load did not
   start over. A second announcement moves the veil again, so a switch that opens a
   window and then replaces its layer still ends with the veil on the layer that is shown.
5. **Release.** `didSettleWallpaperSwitch` fires when the engine's apply returns, which
   waits for the first presented frame of every replaced display: a veil on a scene layer
   fades out then. `didAbandonWallpaperSwitch` fires when the apply throws or is
   cancelled and releases the veil (with the fade when it sits on a window); a scene whose
   replacement failed shows its previous renderer again (see the layer swap in the
   architecture document).
6. **Backstops.** A veil nothing releases is removed after 30 seconds. The fade ends from a
   timer and not from the animation's completion, which does not run for a layer that is
   off screen. `stop()` removes every veil at once and runs before the hosts shut down.

A host window (web page, native clip) takes the veil with `adopt(into:displayID:)`, which
refuses a veil that still covers a live window, and releases it with `contentReady`, with an
optional wait for a page's first paint. `cancel` ends a hold the host abandoned.

**A native-video successor.** `NativeVideoWallpaperHost` replaces a clip, or a scene, by
building a new window, and it takes the hold as an optional dependency (`switchHold:`; the
tests and a host without one behave as before):

- *Order.* For a display whose wallpaper or admission key changed, the host first decides the
  replacement's admission (the metadata read, cached by admission key so opening reuses the
  verdict), then stops the old surface, builds the new window, gives it the veil and orders
  it in, all in one main-actor turn that waits for no file. The old clip plays through the
  read, and a pass that a newer apply or a shutdown overtakes meanwhile closes nothing. The
  old player is still stopped before the new one exists, so a clip is never decoded or heard
  twice.
- *Adoption.* The veil goes onto the window's content layer (`posterLayer`) before
  `present()`, so the window never reaches the screen without it. A second replacement
  before the first clip has a frame moves the veil to the newest window, and a late callback
  from the replaced window cannot release it.
- *Release.* `AVPlayerLayer.isReadyForDisplay`, through the surface's `onReadyForDisplay`,
  releases the veil with the usual 0.2 s fade (none under Reduce Motion). A layer that
  already had its picture when the callback was installed releases it as soon as the window
  is up. `isReadyForDisplay` says a frame can be shown, not that it has been drawn, so the
  fade is what hides a frame or two of lag; if a desktop run shows a flash as the veil goes,
  the knob is `contentReady(after:)`.
- *Refusal.* A clip nothing can play is refused before any window exists, and nothing takes it
  over: the display is reported as failed. The still stays armed for a window of another host that
  might still come, and the host's `engineSettled` call, made as the failure is reported, starts
  the 8 s grace that ends it.
- *Failure.* A clip that cannot be played after admission closes its window and the display is
  reported as failed; the hold is cancelled, because the window it sat on is gone and nothing
  succeeds it.
- *Closing.* A window closed to be replaced hands its veil to the successor through `adopt`.
  A window closed with no clip to follow, because the wallpaper was ejected, went to another
  backend or its display was disconnected, calls `windowClosed`: a veil that sat on that
  window goes with it, so a later switch cannot find it and show it again out of date. A veil
  that still waits for a window, or sits on a scene, is not touched. Either host's reconcile
  may run first, and the other host is the successor a waiting picture was kept for.

**A web-page successor.** `WebWallpaperHost` takes the hold the same way (`switchHold:`, `nil`
in a host without one):

- *Adoption.* A new window is built when the entry page or the project's content changed.
  Its veil goes onto the window's content layer (`posterLayer`) after `page.load()` and
  before `present()`, so the window never reaches the screen without it. The veil is a
  sibling of the web view in the container layer, above everything the window adds later
  (the suspension placeholder included), so `WKWebView` snapshots, which the poster sync and
  the Space posters take, show the page and never the picture. A reconcile that keeps the
  page (the same entry file and an unchanged project revision: a property push, a frame-rate
  or volume change, a refresh that found nothing new) builds no window and takes nothing.
- *Release.* `didFinish` comes before the page's first frame, which is also why the poster is
  read again two seconds later, so after it the host asks the page to confirm a frame
  (`WebWallpaperPage.confirmFrame`): a one-point snapshot taken after the pending screen
  updates, which WebKit returns only once it has drawn and committed a frame of the
  document. The answer calls `contentReady` at once, and so does no answer within
  `WebWallpaperHost.firstFrameLimit` (3 s; a page holding its main thread, a display that
  draws nothing). Only when WebKit refuses the snapshot does the picture wait the old fixed
  `firstPaintSettle`, 500 ms. A committed frame is the page's first, not its finished
  picture: a page that builds itself after load still draws in steps under the fade. A page
  that fails to load calls `contentReady` at once.
- *Closing.* A window closed to be replaced hands its veil to the successor through `adopt`
  (a second switch before the first page loads moves the picture to the newest window). A
  window closed with no web successor, because the display now shows another backend's
  wallpaper, the display is gone or the entry file lies outside the project, calls
  `windowClosed`: a veil that sat on that window goes with it, so a later switch cannot find
  it and show it again out of date. A veil that still waits for a window, or sits on a scene,
  is not touched. The web reconcile often runs just before the native video host's, which is
  the successor a waiting picture was kept for, so ending it here would drop the clip's
  continuity.

## Diagnostics

The hold logs through `AppLog`, one line per step and always the display's CoreGraphics
id:

- `switch hold: display N frame captured in X ms (WxH)`
- `switch hold: display N veil on scene layer`
- `switch hold: display N veil followed a display reconfigure`
- `switch hold: display N adopted by host`
- `switch hold: display N released after S s (scene first frame | host ready | cancelled | window closed | no window took it | ceiling)`
- warnings: `poster not delivered within 250 ms; not holding`, `poster frame WxH could not be
  used; not holding` and `ceiling reached after 30 s; releasing`

A switch with no `frame captured` line was not held. The activation line
([diagnostics](diagnostics.md)) is unchanged and still says who asked and how it ended.

## Verification

`WallpaperSwitchHoldTests` drive the hold with an injected notification center, plain
`CALayer`s, a manual clock and timers: the request goes to the frontmost layer, an unanswered
or unusable request leaves no ticket, announcements move the veil, `reconfigure` moves it only
off a scene that has not presented yet and does not restart the ceiling, the veil fades and is
removed by the timer, Reduce Motion skips the fade, the ceiling and the
host grace release a veil nothing ends, `cancel` and `stop` remove everything including a
still still on its way, and displays are held independently.
`NativeVideoWallpaperHostTests` drive the native host with a fake surface that logs what is
done to it: the replacement window carries the veil when it is presented and keeps it through
a repeated offer or a setting change, the first frame releases it (with the fade, and at once
for a layer that was ready when built), a second replacement hands it on and ignores the
replaced window, another display's still is left alone, a clip that fails to play cancels it,
a window closed with no clip to follow (also when its display goes away) takes its own veil
with it but leaves one that waits for another backend's window or sits on a scene, a
refusal keeps it armed for the scene engine until the bridge has answered and then releases
it (or lets the grace end it), the old clip keeps playing while the replacement's file is
read, a pass overtaken meanwhile stops nothing, and a host without a hold opens as before.
`WebWallpaperFrameConfirmationTests` show the confirmation waiting for a frame a page holds
back and answering at its limit when none comes. `WebWallpaperHostLifecycleTests` drive the web host against real offscreen pages with a fake
window: the replacement window carries the veil when it is presented and keeps it until the
page has loaded and committed a frame, with no timer, a page that cannot load releases it at
once, a window closed with no page to follow takes its own veil with it (also for an entry
file outside the project) but leaves one that waits for another backend's window or sits on a
scene, a reconcile that keeps the page creates no veil, and a host without a hold opens as
before. `WallpaperSwitchHoldTests` pin `windowClosed` itself.
`WallpaperActivationRecoveryTests` pin the hook order around a real
`BridgeStore.activateWallpaperAsync` (announce, apply, settle; abandon when the apply throws;
nothing for a no-op) and which displays a switch holds. `DesktopWallpaperTests` pin the shared
poster frame conversion and that a held frame never becomes the poster.

Not established by any test: that a sublayer above a `CAMetalLayer` composites over its
drawables and hides the black placeholder; that scene, web and native surfaces answer the
request quickly, including a paused renderer; how the still compares with the live frame it
replaces; whether `isReadyForDisplay` alone is late enough that the veil does not come off a
frame early on a real clip; how much of a typical web project's picture its first committed
frame already shows; how long the system picture shows between a web window closing and the
next one opening, and between a scene and the page that replaces it; the fade, Reduce Motion,
multi-display and mirror behavior on a real desktop. The checklist is in [manual smoke](../testing/manual-smoke.md#wallpaper-switching).
