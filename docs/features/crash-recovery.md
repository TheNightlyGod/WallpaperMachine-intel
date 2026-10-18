# Crash recovery

How the app starts, quits and recovers around an unclean exit: the load journal that holds
back a wallpaper which keeps killing the app, SIGTERM and SIGHUP as a quit, broken pipes
that no longer end the process, and the lock that keeps two copies from sharing one
library. Code lives in `App/Services/Lifecycle/` and the bridge crate; the Swift tests are
in `Tests/Unit/Lifecycle/`.

The saved configuration is replayed at every launch. A wallpaper whose scene kills the
process while it loads (a renderer fault, an out-of-memory kill, a bad driver state)
would kill the next launch the same way, and the one after it, so the app could never
start again without the user editing files. The **load journal** breaks that loop. A
wallpaper that was being opened when the app died twice in a row is **held back**: the
app starts without it, says so, and opens it again when the user applies it.
Nothing is deleted, moved or disabled, and the assignment stays in the configuration.

The journal is Rust, in the bridge crate (`engine/load_journal.rs`). The Swift side only
names the build (`ClientPaths.buildStamp`).

## What the user sees

- After the second crash in a row while one wallpaper loads, the next launch starts
  normally and leaves that wallpaper's display without a live scene. The control panel
  shows a **banner** at the top of the page, one row per held wallpaper, with a sentence
  naming it (`"<title>" was not restored: WallpaperMachine quit unexpectedly twice in a
  row while loading it. Nothing was deleted.`) and a **Try again** button. The menu-bar
  menu carries a disabled line, **A wallpaper was held back after a crash**, so a login
  launch with the panel closed still shows the state. Both come from
  `BridgeAppSnapshot.held_wallpaper_ids` and are localized in the app's catalog.
- **Try again** opens that wallpaper on its display(s) and lifts the hold. If the engine
  refuses, the panel's error banner shows the reason and the banner row stays: a retry
  that opened nothing is not a release.
- **Apply** in the inspector, or choosing the wallpaper again from the library, also opens it
  again, even when nothing in its draft changed, and clears the hold and the banner. Only the
  user's own choice does, which is what `BridgeStore` calls `userInitiated` (a Shortcuts or
  URL command that names the wallpaper counts as one, and so does the options dialog's OK).
  **Apply to all displays** counts too, whether from the inspector, a `display=all` link or the
  shortcut's **On all displays**: it applies a held wallpaper again on every display, including
  one that already reads as showing it, and lifts the hold. Copy, swap and applying a saved
  layout move assignments that already exist, so they leave a hold alone. A
  playlist rotation, an automatic rule or a Space or Focus rule that comes round to the
  wallpaper leaves the hold and the strike count alone, so the rotation cannot reopen the
  wallpaper that crashed the app each time it reaches it: that display stays empty and the
  banner says why. **Random Wallpaper** is a user's choice, so it never picks a held
  wallpaper, or chance would release the hold. Apply is as careful as Try again: if the engine refuses, the wallpaper
  stays held, and if the app dies while it loads, the next launch holds it again.
- A hold on a wallpaper that no display is assigned to is kept but not shown; the banner
  returns if the wallpaper is assigned again.
- Installing an app update releases every hold, because the code that crashed is gone.
- Other wallpapers on other displays load as usual.

What a held wallpaper's display shows in the meantime is decided by the desktop picture
code, not by the journal; see [desktop-picture.md](desktop-picture.md). The journal only
keeps the scene from opening. The lock screen is built from the same plan, so a held
wallpaper is not exported to it either until it is applied again.

## What is recorded, and when

`LoadJournal` keeps `<support>/load-journal.json` (`<support>` is the folder that holds
`config.toml`). It is written only when something can go wrong:

1. **Before a load.** `reconcile_with` (`actor/bridge.rs`) builds the scenes it is about
   to hand to the engine, asks which of them will actually open or replace a scene
   (`displays_awaiting_first_frame`, the same test the first-frame wait uses, judged
   against the engine's live display snapshot), and records those `(wallpaper, display)`
   pairs. A scene that is already running is not a suspect, and a reconcile that opens
   nothing, such as a display refresh or `presentation_unloaded`, writes nothing. A mirror's scene
   belongs to its source's wallpaper (`ActivationInputs::build_owned`).
2. **After the first frame.** When the reconcile finishes, including the audio, mute and
   render-scale calls that follow the scene (the changelog records a launch crash after
   applying a render scale, a call made on a scene that is already open), the entries are
   marked settled and stay for a
   **settle window** of 20 seconds. A crash just after a load is still attributed to
   the wallpaper.
3. **When the window ends.** The entries and the wallpaper's strikes are cleared. This is
   the only way strikes are cleared by success.

**Closing the record on a quit.** `WallpaperBridge::shutdown` closes the journal itself
(`LoadJournal::clean_shutdown`) before it asks the actor to shut down; the actor's `Shutdown`
handler does so too. It has to be outside the actor: the actor handles one message at a time,
and `Bootstrap`, a display refresh and the other reconciles hold it until the scenes they
opened show a first frame. A quit that waited its turn would leave the record open for the
whole load, which for a heavy scene is longer than a logout or a quit's own deadlines allow,
and the next launch would count a strike against a wallpaper that was fine. Closing also
latches the journal: a scene that starts opening after the quit began (something queued
behind it) is not recorded, and the `succeed` of the load that was cut short does nothing.

A reconcile that fails, returns early or panics drops its record without a strike: the
process is alive and the failure was reported. Quitting on purpose clears the record too
(`Shutdown` calls `clean_shutdown`), so quitting during a load is not a crash, and neither is
a `kill` or a closing terminal now that [the signals are a quit](#signals). The `quit:`
log line says who asked for the quit and how long each stage took, so a quit that was cut short
by a logout or a kill can be told apart from one the user chose; see
[diagnostics.md](diagnostics.md#why-the-app-quit).

Every stage of a quit has a deadline, so a quit cannot hang half done. A stage that does not
finish in time is left behind and the quit goes on; the bridge's `shutdown`, which closes the
scenes, is the last stage and always gets at least two seconds. It closes the journal's record
the moment it starts, before it waits for anything, so a bridge stage that is left behind, even
one still queued behind a startup load, has already closed it and the next launch counts no
strike for a scene that was still loading. The next launch's `previous session:` line says the
quit did not finish and names the stage.

During a logout, restart or shutdown the deadlines are shorter (1.5 seconds for the other
stages, and the bridge keeps at least one second of them) and a restoration that does not
finish no longer refuses the quit; see [desktop picture](desktop-picture.md#logout-restart-and-shutdown).
The bridge is still the last stage and still closes the journal's record the moment it starts,
so a logout during a load is not counted as a crash even when the bridge does not finish its
second. What a logout can still count is a process that is ended before the bridge stage has
started, while restoration or an earlier stage is running.

## Strikes and the hold

At launch `LoadJournal::open` reads the file. Entries left by a different session mean
that session died mid-load, so each wallpaper in them earns **one strike** (one per
wallpaper, however many displays it was opening on). At **two consecutive strikes**
(`HOLD_AFTER_STRIKES`) the wallpaper is held.

| State | Meaning | Leaves it |
|---|---|---|
| Clear | no strikes | |
| Suspect (1) | the previous session died while opening it | a load that survives the settle window clears it; a second death holds it |
| Held (2 or more) | not opened by any plan | the user applying it again (Apply, Try again), an app update, the wallpaper being removed from the library |

A hold is applied in `ActivationInputs`: `slots()` skips held wallpaper ids, so the scene,
web and native-video plans, the backend report and the lock-screen export all agree.
`Bootstrap` reads the held set after the library scan, drops strikes for wallpapers that
are no longer installed (`prune`, only after a successful scan) and keeps the set in
`BridgeActorState::held_wallpapers`. `BridgeAppSnapshot.held_wallpaper_ids` is that set
restricted to wallpapers a display is assigned to, sorted; it is state for the panel to
word, not an entry in `errors`.

There are two ways back. `ApplyWallpaperOptions` takes the id out of the held set when it
carries `user_initiated` (`BridgeStore` passes its `userInitiated` flag through
`WallpaperBridge.apply_wallpaper_options`), so that the reconcile plans the wallpaper, and
when that lifts a hold it also forces the reconcile that an unchanged draft would otherwise
skip. It calls `forgive` only once that reconcile has succeeded; a reconcile that fails puts
the id back into the held set (`ReconcileFailed.restore_hold`, before the repair that follows
a failed reconcile plans from the set). An apply that reconciles nothing has no load to wait
for and calls `forgive` at once, which is how the user choosing a suspect (one strike)
again starts its count over. An apply without the flag never calls `forgive`: it neither lifts
a hold nor starts a strike count over.
`ReleaseHeldWallpaper` (`WallpaperBridge.release_held_wallpaper`, **Try again**) takes the
id out of the held set, reconciles the configuration and only then calls `forgive`. The
order matters for both: if the reconcile fails the id goes back into the set and the journal
still holds its strikes, and if the process dies during the attempt the next launch counts a
third strike and holds the wallpaper again, where forgiving first would have made the crash
a first offence, opened at startup and crashing the app again before the user could do
anything. A release for a wallpaper that is not held changes nothing and does not touch the
engine.

## Signals

`kill`, `killall`, `launchctl stop`, device management and a terminal that closes end an
app with SIGTERM or SIGHUP. Nothing handled them before: the process died where it stood,
without `applicationShouldTerminate`, so the poster stayed on the desktop until the next
launch and a stop during a load counted a strike. `TerminationSignalRelay`
(`App/Services/Lifecycle/`) now turns both into the quit the menu's Exit runs: restoration
first, then the teardown, with the same deadlines, and the bridge's `Shutdown` closes the
journal's record. The quit logs `reason=signal` and `signal=SIGTERM`, and the session
ledger keeps `terminated by SIGTERM` (see [diagnostics](diagnostics.md#why-the-app-quit)).

- **Caught, not ignored.** The C handler does one `write(2)` of the signal number to a pipe,
  the only thing a handler may safely do; a dispatch source on a utility queue reads it and
  hands it on. A caught handler goes back to the default across `exec`, so SteamCMD, perl
  and the updater script keep the ordinary SIGTERM and SIGHUP. Ignoring the signal and
  watching it with a dispatch source would pass `SIG_IGN` to every child, because `exec`
  keeps an ignore, and a child that ignores its parent's SIGTERM turns each quit into a
  wait for the two-second SIGKILL. Both pipe ends are close-on-exec and non-blocking, and
  the handler is installed with `SA_RESTART`.
- **An ignored signal stays ignored.** `nohup` ignores SIGHUP on purpose; the relay leaves
  a signal that was ignored when it started alone.
- **The first signal asks, the second ends it.** The first signal reaches
  `NSApp.terminate` from the main run loop, never from a main-queue job (AppKit's
  `terminateLater` wait would hang), and in every common mode
  (`TerminationSignalRelay.performOnMainRunLoopInAnyMode`). The default mode alone would leave
  the first signal waiting while a menu is open or an alert is up, which run the loop in
  modes of their own; `kill` would then take until the deadline. A second
  signal, or the deadline, restores the default action and raises the signal again, so a
  wedged app can still be killed the usual way. The deadline is the longest an interactive
  quit can take within its limits (restoration 20 s, teardown 10 s, the bridge's 2 s floor
  and the 5 s exit fuse: 37 s, `QuitSupervisor.Budgets.longestQuit`), so a quit that is
  still within its limits is not cut off. The forced end leaves what the quit had not
  finished to the next launch, as a kill does, and the ledger records a run that had not
  begun quitting as `quit did not finish (terminated by SIGTERM; ended by force)`, not as
  a crash.
- **A refused quit stands the relay down.** If the desktop picture could not be restored
  the quit is refused, the usual alert appears and the next signal asks for a quit again
  instead of forcing the end.
- **During a logout, restart or shutdown** the quit that is already running answers the
  signal's request too, and it keeps its short power-off limits.
- **When it starts.** At the end of `applicationDidFinishLaunching`, and never under
  XCTest. Before that the default action applies, so a stop while the app is still
  launching ends it as before and the next launch calls it `ended unexpectedly`.
- SIGKILL cannot be caught. SIGINT, SIGQUIT and the crash signals are left alone; SIGPIPE
  has [its own handling](#broken-pipes).

## Broken pipes

A write to a pipe or socket whose reader has gone raises SIGPIPE, and with the default
action that ends the process at once: no quit, no log line, the poster still on the desktop.
Rust switches the default off for the executables it builds, but this app is a Swift
executable that only links the renderer, so nothing did. The one place the app writes to a
child's pipe, the import picker's handshake with its helper process, already used a throwing
write and handled the error. It never got to: a helper that died first took the whole app
with it.

`ProcessSignals.ignoreBrokenPipes()` (`App/Services/Lifecycle/`) is the first statement of
`WallpaperEngineApp.main`, before the picker's helper mode, so the helper process is covered
too. From then on the write fails with `EPIPE`, the existing handling stops the helper and
the import action fails with that error while the app carries on. The same holds for code
the app does not own, such as AVFoundation and the renderer's libraries, which see a failed
write and not a dead process.

- **Caught, not ignored.** The handler is a no-op C function. `SIG_IGN` would be inherited
  across `exec` by everything started with `posix_spawn` (SteamCMD), which would then
  ignore a broken pipe where it should end; a caught handler goes back to the default there.
- **Only the default is replaced.** A SIGPIPE that was already ignored or handled when the
  app started cannot end it, so the launcher's choice stands. Calling it twice is the same
  as calling it once. It runs under XCTest as well, which keeps the test host alive when a
  test writes to a closed pipe.
- It does not log. A broken pipe is reported where the write failed, in that code's own
  error.

## Single instance

Only one copy of the app runs per library. Two copies sharing one folder would
each restore a backup, replace posters, write the Workshop queue and run a
renderer against the same wallpapers.

What a user sees when a second copy starts:

- **The same app opened again** (`open -n` or launching the executable directly;
  an ordinary open already brings the running app forward): the second copy exits
  and the first comes forward with its control panel, exactly as a Dock click does.
- **A copy from another location** (for example a downloaded or freshly built app
  while the installed one is running): an alert says another copy is using this
  library and asks to quit it first. Nothing else happens; the running copy is
  left alone.
- **The first copy is quitting**: the second waits, up to 40 seconds, for the
  library to come free and then starts normally. That is the longest an interactive
  quit may take within its budgets (37 s, `QuitSupervisor.Budgets.longestQuit`) and
  a margin, so a relaunch right after a slow but successful quit still finds the
  library free. A quit that is cancelled returns the first copy to the running
  state, so it is not waited for.
- **An update relaunch** needs nothing special: the installer starts the new
  version only after the old process has exited, so the library is already free.

### Contract

- The claim is an exclusive `flock` on `<support>/.instance.lock`, taken in
  `WallpaperEngineApp.main()` before the backup restore, `NSApplication` or any
  service. Because it is held on an open file description, the kernel releases it
  on any exit, including a crash or `kill -9`; no lock is ever left stale by its
  owner. The file is opened `O_CLOEXEC` (and spawned helpers do not inherit it),
  so a child that outlives the app cannot keep the library locked.
- The file records `<pid> running` or `<pid> quitting`. `AppDelegate`
  announces `quitting` as the first step of `applicationShouldTerminate` and goes
  back to `running` if the quit is cancelled.
- A second launch waits up to 2 seconds for a running holder (a quit-and-reopen
  race), up to `longestQuit` plus 3 seconds (40) for a quitting one, then hands over.
  The wait follows the quit's budgets, so it cannot give up on a holder that is still
  within them.
- **A lock must never block launch.** If the lock file cannot be opened or
  locked, if the recorded pid no longer exists (a descriptor leaked into another
  process), if nothing readable was recorded, or if the pid now belongs to a
  program that is not a copy of this app, the app logs a warning and starts without
  the lock.
- The claim comes before the session record (`recordSessionStart`), so a second copy that
  hands over never marks the running copy's session as ended.
- The lock lives in the support folder, so each isolated `WALLPAPER_MACHINE_HOME`
  (unit and UI tests, `scripts/check_rust.py`, benchmark runs) has its own lock and
  copies on separate homes run side by side. The unit-test host and the import
  picker helper never take it.

## Limits

- A force quit, a `kill -9`, a second SIGTERM, a power loss or a logout kill during a load
  or its settle window looks like a crash and counts one strike. Two in a row hold the
  wallpaper, which is why one is not enough. Releasing is one Apply or one Try again.
- A launch that opens several displays at once makes every wallpaper still opening a
  suspect; the journal cannot tell which one killed the process.
- A crash later than the settle window is not attributed to a load.
- Whether the run before a launch really crashed is a separate record. The session
  ledger logs `previous session: …` at every launch, so a strike that comes with
  `ended by a restart, shutdown or power loss` is not necessarily the wallpaper's doing; see
  [diagnostics.md](diagnostics.md#how-the-previous-session-ended).
- Isolated support roots (`WALLPAPER_MACHINE_HOME`, tests) have their own journal,
  because it lives beside `config.toml`.
- The journal is not in the Settings backup package. It is in the diagnostics report (see
  below).
- A file that cannot be parsed, or has an unknown version, is renamed to
  `load-journal.json.corrupt` and the journal starts empty. If it cannot be written the
  load goes ahead; the journal never blocks one.

## The file

```json
{
  "version": 1,
  "build": "1.3.2 (45)",
  "session": "9f3a6c0d2b81e475",
  "strikes": { "3177024520": { "count": 1, "last_at": 1791800000, "display": 7 } },
  "in_flight": [
    { "wallpaper": "3470764447", "display": 8, "started_at": 1791800100, "settled_until": 1791800120 }
  ]
}
```

`build` is `WALLPAPER_MACHINE_BUILD`, which the host sets from the bundle version and
build number; without it (tests, tools) the bridge crate version is used. A file written
by another build is discarded whole, strikes and in-flight entries alike. `session`
identifies the process that wrote the file. Times are Unix seconds. Writes go through a
temporary file and a rename and are not synced: the file has to survive the process
dying, which the page cache does, not a power cut.

## In the diagnostics report

**Export…** under Settings → Storage → Troubleshooting → Diagnostics report puts a copy of
`load-journal.json` at the root of the zip (`DiagnosticsBundle.collectLoadJournal`,
see [diagnostics.md](diagnostics.md#diagnostics-report)), so a bug report about a held
wallpaper carries the strike history. It goes through the same redaction as the logs
(the file holds no paths today, so this only guards later fields) and `README.txt` lists
it. A missing file is a note under "Not included" (`load-journal.json was not present`),
not a failure: the file is written only once a scene has been opened. One that exists but
cannot be read is noted as not readable. The crash report of the run that died is picked
up by the existing `crash-reports/*.ips` rule, and the `load journal:` lines in the
exported logs name the same wallpaper ids.

## Logging

The session log (see [diagnostics.md](diagnostics.md)) carries:

- `WARN load journal: previous session died while opening <id> (display N); strike k/2`
- `WARN load journal: holding <id>` at every launch while it is held
- `INFO load journal: released <id> (by the user)` for Apply and Try again, and `released N held wallpaper(s) after update`
- `WARN load journal: set aside an unusable journal ...` and `could not write ...`
- `DEBUG` lines when a load is recorded and when it settles

## Verification

Device-free, against the fake engine and a temporary support root:

- `engine::load_journal::tests` in the bridge crate: one strike per dead session and per
  wallpaper, the hold at two and its persistence, the settle window (long and short),
  dropped and succeeded tickets, clean shutdown (also from another thread, and nothing
  recorded after it), a new build, forgive, a corrupt file,
  an empty load never touching the disk, and pruning.
- `tests::crash_loop_guard`: bootstrap leaves a held wallpaper out and lists it in the
  snapshot (sorted, only while a display is assigned to it), Apply and
  `release_held_wallpaper` bring it back and release the hold, a release of a wallpaper that
  is not held or whose reconcile fails changes nothing, an Apply whose reconcile fails leaves
  it held (and the repair after the failure plans without it), a crash while an Apply is
  loading it counts a third strike at the next launch, later reconciles keep skipping it,
  an apply that is not the user's (a rotation coming back to a held wallpaper) leaves the hold
  and a strike count alone while the user's apply releases and resets them,
  the record is on disk while a load runs and through its settle window, a quit that arrives
  while startup still holds the actor (or a load that begins after the quit) leaves no
  strike, only scenes that
  really open are recorded, quitting and failing loads leave no strike.
- `DiagnosticsBundleTests`: the journal is exported at the zip root, redacted and listed
  in `README.txt`, its strike history survives redaction, and a missing or unreadable
  journal is noted while the rest of the report is still exported.
- `PanelLibraryActionsTests` and `ShellBannersTests` (Panel, no window): the panel names
  each held wallpaper with the localized sentence (one missing from the library by its id),
  `releaseHeld` reaches the bridge once for a held wallpaper and rejects an installed one
  that is not held, the banner takes no room with nothing held and a row for each held
  wallpaper, **Try again** runs the retry, and a refused retry keeps the row and shows the
  reason in the same banner.
- `tests::activation_plan`: a held wallpaper gets no scene, web or native-video
  descriptor; `build_owned` names the owner of every scene, mirrors included.
- `InstanceLockTests` use temporary folders and an injected clock and process table (no
  sleeping, no windows): acquisition and the recorded holder, a second claim being turned
  away after the grace, hand-over once the holder releases or is dropped, a quitting holder
  waited for beyond the grace and through the longest interactive quit, a leaked claim in a
  surviving child, a dead or unreadable
  holder not blocking launch, an unusable lock file, the decision table, and the
  classification of the running holder (same bundle, another copy, another program).
- `TerminationSignalRelayTests` (real SIGUSR1 and SIGUSR2 raised in the test host, never
  SIGTERM, and `forceDefault` always injected): one signal asks for one quit, a second or the
  deadline forces the default action, back-to-back signals are one request and one force,
  a reset after a refused quit lets the next signal ask again, `stop` puts back the
  disposition that was there, an ignored signal stays ignored, a child started with
  `posix_spawn` sees `DEFAULT` for a relayed signal (the probe is checked to see an
  inherited ignore as `IGNORE`), both pipe ends are close-on-exec and non-blocking, and the
  quit request reaches the main run loop while it is spun in the default, event-tracking and
  modal-panel modes.
  `SessionLedgerTests` pin the cut-short records and `QuitReasonTests` the ledger text.
- `ProcessSignalsTests` (SIGPIPE set back to the default before each call, and the guard
  checked before any write so a failed install cannot end the test host): a write to a
  pipe whose reader is closed returns -1 with `EPIPE` and the process survives, a
  `FileHandle` write throws it as a POSIX `EPIPE` error, a second call keeps the same
  handler, an ignored SIGPIPE or a handler already in place is left alone, and a child
  started with `posix_spawn` sees `DEFAULT` (the probe is checked to see an inherited ignore
  as `IGNORE`).

Not verifiable headlessly: a real engine crash while a scene loads, and how the banner and
the menu line look in the real panel and status menu. The fake engine cannot take the
process down, so the crash is played by a record that never ends. The check on a desktop is
to kill the app with `SIGSEGV` during a restore twice, relaunch, confirm the banner and the
menu line, then press **Try again** and confirm the wallpaper loads; that needs an
explicitly authorized run. The same goes for signals: `kill -TERM <pid>` on a running copy
should restore the desktop picture before it exits, `quit: reason=signal` should appear in
the log, and a second `kill -TERM` during a wedged quit should end it at once; the unit
tests never send a real SIGTERM. Likewise the unit tests close the reader of a pipe they
made themselves; they never kill a real import picker helper while the app writes to it.

Single instance needs a desktop run as well: launching a second copy of the same bundle and
seeing the first activate and show its panel, the alert for a copy from another path, and
the relaunch after an in-app update. These are in the
[manual smoke checklist](../testing/manual-smoke.md#launch-and-window).
