# Lock screen and screen saver (experimental)

The app can animate the macOS lock screen and use applied wallpapers as the
screen saver. Both choices are off by default and require macOS 26 or later. The
file exchange between the app and the sandboxed extension is specified in
[architecture](../architecture.md#lock-screen-extension); this document describes
what the user gets and the rules that keep the two native modes consistent.

## Enabling it

Apply a video or live scene to a display, then enable **Settings → Desktop & Lock Screen →
Animate lock screen**, or the same switch on the welcome guide's Preferences page
(it applies at once there too; the guide's **Skip** turns it back to what it was
when the guide opened). A status row next to the Settings switch reports the
current state, and a **Retry** action appears when activation failed.

### How the surface behaves

This uses a sandboxed native wallpaper extension (the [`Extension/`](../../Extension)
ExtensionKit target) rather than drawing an ordinary app window over the login UI.
While it is active the native desktop remains a still frame, while the existing
desktop renderer keeps playing. That still frame is what Mission Control shows, so
an unlocked lock-screen surface keeps animating for 15 seconds after its first
frame (`WallpaperPresentationAuthority.desktopSettleBudget`) rather than holding an
intro's opening (often black) or a setting before it has faded in. A new wallpaper
or changed setting replaces the renderer and settles again; the periodic Mission
Control update in Settings does not apply in this mode. Nor does the Settings switch
for using the wallpaper as the macOS desktop picture, which stays locked while the
lock screen is requested ([desktop picture](desktop-picture.md#leaving-macoss-own-wallpaper-alone)).

Once settled, the surface pauses its renderer while retaining scene state, textures
and device allocations, and reads the held frame back. That frame is committed
beneath the nonopaque Metal layer (no implicit animation) before readiness is
acknowledged, so there are real wallpaper pixels when a drawable is not yet
available or is reclaimed across sleep; later drawables cover it without a timed
fade. Scene replacement keeps this backing until a new frame arrives; clearing the
configuration or failing to start the replacement drops it. Display sleep and host
suspension pause rather than unload; locking or waking resumes the same renderer
once the display is awake, the host is active and user/power policy permits
playback. This costs more resident memory than showing a static poster, but nothing
renders continuously while paused, and resolution, frame rate and effects are
unchanged. A newly acquired surface or a changed wallpaper still needs an initial
load, macOS can show its own cached snapshot before it presents the extension, and
real lock/wake timing is OS-controlled.

Whether the display is asleep and whether the session is locked are read from the
system each time a surface decides, not remembered from a notification. A surface asks
about its own display, so one monitor sleeping does not pause the surface on another,
and a surface acquired while the displays sleep pauses as soon as its first frame
exists. Display sleep and wake, system sleep and wake, lock, unlock and the wallpaper
service's wake notice only start a re-check: at once, and again 0.25, 0.75 and 2
seconds later, because displays, the session and the video decoder do not all come
back at the same moment. A notification that arrives early, late or not at all
therefore cannot leave a surface paused or rendering for good. A newer event replaces
the checks still pending, and a surface whose state did not change does nothing.

### Where the picture sits

A scene or video sits on the lock screen and as the screen saver where it sits on the
desktop: the display's position decides how the room a Fit, Original size or small
Scale factor leaves, or the overflow of Fill or a large one, is divided (see [scene
rendering](scene-rendering.md)). Under Fit with blurred backdrop the extension, which
always draws through the scene engine, fills that room with the blurred copy, a video
included; a video the native player draws on the desktop shows black bars there and the
copy here (scaling mode 4 in `configuration.json`; an extension that predates it refuses
the configuration as invalid, and both ship in one app). The app publishes it with each scene in
`configuration.json` as an optional `framing` (`panX` and `panY`, fractions from 0 to
1). A file without it, such as one an older app wrote, reads as centred, and a copy of
the extension that predates the key ignores it and draws the picture centred; the
configuration version is unchanged. The extension reads the position, like the scaling
mode, when it builds a renderer, so moving the picture publishes a new revision and
replaces the renderer instead of updating the running one: the held frame stays
beneath it until the new one arrives, and it takes a moment longer than on the desktop.
The steps shown on the desktop while a Position slider is being dragged are not
published; the lock screen follows the release.
A position outside 0 to 1 is refused with the usual invalid-playback-configuration
error rather than drawn somewhere else. Web wallpapers fill their page and carry no
position, and a display that mirrors another is published centred, as on the desktop.

### Scene renderer

The extension draws scenes with Native Metal, the only scene renderer (see [scene
rendering](scene-rendering.md#scene-renderer)), so a scene costs the lock screen what it
costs the desktop. There is nothing to configure: the app no longer publishes a renderer
choice, and a `sceneRenderer` key in a configuration an older app wrote is read past, whatever
it names. After the first frame the extension logs `Backend display=… drew=native Metal`.

A scene the native renderer cannot draw is held, as on the
desktop ([scene rendering](scene-rendering.md#when-native-metal-cannot-draw-a-scene)):
the engine puts no other renderer behind it, and the surface keeps what it shows,
the last frame or, when it has drawn nothing yet, the project's preview picture (a
sublayer of the surface's Metal layer, so it is part of the context WallpaperAgent
hosts). The extension listens to the engine's first-frame and render-failure edges, which
a held scene raises too, instead of waiting out the 30-second first-frame deadline, and
replies that the surface is ready: the lock screen stays on the picture. It logs
`Held display=… stage=<stage> reason=<reason>` once, and writes the failure
into the readiness file as `held`, a note in the extension's own language. It is not an
`error`, which would make the app restore the original wallpaper: the app waits for the
frame as usual, keeps the lock screen on, and appends the note to the lock screen's
status line ("Enabled for 1 display(s) — Native Metal can't draw this wallpaper: …"). A
scene whose frame fails after it drew has nothing to replace, since the surface already
shows the last frame; the extension logs it the same way and the note reaches the app
with the next readiness it waits for. Snapshot requests for a held scene that has drawn
nothing answer with the extension's usual "frame is not ready" error.

### Plain video wallpapers

A plain video plays on the lock screen and as the screen saver with the same players as the
desktop, and with nothing else: the scene engine is never given a video. The app publishes a
video project as `plainVideo` and, when it finds the clip, its file as `nativeVideoFile` (a path
inside the project, only for a regular file that lies in it; a scene, a web page, a missing file
or a configuration an older app wrote has none, and a copy of the extension that predates the
keys ignores them). The extension plays the clip in an AVFoundation layer in its own layer
tree, decoded in hardware. The configuration version is unchanged.

The players take a clip only where the desktop's do: it is judged by the same
admission rule (`NativeVideoAdmission`, compiled into both targets), which is about the file
alone. The clip plays at its own frame rate whatever rate the lock screen was given, because an
AVFoundation layer cannot be capped. A clip AVFoundation cannot open is tried with the app's own
Matroska reader: a WebM or Matroska file it plays (H.264, HEVC and VP9 in it, and AV1 with
hardware decoding) is played by `LockScreenWebMPlayer`, the desktop's `WebMPlayer` without sound
in the extension's layer tree (the extension logs `Backend display=… drew=WebM video`), with the
same planner and deadline as the AVFoundation layer.

A clip neither player takes (VP8, a damaged or unreadable file, a file the app could not find) is
held, like the desktop's failed video: the surface keeps the frame it shows (nothing, when it
never showed one), the host is told a picture exists so it does not wait out its deadline, and
the extension logs `Held display=… stage=video reason=…` once and puts the same reason, in its
own language, in the readiness the app reads, where it appears as the lock screen's note.
Whether the sandboxed extension can use VideoToolbox's supplemental VP9 decoder has not been
checked on a lock screen; if it cannot, a VP9 clip is held the same way. The same happens if a
player fails after it started, or a resumed player does not advance within four seconds: the
player is stopped and the last frame stays. The attempt, from the decision to the first frame,
has its own 10-second deadline, well inside the 30-second first-frame deadline, so the failure is
reported while the host is still waiting. A held clip is not retried while its scene is
unchanged; a different file, a replaced revision or a new frame rate that replaces the renderer
tries the players again. A failure that arrives before the surface has taken its handler is held
and delivered when it does. A change of the frame rate keeps a player, since the clip does not
follow it; a change of the file replaces it.

The clip is never heard. The player (either one) is built from the video track alone, so no audio is decoded,
no audio output or session is opened, it is muted as well, and it asks neither to keep the display
awake nor to become the system's playing media. The picture is placed by `NativeVideoLayout`, the
rule the desktop's native player and the scene engine share (Fit, Fill, Stretch, Original size,
the scale factor), and, like the desktop's native player, it applies the position the app
publishes as `framing`. The surface pauses the player exactly when it pauses the scene engine,
for the same reasons, and a paused player decodes nothing and keeps its last frame on the layer.
The frame the system asks for in a snapshot, and the one held behind the layer, are read through
an image generator for that one request (for a WebM clip, decoded from one key frame of the file);
nothing is read between requests. The extension reads the
file through the exchange-directory access it already has.

### Display changes

Topology refreshes stage the next complete configuration before
replacing the previous one, so no empty manifest is published between a one-display
and a two-display mapping, and the committed enabled state stays until the new
mapping's first frame is acknowledged (or deactivation rolls a real failure back to
disabled). If Core Graphics temporarily cannot resolve a display the bridge still
names, during wake or a lid change, the committed manifest and native selection stay
untouched and that gap is not an error: while no earlier error is pending, the
status monitor retries the same scene set once the topology settles. While the Mac
is locked or no display is awake, a committed display the bridge no longer names keeps
its lock screen too: Core Graphics lists no sleeping display as active, and an
external display can drop off while it sleeps, so applying that departure would hand
its lock screen back to macOS just before the user wakes it. The first check after
the Mac is unlocked with a display awake applies a departure that is still there. A real earlier
compatibility or restoration error is left in place and the monitor stays stopped
until an explicit retry succeeds. Removing the last wallpaper, disabling both modes,
and shared publication or renderer failure recovery clear the manifest. If macOS
reacquires the same `WallpaperID` on the same display at a different size or scale,
the extension keeps its remote context and backing frame and rebuilds the renderer at
the new pixel size; geometry stays local to that display, a changed aspect ratio can
briefly stretch the old frame, and invalid dimensions are rejected before the
existing renderer is touched. Whether macOS keeps a context after an acquire error is
unverified.

### Audio, media and the Enabled state

Lock-screen audio, audio input and media integration are disabled (see
[Audio response](audio-response.md) and [Media integration](media-integration.md));
the bridge exports lock-screen scenes with media off and the extension turns audio
and media off again after applying the configuration, so a desktop Scene that uses
now-playing does not keep that feed on the lock screen.

"Enabled" is not claimed optimistically: it requires the system extension to
acknowledge a rendered frame. Every snapshot refreshes the service, so refreshes
arrive while that frame is awaited; one that interrupts the wait neither claims
Enabled nor publishes the activation again, but waits on for the same revision until
the original deadline (35 seconds), and only a confirmed activation saves the setting
for the next launch. The extension answers macOS only once that frame exists, and
WallpaperAgent abandons an extension that has not answered after about 31 seconds
(observed on macOS 27.2), so a scene must reach its first frame well inside that; see
[startup costs](../testing/runtime-regressions.md#startup).

## Use wallpaper as screen saver

Enable **Settings → Desktop & Lock Screen → Screen saver → Use wallpaper as screen saver**. Each
display follows its applied wallpaper and committed properties, including scene,
video, web and still-image/pixiv projects. Committed means saved: a property edit
that the desktop only shows while it is made ([edits on the
desktop](wallpaper-properties.md#showing-edits-on-the-desktop)) reaches the lock screen and
the screen saver with **Apply changes**.

This control owns only the system's **Idle** selection. **Animate lock screen** owns
**Desktop**; either can be enabled or disabled without changing the other's
selection, and the screen saver does not require the lock-screen switch. macOS still
controls idle timing, password requirements and dismissal; the app changes none of
those settings.

### Global overrides

macOS can keep all-displays overrides, including its default
screen saver, which take precedence over individual display choices. Enabling either
mode journals and removes only that mode's global override. A combined global choice
becomes Desktop-only for the screen saver or Idle-only for lock-screen animation;
enabling both removes the global override until restoration.

### Linked default provider

The built-in `default` provider can link desktop and
screen saver into one choice, globally or for a display. The app separates that
choice while either mode is active and preserves the other mode. Disabling, quitting,
or recovering after a crash restores the original linked configuration, including
inherited display settings; later changes made in System Settings are preserved
instead of relinked over. Other linked providers are unsupported and prevent
activation: the app reports the conflict instead of overwriting those choices.

### Complete display overrides

New display overrides, including those inside
Spaces, contain both the Desktop and Idle choices even when only one mode is enabled;
the unselected one comes from the inherited system selection or its restoration
journal. macOS rejects the entire wallpaper store if an `individual` override omits
either field, and a lock-screen-only override with no Idle field prevents the renderer
from starting. Temporary overrides return to inheritance on disable or recovery,
unless a later external choice needs to be kept.

### Selected is not rendering

"Selected" means the native choice was committed, not
that a screen saver has started: macOS may acquire an Idle-only surface only when it
starts the screen saver. A later renderer failure is shown beside the setting, and
restoration preserves choices changed elsewhere. If both modes are requested and the
lock-screen frame acknowledgement times out, only Desktop is restored; the app
publishes a new Idle-only revision and keeps the screen saver selected, also when
restoring saved preferences after an update or relaunch. The lock-screen error stays
visible without turning off a previously saved lock-screen preference. Automatic
updates keep the screen saver's wallpapers and pause state current but do not retry
the failed lock screen; its **Retry** action, or explicitly enabling its switch,
starts a new attempt, and late reports for the abandoned revision cannot overwrite
the screen saver's state. Retry preserves the last committed display mapping, and
turning the screen saver off restores its Idle choice immediately even if a display
UUID is temporarily unavailable during wake.

Both modes share the publisher and extension. Configuration-loading errors,
unresolved extension conflicts, reported renderer failures, and failed publication or
restoration can roll back both selections.

### Web and still wallpapers

Web and still wallpapers use a live WebKit layer tree, not a recorded video or a
periodic screenshot. Only their staged project and referenced imports are granted file
access. Audio, media integration, camera/microphone/display capture, interaction and
author dialogs are disabled. Pause freezes page execution and retains the compositor
tree; it does not resume playback the user paused. Web projects remain unsupported for
**Animate lock screen**; that combination is reported as not applicable.

## Caveats

- **Different wallpaper for each desktop** and animated lock-screen wallpaper require different
  Desktop ownership. Settings prevents enabling both for an active independent
  display; choose another automatic mode or turn animated lock-screen wallpaper off.
  Screen-saver-only mode can still use the currently applied content. See
  [Space-based wallpaper choices](spaces.md).
- It requires macOS 26 or later. On earlier releases the app does not start the
  service, Settings reports "Requires macOS 26 or later", and the extension refuses
  the system's connection: the private protocol it speaks has only been verified on
  macOS 26 and 27.
- It uses private macOS wallpaper APIs and wallpaper-store formats that may change;
  it may stop working after an OS update, and rendering is not guaranteed on every
  macOS release.
- Lock-screen animation replaces Desktop; screen-saver playback replaces Idle.
  Selection changes reload the wallpaper service, and unsupported per-display
  configurations are rejected rather than converted destructively.
- Playback respects the pause and battery settings, and the reduced-quality frame
  rate that Low Power Mode, heat or a low battery can ask for. Only the frame rate
  reaches the lock screen and the screen saver: the lock-screen export carries no
  render scale, so they draw at the surface's own resolution whatever the render
  scale is. The [2D scene resolution](performance.md#2d-scene-resolution) is not
  carried either: the extension never sets it, so a 2D scene there is rasterized at
  its canvas size, the engine's own default. The lock screen covering the desktop does not pause it. A change made
  while the Mac is locked has not been exercised.
- The extension answers the whole private wallpaper-service protocol, 21 requests on
  macOS 27.0. macOS drops the connection of an extension that cannot answer a request,
  or answers it with another reply type, and the service also sends requests
  WallpaperMachine has no use for: downloads, skipping shuffled content, context-menu
  items, added wallpapers, migration and debugging. Those get an immediate "nothing to
  do" reply; the service's own wake notice makes every surface re-check whether it
  should be presenting, and its time-change notice is ignored.

## When activation fails

If the renderer fails, or misses the extension's own 30-second first-frame deadline,
the extension writes the reason to its readiness file and the status row shows it.
Configuration-loading failures and incompatible extension copies produce a specific
error without waiting for the timeout: the app publishes `activation-request.json`
alongside the manifest and the extension answers in `extension-status.json` with the
activation revision, its bundle path, supported configuration version and any loading
error. Reports for an earlier revision are ignored, and a successful configuration
report is not frame readiness. For older extensions that cannot send this report, a
timed-out activation checks the current user's running extension paths and identifies
a different app copy when one is found; otherwise the generic "macOS did not load the
lock-screen renderer" message means no matching frame acknowledgement arrived. A
renderer the user switched off in macOS is told apart earlier still, while registering,
and stops activation at once ([App copies and registration](#app-copies-and-registration)).

The extension keeps a bounded log at
`~/Library/Application Support/WallpaperMachine/LockScreenExchange/extension.log`
(included in the [diagnostics report](diagnostics.md#diagnostics-report)). The app and
extension exchange files only in that directory, never through the extension's
sandbox container, so macOS does not ask the app for access to another app's data;
the extension removes files earlier releases left in that container. Startup and
first-frame failures stop the surface and invalidate its context rather than leaving
the last backing frame hosted as a successful replacement. A retry with the same
wallpaper identity creates a new generation, a healthy same-identity update keeps its
context, and completion or readiness callbacks from an older generation cannot remove
or acknowledge its replacement.

### App copies and registration

Every copy of the app on disk can register the same
extension identifier, including Debug builds and worktrees. Before activating either
native mode, WallpaperMachine reconciles registrations to the **currently running
app**: it validates its bundled renderer, lists all versions and physical copies with
`pluginkit -m -A -D -v -i app.wallpapermachine.wallpaper-extension`, registers its own
app and extension, unregisters other copies of the same app from LaunchServices and
PlugInKit, then reads the registry again to confirm only its own extension remains.
An already correct registration is left alone. App bundles, worktrees and build
output are preserved, so Release and Debug copies can stay on disk. A missing or
invalid current renderer stops activation, an unrelated bundle occupying an old
registration's path is never unregistered, and failed discovery never authorizes
cleanup.

Registration commands run off the UI thread with cancellation and a ten-second
deadline each. Registration never changes extension elections, resets the system
registry, installs apps or restarts app copies. Snapshot refreshes share an
in-progress attempt (neither restarting it nor resetting the automatic recovery
limit), and changing a native-mode switch or shutting down cancels pending
preparation before it can publish. Registration alone does not establish playback:
activation still waits for the matching first-frame acknowledgement.

The same registry listing carries the user's election for the renderer as the first
character of each line (`pluginkit(8)`): blank when the user never chose, which is the
normal state, `+` to use it, `-` to ignore it, `=` superseded, `!` for debugging.
Only `-` on this app's copy is acted on. If it reads `-`, activation stops before
anything is published, without the 35-second wait, and the row says macOS has the
renderer switched off and Retry turns it back on. Retry, from either the lock-screen
or the screen-saver row, then runs `pluginkit -e use -i
app.wallpapermachine.wallpaper-extension` once and reads the registry again; if macOS
still reports the renderer ignored the row says so and points to System Settings, and
every further Retry tries once more. That command is the only place the app changes an
election and it runs only for that click: the monitor, snapshot refreshes, a relaunch,
switching a mode off or on (the offer is also dropped once both are off), a different
earlier failure and a click that finds nothing to activate never run it.
The other marks are logged and do not stop activation. The repair is skipped when this
copy's election is not `-` (for example after the user switched it on in System
Settings). It leaves the election at `+`; `pluginkit -e default -i
app.wallpapermachine.wallpaper-extension` clears it again.

Once the registry confirms this app's extension (never after a failure or a
cancellation), activation ends leftover renderer processes. macOS can hand requests to
an extension process that is already running instead of launching the registered
binary, so a helper left behind by another copy or by an earlier build stalls
activation until it is gone. The app lists this user's processes of the extension
executable, identified by the kernel-reported path, the bundle identifier and the
process start time, and ends those that cannot serve the registered copy: a process
running from a different bundle, or one whose executable was replaced in place after the
process started. A replacement shows either as an executable created or modified after
the process started (a rebuild) or, for a copy that keeps its source's file dates
(`ditto`, `cp -p`, Finder over an existing file), as a running build UUID that is not
among the registered executable's (compared as described below). An unreadable build on
either side keeps the process.

A process whose files are gone is the state an in-app update leaves behind: the
updater renames the old app aside and deletes it before the new one opens, so macOS no
longer reports a path for the old helper, which keeps running until its idle grace
ends. Such a process is recognised by its name, its owner and the build UUID the kernel
recorded when it started (`proc_pid_rusage`), which stays readable after the file is
deleted. It is ended when that UUID is not among the UUIDs (`LC_UUID`, one per
architecture slice) of the registered extension executable, which the app reads from
disk. File dates are not used for this: `ditto`, which the updater copies with, carries
the release's own file dates into the installed copy, and those are normally older than
the moment the old helper started. A process that runs the same build as the registered
executable, or whose build or the registered executable's cannot be read, is left alone
and logged at debug level. A process that has already exited and is only waiting to be
collected is not listed.

Each ended process gets SIGTERM and up to two seconds to exit; only survivors get
SIGKILL. Before every signal the app reads the pid again and sends it only if the
executable path (or, without one, the name) and start time still match, so a reused
pid is never hit. Only the extension helper that ExtensionKit starts again on demand is
ended: the app, other app copies and WallpaperAgent are never signalled. Ending a
process is best effort: a refused signal is logged and activation continues to the
timeout diagnostics below.

macOS can rediscover a copy after a build or launch, so unregistering it is not a
permanent exclusion. If a current diagnostic (or a legacy timeout's process-path check)
identifies another copy, the app restores its owned selections and makes one fresh
activation attempt with a new revision, repeating registration repair and ending
leftover renderer processes again. If that also fails, it restores the selections and
shows **Retry**; close other running copies before retrying. Ordinary two-second
refreshes do not rewrite registration. Startup logs include the extension bundle path
and configuration version, because checking only the identifier does not prove which
copy macOS loaded.

### Idle exit

The extension exits 30 seconds after its last wallpaper-service
connection closes, provided no lock-screen, screen-saver or preview surface is alive;
a new connection or surface in that window keeps it. Without this, RunningBoard hands
an already-running extension process to WallpaperAgent even after macOS has
registered another copy (an update or another build). That process never receives the
new connection, and WallpaperAgent processes requests one at a time, so each System
Settings query stalls for about 30 seconds while wallpaper choices, the lock screen
and the screen saver wait behind it. Activation ends a process from an older build that
lingers (see [App copies and registration](#app-copies-and-registration)), and macOS
starts the registered copy on the next request. That includes the helper left by the
in-app updater. A process that cannot be told apart from the registered build (the same
build, or one whose build cannot be read) is left alone; quit it with
`pkill -x WallpaperMachineExtension` or log out.

### What the logs record

Beyond failures, the extension and the app log a few measurements, so that decisions
about the private wallpaper-service requests rest on what real activations do. They
change no behavior, and none has yet been read from a real activation, so this page
states no latency or request finding.

In `extension.log`:

- `Acquired id=... firstFrameAfter=3.4s`: the time from the request arriving to the reply
  that carries the surface, which is when WallpaperAgent receives its first frame. From
  10 seconds the line adds `(slow)`, and from 20 seconds `(near limit)` together with
  `First frame took 21.0 s; WallpaperAgent gives up at about 31.0 s`. WallpaperAgent was
  observed to stop waiting after about 31 seconds on macOS 27, and the extension's own
  deadline is 30. A failed acquire logs `Acquire failed display=... after X s: <reason>`.
- `Connection closed pid=... served=K open=M surfaces=S`: one line per wallpaper-service
  connection, with the requests it carried, the connections still open and the surfaces
  still alive. `served=0` is a connection that opened and closed without asking for
  anything. Nothing acts on it.
- `Request shape acquire: <type> destination destination.size ...` (and `update`): the field
  names an acquire or update request carries, once per distinct shape per launch. Only
  names are recorded, never what they hold: no paths, titles, identifiers or sizes; dictionary
  keys and set members, which are data, are left out, and a name that is not a plain
  identifier shows as `?`. The line is capped in length.
- `Held display=… stage=… reason=…`: the scene engine could not draw the scene with Native
  Metal (nothing else may), or the extension's players could not play a video (`stage=video`),
  so the surface holds its last frame or its preview picture. Once per failure. See [Scene
  renderer](#scene-renderer) and [Plain video wallpapers](#plain-video-wallpapers).
- `Backend display=… drew=native Metal`: once per surface after its first frame.
- `Backend display=… drew=AVFoundation video`: the first frame of a plain video came from the
  AVFoundation player (`drew=WebM video` for the WebM player); `Held display=… stage=video
  reason=…` says why a clip neither could play is held.

In the app log (the [diagnostics report](diagnostics.md#diagnostics-report) includes it):
`Native lock screen: first frame acknowledged after 4.2 s (waited from selection reload)`
is how long the app waited, from applying the selection (which reloads the wallpaper
service when the selection changed) to the first acknowledged frame, so it includes that
reload; a timeout logs `no first frame acknowledged after 35.0 s` (or adds `waited` to the
running-copy line) instead.

```sh
grep 'firstFrameAfter\|First frame took\|Connection closed\|Request shape' ~/Library/Application\ Support/WallpaperMachine/LockScreenExchange/extension.log
```

## Turning it off

Disabling either control restores only its still-owned selections. Quitting restores
both. Wallpaper and screen-saver changes made elsewhere are preserved.

If the native provider replaced a desktop poster, quit restores the native selection
first, then waits for WallpaperAgent's asynchronous reload and restores the poster's
saved original (poster ownership and the quit wait are described in
[desktop picture](desktop-picture.md#quitting)).
If restoration still fails after the wait, or takes longer than 20 seconds, quit is cancelled
and an alert gives the error; it also stays in the menu bar (and native-feature status) so the
user can retry. A failed activation
also restores native selections, but resumes live desktop playback afterward.

## Background checks and recovery

The service keeps one two-second monitor while a mode can still refresh safely,
recovery is complete, and shutdown has not begun. The timer may fire up to a second
late so the system can share the wakeup with other timers: its tick only reconciles
state that has no notification of its own (a battery pause, a new Space, a choice in
System Settings), and it never fires early. Busy refreshes keep the timer but
skip its work; an active request with no wallpapers still checks for a later
wallpaper; disabling both modes or shutting down cancels the timer immediately. A
shared error stops automatic monitoring until an explicit retry or another existing
refresh path succeeds. A lock-screen-only acknowledgement timeout does not stop
monitoring the retained screen saver, and those checks never restart the failed
lock-screen attempt; disabling the screen saver in that state stops the monitor until
either mode is explicitly reactivated. A pending display-identity lookup does not
clear an error and does not by itself start the monitor; with no error, the same timer
retries an unchanged scene set when the identity resolves.

A library refresh, explicit wallpaper reload or managed-asset change invalidates the
content check even when project paths and options stayed identical. The publisher
recalculates its asset fingerprints: changed bytes produce a new immutable
publication, while identical scene records keep the current revision and do not
reload the extension.

A failure a later attempt can get past does not hand the wallpapers back when it
hits modes that are already committed and still requested: WallpaperAgent rewriting
its store between the app's read and write, WallpaperAgent between a restart and its
relaunch, or no first frame within the readiness wait. The committed selection stays
on the lock screen and the monitor publishes again after 2, 4, 8, 16 and 32 seconds,
the status keeping its last progress text. A sixth failure in a row is reported and
restored like any other, with **Retry**. A first activation, a switch change and every
other failure report at once, as before. A write that lost the race to WallpaperAgent
wrote nothing, so the selection's next attempt does not count the fields it was about
to take as its own (it would read them as changed outside the app); the recovery
journal keeps them on disk.

macOS keeps a lock-screen renderer whose process ended (a crash, or a process ended
from outside) as its wallpaper and never asks for it again: every update to it fails
and the lock screen stays black. The extension names its process in each readiness
file (`processID`), and the app watches the processes that acknowledged the committed
lock screen with a process-exit source, never by polling. When one exits, the app
publishes the same scenes as a new revision, which makes WallpaperAgent load the
renderer again, and waits for its first frame. A process macOS started in its place
that has already drawn the committed revision is watched instead. More than three
exits within ten minutes restore the system wallpaper with "The lock-screen renderer
stopped repeatedly" and **Retry**. An extension copy older than the field is not
watched.

Repeated checks do not rewrite an unchanged recovery journal. New Spaces, choices made
in System Settings and wallpaper-service reloads all rewrite the system wallpaper
store, so each check compares only the store file's identity (device, inode, size,
modification and change times) and rereads the store only after one of them moves;
unchanged inputs also skip the compatibility check. A revision-only store update may
still need a service reload. The recovery union is persisted before the store changes
and pruned only after a successful reload; failed writes, reloads or journal removal
keep it for retry, and a malformed saved linked or inherited baseline fails recovery
before the store changes or the journal is removed.

macOS copies the extension's selection into the fallbacks it reloads (`SystemDefault`
and each Space's `Default`), and a Space created while the feature is on, a new
desktop or a full-screen app's, starts from those copies, so the live store has no
native choice left to restore it to. Such a Space is taken over like any other, with
originals taken from the journaled originals of those fallbacks, and restored to them
when the feature turns off. A Space created after the last check, just before the
feature turns off, was never journaled; turning off still restores its Default and the
journaled displays' nodes the same way, and keeps the journal for a retry if nothing
native is left to restore them to.

## Storage

Native wallpaper assets are isolated copies, using APFS clones where available, and
still require additional disk space. Scene and video wallpapers publish the assets
they reference as immutable `revisions/<fingerprint>/` trees in the exchange
directory (see [User-selected files](user-files.md)
for chosen files); web projects receive a separate read-grant root containing only
that project's referenced managed files.

Snapshot paths are relative to enumeration depth, not the textual spelling of
the source root. System directory aliases and linked ancestors therefore keep
nested asset names intact instead of duplicating part of the project path.
The source directory itself and enumerated assets still cannot be symbolic
links or special files; this does not broaden the extension's read grant.

## Verification

The offscreen suites (service, selection journal, extension registration, frame
backing, presentation authority, the protocol comparison, and the screen saver's
native-context/WebKit surface) are inventoried under *Lock screen* in
[coverage](../testing/coverage.md). They never mutate LaunchServices or PlugInKit and
select no real wallpaper. Real idle transitions, password UI, multi-monitor compositor
delivery, sleep/wake visuals, live registration repair, ending a genuinely stale
extension process, macOS choosing the intended extension, switching a really ignored
renderer back on from Retry, the wallpaper service's wake and time-change notices
completing without an error in WallpaperAgent's log, what the timing, connection and
request-shape lines report after a real activation (see [What the logs
record](#what-the-logs-record)) and a moved picture appearing at its position on the lock
screen and as the screen saver (the extension logs `Framing display=… panX=… panY=…` each
time it builds a renderer) and the extension drawing with Native Metal (the
`Backend display=…` line) still require an authorized desktop check. So do
a plain video playing in the AVFoundation layer on a real lock screen and as the screen saver
(that the sandboxed extension may open the clip, hardware decode, the picture hosted in the
compositor's remote layer tree, resuming after sleep) and the held frame and note for a clip
the players cannot open; only the decision, the layout, the failure of the open and the
publication are covered offscreen.

### After sleep, wake, lock and unlock

Each of those events logs one line when the surfaces re-check, and a surface logs a
`Playback` line only when its paused state actually changes:

```sh
grep 'Re-checking presentation\|Playback display' ~/Library/Application\ Support/WallpaperMachine/LockScreenExchange/extension.log
```

`Re-checking presentation (display wake) surfaces=1` names the cause (`display sleep`,
`display wake`, `system sleep`, `system wake`, `screen locked`, `screen unlocked` or
`wallpaper service wake`). The `Playback ... paused=` line after it should match the real
display state, including after a wake for which no `display wake` line appears.

### After a macOS update

The first connection each launch compares the extension's declared requests and reply
types with the system's own `WallpaperExtensionXPCProtocol` (read on macOS 27.0; macOS 26
has not been compared) and writes one line to `extension.log`:

```sh
grep 'XPC protocol' ~/Library/Application\ Support/WallpaperMachine/LockScreenExchange/extension.log
```

`XPC protocol matches the system (21 selectors)` means nothing changed. `XPC protocol
drift: missing=[...] extra=[...] differing=[...]` names the requests macOS added
(`missing`), no longer has (`extra`) or now declares with another argument or reply
type (`differing`); a missing or differing request makes macOS drop the connection, so
update `Extension/WallpaperExtensionBridge.h` and `WallpaperExtension.swift` before
the lock screen is trusted on that release. A skipped check is logged as such and
changes nothing. `Unsupported request <selector> answered inertly` appears once per
request kind the extension has nothing to do for.
