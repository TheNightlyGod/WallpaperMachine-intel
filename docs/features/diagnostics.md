# Logs and diagnostics reports

How the app records what happened, and how a user hands that record to us with a
bug report. The runtime diagnostics counters used for power claims are separate;
see [power-benchmark.md](../testing/power-benchmark.md#runtime-counters).

## The application log

One log for the whole process. Swift (`App/Logging/AppLog.swift`), the Rust bridge
and core, and the C++ renderer all write into the bridge's `ApplicationLogger`
(`Renderer/Bridge/src/logging.rs`). Files live under
`<app support>/Logs/<session>/<N>.log`. Each launch is one session, named by its
start time (`20260927-150211`, `-1`, `-2`… for same-second launches).

Every line has the same shape:

```
2026-09-27T15:02:11.482+08:00 ERROR [load#7] WPSceneParser.cpp:1061 unknown tex "x"
```

- **Time**: local time with its UTC offset and milliseconds. Users report what
  their clock said, and crash reports carry their own offset. Swift lines keep
  the time they were logged, even when they were held until the bridge opened
  the log.
- **Level**, then **`[load#N]`** when the line belongs to a wallpaper load, then
  the source file and line.

### Wallpaper loads

Every wallpaper load gets a process-unique number. The load's first line is a
header:

```
… INFO [load#7] backend.rs:93 scene load: display 1 3456x2234 @2x 120Hz, fps 60, scaling fit x1, render native, paused false; project title="Rain" type="scene" version=3 workshop=123456 file="scene.json" at …/123456/project.json
… INFO [load#7] SceneWallpaper.cpp:1540 scene backend: native_metal
```

- **Scene and video wallpapers on the scene engine**: the header is written by
  `OweBackend::open_scene`, the single place every open or rebuild passes
  through. The renderer's `main` and `render` threads for that scene adopt the
  number when they start (`owe_scene_wallpaper_set_log_scope`). So a parser
  error, the backend choice and the first frame all carry it, even while
  another display is loading at the same time.
- **Web wallpapers and native video**: the Swift hosts start their own loads
  through `AppLog.beginLoad`, and their later lines pass `load:`.
- **Not tagged**: the renderer's frame timer thread and its shared
  decoder/audio threads carry no load number. Match those lines by time.

The `project.json` summary is read leniently: a field of an unexpected type is
left out, and an unreadable manifest is logged as such rather than failing
the load.

### Wallpaper activations

"Why did my wallpaper change?" is answered by one line per activation, written by
`BridgeStore` when the display's change finishes:

```
… INFO … activation: wallpaper 123456 display 1 origin playlist applied in 85 ms
… WARN … activation: wallpaper 123456 display 1 origin user failed (refused) in 12 ms
```

- **Origin** is who asked: `user` (the panel, menu bar, a hotkey, Shortcuts, a
  link, or a [Download and apply](workshop-downloads.md#download-and-apply) whose
  wallpaper has arrived), `playlist`, `automation` (a rule), `layout` (a saved
  display layout) or `updateReload` (an update loading new files, or Retry for a
  scene that stopped drawing, which loads the same files again).
- **Result** is `applied`, `noOp` (the display already showed it, so nothing was
  touched) or `failed` with a category: `cancelled`, `refused` (the app declined
  with a reason it shows in the panel) or `error` (anything else). Failures are
  warnings.
- The line names the wallpaper by its library id, never its title, and a failure by
  category, never its message: the message is on screen and may carry paths. The
  duration includes any wait for an apply already in flight.
- An update reload also writes a `reload:` line per display, with the same fields:
  `applied`, `skipped` (a newer command, usually the user's choice, took the
  display's turn or the display no longer showed the wallpaper, so the files load
  at the next update or launch) or `failed`. A
  reload that ran is preceded by the `activation:` line of its re-apply. An automatic
  change that gives way to a choice the user is waiting on logs `activation yielded to
  a waiting user choice` instead.
- The inspector's **Reapply wallpaper** writes a `reapply:` line (origin `user`,
  `applied` or `failed`) after the `activation:` line of its re-apply, so a restart
  reads differently from a plain apply. A refusal before the display was touched
  (the wallpaper's files, the display or an unfinished edit) is a `failed` line with
  no `activation:` line before it. When the display did not show the wallpaper yet,
  Reapply is a plain apply and writes only the `activation:` line.

### What each session starts with

- The logger's own line: process id and level in force.
- The saved preferences that decide how wallpapers render: render scale, battery mode, frame-rate limit, scene optimisation,
  on-demand updating and the experimental switches.
- `environment:` lines from Swift (`DiagnosticEnvironment`): app version and
  build, macOS, hardware model, CPU, core count, memory, GPU, low-power and
  thermal state, languages, locale, time zone, and each display's pixel size,
  scale, refresh rate and name.
- `previous session: …`, how the run before this one ended (see
  [below](#how-the-previous-session-ended)), and for a run that died,
  `previous session crash report: …` about 20 seconds later.
- Startup milestones (`startup: …`).

The same facts, as numbers and fixed words and without names, paths or the time zone,
are what [Send performance data](telemetry.md) reports when the user has turned it on.
Each upload, failed upload and deletion request leaves a `telemetry:` line, and so does
each day's [active count](telemetry.md#daily-active-count), sent or not.

Each time the quality settings are applied (a battery-mode, frame-rate-limit or
battery-profile change, a power-source change in reduced-quality mode, or a change
of the reduced-quality request the app makes for reasons such as heat), the
frame-rate ceiling and render scale in force are logged, with the causes of any
such request.

### How the previous session ended

A log session says what the app did, not whether it was allowed to finish. Without
that, a report about a lost wallpaper cannot be told apart from a crash, a force
quit or a restart. The **session ledger** (`SessionLedger`,
`<support>/Session/ledger.json`) keeps one record per run with a phase: `running`
from launch, `quitting` once a quit starts, `ended` as the last act of
`applicationWillTerminate`. The next launch reads the record, classifies it and logs
one line, at the very start of `main` and so before any other startup line (it is
held until the log opens and keeps its own time). The message looks like this, at
`WARN` for anything but a normal quit:

```
previous session: ended unexpectedly (a crash, a force quit or a kill) (1.3.2 (45), pid 4821); 2 of the last 4 sessions ended unexpectedly
```

| Record found | Logged as | Meaning |
|---|---|---|
| none, or a file that cannot be read | `none recorded` | first launch, or the ledger was lost |
| `ended` | `quit normally (<reason>)` | the app quit through its own shutdown; the reason is the one logged at the start of the quit ([below](#why-the-app-quit)) |
| `quitting` | `quit did not finish (<reason>)` | a quit began and the process died before it ended: a stage hung and was killed, a second termination signal ended it, the system cut the quit short, or the quit went on without a stage it gave up on (the reason then ends `; left running: <stages>`) |
| `running`, same boot | `ended unexpectedly` | a crash, a force quit, a `kill -9`, an out-of-memory kill, or a SIGTERM that arrived before launching had finished (after that it is a quit) |
| `running`, another boot | `ended by a restart, shutdown or power loss` | the machine went down while the app ran |
| any phase, with an exception named | `ended by uncaught exception <name>` | see below |

"Same boot" is exact: the record carries `kern.bootsessionuuid`, the value macOS
writes into a crash report as `bootSessionUUID`, so there is no clock tolerance to
get wrong. A boot the kernel would not name is never called a restart. The line
ends with how many of the recent sessions (the last five at most) ended
unexpectedly, a crash or an uncaught exception, and how many in a row when that is
two or more.

For a run that ended unexpectedly, `previous session crash report: <file>
(<type>/<signal>)` follows once the app has been up 20 seconds, naming the report
in `~/Library/Logs/DiagnosticReports` (`WallpaperMachine*.ips`) whose body carries
the same process id and boot session, looking through the newest eight written since
that run started. The wait is for ReportCrash, which writes the file after the
process is gone. A report that is not there, or cannot be parsed, is simply not
logged.

An Objective-C exception that nothing catches is logged before the process dies:
`ERROR uncaught exception <name>: <reason>` and one line with the top 12 call-stack
frames. The handler is chained, so one installed earlier still runs, and it writes the
exception's name (not the reason, which may hold paths) to the ledger.

What the ledger does not do: it installs no handlers for crash signals (those could clash
with the ones other libraries install, or alter the crash report; SIGTERM and SIGHUP are
a separate matter, see [signals](crash-recovery.md#signals)), writes no
heartbeat, and is not part of the diagnostics report: the line in the log is.
A normal session writes the file three times, at launch, at the start of a quit and
at exit; a quit that is refused goes back to `running`, and one that leaves a stage
behind updates its reason, which is one more each. Each write
replaces the file atomically. If a second copy of the app is started on the same
support folder, the older copy no longer touches the record. The ledger is per
support folder, so `WALLPAPER_MACHINE_HOME` copies keep their own. Hosted tests and
the import-picker helper process do not use it.

### Why the app quit

Every request to quit reaches `applicationShouldTerminate`, which logs who made it before
anything is torn down. The line is written for a request that arrives while a quit is
already running too, which is how a second Exit or a logout during a user quit shows up:

```
quit: reason=logout mode=powerOff frontmost=com.apple.loginwindow panelVisible=false updateInstallPending=false alreadyInProgress=false powerOffNotified=true appleEventReason='rlgo' signal=none
```

`mode` is how the quit behaves: `powerOff` when the reason is a logout, restart or shutdown or
macOS announced one (a signal that arrives during a shutdown is still `powerOff`), otherwise
`interactive`. A power-off quit has shorter deadlines and is never refused; see
[desktop picture](desktop-picture.md#logout-restart-and-shutdown).

`reason` (`QuitReason`) is the first of these that applies:

| reason | when |
|---|---|
| `signal` | SIGTERM or SIGHUP was turned into the quit by `TerminationSignalRelay` ([signals](crash-recovery.md#signals)); `signal=SIGTERM` in the line names it, and the session ledger keeps `terminated by SIGTERM` |
| `logout`, `restart`, `shutdown` | the quit Apple event names that kind (`why?`: `rlgo`/`logo`, `rest`/`rrst`, `shut`/`rsdn`), or macOS announced a power-off (`NSWorkspace.willPowerOffNotification`) and the event named none. The announcement cannot say which kind it is, so that case reads `shutdown`; `appleEventReason=none` in the line tells it apart |
| `update` | the updater has started its installer and is waiting for the app to quit (`AppUpdateStore.isInstallPending`). A Quit chosen while the update is still being prepared is the user's: it cancels the preparation |
| `unknown` | the event carries a reason code this build does not know |
| `user` | anything else: the menu, the Dock, another app's plain quit |

The event's reason is a parameter of the quit event, readable only while that event is being
handled, so it is read at the top of `applicationShouldTerminate` and nowhere else. A quit
that comes from a menu or from the updater has no event. The power-off announcement is
believed for 120 seconds (a judgment, not a measurement) and forgotten when a quit is
refused: nothing tells the app when another app cancels a logout, and a stale announcement
would otherwise relabel the next Quit. The reason is also written to the session ledger,
so the next launch's `previous session:` line names it, including for a quit that never
finished.

The stages of the quit are timed, also when they fail:

```
quit: stage restore took 840 ms
quit: stage services took 3 ms
quit: stage imports took 2 ms
quit: finished after 1310 ms: restore 840 ms, services 3 ms, imports 2 ms, steamcmd 1 ms, workshop 1 ms, pixiv 0 ms, bridge 455 ms
```

`restore` is the lock-screen and desktop-picture restoration, `services` stops the timers,
monitors and hosts the app runs, `bridge` is the renderer's shutdown; the others are the
import, SteamCMD, Workshop and pixiv work. The total runs from the start of the quit, so it
also counts the work between stages. The synchronous teardown in `applicationWillTerminate`
is not timed. Every stage has a deadline (`QuitSupervisor`, [budgets](../architecture.md#appkit-shell)),
and the lines say what happened when one is missed:

| Log | Meaning |
|---|---|
| `quit: stage restore took N ms and failed: <error>`, then `quit: cancelled after …` | restoration threw; the quit is refused and the app keeps running |
| `quit: stage restore had not finished after N ms and was left behind`, then `quit: cancelled after …` | restoration took longer than 20 s; the quit is refused. `Quit cancelled because wallpaper restoration did not finish within N ms` follows at `ERROR` |
| `quit: stage <name> had not finished after N ms and was left behind`, then `quit: finished without <names> after …` | a later stage outlived its share of the 10 s teardown budget; the quit went on without it. `quit: going on without <names>, which did not finish in time` follows at `WARN`. A stage that had no time left at all is still started, and logged this way too |
| `quit: stage <name> took N ms and failed: <error>` | a later stage threw; the quit went on |
| `quit: power off; desktop restoration unfinished (<why>), the poster journal will finish it at the next launch`, then `quit: finished without restore …` | a logout, restart or shutdown: restoration threw or took longer than 3 s, and the quit went on instead of being refused. The stage line before it says which |
| `quit: already in progress, this request waits for it` | a request to quit arrived during a quit and was not refused, because it was a logout, restart or shutdown or the quit running was one. The quit that is running answers both when it finishes |
| `quit: a logout, restart or shutdown arrived during this quit; going on under its time limits` | the user's quit failed to restore the desktop after such a request had joined it. Instead of being refused it is run once more with the power-off limits |
| `quit: already in progress, this request is refused` | a second user quit during a user quit. A SIGTERM that arrives during one is logged this way too: the quit that is running is the answer, and a further signal would end the app at once |
| `signal: SIGTERM received; quitting in order, and a second one ends the app at once` | the first SIGTERM or SIGHUP, logged off the main thread before it is handed to the main run loop, so a stalled main thread still leaves the reason. The `quit:` line follows when the request is handled |
| `signal: SIGTERM again, or the quit did not finish in time; ending the app by its default action` | a second signal, or the deadline for the first (37 seconds, the longest an interactive quit can take within its limits). The process ends by the signal's own action. A run whose quit had not begun is left `quitting` in the ledger with the reason `terminated by SIGTERM; ended by force`, so the next launch logs `previous session: quit did not finish (terminated by SIGTERM; ended by force)` and not a crash |
| `signal: SIGTERM and SIGHUP will end the app without a quit: <why>` | the handlers could not be installed at launch (a pipe or `sigaction` failed); the app runs, and a stop kills it as before |
| `quit: the process was still running N ms after the quit finished; ending it` | the exit fuse: `applicationWillTerminate` ran, and the process did not exit within 5 s (1 s after a stalled stage), so it was ended with `_exit` after the preferences were flushed. It is armed only once restoration is done, so it can never cut restoration short |

The summary marks each stage that did not finish as `(stalled)` and one that threw as
`(failed)`. A quit that left a stage behind does not mark the session ledger `ended`: the
record stays `quitting` with the stage named in its reason, so the next launch logs
`previous session: quit did not finish (user; left running: bridge)`. A power-off quit that
went on without restoring the desktop still ends: its reason carries the note instead, and
the next launch logs `previous session: quit normally (logout; desktop restoration
unfinished)`. A stage that stalls
is a sign of what to look at (a SteamCMD that does not stop, a renderer shutdown that
hangs), and the stage durations of ordinary quits are what its budget has to be tuned from.
### Memory pressure

macOS tells every process when the Mac's memory gets short and when it recovers. The
app writes each change to the log with the memory it was using and the scenes it was
drawing at that moment, so a report can show whether memory was short when something
went wrong:

```
memory pressure warning: process footprint 3.2 GB, 2 scenes presenting
memory pressure normal after 42 s: process footprint 2.1 GB
```

The first is a `WARN` line, the second an `INFO` line.

- **Level**: `warning` and `critical` are warnings; the return to `normal` is information
  and is written only after pressure the log reported, with how long it lasted.
- **Footprint**: the process's physical footprint, the figure Activity Monitor shows as
  "Memory" (`ri_phys_footprint`). It is for the whole app and cannot say which wallpaper
  holds the memory. When macOS does not answer the line says `unknown`, never `0`.
- **Scenes presenting**: scene wallpapers drawing or waiting to draw, as of the last
  snapshot. A scene the user paused, the system suspended or that stopped after a failure
  is not counted. Web pages and native videos are not scenes and are not counted.
- **Rate**: the same level repeated within 5 seconds is one line, measured from the line
  that was written. A change of level is always a line.

The app does not unload, pause or lower a wallpaper on screen in response, and nothing
reads a threshold: a limit would need footprints measured on real Macs and a way to tell
which scene to give up, and stopping a wallpaper unprompted is more intrusive than the
problem it guards against. The one thing pressure frees is what is not on screen: the
wallpapers a display keeps paused for its other desktops
([different wallpaper for each desktop](spaces.md#keeping-each-desktops-wallpaper)) are
let go while it lasts, which the log says in a `space parking:` line. The event source is cancelled when the app quits
and nothing polls. The lock-screen extension is a separate process, and neither
its footprint nor its pressure events are recorded.

The report's `environment.txt` includes the footprint at export time and the number of
wallpaper windows open (`process footprint 2.4 GB (physical), 6 wallpaper windows`, or
`process footprint unknown, …`), which gives the figure above something to be read
against.

### Levels and detailed logging

The default level is `info`. **Settings → Storage → Troubleshooting → Detailed
logging** adds `debug` lines. It takes effect immediately, is saved as
`diagnostics.verbose_logging` in `config.toml`, and stays on across relaunches
until turned off, so a problem that appears at launch is still captured. Every
change of level is logged. `WALLPAPER_ENGINE_LOG_LEVEL` (`error`, `warn`, `info`,
`debug`, `trace`, `off`) overrides both the default and the setting for the
process. The level applies to Swift lines too. The workshop download lines that
[Show download logs](workshop-downloads.md) depends on are therefore `info`.

### Retention

- A file rotates at 5 MB. A session keeps its newest 10 files.
- At launch, the newest 9 earlier sessions are kept as long as together they
  fit in 100 MB; every older session is removed.
- **Clear…** on the Logs row in Settings → Storage removes every session except a fresh one.

### Before the log opens

`AppLog` is callable from any thread and never hops to the main actor, so a
stalled main thread does not also silence the lines that would explain it.
Lines logged before the bridge exists are held, up to 1000, and written when it
attaches, together with a count of any that were dropped. If the bridge fails to
start, the held lines and every later one go to stderr.

The lock-screen extension is a separate sandboxed process. It keeps its own
bounded `extension.log`; see [lock-screen.md](lock-screen.md).

## Diagnostics report

**Settings → Storage → Troubleshooting → Diagnostics report → Export…** writes one
`WallpaperMachine-diagnostics-<date>-<time>.zip`, by default to the Desktop, and
reveals it in Finder. It is built off the main actor by `DiagnosticsBundle`
(`App/Services/Diagnostics/`):

| Entry | Contents |
|---|---|
| `logs/<session>/<N>.log` | Newest 5 sessions, newest files first, at most 64 MB in total. A file that would exceed the budget contributes its tail, marked `[truncated: …]` |
| `lock-screen/extension.log` | The extension's log, if present |
| `load-journal.json` | The crash-loop guard's journal, [crash-recovery.md](crash-recovery.md): the strikes per wallpaper and the scenes that were opening when the app last stopped. Wallpaper ids, display numbers, times, the build and an opaque session id; no paths. The file exists once a scene has been opened; without it the report notes that it was not present |
| `crash-reports/*.ips` | Up to 5 macOS crash reports from the last 14 days whose name starts with `WallpaperMachine` (app and extension) |
| `diagnostic-reports/*.diag`, `*.spin`, `*.hang` | Up to 5 macOS resource, spin and hang reports from the last 14 days whose name starts with `WallpaperMachine`, newest first across both report folders. See [below](#macos-resource-spin-and-hang-reports) |
| `environment.txt` | The environment lines above, read at export time, plus the saved render settings with the reasons Reduced quality holds and the frame-rate ceiling in force, the backend and live mode of each running scene (`mode stopped_after_failure` for a scene whose renderer stopped after a failure, apart from `user_paused` and `policy_suspended`; see [scene rendering](scene-rendering.md#a-scene-that-stops-drawing)), the state of each wallpaper window with whether the displays have separate Spaces ([below](#wallpaper-window-state)), and the app's memory footprint at export time ([above](#memory-pressure)) |
| `README.txt` | What is included, what was missing or skipped, and what was redacted |

Everything except `README.txt` passes through `DiagnosticsRedactor` first:

| Replaced | With |
|---|---|
| The home folder path, including its `/private` and `/System/Volumes/Data` forms | `~` |
| The macOS short and full user name | `<user>` |
| The saved Steam account name, and the name in SteamCMD's `Logging in user '…'` | `<account>` |
| Values of authorization, cookie, password, secret, session id, Steam Guard, token and similar keys, in `key=value`, `key: value` and JSON forms | `<redacted>` |
| The value of the `Beta Identifier:` line of a macOS resource report, a GUID that is the same in every report from this install | `<redacted>` |
| The Mac's host name in the file name of a macOS resource report | Dropped from the name stored in the zip |

Names are replaced only as whole tokens. Wallpaper titles, Workshop IDs and file
names inside the library are kept: those are what reproduce the problem.

### macOS resource, spin and hang reports

A crash report exists only for a process that crashed. macOS also writes a report
when the app writes too much to disk, burns too much CPU, or stops responding, and
those name the code that was running. On macOS 27 they are not in the user's
`~/Library/Logs/DiagnosticReports` but in `/Library/Logs/DiagnosticReports`, as
`<process>_<date>_<host name>.diag` (`.cpu_resource.diag` for CPU). Spin and hang
reports use `.spin` and `.hang`. That folder is `root:_analyticsusers`, mode
`rw-rw----`, so it is listable only by an account in the `_analyticsusers` group.
Older macOS releases wrote them to the user folder, so the export looks in both.

- **Which files**: regular files directly in either folder (so `Retired/` is
  skipped) whose name starts with `WallpaperMachine`, which also matches
  `WallpaperMachineExtension`, with one of those three extensions, modified inside
  the last 14 days and not in the future. The same window as crash reports. `.ips`
  files stay under `crash-reports/` and are read from the user folder only.
- **How many**: the 5 newest across both folders. A report over 4 MiB contributes
  its tail, marked `[truncated: …]`. Real ones are 20 to 30 KB.
- **Classified by name, never by content.** The body differs between macOS releases,
  so it is redacted and copied, not parsed.
- **Stored name**: the host name is dropped (`WallpaperMachine_2026-10-10-193707.diag`),
  because a Mac's host name is usually its owner's name and the redactor only knows
  the account's names. Two reports that end up with the same name get a `-2`.
- **Not readable**: if the system folder cannot be listed, the export still succeeds
  and README.txt says `macOS resource reports were not readable (the account may not
  be in the _analyticsusers group)`. Reports from the user folder are still included.
  If both folders are readable and empty, it says there were none in the last 14 days.
- **Left out on purpose**: jetsam (memory-pressure) events. They list the other
  processes that were running, which a bug report should not carry.

Bug reports on GitHub use the issue form in
`.github/ISSUE_TEMPLATE/bug_report.yml`. It asks for the Workshop ID and requires
what the reporter did, what went wrong, what they expected and the exported
report. It points to Detailed logging for problems that are hard to reproduce.

### Wallpaper window state

`environment.txt` ends with one `desktop windows:` line (how many wallpaper
windows are open, and whether the displays have separate Spaces) and one
`desktop window …` line per window of the three kinds that host wallpaper
pixels (the scene renderer, web and native video windows). It tells "the
process died" apart from "the window exists but is not shown":

```
desktop window MWEWallpaperDesktopWindow #1234 display 1: frame (0,0,3456,2234), display frame (0,0,3456,2234), level -2147483623, collection behavior 0x51, alpha 1.0, ordered in yes, active Space yes, occlusion visible yes; window server: layer -2147483623, alpha 1.0, on screen yes, bounds (0,0,3456,2234); state ok
```

AppKit's view (frame, level, ordered in, active Space, occlusion) and the window
server's view (layer, alpha, on screen, bounds, which are in CoreGraphics
coordinates with the origin at the top left) are read once, at export. The
server side is one `CGWindowListCreateDescriptionFromArray` call for the app's own
window numbers: no window list scan, no polling and no Screen Recording
permission. Titles are never read. The last field names the first fault that
applies, in this order:

| `state` | Meaning |
|---|---|
| `notOrderedIn` | AppKit does not consider the window ordered in |
| `absentFromWindowServer` | The window server has no entry for the window number (`window server: absent`) |
| `notOnActiveSpace` | Ordered in on a Space that is not showing |
| `offScreenInWindowServer` | AppKit says shown, but the window server does not list it on screen |
| `outsideItsDisplay` | The frame does not intersect its display (`display ?` when the window is on none) |
| `transparent` | The window's or the window server's alpha is below 1 |
| `ok` | None of the above |

A state is an observation, not a verdict: inside another app's full-screen Space
the wallpaper windows legitimately read `notOnActiveSpace`. Whether any of these
faults explains a missing wallpaper on a given Mac is not established here; the
lines exist to show which one a report has.

### Desktop window audit

The export reads the windows once. The running app also looks at them after an
event that can move a window, and writes a warning to the application log when
one is not showing. It never polls.

| Trigger | Looks at |
|---|---|
| A Space change, the Mac waking, the displays waking, the wallpaper resuming after the policy paused it (an unlock, for one), or a display added, removed or moved (screen changes that leave every display as it was are ignored) | +1 s and +3 s |
| A wallpaper window the app had not seen (a wallpaper opened, or the window was rebuilt) | +1 s, +2 s and +5 s |

A new trigger replaces a schedule that is still waiting. Each look uses the
state table above and ends the audit at the first look where every window is
`ok`. Nothing is written for a healthy audit.

The audit says nothing, and repairs nothing, when no window is expected to show:

- the presentation policy has paused or unloaded the wallpaper (display sleep,
  session lock, an app rule, or other-app audio set to pause);
- for `notOnActiveSpace` and `offScreenInWindowServer`, the window's display is
  in a full-screen app's Space, which the Space monitor reports as having no
  current desktop. Where the Space topology cannot be read, the fault is
  recorded.

A fault the Space does not explain (`outsideItsDisplay`, `transparent`,
`notOrderedIn`, `absentFromWindowServer`) is recorded in every Space.

```
desktop window audit: display 1 MWEWallpaperDesktopWindow #1234 is notOnActiveSpace at +1s after activeSpaceDidChange; desktop window MWEWallpaperDesktopWindow #1234 display 1: …; state notOnActiveSpace
desktop window audit: display 1 MWEWallpaperDesktopWindow #1234 is still notOnActiveSpace at +3s after activeSpaceDidChange, after 0 repairs
```

The first line carries the same window line as the report. The second is written
at the last look when the fault persists. A report of the same fault on the same
window is not repeated within 60 s.

**Repair is off by default.** Setting the hidden preference
`WallpaperMachine.reassertDesktopWindows` to true
(`defaults write app.wallpapermachine WallpaperMachine.reassertDesktopWindows -bool YES`;
it is read at each look, so no relaunch is needed) lets each trigger apply at most two
steps to a faulty window, one per look and only while it is still faulty:

1. order the window front;
2. set its level and collection behavior to what the app opens it with, then order it front.

Each step is logged (`repair 1 (order front) applied to …`), and so is the
recovery (`every wallpaper window is showing again at +3s after … , after 1 repair`).
The windows are the app's own, so nothing here needs the Accessibility permission.
The default is off because moving windows can make the window server recompose and
the fault has not been seen on macOS 27.x. Whether to turn it on waits for a log from a
Mac that shows the fault.

### Wake check

After the Mac wakes the app confirms that its scenes draw again
([performance](performance.md#playback) has what is checked and what is left alone). A
healthy wake writes information lines; a scene that was found stalled is a warning.

```
[wallpaper-bridge power] wake check (didWake): looking at scene surfaces
[wallpaper-bridge power] wake check: display 2 skipped (paused)
[wallpaper-bridge power] wake check: display 1 ok (frames 412 -> 598)
wake check (didWake): 1 display checked, 0 repaired, 1 skipped
```

The bridge writes the first lines while the check runs, one per display, and the app
writes the summary when it returns. A check that found trouble looks like this:

```
[wallpaper-bridge power] wake check (didWake): looking at scene surfaces
[wallpaper-bridge power] wake check: display 1 stalled (no frames in 3.0 s, frames 412 -> 412); reconfigured the surface (attempt 1)
wake check (didWake, once presentation resumed): 1 display checked, 1 repaired
```

`once presentation resumed` means the wake landed while the wallpaper was suspended (the
lock screen, usually) and the check ran when it resumed. The outcomes the bridge reports
per display are `ok`, `repaired`, `recovery_pending` (a repair was already under way),
`gave_up` (this minute's attempts are spent, so the scene stays stopped),
`recovery_failed`, and `skipped_paused`, `skipped_not_continuous` (an event-driven scene),
`skipped_unreadable` (the renderer returned no reading) and `skipped_changed` (the display's
scene was replaced while the check waited). The summary counts `gave_up`,
`recovery_pending` and `recovery_failed` as "still not drawing" and writes a warning for
them as well as for a repair. A check that fails to reach the bridge writes
`wake check (…) failed: …` and is not retried.

## Inspecting a web wallpaper

**Settings → Storage → Troubleshooting → Allow inspecting web wallpapers** lets
Safari's Web Inspector attach to the pages of [web wallpapers](web-wallpapers.md)
running on this Mac, so a Workshop page that renders wrong or logs errors can be
debugged. In Safari, turn on *Show features for web developers* (Settings →
Advanced), then pick the page from the **Develop** menu's submenu for this Mac.

- Off in a release build until the user turns it on; a debug build starts with it
  on. An explicit choice, either way, is kept in `UserDefaults`
  (`WallpaperMachine.inspectWebWallpapers`) and survives a relaunch. It is not part
  of a [backup](backup-restore.md): diagnostic state does not travel to another Mac.
- A change reaches the pages that are already running without reloading them, and a
  wallpaper or live preview opened later follows the current value. Each change is
  logged (`web wallpaper inspection enabled|disabled`).
- It covers desktop web pages and the preview in the inspector. The screen saver, the
  lock-screen extension and the control panel are not governed by it.
- While it is on, anything that can use this Mac's Safari can read the page's
  JavaScript context, including data the page keeps in `localStorage`. Turn it off
  when the debugging is done.

## Verification

- Rust:
  - `tests::wake_revalidation` (`Renderer/Bridge/src/tests/`): which scenes
    the wake check probes and repairs, against scripted frame counters.
  - `logging::tests` (`Renderer/Bridge/src/logging.rs`): line format, load tag, session and
    file retention.
  - `log_context::tests` (`Renderer/Core/src/log_context.rs`): scope nesting, project summary.
  - `settings_intents::verbose_logging_persists_across_relaunch_and_can_be_turned_off`.
- Swift: `AppLogRouterTests`, `DiagnosticsRedactorTests`, `DiagnosticsBundleTests`,
  `SessionLedgerTests`, `CrashReportIndexTests`, `UncaughtExceptionLogTests`,
  `ActivationLogTests` (the activation and reload lines, their results and failure
  categories), `QuitReasonTests`, `QuitTimingsTests`, `AppUpdateTests` for when an install counts as
  pending, `DesktopWindowDiagnosticsTests` (state precedence, line format, window server
  description parsing and the window ID array read, against injected observations),
  and `WallpaperWindowAuditorTests` (when the audit looks and stops, what it logs and how
  often, the repair ladder and its budget, and when it stays silent, with injected
  observations and delays).
  `SystemWakeRevalidatorTests` (when the wake check is asked for, deferred and
  superseded, and how its answer is logged, with injected notifications, delays and
  bridge answers).
  `MemoryPressureMonitorTests` (what each pressure level logs, the duration of a
  stretch of pressure, the 5-second collapse and an unreadable footprint, with events
  fed to the handler and an injected clock) and `ProcessFootprintTests` (the byte
  formatting, and the real footprint read of the test process, which grows when the
  process touches memory).
  `WallpaperReapplyTests` (the `reapply:` lines).
  `WebWallpaperInspectionTests` (an explicit choice wins over the build default and
  announces itself; a page is attachable only when its owner says so), and the
  running, new and preview page cases in `WebWallpaperHostLifecycleTests` and
  `WebWallpaperPreviewSurfaceTests`; `PanelGeneralSettingsTests` for the setting,
  stored, reported and kept across a relaunch.
- Not established by tests:
  - that Safari's Develop menu lists a desktop wallpaper page and attaches in a
    release build;
  - that a real scene's renderer lines carry its number on the desktop;
  - the unreadable-folder note on a Mac whose account is not in `_analyticsusers`
    (the test uses a path that cannot be listed);
  - spin and hang reports from a real hang: the fixtures are named after the
    `.diag` reports macOS wrote on this machine, and no `.spin` or `.hang` file was
    available to check the naming against;
  - what a real Dock Quit, menu Exit, update, logout, restart and shutdown put in the
    `quit:` line (the classification is tested on constructed events and flags, and a real
    `why?` parameter was never captured from loginwindow);
  - how a real force quit, `kill -9`, crash and restart appear in `previous session:` on the
    next launch: the classification is exercised on records and injected boot sessions, and
    `.ips` fixtures are modeled on the shape of a real report;
  - that ReportCrash has written the report by the time the lookup runs;
  - the Save panel;
  - Finder reveal;
  - the wallpaper window lines for open wallpaper windows (the window server read is checked
    against whatever window the session lists on screen, and skipped when there is none; the
    AppKit read against an `NSWindow` that is never shown);
  - a real memory-pressure transition: the test host cannot provoke one safely, so the
    handler is called directly and the dispatch source that feeds it is not exercised;
  - whether macOS ever leaves a wallpaper window on another Space on a given release, whether
    a window of these kinds reports `isOnActiveSpace` in a full-screen Space, and whether
    either repair step brings an off-Space window back: the audit's decisions are tested, the
    live windows and the repair need a desktop run.
