# System desktop picture and Mission Control

The wallpaper on screen is an app window, but macOS keeps its own static desktop
picture for every desktop (Space) of every display. That picture is what Mission
Control and the Spaces bar show, what appears for a moment beneath a renderer that is
still loading when the app starts, and what stays on screen when the app is not running. A
switch to another wallpaper keeps the previous picture on screen instead where it can
([wallpaper switching](wallpaper-switching.md)). WallpaperMachine
installs a **poster**, a still frame of the animated wallpaper, as that picture so it
matches what the user sees, and puts the user's own wallpaper back when the app quits.
The windows that draw the live wallpaper are described in
[architecture](../architecture.md#desktop-wallpaper-windows-and-private-api-handling).

The pieces are `DesktopWallpaperSync` (when to take, encode and apply posters),
`DesktopWallpaperLedger` (which desktops to write, the journal of originals and the
restoration) and `DesktopSpaceWallpaperAPI` (the private per-Space calls), all in
`App/Services/Desktop/`.

## What the user sees

Mission Control thumbnails are sampled still frames, not live animation. A poster is
the renderer's real final pixels, not a screen capture and not a Workshop cover, so
scaling and cropping match the live wallpaper, including the blurred copy of Fit with
blurred backdrop (a video the native player draws has black bars there, as on the
desktop). Rendering, JPEG encoding and the
system's thumbnail compositor still take time, so an update is not instant.

**Settings › Desktop & Lock Screen › Desktop › Update the Mission Control picture every 5
minutes** (`PlaybackPreferences.refreshesDesktopPicturePeriodically`, off by default)
retakes the poster every five minutes while the wallpaper plays, for wallpapers that
change over time; the wait may run up to 30 seconds longer so the system can share the
wakeup with other timers. Without it the poster is taken only at the moments listed
[below](#when-a-poster-is-taken), so it shows the wallpaper as it looked once it
settled. With it, every retake of an animated wallpaper is a new file that macOS keeps
a full-size copy of for good ([below](#a-new-file-for-every-new-frame)), so the setting
costs disk space for as long as it is on. The setting applies to the running sync at once and has no effect while the
lock screen is animated, because poster sync is then suspended
([below](#the-native-lock-screen-provider-and-space-selection)), or while posters are
[switched off](#leaving-macoss-own-wallpaper-alone), where its row is disabled.

With no live wallpaper on a display, nothing is written there: its desktops show the
user's own wallpaper again.

### Leaving macOS's own wallpaper alone

**Settings › Desktop & Lock Screen › Desktop › Use the wallpaper as the macOS desktop
picture** (`PlaybackPreferences.writesDesktopPicture`, on by default) decides whether
the app installs posters at all. Turned off, the app never changes macOS's wallpaper
settings: Mission Control and the Spaces bar show the user's own picture, as does the
moment before a wallpaper loads. The switch is local to the Mac, like the periodic
refresh, so a [settings backup](backup-restore.md) neither exports nor restores it.

- **Every write goes through one gate.** `AppDelegate.startDesktopWallpaperSync` returns
  early while the switch is off or a restore is still running, and each start (a
  snapshot, a surface change, the lock-screen handback, a cancelled quit, launch) comes
  through it, so no poster can be written whatever triggers it. The five-minute row is
  disabled while the switch is off, because a retake would write nothing.
- **Turning it off puts the user's picture back at once.** The running sync stops and
  restores with the same verified path a quit uses (`restoreForTermination`: every
  desktop read back, retried for about five seconds while WallpaperAgent reloads, the
  macOS 27 leftover reference tolerated), then the sync is dropped. A poster still
  being written is waited for. If the restore fails, the suspended sync is kept so a
  quit retries it, the error shows in the menu bar menu and the log, and nothing
  retries on its own; turning the switch on and off again does. Turning it back on
  while a restore runs waits for the restore to finish, then starts posters again.
- **A poster left behind is found at launch.** With the switch off and no sync running,
  the launch (and the end of an animated lock screen) reads the journal
  (`DesktopWallpaperLedger.hasRecordedOriginals`): if it still names an original or the
  [store copy](#the-journal-of-originals) is still there, a sync that never starts restores it, for a poster that a crash or an earlier run with
  the switch on left on a desktop. A desktop showing anything but a poster keeps its
  choice, as on every restore.
- **Animate lock screen decides.** While the lock screen is requested, or the native
  provider has the desktop, the extension owns the picture and journals the poster as
  its own original. The switch is then locked in the panel with the reason, the action
  refuses a change (`LockScreenWallpaperService.locksDesktopPictureChoice`, from the
  request until the handback, even after a failure), and neither the restore nor the
  repair runs (`claimsDesktopPicture`, the condition poster sync already used to stay
  away). When the provider hands the desktop back with the switch off, nothing starts and
  a poster the handback left is put back.

## When a poster is taken

A poster is requested from the surface that draws the wallpaper, which answers with
its final pixels: a Metal readback for scene and Compatibility-backend video, a
`WKWebView` snapshot for a web wallpaper, and the player surface's image for a
native-backend video. The request and the answer carry the same context string (empty
outside Space selection mode), so a reply can be matched to the request that asked for
it. A web wallpaper the host has suspended (covered, or paused after its first frame)
answers from the frame it kept when its view left the window tree, since WebKit does
not promise a snapshot of a detached view (an edit made while it is paused draws in
the window first, and the frame is kept again); a page not yet detached is
snapshotted live. The first ready frame goes to every native desktop of the display
at once, without visiting them, except on a display with a
[different wallpaper for each desktop](spaces.md), where it goes to the current desktop
and every other desktop gets the saved poster of its own wallpaper.

A native-backend clip stored rotated or mirrored (a portrait phone recording) is shown
upright by the player layer, but the frames the playing item hands back are not, so its
poster is read with a one-shot image generator that applies the clip's orientation. That
is a second decode of a few frames per poster and is counted as
`nativeVideoPosterFallback`; an upright clip reads the frame that is already playing.
Neither path resumes a paused video.

- **A wallpaper starts or changes.** It is captured at once and again after
  `DesktopWallpaperSync.settleCaptureDelays` (3 s and 15 s), because intros, fades and
  settings that fade in are missed by the first frame. A wallpaper that resumes after
  a pause, a cover or display sleep settles the same way (`presentationResumed`),
  unless its poster has settled (below).
- **A wallpaper is moved on a display.** The inspector's Position sliders and **Center**
  change what the final pixels show, so a committed move requests the same capture as a
  new wallpaper (`BridgeStore.onDisplayFramingChanged`); moves that arrive close together
  share the 500 ms refresh interval, and a move the bridge refused requests nothing. The
  steps shown while a slider is being dragged are previews and request nothing; the release
  does.
- **Property edits shown on a display.** With **Show property edits on the desktop as I
  make them** on ([edits on the desktop](wallpaper-properties.md#showing-edits-on-the-desktop)),
  a display that may be drawing an edit nobody applied is neither asked for a poster nor
  taken one from, a frame already on its way included: the surface is read back from
  what the scene draws, and the picture macOS keeps would show the edit. That holds
  whatever asks (a Space change, the periodic setting, another wallpaper starting), so
  Mission Control and the moment before a wallpaper loads keep the saved look
  (`DesktopWallpaperSync.showsUnsavedLook`, from `BridgeStore.isShowingPropertyEdits(onDisplay:)`:
  every display that shows a wallpaper whose edit was shown, a mirror too). Revert,
  turning the choice off, **Apply changes** and deleting the wallpaper end it
  (`BridgeStore.onPropertyEditsOnDesktopEnded`) and take the poster as a new wallpaper's
  is taken, which also replaces a frame that was read just before the saved look came
  back. A scene that loaded again meanwhile draws the saved look but stays held until the
  edit ends, so its poster is older, never unsaved.
- **A Space change or wake.** The existing poster is applied at once, so a new Space
  has one immediately. A fresh frame is requested only for a surface whose poster has
  not settled (see the next item). Desktops that kept refusing posters are tried
  again, and the Space monitor re-reads the topology first.
- **A settled poster is kept until the wallpaper changes.** A Space change, a wake, a
  resume (`presentationResumed`) and an engine snapshot that leaves every display as it
  was retake only a surface whose poster has not settled: one taken before the last of
  the settle captures could have landed, one a paused display answered with, or none
  at all. A surface that a settle capture is still to ask is left to it. Each display
  is judged on its own, and a settled poster stays however long ago it was taken,
  because every new frame of an animated wallpaper is a new file macOS keeps
  ([below](#a-new-file-for-every-new-frame)). A snapshot changes the displays when its
  `DesktopPosterLayout` (each display's wallpaper, mode, mirror target and scaling, the
  wallpapers' files and the screens' sizes) differs from the last snapshot that sync
  saw (`DesktopWallpaperSync.snapshotApplied`), so a change made while the animated lock
  screen held the desktop still counts; playback, audio, quality, frame rates, volumes
  and the panel's selection do not. A wallpaper that starts or changes, a move, an apply,
  the end of shown edits, the periodic setting and a poster scoped to a Space
  ([spaces.md](spaces.md#poster-ownership-and-late-frames), which must confirm its
  context) are not affected. The resume's settle captures cover only the surfaces that
  were retaken, and nothing is scheduled when none were. A frame that a paused or
  covered surface answers with is the one it kept, so it does not settle its poster: a
  Space change or wake that asks such a surface while its display is paused leaves the
  resume to retake it. The debug log notes the displays whose poster was kept.
- **A frame nobody asked for.** A renderer sends its first frame unasked. On a surface
  whose poster has settled, and which no settle capture is still to ask, it is
  dropped: a renderer started again in the same window draws the same wallpaper, and
  that first frame is often the start of an intro (a new wallpaper, a move or a new
  screen size asks for posters itself). On a surface without a settled poster, such as
  a window that just opened (a wallpaper unloaded while the displays slept gets a new
  one), it becomes the poster without settling it, and the surface settles as a new
  wallpaper does.
- **Periodically**, every `periodicRefreshInterval` (300 s), while the setting is on.
- Settling and periodic captures ask only displays whose wallpaper is presenting
  (`canCapture`: the presentation policy has not suspended playback globally or for
  that display); a new wallpaper captures every surface, and a Space change and a
  wake every surface whose poster is not kept.
- A frame identical to the current poster costs a readback and a hash, and is neither
  encoded again nor rewritten. Bursts of refresh requests collapse so that at most one
  runs every 500 ms.
- Only the newest frame of a surface that is still on screen may become its poster.
  While one wallpaper window replaces another on a display, the poster whose frame
  arrived last wins, counted on receipt and not when encoding ends, so a slow encode
  cannot put the old picture back; a window without a poster yet never removes its
  sibling's.

Posters are JPEG (`DesktopPosterEncoder`, quality 0.9, sRGB) under
`<support>/DesktopPosters/` (`<support>` is `ClientPaths.supportURL`). The file name
hashes the display, the original it replaced and the pixels, so a filename is never
reused for different pixels (WallpaperAgent can cache inactive-Space thumbnails by
URL) and identical frames share one immutable file. A poster has the display's exact
aspect ratio and is written with fill-screen placement, so the renderer's crop or bars
are kept without scaling the content a second time. A failed synchronization is
retried up to three times, 100 ms longer each time, for the system's asynchronous
acknowledgement and Space-creation races; the initial update is never delayed for
them.

### A new file for every new frame

Because the file name hashes the pixels, an animated wallpaper turns every capture
that is not identical into a new poster file. On macOS 26 and later, WallpaperAgent
keeps an uncompressed, full-size bitmap of every image file a desktop has shown in
`~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image/`
and does not delete it, even after the poster file itself is gone: 17.8 MB per poster
on a 14-inch MacBook Pro (3024 × 1964 at 24 bits). When every engine snapshot retook
every poster three times, and a Space change, a wake or a resume retook any poster
older than two minutes, that cache grew to about 100 GB. That is why a settled poster
is kept until the wallpaper changes and why the periodic setting is off by default. The
app does not clear the cache: it belongs to WallpaperAgent, lives in another app's
container, and changing it behind the system's back is unsupported.

## Reaching the per-Space picture

`DesktopSpaceWallpaperAPI` `dlopen`s CoreGraphics and HIServices and resolves
`_CGSDefaultConnection`, `CGSCopyManagedDisplaySpaces`,
`DesktopPictureCopyDisplayForSpace` and `DesktopPictureSetDisplayForSpace`. Every
symbol is optional: if one is missing the initializer fails and the caller falls back
to the public `NSWorkspace` API, which is scoped to the visible Space. That fallback
is logged once, has no Space identity and so cannot accept a Space-scoped write.
Switching Spaces, patching the wallpaper plist and restarting system processes are
deliberately not used to show posters. Only a full restoration edits the store and
restarts WallpaperAgent, to put back choices this API cannot write (see [the journal of
originals](#the-journal-of-originals)).

A target is a display and the UUID of one of its regular desktops; fullscreen-app
Spaces are not desktop thumbnails and are skipped.

`SystemDesktopPictureWorkspace.referencedPictureURLs` reads the system wallpaper store
(`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`) read-only, to
see what WallpaperAgent will load. A selection waiting for the agent to reload may not be
visible through the picture API yet, and the picture API can still report the old
selection after the store has the new one. Screen-saver-only (idle) choices are
excluded because they do not own the desktop and posters never write them.

## The journal of originals

Before anything is replaced, `DesktopWallpaperLedger` records the user's original
per-Space picture in `<support>/DesktopPosters/originals.json`, keyed by poster file
name. It keeps the complete native configuration, including the opaque options blob of
a dynamic wallpaper or slideshow, and writes it back as it was rather than rebuilding
it. The entry is saved before the native call, so a crash or relaunch can still find
it; after a crash the poster stays installed until the next launch, which recognizes
it by its folder and journal entry and keeps the original.

A pathless (inherited) selection or a poster cannot bring the user's wallpaper back, so
before any write the ledger resolves each display's original in this order: its first
real per-Space original, then its effective image through `NSWorkspace`, then its saved
journal, and finally another display's original. With no recoverable original it leaves
that desktop untouched and reports the failure through `AppLog`; live playback
continues without new posters there.

Another app can delete a picture it set, as a wallpaper app clearing out its old
downloads does, and macOS refuses to show a file that does not exist. Writing that
original back would fail on every attempt and so refuse every quit. So whenever a
desktop is put back (at quit, when its display stops playing, when the switch is turned
off, and in the launch repair), an original whose file is gone counts as unavailable. The
desktop gets the next original whose file is still there, in the order above (another
desktop on its display, its effective image, its journal, another display's). When none
is left it gets macOS's default picture
(`/System/Library/CoreServices/DefaultDesktop.heic`, written as the file that link points
to). `AppLog` records the missing file and what was put back instead. Only a definite "no
such file" counts. A file the app may not look at, such as one in a folder macOS's
privacy protection covers, is written back as before. Files are looked at only while a
desktop is being put back, never for each poster.

The per-Space API speaks only image paths, so a choice that is not an image cannot be
written back through it. An aerial, a dynamic or another extension wallpaper (macOS 27's
default Golden Gate, for example) shown on all Spaces reads as an empty per-Space
selection, and `NSWorkspace` answers with a still stand-in (`DefaultDesktop.heic`).
Writing that still back alone would leave an image choice on every desktop, which macOS
shows as a different wallpaper. So before the first poster the ledger also saves a copy
of the system wallpaper store (`Index.plist`) in `<support>/DesktopPosters/store-original.json`,
and journals each picture it writes back there with the time of the write: a store
selection of that file counts as the app's only when its `LastSet` falls at one of those
writes, so the same picture chosen in System Settings stays. A full restoration (quit, the switch
turned off, the launch repair), once every desktop reads back without a poster, puts back
`DesktopWallpaperStoreRestoration`'s result: every store desktop selection that names
only posters or pictures the app wrote back gets its pre-poster value, a node the writes
created goes, and WallpaperAgent is restarted to load it; a restart that fails is
retried by the next pass or launch even though the store has nothing left to change. A selection chosen in System
Settings meanwhile is kept, a snapshot entry that already named a poster is never put
back, and the store is written only if it is still the version just read. The copy is
deleted once restoration succeeds.

A desktop showing anything but a poster was changed outside the app and keeps that
choice on restoration. When a display stops showing a live wallpaper, its desktops are
restored while the others keep their posters.

Posters no readable desktop shows are deleted. A display is complete when every desktop
on it is a native Space whose picture was read; elsewhere an unseen desktop may still
show a poster, so only the newest `retainedPostersPerIncompleteDisplay` (4) are kept
there and older ones go. A poster a readable desktop shows is never deleted, and
neither is one whose write is still settling.

## Writes macOS delays or refuses

The per-Space setter returns before the write is applied, so its return is not an
acknowledgement. `DesktopSpaceWallpaperAPI.set` reads the picture back right after the
write: one that does not read back yet is **unconfirmed**
(`DesktopPictureUnconfirmed`), not refused. WallpaperAgent copies the poster file some time after
the write, so the file stays on disk for `DesktopWallpaperLedger.confirmationWindow`
(1 s) even if a newer frame replaces it or its desktop stops receiving posters, and
`DesktopWallpaperSync` synchronizes again once that window has passed. A pending
write that reads back is confirmed without counting a refusal; one that still has not
after the window counts as refused. The same poster that is still on its way is not
rewritten, and a poster that lands on a desktop which no longer receives them is put
back to the original wallpaper by that follow-up pass.

A desktop macOS keeps refusing (`DesktopWallpaperLedger.refusalsBeforePause`, 4 writes
in a row) is logged once and left alone, rather than rewritten on every snapshot, until
the next Space change or wake. One desktop failing never stops the others: the pass
continues and reports the first error afterwards.

## macOS 27

The per-Space setter forwards to WallpaperAgent, which applies the write
asynchronously, about 0.3 s later. Because WallpaperAgent runs sandboxed, it resolves a
relative image path inside its own container, where the poster does not exist, and
rejects the write. Paths are therefore sent absolute from macOS 27
(`DesktopSpaceWallpaperAPI.takesAbsolutePaths`); through macOS 26 the setter
mis-expanded absolute home paths into `/~`, so they are sent root-relative there.

macOS 27 can also copy a Space write into the display-wide and system-default
selections. No per-Space write reaches those, so the poster remains named there after
every desktop that can be written has been restored; see
[Quitting](#quitting). When diagnosing, read back through the picture API, because the
agent's on-disk `Index.plist` can lag its in-memory store until a scheduled write.

## Quitting

`applicationShouldTerminate` first suspends poster sync, so no new poster is written
during the quit (a restore the [switch](#leaving-macoss-own-wallpaper-alone) started is
cancelled, since the quit restores the desktop itself). The native lock-screen service
then restores its own selections
(without a lock-screen service, on macOS earlier than 26, restoration starts
directly), and the poster service restores the originals: it puts each desktop's
journaled original back (or, when that file is gone, [the next one that still
exists](#the-journal-of-originals)), puts back [store selections the per-Space API cannot
write](#the-journal-of-originals), checks image references in the native store, and
retries asynchronous restoration for about five seconds (25 attempts, 200 ms apart)
while WallpaperAgent reloads. Quit waits for every restored desktop to read back and for any poster write
still in flight; one that lands late is restored again.

A poster the store still names after every writable desktop is restored and read back
is logged and does not block quit, since macOS 27 can keep a reference no per-Space
write can remove. Any other failure cancels the quit, and so does restoration that
takes longer than 20 seconds (`QuitSupervisor`). Nothing after restoration starts for a
cancelled quit. Because the app is hidden while it quits, a cancelled quit puts things back
and says so:

- poster synchronization restarts unless the native lock-screen provider has the desktop
  or the switch is off;
- the control panel (and What's New) comes back if it was open, on the section it was on;
- an alert gives the reason: the restoration error's own text (macOS is still restoring the
  desktop wallpaper, or the original could not be recovered and the user should select
  their wallpaper again in System Settings), or that restoring took too long, and that
  quitting again retries;
- an update installer that was waiting for the app to quit is called off, so it cannot
  replace the app at some later quit; the update stays downloaded and About offers it again.
  The helper can take two seconds to answer, so this is done after the system has been told
  the quit is cancelled. The app counts as running again only in the step that sends that
  reply: a request that arrives before it is answered by the quit that is running, and one
  that arrives later starts a new quit, so a cancellation never lands on a quit that has begun;
- the error also stays as a line in the menu bar menu, and the user can quit again.

The restoration stage is cancelled when its time is up. `restoreForTermination` checks for
cancellation before every one of its 25 attempts and its wait between them is cancellable, so it
stops promptly and leaves the originals journal as it was. A step that never returns and
ignores cancellation (a hung call into WallpaperAgent) cannot be stopped; the quit is still
refused on time, but that step may finish later.

While a quit is running the menu shows a disabled **Quitting…** in place of **Exit**, and a
second request to quit from the user is refused. The stages after restoration (services,
imports, SteamCMD, Workshop, pixiv, the renderer) share 10 seconds. See
[architecture](../architecture.md#appkit-shell) for the budgets and the exit fuse and
[diagnostics](diagnostics.md#why-the-app-quit) for the log lines.

A `kill` takes this path too. SIGTERM and SIGHUP are relayed to the same quit with the same
limits, so the desktop picture is restored before the app exits; a quit refused for a failed
restoration shows the alert like any other, and a second signal ends the app at once
([signals](crash-recovery.md#signals)).

### Logout, restart and shutdown

Refusing a quit is right for a user who can read an alert and try again. It is wrong when
macOS is logging out, restarting or shutting down: the system is waiting for every app,
and a refusal cancels the whole logout and shows the user a dialog. So a quit that the
system asked for (`QuitMode.powerOff`: the quit event names a logout, restart or
shutdown, or macOS announced one with `willPowerOffNotification`) never refuses. It runs
the same ordered stages with shorter deadlines and goes on whatever restoration does:

| | user's quit | logout, restart, shutdown |
|---|---|---|
| restoring the desktop | 20 s | 3 s |
| the other stages together | 10 s | 1.5 s |
| the renderer's shutdown keeps at least | 2 s | 1 s |
| exit fuse after the quit finished | 5 s | 2 s |
| restoration fails or does not finish | the quit is refused, with the alert and the panel | the quit goes on |

The budgets are judgments, not measurements; the stage durations every quit logs are what
to tune them from.

Restoration that is cut short loses nothing. `restoreForTermination` stops at the next of its
25 attempts when its deadline cancels it, and `DesktopWallpaperLedger` keeps an entry in
`originals.json` until its poster is no longer shown. The desktop may keep showing the last
poster after the next login until the app runs again, and the original it replaced is still
on record to put back, as after a crash ([the journal](#the-journal-of-originals)). The log
says that the desktop restoration is unfinished and that the poster journal will finish it
at the next launch (`quit: power off; desktop restoration unfinished (…)`). The session
ledger keeps `logout; desktop restoration unfinished` as the quit's reason, so the next
launch's `previous session:` line reads `quit normally (logout; desktop restoration
unfinished)` and not a crash.

The quit alert, bringing the panel back and the **Quitting…** line belong to a refused quit
and never appear. A call that never returns because it blocks the main thread (a hung call
into WallpaperAgent) cannot be stopped by any deadline; the system's own patience, and then
its kill, end it, and the journal covers that as it covers a crash.

A request to quit that arrives while another quit is running is answered by what it is:
a second user quit is refused, but a logout, restart or shutdown (and anything that arrives
during one) waits for the quit that is running and is answered with it, so it is not
refused either. If the user's quit then fails to restore, it is tried again once under the
power-off limits instead of being refused.

## The native lock-screen provider and Space selection

With **Animate lock screen**, the sandboxed extension owns the system Desktop provider,
so the still frame Mission Control shows comes from the extension, which keeps
animating for 15 seconds after its first frame before holding it
([lock-screen.md](lock-screen.md#how-the-surface-behaves)), and poster sync has nothing
to do. `suspendForNativeProvider` stops every poster write, cancels the timers and
drops the per-layer state, but keeps the poster file and the journal because the
native provider journals the current poster as the original it will restore. Poster
sync restarts when the provider releases the desktop, and is not started while one is
active or an animated lock screen is on its way to taking it. A screen saver chosen on
its own leaves poster sync running. For restoration order at quit with the provider active, see
[lock-screen.md](lock-screen.md#turning-it-off).

A display with a different wallpaper for each desktop scopes its fresh posters to the
visited desktop and holds them while it has no current target; the other desktops, and
the current one until a fresh poster is taken, get the last poster of their own wallpaper
([pictures of the other desktops](spaces.md#pictures-of-the-other-desktops)). Its windows
stay on the current desktop, so Mission Control shows each desktop's picture rather than
the live window. The context bookkeeping that rejects late frames is in
[spaces.md](spaces.md#poster-ownership-and-late-frames), and the mode's conflict with
the animated lock screen in
[spaces.md](spaces.md#focus-mirroring-and-native-lock-screen-ownership).

## Verification

`DesktopWallpaperTests` cover posters, timing, refusals, originals, quit and the
switch's restore with synthetic pixels and an in-memory workspace that never touches
the user's wallpaper;
the inventory is under [Posters](../testing/coverage.md#posters-mission-control). What
Mission Control actually shows, its refresh latency, and macOS accepting and restoring
the native selections are not covered and need an authorized desktop run
([manual smoke](../testing/manual-smoke.md#native-desktop-posters-and-mission-control)).
