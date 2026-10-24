# Current native coverage

What the Swift test bundle asserts, one section per `Tests/Unit/<Domain>/`
folder. This is the inventory behind `python3 scripts/test.py`; the strategy,
layers, tiers and evidence policy live in [README.md](README.md). Read it to
find out whether a behavior is already covered before adding a test, and where a
claim stops: "Not covered" notes name what the tests do not establish. Nothing
here starts the app, opens a window or touches the desktop.

Entries are class names, so `python3 scripts/test.py --only <Class>` runs one.
Where a feature document has its own Verification section it owns the detail and
is linked from the domain; the shared limits are collected at the end.

## Appearance

- `AppThemeTests` — a chosen theme survives recreation and reset leaves other
  preferences alone; an invalid change cannot overwrite saved values; a damaged
  saved accent or an unknown icon does not discard the rest.
- `AppearanceSettingsTests` and `PanelShellActionsTests` (Panel) save every
  Appearance choice (mode, accent, tone, icon) in the store's format, refuse an
  invalid accent, round-trip accents through the colour well and reset without
  touching unrelated preferences; `PanelThemeTests` derive the palettes from the
  preferences and the resolved appearance.

## Automation

`AutomationCommandTests`, `AppAutomationTests`, `HotKeyPreferencesTests`,
`GlobalHotKeysTests`, `WallpaperAutomationPlannerTests`,
`WallpaperAutomationStoreTests`, `WallpaperAutomationSchedulerTests`,
`WallpaperFocusFilterTests`, `StatusMenuModelTests`, and `PanelAutomationActionsTests`
and `DisplaysSettingsModelTests` (Panel): rules,
solar and DST boundaries, appearance selection, Focus recovery and manual
precedence, editor round trips and preference validation, and the menu bar menu's
layout (flat for one display, a submenu per display with every command naming its
display, ordering and titles, Remove or Start Again, Random Wallpaper where something else
can be chosen, Mute Wallpapers after Play/Pause, ticked while muted and offered then with
nothing playing, the Workshop downloads line right under Control Panel and absent when idle,
its byte-weighted percent left out when a job cannot say and never reaching 100, which displays
are listed), the `random` link and its pools, the
`mute`, `unmute` and `togglemute` links (which take no query) and the shortcut keys for them.
`WallpaperBackupTests` covers rule merging and local recovery-state rollback, and that the
mute of every wallpaper is neither exported nor accepted from a package. What each covers, and what
needs the running app, is in [automation](../features/automation.md#verification).

## Desktop

### Posters (Mission Control)

`DesktopWallpaperTests` use synthetic renderer pixels, an in-memory workspace,
unattached `CAMetalLayer`s and injected notification and encoding services:

- Pixels and delivery: JPEG dimensions, channel order and orientation within
  lossy tolerance; a new wallpaper and the first ready frame reach every Space
  without visiting it; the newer frame wins whatever order encodes finish in;
  late frames and encodes from another Space or an old layer are rejected; a
  frame identical to the poster is neither encoded nor written.
- Capture timing: an animated wallpaper gets new poster files only as a new or
  changed wallpaper settles, not through hours of Space changes, wakes, resumes,
  `refresh(capture: .unsettled)` calls and renderers that start again; a snapshot
  passed to `snapshotApplied` retakes every poster only when its `DesktopPosterLayout`
  differs from the last one, and that layout stays equal when frame rates, volume,
  mute or titles change and differs for a display's wallpaper, mirror target,
  scaling, scaling factor, enabled state, mode, screen size or scale, and the
  wallpapers' files; a frame dropped for another request's context still answers
  its request; a Space change
  applies the existing poster at once and asks for a fresh frame only when the
  poster has not settled (displays judged separately; Space-scoped posters, a frame
  a paused display answered with and a frame that failed to encode never settle it),
  however long ago a settled one was taken; a Space change or snapshot during
  settling leaves the capture to the settle sequence; a resume retakes only displays
  without a settled poster; a frame nobody asked for never replaces a settled poster
  and settles a new surface like a new wallpaper; periodic captures only while
  enabled; later captures skip displays that are not presenting.
- Unsaved looks: a display that draws property edits nobody applied is asked for
  nothing by a new wallpaper, a settle capture or a Space change, a frame already on
  its way is dropped, the poster stays the saved look, and it is retaken once the
  display draws the saved look again.
- Refusals: a desktop that keeps refusing posters is left alone until the next
  Space change; a poster that reads back late is confirmed without counting a
  refusal; a failed Space neither blocks the others nor loses its old poster.
- Originals and quit: inherited (pathless) selections resolve through the public
  API before any poster write and are never replaced by an unresolved poster;
  independent per-Space originals survive; a user's own wallpaper change is not
  overwritten on restore; an original whose file is gone gives way to another
  display's original and then macOS's default picture (when its display stops playing,
  at quit and in the launch repair), while one the app may not look at is still put
  back; quit waits for the native reload, every read-back and
  in-flight writes, keeps the original when restoration fails persistently, and
  cannot be blocked forever by an unreachable reference; cancelling a restoration
  that is waiting (a logout's deadline) stops it and leaves the journal entry and the
  poster for a later run to finish.
- Switching posters off: the journal reports an original until it is restored (a
  missing, damaged or emptied journal reports none); a running sync restores every
  desktop, stays suspended and writes nothing for a frame, refresh or resume that
  follows; a fresh sync over a journal left behind restores it, the launch repair.
  `PlaybackPreferencesTests` (on until turned off, one change notification),
  `LockScreenWallpaperServiceTests` (when the lock screen claims the picture and locks
  the choice) and `PanelGeneralSettingsTests` (the setter stores the choice or is
  refused while the lock screen is requested; the row, its disabled five-minute
  neighbor and its lock reason) cover the rest. The `AppDelegate` wiring that decides
  when to restore is not unit-tested.
- Retention: frame URLs are immutable and pruned only after every Space updates;
  displays on the current-Space fallback or with an unreadable Space keep a
  bounded number of the newest posters.
- Frames: the frame a ready notification carries keeps its channel order as a picture
  and is refused when a value is missing or mistyped, its byte count does not fill its
  size, or it is larger than the encoder reads back; a frame asked for by a wallpaper
  switch (context `switch-hold:…`) is never encoded or written as a poster.

Not covered: what Mission Control actually shows and its refresh latency, and
macOS accepting or restoring native selections. Both are on
[manual-smoke.md](manual-smoke.md). Nor is `AppDelegate`'s wiring: that every engine
snapshot reaches `snapshotApplied`, and that `desktopPosterLayout()` fills the layout
from the store's snapshots and `NSScreen`. Behavior: [desktop picture](../features/desktop-picture.md).

### Wallpaper activation

`WallpaperActivationRecoveryTests` use a fake renderer bridge: they cover
application preflight and recovery, not decoded frames or desktop playback.
Missing, empty and non-file video entries are rejected before any change; an
original synthetic H.264 Matroska clip applies through Apply and Apply changes
(the playable-format refusal applies to every video now: an AVI is refused with its format named); decoder failures keep the error and leave the
library usable for retry; history changes only after a successful activation;
playback-environment changes (suspend/resume, unload/reload, audio, reduced quality) and library
refreshes wait for an in-flight apply and the reverse, while explicit Pause still
interrupts; the first-wallpaper support prompt follows only a successful
downloaded activation; only the user's own activation reports a manual choice,
and an update reload gives way to a choice the user is waiting on; a wallpaper
held back after a crash keeps its display assignment, so only the user's choice
of it reaches the bridge to lift the hold (as does Apply to all displays, which
asks for it), while a playlist, rule or layout finds it already shown and stops. The same suite
covers Retry for a scene that stopped drawing over the two-display fake: it takes
the wallpaper off the named display and applies it again and touches no other, a
display with no wallpaper gets an error and no change, a mirroring display reloads
the display it mirrors (and a mirror of an empty display gets the error), a retry
that waited behind a command switching its display leaves the switch alone, one that
arrives while the user's switch runs there gives way at once, and a newer
choice replaces a retry still waiting; reloading everywhere after an update still
reloads every display. `UserCommandQueueTests` — commands run in arrival order, a
newer command in the same slot replaces a waiting one, a playlist, rule or
update reload never replaces a user command waiting in its slot (it returns at
once and leaves the slot revision alone), and a choice noted without a command
counts once in each slot named and replaces nothing that waits.
`WallpaperReapplyTests`, and `PanelLibraryActionsTests` and `InspectorPolicyTests` (Panel) — the inspector's
**Reapply wallpaper** takes the wallpaper off its display once and applies it
again from an empty display, as the user's choice but not as a first apply
(history and the support prompt stay as they were); it refuses before any
eject when the wallpaper's files, the display or an unfinished edit would make
the apply fail; a wallpaper the display does not show is simply applied; and
through the panel's actions only that button restarts, while a tile's double-click
leaves the shown wallpaper running. Not covered: whether a scene reload flashes
on the desktop ([manual-smoke.md](manual-smoke.md)).

### Wallpaper switching

`WallpaperSwitchHoldTests` drive the switch hold with an injected notification center,
unattached `CALayer`s, a manual clock and timers fired by hand; nothing opens a window.
[Wallpaper switching](../features/wallpaper-switching.md) owns the behavior:

- The still: the request goes to the frontmost layer of a display and carries a
  `switch-hold:` context; an answer that arrives inside the request or after it is taken;
  an unanswered request (250 ms), an unusable frame, a display with no wallpaper window
  and a display that is not seen leave no ticket; a second switch keeps the still it has and
  restarts the ceiling; a switch during a fade takes a fresh still.
- Placement: the renderer's `open` and `replace` announcements move the veil onto the new
  layer, `reconfigure`, another display and an announcement without a display id do not;
  a host takes over a veil only when the window it sat on is gone.
- Native video, in `NativeVideoWallpaperHostTests` with a fake surface that logs what is done
  to it: the replacement window is presented with the veil already on its content layer and
  keeps it through a repeated offer or a setting change; its first frame releases it (a layer
  that was ready when built, too), and a replaced window's late report does not; a second
  replacement takes the veil on, another display's veil stays where it is; a clip that fails
  to play cancels it; a window closed with no clip to follow (ejected, or its display went
  away) takes its own veil with it, while a veil that waits for another backend's window or
  sits on a scene is left for its successor; a refused replacement leaves it armed for the
  scene the engine opens
  and releases it when the bridge has answered, or by the grace when no scene follows; the
  old clip keeps playing while the replacement's file is read (probe, stop, make, present in
  that order), and a pass overtaken in the read stops nothing.
- Web pages, in `WebWallpaperHostLifecycleTests` with real offscreen pages and a fake window
  that records whether the veil was on its content layer when it was presented: the
  replacement is presented with the veil, which stays after the page reports it has loaded
  until the 500 ms settle timer fires; a page that fails to load (a missing entry file)
  releases it with no settle; a window closed with no page to follow (the display lost its
  web wallpaper, an entry file outside the project) takes its own veil with it, while a veil
  that waits for another backend's window or sits on a scene is left for its successor; a
  reconcile that keeps the page (property or frame-rate push) builds no window and takes no
  veil; a host without a hold opens plain. `WallpaperSwitchHoldTests` pin `windowClosed` on
  its own (the veil it sat on goes at once and leaves no timer; an armed, scene, other-window
  or other-display veil stays).
- Release: the scene's first frame (the engine settling) fades the veil, which is removed by
  its own timer; a host's content fades it after its settle; `cancel` and `stop` remove it,
  also while the still is on its way; Reduce Motion skips the fade; the 30 s ceiling and the
  8 s host grace release a veil nothing ends, and the grace never outlasts a nearer ceiling;
  displays are held and released independently.

`WallpaperActivationRecoveryTests` also pin the store's side: a switch is announced with the
live display ids before the bridge apply and settled after it, an apply that throws abandons
it instead (an apply that landed but was not reported active still settles, so exactly one of
the two fires), an activation that finds its wallpaper already shown announces nothing, and
a switch covers the display and every display mirroring it.

Not covered: whether a sublayer composites over a `CAMetalLayer`'s drawables, whether real
surfaces answer the request within 250 ms (a paused renderer included), how the still compares
with the live frame, and the fade, Reduce Motion, multi-display and mirror behavior on a desktop
([manual-smoke.md](manual-smoke.md#wallpaper-switching)), nor whether `isReadyForDisplay`
alone is late enough for a real clip that the veil does not come off a frame early, nor whether
500 ms after a web page's `didFinish` is enough for its first paint, nor how long the system
picture shows between a window closing and the web page's window opening.

### Playback policy

- `WallpaperPresentationPolicyTests` — display sleep and wake, session lock
  (asked only when it can have changed, re-asked on wake and user switch, a
  missed unlock clearing at the next evaluation), the unlock reported once to
  `onSessionUnlocked` (also when missed, after a wake or a user switch, never at start
  while locked or at stop), full occlusion and a covered
  working area suspending after the settle delay, per-display independence,
  reconnect handling, retried failed suspends and resumes, `stop()` resuming
  every suspended surface, and the resume announcement (`onResumed`) after a global
  or per-display resume, but not after a suspend, a refused delivery or teardown. A
  display the user is not using is one more hidden reason: suspended after the settle
  delay, resumed at once, joined to coverage, never darkening every display, playing
  while the display in use is covered or under a full-screen app, untouched
  by a sleep and wake, and not counted as hidden for the update alert's gate.
- `SystemWakeRevalidatorTests` — against a private notification center and
  injected delays, idle wait and bridge call: a wake's two notifications are one
  check, a check waits for the command queue, a wake at the lock screen is checked
  when presentation resumes, a newer wake supersedes a waiting one, `stop()`
  cancels, a bridge failure is reported and not thrown, and the summary counts
  repaired, skipped and still-stopped displays (as counts, with the warning that
  goes with a repair; one test pins the wording of the log lines, which are the
  ones the diagnostics doc shows). The bridge's half is `wake_revalidation` in
  `wallpaper-bridge`.
- `PlaybackPolicyCompositionTests`, `PlaybackPreferencesTests`,
  `AppRuleMonitorTests`, `OtherAudioMonitorTests` — how sleep, lock, app rules
  and other-app audio compose (Stop beats Pause, Keep running ignores audio),
  defaults and corrupt stored values (the battery mode's `reducedQuality` is not a
  condition choice), the stored Reduced quality choice of the three system conditions
  that is never a rule action, running versus frontmost rules, and the
  other-audio settle. The quality channel is one more delivery beside presentation and audio:
  a reduction reaches the bridge on its own without suspending anything, an unchanged set is
  not sent again, a refused request or release is sent again by the next evaluation (and not
  inside the same one), `stop()` releases it, and it waits for the global acknowledgement and
  follows it without depending on it. A real `SystemConditionMonitor` wired to the policy covers
  the chain for heat: serious reduces, critical also pauses without sending the reduction
  again, cooling to serious resumes and keeps it, and nominal releases it. The store call and
  the app delegate's closure are thin forwarders and are not tested on their own. The user's
  mute of every wallpaper is one more source of the single audio-suppression flag: delivered at launch, silent without touching presentation, still held
  by a mute rule or other-app audio when lifted, and released at teardown; its preference
  defaults off, persists and announces one change. Its Settings switch (stored, reported and
  kept across a relaunch, the first Playback row following the preference whoever changes it)
  is in `PanelPerformanceSettingsTests` and `SettingsEditingModelTests`. Whether sound really stops is not covered
  (see [manual smoke](manual-smoke.md#audio-responsiveness)).
- `SystemConditionMonitorTests` use injected Low Power Mode and thermal readings
  and a private notification center: Low Power Mode acts only once an action is
  chosen, only serious and critical heat counts, a Focus filter joins the other
  conditions and survives a new instance, and `stop()` releases every action and every
  quality reduction. Reduced quality, chosen for any of the three conditions, is
  reported as a `QualityReduction` and never as a rule action: heat reduces at serious
  and also pauses at critical (staying reduced on the way back to serious), Pause and
  Stop at heat report no reduction, and the conditions combine independently. A fake
  battery source drives the low-battery rule, Reduced quality included: it is neither
  read nor observed until an action is chosen, engages at the level and releases five
  points above it, follows a changed level and a plug-in at any charge, never engages
  without an internal battery, joins the other conditions, and a wake-time refresh
  reads a change nobody announced. The engaged conditions it publishes for the panel
  name each condition with what its own rule does (heat on Reduced quality reads as a
  pause at critical, a Focus filter is not listed), follow the low-battery margin, change
  the state without asking the policy again when a second condition adds the same
  action, and clear on `stop()`. `LowBatteryTests` pin the gate sequence, the margin
  and the parse of IOKit's power-source description (internal battery only, no UPS, no
  zero maximum) with synthetic dictionaries; the real source is only started and
  stopped to prove it releases itself.
  `WallpaperFocusFilterTests` pin the filter's default to the choice that lets
  wallpapers run, since macOS performs it with defaults when a Focus ends.
- `PowerSourceMonitorTests` use an injected reading: only a different source is
  reported (the system notification also fires as the charge moves), a change made
  before `start()` is not lost, and the snapshot refresh after a change repeats until
  the bridge reports the source the system did, survives a failed refresh, stops after
  the last delay and on cancellation. The notification itself, and the race between
  the renderer's power thread and the app's observer, need a real plug or unplug and
  are not covered.
- `PowerSourceResamplerTests` use a private notification center and a sleep the test
  releases: a wake reads at once and once more at the follow-up, a display wake
  right after a system wake gives two reads now and one follow-up, a later wake
  gets its own follow-up, and `stop()` cancels a pending follow-up and ends
  observation. The Rust `power::tests` and `tests::power_settings` prove the other
  half with a fake reader: a changed source is delivered once, a delivery the
  actor rejected is offered again, an unreadable source is left alone, and the
  battery policy is applied through the bridge from a change nobody reported.
- `ActiveDisplayTrackerTests` drive the tracker through injected screens, pointer, monitor and
  a sleep the test releases: the display under the pointer plays at once and the one it left
  after the dwell, a return within the dwell pauses nothing and a cancelled wait that ends
  late cannot cut a later one short, events inside one display change nothing, a pointer on a
  screen the app does not manage or between screens pauses nothing, no monitor exists with one
  display or with the option off, an unplugged or rearranged display is re-resolved, a pointer
  that moves while this app is active is found by the timer with no event, becoming or
  resigning active reads it once, and the timer and the activity observers end with tracking.
  One case runs the real policy from the tracker's changes.
- `DisplayRefreshCoalescerTests` — a burst during a refresh is answered by one
  more; screen changes that leave the displays as they were refresh nothing; a
  failed refresh is retried. A display missing from the screen list waits one
  fixed, never extended settle (injected clock) before the refresh: a display
  that returns costs no bridge work and is announced once to the hosts (also when it
  returns as the wait ends), one that stays away refreshes once and is not announced, and a
  display added, swapped, moved or promoted to main, a screen without an ID, the
  first reading and a retry never wait. Fixtures for the shapes that make AppKit's
  list and the bridge's differ: a mirror set collapsing two screens into one (the
  survivor unchanged waits and refreshes once, the other member surviving at the
  origin refreshes at once), a closed lid leaving the external display first and at
  the origin, and unnumbered screens coming and going; each refreshes once for its
  shape and not again for the same reading. They pin the coalescer's reading of
  those shapes, not what macOS really lists. Not covered: whether real hot-plugs and
  wakes blip, and whether 0.8 s is long enough. `DisplayTitleResolverTests` —
  localized display names replace the renderer's label; `DisplayGeometry` finds a
  screen by id or by the title's live id, clamps its shape and has none for an
  unattached display.
- `WallpaperWindowAuditorTests` — against injected window observations and
  recorded delays, asserting the reports the auditor makes (fault, window, look,
  repairs done) and pinning the wording of the log lines in one test: a healthy
  desktop writes nothing and looks once; a window off
  its Space is reported at the first look and again at the last, repaired only with
  the hidden preference and never beyond the two-step ladder or its budget; a
  burst of triggers keeps one schedule; nothing happens while presentation is
  paused or for a Space fault in a full-screen Space; repeated reports are
  throttled; only a new window number or a moved display starts a check.

Not covered: the real Focus Settings pane and a real Low Power Mode; a real thermal change
or Low Power Mode driving Reduced quality through the monitor, policy and bridge to a
running wallpaper, a change while the Mac is locked, the live layout of the Playback
rows and how their sentences read in each language, and any power saving; a real plug or
unplug during sleep, including whether `IOKit` answers correctly the moment the Mac
wakes; a real discharge crossing the low-battery level, how often IOKit posts the
power-source notification on this Mac, and how the two rows lay out in the live
panel; real global and local pointer events across two physical displays, the real
activation notifications that start and stop the timer, the display-ID mapping with
mixed scaling, and how the dwell feels; real wallpaper windows on another Space and
the effect of either repair step; whether a scene surface stops producing frames
across a real sleep and wake, and whether the wake check's repair restores it (needs
a desktop run).

### Spaces

`WallpaperSpaceMonitorTests`, the Space scenarios in
`WallpaperAutomationSchedulerTests`, `WallpaperSpacePinningTests` (windows kept on the desktops
of their wallpaper, hidden while loading), `WallpaperSpaceParkingTests` (the wallpapers each
display keeps, memory pressure), the renderer's `space_parking_tests` and the bridge's
`tests::space_parking` (parked scenes), the kept clips and pages in `NativeVideoWallpaperHostTests`
and `WebWallpaperHostLifecycleTests`, the Wallpaper per Desktop tile in `QuickSettingsTileTests`,
store and backup migration checks, and
`PanelAutomationActionsTests` and `DisplaysSettingsModelTests` (Panel). `DesktopWallpaperTests` covers
Space-scoped writes, saved posters for the other desktops, late frames and encodes, replacement
gaps and restoration; `DesktopSpacePosterCacheTests` the saved posters themselves.
Not covered by tests: real Space transitions and installed desktop behavior; what one desktop
run checked is in [Spaces](../features/spaces.md#storage-and-verification).

### Display layouts and transfer

`WallpaperDisplayTransferTests` and `WallpaperDisplayTransferIntegrationTests`
cover capture of stable display identity, complete validation before any write,
copy and swap, rollback and recovery (including cancellation and empty
destinations), one history entry per display, newer manual commands and a
transfer counting as the user's choice for each display it gives a wallpaper
to, from the moment it is asked for. Applying one wallpaper to every display
is covered through planning (the main display first, ineligible displays left out, no
display or an unknown wallpaper refused), execution (a display that already shows it
is skipped unless the wallpaper is held back after a crash, in which case it is applied
again and the apply lifts the hold; a display set that changed while preparing is refused
before any write), the real store (one history entry and one manual choice per display,
the apply passed to the bridge as the user's, a held wallpaper opened on every display
with copy and swap leaving the hold alone, rollback after a failure on the second display,
pending edits refused before any write) and the link
parser (`apply?…&display=all`).
`WallpaperDisplayLayoutStoreTests` (Library) covers bounded persistence.
`PanelDisplayLayoutActionsTests` (Panel) covers save, rename, apply, delete, copy and
swap, a failed swap putting both displays back, a layout whose display is gone and the
limit; `DisplaysSettingsModelTests` the page's status lines and keyboard focus;
`SettingsBRenderTests` the page in every language at the smallest window; and
`InspectorPolicyTests` and `PanelLibraryActionsTests` the inspector's Apply to all
displays (offered only with two displays that can take a wallpaper; a failure restores
them).
Not covered: real WindowServer transitions, visible appearance and separate
per-Space assignments; see
[display layouts](../features/display-layouts.md#code-and-verification).

## Diagnostics

- `AppLogRouterTests` — lines logged before the bridge keep their time and order
  and are written when it attaches; overflow is reported, not silent; loads start
  only once the log is open; concurrent lines all arrive.
- `DiagnosticsRedactorTests` — home paths in all forms, user and account names
  as whole tokens only, SteamCMD sign-in names, credential values, the beta
  identifier of macOS reports.
- `DiagnosticsBundleTests` — newest sessions first (including `-N` suffix order),
  the byte budget with tail truncation, crash-report prefix, age and count
  filters, a missing extension log noted, the load journal, resource, spin and
  hang reports from both report folders (prefix, extension, age, `Retired/`,
  count, the host name dropped from stored names, an oversized file's tail, an
  unreadable system folder noted without failing the export), and the zip's
  actual entries.
- `SessionLedgerTests` — a record is classified as clean quit, stalled quit,
  unexpected end, system restart or exception (the exception outranks the phase),
  with the boot session compared exactly and an unknown one never called a restart;
  the ring keeps five sessions and counts unexpected ends in a row; an unreadable
  or foreign-format file reads as a first run and is replaced; a refused quit goes
  back to running; a session writes the file three times and nothing writes it
  again; an older copy does not rewrite a newer copy's record; every quit reason
  survives to the next launch and is named in its report, for a finished quit and a
  stalled one.
- `CrashReportIndexTests` — a report is matched by process id and boot session in
  its body, not by name; wrong prefix, wrong extension, another boot, an older
  file, a header without a body and a malformed body are passed over.
- `UncaughtExceptionLogTests` — an exception is logged as one line with its name
  and reason, and the next launch reads it from the ledger.
- `DiagnosticEnvironmentTests` — a running scene's report line carries the
  renderer's live mode (a scene stopped after a failure reads apart from a paused
  one), keeps where it runs and what drew it, and says nothing about the mode
  when there is no reading.
- `RuntimeCountersTests`, `RuntimeDiagnosticsReportTests` and
  `RuntimeDiagnosticsWindowTests` — counters record only inside an open,
  self-expiring session, per surface, with a bounded table; the report keeps
  surface-exclusive and shared work apart, never labels present requests as
  displayed frames, and states the milliseconds it counted.
- `MemoryPressureMonitorTests` and `ProcessFootprintTests` — each pressure level's
  report with the footprint and presenting-scene count, the length of a stretch of
  pressure, the 5-second collapse of repeats, an unreadable footprint staying unknown
  rather than zero, one test pinning the wording of the two lines the diagnostics doc
  shows, and the footprint of the test process growing with the memory it touches.
  The footprint-growth case touches a fresh anonymous mapping, not reusable heap
  pages already charged to the host; its 32 MB growth margin and bounded attempts
  stay unchanged. A real pressure transition is not provoked.
- `EnergyUsageMonitorTests` and `WallpaperEnergyRatingsTests` — coalition
  readings, contention, before/after comparisons, grades, battery share and the
  rating recorder; two `testKernelCounters…` cases read the test process's real
  kernel counters.

Log line format, retention and the verbose setting are covered in Rust; see
[diagnostics](../features/diagnostics.md#verification).

## GitHub

`AppUpdateTests` use fixture JSON, a fake client and isolated `URLSession`
responses; they never contact GitHub, download a real release or replace the
running app.

- Checking: version comparison, disk-image asset selection, the manifest path
  that spends no API request, host allowlisting, SHA-256 digest requirement,
  rate limits, progress clamping, classified errors and install retry/timeout. A
  missing latest release is normal only after the repository is confirmed
  reachable; missing repositories, failed lookups and malformed metadata remain
  errors, and rechecking clears stale notes and availability.
- Installing, against real disk images made with `hdiutil`: the app is copied out
  without following the `Applications` link, a foreign bundle is refused, the
  image is detached either way, and an app that cannot install in place opens
  the downloaded image.
- `UpdatePresentationTests` and `AboutSettingsTests` (Panel) walk the About card
  from no release through the download to an install that needs a yes.
- `UpdatePromptGateTests`: when the unattended alert is held (suspended
  presentation, a covered display, What's New open, quitting), that the control
  panel in front overrides the presentation holds, and that a held prompt is
  offered exactly once after the hold lifts. The alert itself, and leaving a
  full-screen app, are on [manual-smoke.md](manual-smoke.md).

`WhatsNewTests` — what a launch announces across fresh installs, upgrades that
skip versions, downgrades and language choice. Not covered: a live release
check, the published disk image and replacing the app in Applications; these are
on [manual-smoke.md](manual-smoke.md).

## Library

- `ImportTests` — atomic adoption, duplicates never overwrite, concurrent
  destinations keep one whole project, cancellation never commits an incomplete
  project, rejection of traversal, links, special and incomplete content, and a
  bad sibling not blocking a good one; downloaded projects move whole, an update
  replaces the installed tree, and Workshop presets are assembled on a base that
  was downloaded with them, is installed, or sits beside them in a Steam library,
  and are rejected without a usable base. Where a chosen folder is searched (a
  Steam library, `steamapps`, a Wallpaper Engine install or a copy of it, its
  `projects` folder and either half), a chosen `project.json`, `scene.json` or
  `.pkg` standing for its folder, and links refused in the file, its folder and
  the manifest beside it, are covered, as is the Workshop id a renamed project
  takes from its manifest or link (and the values that are not one), which
  follows the duplicate policy when already installed. **Keep both** copying
  nothing the library already holds is covered for folders, videos and HTML files
  (a one-byte change across chunk boundaries, a same-length manifest edit, added,
  missing, renamed and resized files and folders, Finder's `.DS_Store` on either
  side, the app's `.mwe-user-assets` bridge in the installed project, links in the source and in the library, a preset, an identical folder that
  is not a wallpaper, and cancelling during the comparison). **Replace if changed**
  is covered for a changed folder (the old tree gone, not merged, no staging left),
  identical content left unswapped, one import mixing changed, identical and new
  projects, repairing an install that cannot play, refusing a folder without a
  manifest, a file and a link, a failed swap (a locked folder) keeping the installed
  project, cancelling, and a single file; the panel's choice naming the policy
  (anything unknown stays on skip) and `LibraryImportStore` reloading only replaced
  projects, after the rescan, are covered too, as is a quit not waiting for a rescan or a
  reload still running and starting none it had not begun. Not covered: the speed
  of comparing a multi-gigabyte project on an external drive, and a display
  reloading a replaced wallpaper. Fetching a preset's base in the same
  SteamCMD run is in `DownloaderLifecycleTests`, with a base that is denied, exits
  early or keeps dropping the connection reported as the base failing (naming it
  and keeping Steam's reason), the preset's own failure left as it is, and Try again
  resuming from the kept preset.
- `ImageImportTests` import real ImageIO pictures as the still `web` project with
  the original's bytes kept and the file name kept out of the page, the fit
  chosen from the picture's shape, a JPEG display copy for a TIFF, an undecodable
  file refused, **Keep both** keeping the `image-` prefix for a different picture
  and copying nothing for the same one, and `LibraryImportStore` refusing a second
  import and rescanning once.
  `StillImagePlacementTests`, `StillImagePageUpgradeTests` and
  `StillImagePageRenderingTests` (offscreen) cover per-display placement
  persistence, fit-aware geometry, the version-bound upgrade of generated pages
  (never overwriting an author edit), actual resource changes and reset races.
- `WallpaperImportPickerTests` exercise real child processes: cancellation before
  launch, reaping after cancellation, cleanup when activation fails, invalid
  handshakes, failed exits not treated as user cancellation, and concurrent
  helpers. `WallpaperImportStagingTests` — a live claim protects an import and a
  released one is reclaimed. Not covered: the native picker's localization and
  the selection-to-parent URL handoff (these tests open no picker), and the
  Finder/Dock hand-off.
- `DeletionTests` and `BatchDeletionTests` — only the managed copy goes to the
  Trash, the source is preserved, traversal and symlinks are rejected, a Trash
  failure leaves the wallpaper in the library, a batch continues past failures
  and refreshes once.
- `WallpaperCollectionStoreTests` — stable identity and ordered membership across
  reload, rename and deletion; invalid names apply nothing. `NextWallpaperTests`
  — library order, skipping unsupported wallpapers, wrapping.
  `WallpaperHistoryStoreTests` — per-display persistence, bounded recent lists,
  repeated Previous, removal and clearing.
- `WallpaperPresetStoreTests` — typed applied-property snapshots (the listed
  properties only, with a rule-hidden one still known to a preset that names it),
  portable managed attachments, size limits, alias rejection, draft and
  permission rollback, and applied-source retention after deleting a preset.
- `WallpaperBackupTests` — real package export, preview, staged next-launch
  restore, conflict policy (Keep existing, Replace), parser and schema rejection,
  authorization, rollback and interrupted recovery, persistent-only preferences,
  full-size preset archives and manifest preflight. `PanelStorageActionsTests` and
  `StorageSettingsModelTests` (Panel) turn the Storage page's choices into the
  requested pending restore and open no file panels.
- `WallpaperCompatibilityTests` — target, content and configuration generations
  and truthful unknown states. They do not establish complete scene or on-screen
  compatibility.
- `LetterboxDetectorTests` — the black-bar decision over synthetic luma frames:
  letterbox, pillarbox and windowbox edges within a row, hairline edges ignored,
  noisy black and a logo or subtitle inside a bar, fades and dark scenes skipped,
  disagreeing, lopsided and implausible bars. `LetterboxZoomTests` — the Fill scale
  factor for a given display worked from the engine's layout (16:9, 16:10, 4:3 and
  ultrawide), rounding up and the limits. `VideoLetterboxProbeTests` — the probe
  over injected frames (repeats counted once, orientation kept, large frames
  measured at the same fractions), plus unreadable, audio-only, timed-out,
  cancelled and replaced files; nothing in it decodes video.
  `VideoLetterboxProbeMediaTests` — opt-in (`WALLPAPER_MACHINE_MEDIA_TESTS=1`, see
  [README](README.md#opt-in-layers)): small generated H.264 clips with bars painted
  at known rows are decoded through `AVAssetImageGenerator` (a few frames, no
  player, window or audio) for letterboxed, pillarboxed, top-only, full-bleed and
  all-black pictures; skipped in the routine gate, so the bar edges measured on real
  decoder output are not covered unless it is run.
  `VideoLetterboxStoreTests` — results per library revision, one probe at a time,
  cancellation writing nothing, the 16-entry bound, and confirming a result against
  the file before it is acted on (a replaced file drops it, a newer check landing
  meanwhile refuses it). They do not show how the factor
  looks on a real display, nor real wallpapers with burnt-in subtitles, fades or
  anamorphic pixels.
- `LibraryMetricsTests`, `ClientPreferencesTests` — folder size and date measured
  off the snapshot path, manifest approval and tags, and an explicit defaults
  suite staying independent of the application's own preferences.
- `LibraryCoverStampsTests` — preview stamps read after the snapshot answered and
  announced once per pass, a rescan that replaced nothing announcing nothing, a
  replaced preview (by size or by time) keeping its old stamp until the new one is
  read and then announced, a wallpaper that left or whose preview moved having
  nothing known, an unreadable preview stamped 0, and an ask made while a pass was
  reading not being lost.

## Lifecycle

- `QuitReasonTests` — the reason a quit is given for every combination of what the system
  told the app: a signal beats everything, the system leaving beats an update, an update
  beats a plain quit, the event's own reason beats the power-off announcement, an unknown
  code is not taken for the user's; the codes match the SDK's; the reason is read from a
  real `NSAppleEventDescriptor` parameter and not from an attribute, text or an integer; an
  announcement stops counting after its lifetime and after a refused quit. They also pin which
  reasons make a power-off quit (the three kinds, and a signal that arrives during an announced
  shutdown, but not a user's quit, an update or an unknown reason) and the text the session
  ledger keeps for a quit that left the desktop unrestored or a stage running.
- `QuitTimingsTests` — stages keep their own duration in the order they were settled, a stage
  that failed is timed and says why in the log, a stage that was left behind is marked and keeps
  how long it was waited for, the total covers the work between stages, one line per stage plus
  one summary. A scripted clock, no sleeping.
- `QuitSupervisorTests` — stages run in order and every duration is logged once; restoration
  that throws or never returns cancels the quit and teardown does not start; a stage that
  finishes after its deadline changes neither the outcome nor the log; a hanging teardown
  stage is named and the stages after it still run; teardown stages share one budget, a stage
  with no time left is still started, and the last one keeps its floor; a teardown stage that
  throws does not stop the quit; the exit fuse is shorter after a stalled stage and fires
  once, off the main thread. The deadline is a scripted sleep fired by the test and the
  budget each stage was given is the sleep it waits for, so nothing depends on machine
  speed; one test runs the real timer with tiny budgets. `FirstResultTests` pin that the race
  resumes its waiter once however many results arrive. For a logout, restart or shutdown
  (`QuitMode.powerOff`): restoration that throws or never returns lets the quit go on
  without refusing it, the teardown still runs, the restoration is waited for 3 seconds
  and not 20, the teardown has 1.5 seconds with a one-second floor for the last stage, and
  the same failure still refuses a user's quit. `QuitRequestAnswerTests` pin the answer to
  a request that arrives mid-quit: a second user quit is refused, a logout during one waits
  for it, and anything during a power-off quit waits.
- `AppUpdateTests` (GitHub) also pin when an install counts as pending: not while the
  update is prepared, yes once the installer waits and the app is asked to quit, not when
  the installer could not start. They also pin that a refused quit stops the waiting
  installer once, leaves the update to install again, does nothing when no installer
  waits, and keeps a helper that would not stop owned.
- `TerminationSignalRelayTests` — real SIGUSR1 and SIGUSR2 stand in for SIGTERM and SIGHUP, so
  a failed install cannot take the test host down, and the forced end is always injected: one
  signal asks for one quit and the process survives, a second signal or the deadline forces
  the default action instead of asking again, back-to-back signals are one request and one
  force, a reset after a refused quit lets the next signal ask again, each signal arrives
  with its own number, `stop` restores the disposition that was there (not the default), an
  ignored signal stays ignored, a child started with `posix_spawn` sees the default
  disposition (the probe is first shown to see an inherited ignore, which Foundation's
  `Process` would hide by resetting every signal) and both pipe ends are close-on-exec and
  non-blocking. `QuitReasonTests` pin the ledger text of a signal's quit, `QuitSupervisorTests`
  the longest a quit can take (the signal deadline) and `SessionLedgerTests` that a run cut
  short before it began quitting reads as a quit that did not finish, not a crash.
- `ProcessSignalsTests` — SIGPIPE is set back to its default before each call and the guard is
  checked before any write, so a guard that failed to install costs one test and not the
  test host: a write to a pipe whose reader is closed fails with `EPIPE` and the process
  survives, a `FileHandle` write throws it as a POSIX `EPIPE` error, a second call keeps the
  same handler, an ignored SIGPIPE or a handler already in place is left alone, and a child
  started with `posix_spawn` sees the default disposition (the shared `ChildSignalProbe` is
  first shown to see an inherited ignore, as in the relay's test).
- `InstanceLockTests` use temporary folders, an injected clock and an injected process table:
  the claim and its recorded holder, a second claim turned away after the grace, hand-over on
  release, a quitting holder waited for beyond the grace and for as long as the longest
  interactive quit may take, a claim never inherited by a surviving child, a dead, unreadable
  or unusable lock never blocking launch, the decision table, and the classification of the
  running holder. See
  [crash recovery](../features/crash-recovery.md#single-instance).
- Not covered: a real quit, logout or restart; `applicationShouldTerminate` itself needs
  the running app (hosted tests short-circuit it), so the alert, the panel coming back, the
  "Quitting…" menu line, the exit fuse's `_exit`, whether macOS shows its cancelled-logout
  dialog, how AppKit treats a request answered with `terminateLater` while another is
  pending, the retry of a user's quit that a logout interrupted, and a real `kill -TERM`
  ending in an ordered quit (including whether the main run loop wakes for it while the
  panel's modal alert is up) are desktop-only observations ([manual smoke](manual-smoke.md#native-desktop-posters-and-mission-control)).
  The single-instance hand-over is not covered either: activating the first copy, the alert
  for a copy from another path and the post-update relaunch need a desktop run
  ([manual smoke](manual-smoke.md#launch-and-window)).

## Localization

`AppLanguageTests` cover the preference store: system matching, persistence, the
`AppleLanguages` mirror, rejected tags and the snapshot offering every shipped
language under its own name, and that every language names a distinct, well
formed Wallpaper Engine locale for a wallpaper's own label tables. How those
tables resolve is covered by the bridge crate's `tests::property_snapshot` and
`project::localization` tests, since a Swift test cannot put a project in a real
bridge; `PropertyLabelLanguageTests` cover the app's side of it: the language
list sent, the open inspector read again and relabelled, a read that finishes
after another wallpaper opened dropped, and a refused request never undoing the
language choice. The Python catalog checks
(`scripts/tests/test_panel_localization.py`) keep the registries, catalogs and
`.xcstrings` naming the same languages and keys, and every phrase of the panel's
built-in label table translated in every catalog; see
[localization](../localization.md).

## LockScreen

The native-selection and service suites run against a synthetic store and injected
services. They never mutate LaunchServices or PlugInKit, select a real wallpaper
or depend on a second physical monitor.

- `LockScreenWallpaperTests` (selection journal) — per-display ownership with
  independent originals; external Desktop changes survive; a reload failure
  leaves a recoverable journal; inherited, linked and system-copied selections
  restore, or stay recoverable after a reload failure; later global Desktop and
  Idle edits are preserved; malformed baselines are rejected without store
  writes; an unchanged journal is not rewritten; a concurrent store change keeps
  the union. The same class holds the scene contract the extension reads: a file
  without a position reads as centred and one with it round-trips, an unmoved scene
  keeps the old file shape, a moved picture or a changed scaling mode replaces the
  renderer while frame rate, title and pause do not, no position and the middle are one
  picture, and an out-of-range or non-finite position is invalid.
- `LockScreenWallpaperServiceTests` — activation failure hands the Desktop back
  to the poster provider; surviving lock screens are not cleared by topology
  changes; screen-saver-only, lock-only and both modes disable and roll back
  independently; shared-extension and Idle-only publication failures roll back;
  stale failure reports are ignored while a current renderer failure restores the
  selection; one bounded automatic retry repairs a wrong extension copy; shutdown
  restores native choices before waiting for Desktop restoration; a switched-off
  renderer stops activation at once and only the user's Retry (lock-screen or
  screen-saver) switches it back on, once per click, never from the monitor after a
  relaunch, after another failure, after a click that had nothing to activate or
  from switching a mode off and on again; a scene or video publishes its display's position
  and a web page none, and moving the picture publishes a new revision that reuses the
  project while the same position publishes nothing.
- `LockScreenVideoPlannerTests` — which player plays a plain video on the lock screen: the
  AVFoundation layer when admission accepts the clip (the frame rate it was given takes no
  part), the WebM player for a file AVFoundation cannot open that the project's reader takes,
  and `unplayable` with the reason for every refusal (not playable, unreadable), for a clip
  that is missing, and for a path that leaves the project, never another renderer; that
  nothing that is not a plain video takes a video player; that a file AVFoundation cannot open
  (garbage bytes, a missing file) fails the player's `prepare()`, which is what makes the
  surface hold the clip with the reason; that the attempt's deadline expires on an injected
  clock without waiting and is bounded below the surface's 30 seconds; and that a player
  failure that beats the handler's assignment is delivered once when it is assigned.
  `LockScreenHeldFailureTests` covers the engine's stages and the `video` stage the extension
  itself reports. The surface wiring lives in the extension target, which no unit test
  compiles, so it is checked by building it. `LockScreenWallpaperTests` also covers the
  configuration keys `plainVideo` and `nativeVideoFile` (round trip with and without, which
  changes replace a renderer, and that a changed frame rate replaces neither a video player
  nor the scene engine), that a `sceneRenderer` key an older app wrote is read past whatever
  it names and that none is written now, and the service tests that a video project is always
  published as a video, with its media file when the app finds it, and that a refresh that
  changes nothing publishes nothing. Not covered: a real lock screen, the player playing a clip there.
- `LockScreenExtensionRegistrationTests` use synthetic app bundles and an
  injected registry: current-copy selection, duplicate and removed-copy cleanup,
  symlink aliases, invalid inventory rejection, cancellation, command failures;
  stale extension processes are ended only after the registry confirmed the
  intended copy and never after a failed, conflicting or cancelled registration;
  every election mark is parsed (including superseded and disagreeing versions at one
  path) and only an ignore on this app's copy stops activation, with the specific
  failure and nothing ended; the repair runs exactly one `pluginkit -e use`, reads the
  registry back, reports an election that does not change or a refused command, and
  leaves an election alone that is not this copy's ignore.
  `LockScreenExtensionDiagnosticsTests`, `LockScreenSurfaceRegistryTests`,
  `LockScreenIdleExitTests` (including the open-connection count the close line
  reports) and `LockScreenFrameBackingTests` (snapshot pixels composited under a Metal
  layer without a drawable) cover the extension side.
- `LockScreenFirstFrameTimingTests`, `LockScreenRequestShapeTests` and
  `LockScreenConnectionTraceTests` — the log measurements: first-frame timing classified
  at its 10 s and 20 s thresholds (with the near-limit warning before the agent's 31 s),
  the seconds field printed with one decimal; request shapes reduced to sorted dotted
  field names that never contain the values (optionals looked through, an enum case named
  only when it carries a payload, dictionary keys and set members left out, names that are not
  identifiers hidden) and bounded in depth, count and line length; and a connection's served
  count exact under concurrent calls. Which fields the system's real requests carry, and how
  long real first frames take, are what the extension logs report after a desktop run.
- `LockScreenExtensionProcessesTests` — which running extension processes are
  stale (another bundle; a binary replaced after launch, by a newer file or by a
  copy that kept its source's old dates but holds another build than the one
  running; or a process whose files are gone and whose build UUID is not the
  registered executable's, with file dates playing no part), SIGKILL only for
  survivors of the SIGTERM wait, a changed pid identity never signalled, nothing
  sent when cancelled, and the live libproc table against a child the test spawns
  itself (path, start time, replaced-binary detection by date and by a
  date-preserving copy of another build, the path-less state after its bundle is
  deleted, reused-pid refusal). `MachOImageUUIDsTests` — the `LC_UUID` reader on
  synthetic thin and universal images, malformed and truncated input, and the test
  host's own executable against the UUID the kernel keeps for it. The registration's
  default process table is inert, so tests never touch the installed extension.
- `LockScreenXPCDriftTests` — the comparison of the extension's XPC protocol with the
  system's: class annotations ignored while type codes and block signatures count, a
  Boolean reply differing from an object reply, missing/extra/differing selectors listed
  sorted, and the live runtime's encodings of an Objective-C protocol. The request
  handlers live in the extension target, which the unit tests do not load; their
  agreement with the system is what the drift line in `extension.log` reports.
- `DisplayPowerProbeTests` — a known display answering for itself, a display-less
  surface counting as asleep only when every online display is, no displays not
  counting as asleep, and the power state read at each question rather than remembered.
- `LockScreenReevaluationBurstTests` — a check now and one at each offset, a newer
  trigger retiring the earlier burst even for a check already on its way, cancel, and
  the sleeping schedule running each check once and not running a cancelled one.
- `WallpaperPresentationAuthorityTests` — both display/host wake orders, user
  pause surviving sleep and wake, a lock-screen surface presenting only while
  locked, and an unlocked one settling for `desktopSettleBudget` before it holds
  a frame.

Not covered: the extension drawing a moved picture at its position, real lock-screen
visual timing, private XPC snapshot transport, the wallpaper service's wake and
time-change notices completing, the real display power
and session state after sleep, wake, lock and unlock, live
registration repair, ending a genuinely stale extension process, a really ignored
renderer being switched back on and macOS choosing the intended extension copy; these
need an authorized runtime check
([lock-screen](../features/lock-screen.md#verification)).

## NativeVideo

- `NativeVideoAdmissionTests` — a clip is admitted at every rate it was written at
  (including 120 fps) and as a variable-rate clip, since it plays at its own rate; refusal
  of corrupt, missing, audio-only and unplayable content.
- `NativeVideoLoopRangeTests` — one pass of the loop is the video track's range: a clip
  whose audio runs past its picture loops with the picture, a silent clip loops all of it,
  and a clip with no readable picture loops the whole item. `NativeVideoPlayerMediaTests`
  (opt-in) check that every copy the looper queues stops at the end of the picture.
- `VideoFormatSupportTests` — the container told from the first bytes (the extension is not
  trusted over them; a file whose bytes show none is named by its extension), codec names, and
  the rule: a playable clip with a video track is supported, AV1 is refused without hardware
  decode and named as AV1, a file nothing opens (or with no video track) is refused with its
  container and codec named, Matroska and WebM that AVFoundation cannot open are tried with the
  app's own reader (playable ones are `supportedWebM` and keep their opened file for the surface, the
  rest are left to the scene engine), an unreadable file refuses nothing; real files: an H.264 clip supported, garbage
  named by its extension, an audio-only file refused, H.264 in Matroska supported by the WebM player, VP8 left to the scene engine. `WallpaperActivationRecoveryTests`
  checks Apply, Apply changes and an AV1 verdict refuse before the renderer is reached with the
  format named, and the same wallpaper applies once its file plays.
- `WebMOpeningTests` — the WebM reader through Swift: the properties of a VP9 file, the sample
  buffers (decode order, key frames, seeking), Opus audio as float buffers, VP8 named and refused, junk
  and a cut-off file and a missing file told apart, and the poster. `WebMPlayerTests` — the feeder over
  recording sinks (the wrap at the end with time continuing, one pass of audio cut where the picture
  wraps, repositioning to the key frame before a time and dropping sound the clock has passed, a turned
  clip's axes), and the player on a layer that is not in a window: first picture, running and looping,
  pause and resume, start paused, a restart that spends its allowance, an upright poster, a decoder
  that refuses the frames. `LockScreenWebMPlayerTests` (the lock screen's WebM player: the first frame composed at the display's size, pause with a frame still readable, a stop before the first picture ending `prepare`, a held failure delivered once) and the planner's WebM cases (`LockScreenVideoPlannerTests`: an unplayable answer goes to the reader, only that answer, and a file the reader refuses keeps AVFoundation's reason). `WebMVideoWallpaperWindowTests` — the desktop surface for WebM: ready and
  playing, user pause and suspension as separate reasons, the scaling choice and position moving the
  picture, a file that cannot be opened failing as a verdict (held until a handler arrives), a window
  opening its own file, the poster at the display's size, stopping.
- `NativeVideoWallpaperHostTests` — startup waits for surface readiness, a refused
  wallpaper is reported as a failed display with its reason (no window, nothing takes the clip
  over, the failure and its message in the wallpaper's state, read once and not reopened for every
  snapshot, judged afresh when the file changes; a failure that is not a verdict on the file is
  restated for its own startup revision and tried again under a newer one), re-evaluation
  when the admission key (the file) changes, one surface per display, a mirror group
  judged once under its source's key, hidden-display and user-pause handling, a clip stopped
  by a reading taken while the desktop (or one display) was covered playing again
  once `WallpaperHosts.reconcile` has the host read the bridge again (that
  `AppDelegate` makes the call after each delivery is not run by any test),
  posters from replaced surfaces not published, and the switch hold (see
  [Wallpaper switching](#wallpaper-switching)). `NativeVideoPlaybackFailureTests` — the
  reported failure keeps the codes under the localized message and a clip with
  sound is rebuilt with its picture alone.
- The metadata-read bound, in the host suite with a hand-fired clock
  (`ManualSleeper`) and a read held open by a gate: a read that never returns is
  abandoned after the limit for its storage (8, 30 or 60 seconds, per class) and the
  display is reported as failed with a reason that says the read did not finish; the
  timeout is not retried in the pass, not cached as a verdict (a newer startup revision reads
  the file again), and counted as
  `nativeVideoProbeTimeout`; each retry is bounded too; the same file has at most one
  read outstanding and is answered at once while it is, and a pass cancelled before a
  retry's read begins leaves no read outstanding; a close queued behind the
  stuck pass happens in the next one; and the storage is not classified again for an
  offer that opens nothing. `NativeVideoDeadlineTests` — the race itself: the operation,
  the timer or the caller's cancellation wins, the caller is always released, the
  loser's timer is cancelled, and a late result of a read that nothing cancels is
  dropped. `NativeVideoStoragePolicyTests` — the classification order over every
  combination of volume flags (an unreadable flag is never taken as internal), the
  deadlines growing with slower storage, a missing file reading as unknown, and a
  classification that never returns counting as unknown after 2 seconds.
- The first-frame deadline, in the host suite with the same hand-fired clock and a
  fake surface that never reports a frame: the first miss asks the surface to restart
  and starts a second deadline of the same length, the second miss reports the display as
  failed once, under its admission key, closes the window and ends its startup, a restart
  the surface refuses fails it at once (the text of the reason is not pinned),
  and each missed deadline counts as `nativeVideoFirstFrameTimeout`. The deadline is
  10, 30 or 90 seconds per storage class; a frame before the deadline stops the
  countdown, and a frame after the failure, a replaced surface, a closed surface and a
  shut-down host leave nothing to fire. A display that is hidden (on its own or
  globally) is not judged: the watch parks and starts again with a full deadline only
  when every reason has ended, keeping a restart it had already spent; a user-paused
  clip is still judged, and one display's frame settles only its own watch. A timeout
  is not remembered by the host as a verdict, so a newer offer of the same key opens again,
  while a decoder failure still is. `NativeVideoRecoveryBudgetTests` — two rebuilds per window and a refusal
  after that, the allowance returning as old rebuilds leave the window, a stable run
  forgiving the history (measured from its first frame, interrupted only by a
  permitted rebuild, not by a refusal), and a reset.
  `NativeVideoPlayerMediaTests` (opt-in) add the real stall: an `hev1` clip
  (`Hev1Fixture`, skipped when an OS decodes it or rejects it outright) reaches
  ready with no picture size and no layer frame, is restarted twice and then refused,
  with every replaced item released; a healthy clip restarts and plays again, its
  stable run earning the allowance back through the injected clock; and a restart
  never starts a paused clip and is refused after a stop or a reported failure.
- The liveness check and its repair after a long pause or a wake. `NativeVideoLivenessTests` — the pure rule: a
  new picture plus a clock that moved by about a frame is advancing, in any order across
  samples; a clock that runs with no picture (what an `hev1` pipeline looks like) is
  stalled, and so are pictures with a frozen clock and neither; less than a frame of
  movement does not count but builds up across samples; time going backwards and a new
  item are the loop wrapping, and a new item is never picture evidence; times that are not
  finite anchor nothing; a player waiting for data throughout, or a window with nothing to
  sample, is waiting rather than stalled. `NativeVideoHealthSupervisorTests` — with a
  scripted target and the hand-fired clock: a healthy pipeline is reported and sampling
  stops at the proof; a dead one is reported only after the whole window and the window
  bounds the samples (20 for the default policy); waiting and sample-less windows are
  reported as such; a surface that cannot be judged is not even waited for, and one that
  stops being judgeable during the settle or mid-run is dropped without a report; a cancel
  releases what sampling attached at once; a newer trigger replaces a check that is only
  looking and starts over from its own settle. `NativeVideoHealthLadderTests` — the order of
  repairs as a pure rule: a kick first, a rebuild only if the kick did not help, then the
  give-up with what was seen and tried; a rebuild the budget refuses is given up at once
  after the kick; a player that only waits is looked at twice more before it counts as
  stuck, and that patience is not renewed by a repair. The supervisor suite then runs the
  ladder against a scripted target: a dead pipeline gets exactly one kick, one rebuild and
  one report, in that order, with a settle before each look and the longer window after the
  rebuild; a kick or a rebuild that brings pictures back ends the check and tells the
  target; a refused or unstartable rebuild is reported instead of tried; a pause or cancel
  mid-ladder stops every further repair; and a trigger that arrives once repairing has
  begun is absorbed rather than kicking twice, while one that arrives after the ladder ended
  starts its own. `NativeVideoRecoveryBudgetTests` also pin that asking whether a rebuild
  is open charges nothing and agrees with the real request. The host suite checks that a
  stalled report is counted as `nativeVideoPlaybackStalled` once per check, at its first
  look, and that the host does nothing about a report itself, that healthy and waiting
  reports are not counted, and that a report from a replaced surface is ignored. A failure
  after the ladder gave up (an unsettled failure) is not remembered by the host as a
  verdict, so a newer offer of the same key opens again, while a settled
  decoder failure still is. A wake
  (displays, Mac or session, each of the three) asks only the surfaces that are playing to
  verify, after a settle and not before; a burst of notifications is one request; a
  surface that stopped playing during the settle is not asked; a host with no surface open
  starts no settle; and a shut-down host ignores wakes and cancels the settle in flight. `NativeVideoPlayerMediaTests` (opt-in) add the
  real player: a healthy clip resumed after a long pause, or woken, is reported advancing,
  never kicked or rebuilt, with its item untouched and nothing left attached; only a
  pause of at least 5 seconds (user or hidden display) starts a resume check and pausing
  again cancels it; a paused or hidden clip is not checked by a wake; an `hev1` clip
  (skipped when an OS decodes it) is never checked because it never showed a picture, and
  sampled by hand its clock moves while no picture is produced, which is the stall a
  time-only check would miss. Marked as having shown a picture once, the same clip is the
  dead pipeline a reclaimed decoder leaves: it is kicked, rebuilt and reported exactly
  once and as unsettled, the counters show one kick and one rebuild, every replaced item
  is released and the check survives its own rebuild; with the allowance spent by earlier
  restarts it is kicked and reported without a rebuild; and a rebuild requested elsewhere
  ends the check
  at once, so it reports nothing more and rebuilds nothing. A kick leaves a healthy clip
  playing and does not start a paused one. Sampling follows the loop to its next copy; a
  paused clip stops reporting pictures; and a stopped player has nothing to sample.
- A pass overtaken while it waited, in the host suite with a metadata read held open by
  a gate while the next snapshot arrives: a wallpaper that was replaced, dropped from
  the native list or given another admission key by then is never built (the host
  records every surface it makes, so one built and closed again would show), and the
  startup it began is ended by the next pass. A burst of snapshots that keep offering
  the same wallpaper does not abandon its open, and the clip starts at the latest
  volume; a bridge that cannot be asked presents the wallpaper as offered. A second
  `apply` in flight drops the older one, including the files it had still to read and
  the settings it would have put over the newer pass's. A display that vanished or
  moved while a file was read gets no surface or the frame it has now, and the next
  pass opens it from the kept verdict without reading the file again.
- A display the bridge offers that the host's screen list lacks, in the host suite with the
  list edited between passes: the offer for the missing display builds no window and reads
  no file, is not refused (so the bridge keeps offering it), and is recorded in
  `offeredButUnseenDisplayIDsForTest`; the display that is listed still plays. The warning is
  logged once per wallpaper and display however many snapshots follow (read through a
  counter, since the log is global), again for a different wallpaper offered there, for an
  offer that went away and came back, and for a display that was listed in between and
  went missing again. A listed display that drops out is closed and the same offer opens it
  when it returns, and a display that returns inside the refresh filter's settle (no refresh,
  no snapshot) is opened again by the filter's announcement, driven through a real
  `DisplayRefreshCoalescer` rather than a hand-called `apply`; shutting down forgets the
  set. Not covered: whether a real mirror set, AirPlay screen or closed lid makes the lists
  differ.
- `NativeVideoLayoutTests` — where the picture goes under Fit, Fill, Stretch,
  Original size and a scale factor: the rectangles equal the numbers the
  renderer's own `ComputeWallpaperScalingLayout` gives (Original size is one video
  pixel per point; an unusable factor is 1; rounding ties fall on the renderer's
  side), degenerate sizes and absurd factors stay valid, and the plain modes at
  factor 1 stay AVFoundation's gravity while Original size and a factor wait for the
  picture's size, and a position (the room is divided as the renderer divides it, an unusable
  one is held to the edge or the middle, and any position but the middle needs an explicit
  frame because gravity centres); Fit with blurred backdrop is laid out exactly as Fit,
  black bars and all, since the player has no blurred fill. The host suite checks the user's mode, factor and position reach
  a running surface without reopening or re-probing it, each display keeping its own, and the
  desktop-picture poster is drawn with the same layout (Fit leaves black bars, Original size is
  not scaled to the display, a factor zooms, a position puts the picture in its corner); the
  player suite places the live layer for a position (flush to each edge, gravity back at the
  middle, a position that is not a position held to the edge or the middle). To regenerate or extend the expected rectangles, compile
  `Renderer/Engine/src/Presentation/WallpaperScaling.cpp`
  directly (it needs no GPU header), hand `ComputeWallpaperScalingLayout` the display as
  `lround(devicePixels / scale)` logical points (as `MetalRender::Impl::scalingLayout`
  does), and print `viewport_px`.
- `NativeVideoPosterOrientationTests` — which clips cannot take a poster from
  the playing item: the display matrix of real generated clips (rotated by 0, 90,
  180 and 270 degrees, one mirrored, and a movie with no picture) is read back,
  and every one but the upright clip selects the one-shot image generator.
  Metadata only; no player is created.
- `SyntheticVideoFixtureTests` cover the generated-clip writer's input-ready
  waiting; the writer can store a clip rotated by a display matrix.
  `NativeVideoPlayerMediaTests` drive the real player and are opt-in
  (`WALLPAPER_MACHINE_MEDIA_TESTS=1`, see
  [README.md](README.md#opt-in-layers)). Among them, the player layer lands where
  the layout says (`AVPlayerLayer.videoRect` for Fit and Stretch, the layer's frame
  for Original size and a factor, for an upright and a quarter-turned clip; Fill's
  crop is not observable because AVFoundation clips an aspect-fill `videoRect` to the
  layer, so only its gravity is asserted), moves
  when the display is resized or its density changes, and a window follows its screen
  frame without being shown; the poster of a
  portrait-rotated clip has the picture's orientation and size and matches an
  upright reference frame, a paused rotated clip still answers without resuming,
  and an upright clip keeps reading the playing frame (`nativeVideoPosterFallback`
  stays 0).

Not covered: first frames presented on a real display, a rapid A, then B switch on
a real display (that no window of the replaced clip appears, even briefly), the Mission Control
or other-Space poster of a rotated clip as macOS shows it, a side-by-side of
Fit, Original size and a scale factor on a real display against Compatibility
(including the composition cost of a large factor), and a genuinely stuck volume (a
sleeping external disk, an unreachable share, an evicted cloud file) with the restart,
the failure and the reason they produce in the wallpaper's state: the limits and rules are
covered, and the frame-less clip by the opt-in `hev1` test, but no test blocks a real
`AVAsset` load or starts a clip from a volume that is slow to answer. Also not covered:
whether a real long suspension, sleep, lock or covered desktop (hours, display sleep, Low
Power Mode) ever costs a clip its decoder on this Mac, and whether a kick or a rebuild
brings one back. The check and the ladder are covered, and so is the dead pipeline they
must recognise (`hev1`, which a kick and a rebuild cannot repair, so it always ends in the
failure), but nothing here reclaims a decoder and no test shows a repair that works on
a stuck pipeline. Those premises are answered by the `nativeVideoPlaybackStalled`,
`nativeVideoPlaybackKick` and `nativeVideoPlaybackRebuild` counters on a real machine, and
by the sleep, lock and unlock rows in [manual-smoke](manual-smoke.md#native-video-backend-experimental-opt-in).
Most of the rest of this list has rows there too: a rapid switch, the menu bar's tint, Fit,
Original size and a scale factor against Compatibility, the Mission Control picture of a
rotated clip, a real hot-plug, mirror set, AirPlay screen or closed lid, and a slow
volume.

## Panel

`Tests/Unit/Panel/` covers the SwiftUI control panel. Model tests build the controller through
`PanelTestCase.makeController(...)` or `withPanel(...)` (`PanelFixture`: a temporary
`WALLPAPER_MACHINE_HOME`, a `TemporaryDefaults` suite, a snapshot-only bridge, English, the
first-run guide already seen, `RecordingDialogs` that answer no unless told otherwise) and call
the typed actions. Render tests host the real views in an unordered window from
`ControlPanelWindow.make` or an `NSHostingView`, never order a window front, set the appearance on
the window or the hosting view and never on `NSApp`, and assert sizes, model state or the toolbar,
not pixels. A test
that reads rendered words passes a language (`appLanguage: .english()` from
`Tests/Unit/Support/TestAppLanguage.swift`, or a store with explicit `systemLanguages`): the shared
`AppLanguageStore` follows the developer's own choice. The shared panel language that `L()`
reads follows `AppLanguageStore.testHost` (English): the test bundle binds it before every test,
so a test that binds another language cannot leak it into the next one; restore to `.testHost`,
never to `.shared`.

- Controller and actions: `PanelControllerTests` (persisted flags restored and the legacy
  inspector-width key removed, each area model created once, `start()` wires the stores and
  `stop()` undoes it, the window closing stops the panel, energy sampling only while Settings is
  visible, returning to the window re-reads the bridge only while a Login Items approval is pending
  and looks for scene assets installed meanwhile, a closed panel ignores its old window);
  `PanelActionCoordinatorTests` (a key is busy while its action runs, a repeat is dropped and hands
  back the original task, latest-wins runs every value in order past a failure, keys are
  independent, unkeyed work is untracked, every error reaches the reporter);
  `PanelActionRoutingTests` and `PanelMediaActionRoutingTests` (which actions clear the banner
  first and which leave it, queued work waits behind a running command and direct work does not, a
  newer command in the same slot replaces one still waiting, a failure reaches the banner and frees
  the key, success reconciles the dismissals, the id resolvers refuse what is gone);
  `PanelErrorStateTests` (precedence, a cancellation is not shown, a bridge error dismissed by
  revision returns when it happens again, library and download failures stay dismissed until they
  recur, a cleared source re-arms its dismissal); `PanelPresentationTests` (injected and real
  window visibility, the key and close hooks, a view losing its window counts as closing);
  `PanelStoreRevisionsTests` (each store's notification bumps only its own counter, posts from
  another instance or a background thread, nothing counted outside `start()`/`stop()`, a reader is
  told); `PanelInspectorObservationTests`; `PanelPreferencesTests` (the keys earlier builds wrote,
  favorites as the JSON of the sorted array, unreadable favorites read as none);
  `ExternalLinkTests` (every fixed and built link passes the allowlist, https to an exact host
  without credentials or a port only, the opener reached only for an allowed link);
  `TransferFormatTests`, `DragStepPumpTests` (the first value at once, later ones after 100 ms,
  never two steps in flight, the release waits for the step on its way and always saves, a
  deferred first step for a colour), `DisplayOptionsLoaderTests` (fetched only while Settings is
  visible, a failure falls back without looping, a stale or cancelled read never overwrites a newer
  one), `EnergyReadoutTests` and `PanelEnergyRestartTests` (each rendering setting restarts the
  comparison once, other settings and refused changes do not).
- Window and shell: `ControlPanelLaunchTests` (a login launch keeps the panel closed once set up),
  `ControlPanelViewTests` (the hosted root starts its controller and stops it when the window
  closes), `ControlPanelWindowSizingTests` (the 760×560 floor in a hosted window, the key-view
  loop, moving to the active Space while keeping full-screen capability, fronting that
  deminiaturizes only a minimized window), `PanelViewStateTests` (the reopen state's limits),
  `PanelRootRenderTests` (small window proposals with a long display title in every language, the
  guide over the split view, the toolbar and title following the page, an app reveal of a Settings
  section shown once), `PanelPageTransitionTests` (every page change with the inspector open or
  closed leaves the window whole), `ShellModelTests` (quick clicks end on the last page, Back to
  library, the typed target display, Recently used per display, one popover at a time, the import
  pill's memory, the Escape order, the inspector open with room and closed below 960 points until
  the person chooses, what the split view writes back not counted as a choice, notices announced
  and expiring, the support prompt waiting behind the guide, a popover or a running apply),
  `ShellRenderTests` (the shell takes any window size in every language and appearance, full
  screen, Split View and minimum sizes, the window title and subtitle, the target menu and
  inspector toggle on library pages only, a banner never widening the layout, shrinking step by
  step with the inspector open, Command-F reaching the Settings search, the tabs in the toolbar,
  the Now Playing bar's height and its details popover), `ShellBannersTests`,
  `ShellSearchFocusTests`, `PanelTitleTests`,
  `CollectionEditorModelTests` (create, rename and delete with the inline name field and the
  confirmation sheet), `PanelShellTests` (choosing a Settings section ends the search, a reveal is
  adopted once, disclosures, the inspector choice and the library page remembered, the guide open
  until the flag is set) and `PanelShellActionsTests` (navigation, the first visit's Workshop and
  pixiv loads, the reopen report, the first-run flags, appearance and language choices, which tell
  the bridge and re-read the open wallpaper's options).
- Language and theme: `PanelLocaleTests` (every shipped language resolved from its own bundle,
  integer and text arguments, reordered and repeated placeholders, a literal percent, English
  fallback, unformatted runtime lookups, the system region kept, the bound store driving the
  language), `SettingsSectionsLocalizationTests`, `PanelThemeTests`, `AccentPaletteTests` (every
  token equal to the original algorithm's, readable fills, links and rings for every accent) and
  `SurfacePaletteTests`.
- Images: `PanelImagePipelineTests` (covers scaled and read only inside the library, a symlink out
  and a non-image refused, a replaced preview under a new stamp is another image, a cover that
  cannot be made falls back once to the downsampled preview, stills decoded to the view's size
  and cached, only https Steam previews and only pixiv's image host and the fixed property hosts
  read, a view that goes away stops waiting without cancelling the shared fetch, animations only
  from sources that fit the budget), `PanelImageViewTests` (offscreen hosting, drawn-size decoding,
  stable layout, scrolling a lazy list releases both the decoded wrapper and its `CGImage` after
  cache eviction, scrolling back reloads it, and a cache hit stays alive while visible but is
  released on disappearance), `AnimatedPreviewTests` (GIF, APNG and WebP frames and delays,
  no timer until asked and never without a window),
  `PropertyImageCacheTests` (bounded transfers, author images cannot become a network proxy) and
  `LivePreviewSchedulerTests`.
- Installed and the library: `PanelLibraryActionsTests` (favorites, Show in Finder, selection
  slots, only Reapply restarting what the target shows, the target display taken when the user
  asked, hiding after an apply, Apply to all displays and its rollback, previous and next,
  playback, refresh, the held-wallpaper sentence and **Try again**, per-display host states and
  their exact retry), `PanelLibraryImportTests`, `PanelLibraryRemovalTests` (confirmation, no
  window means no deletion, one question for a batch, partial failures named),
  `PanelLibraryRowsTests` (rows joined with measured facts, covers only once stamped, a rescan that
  replaced no preview leaves every row alone, 10,000 rows built once whatever else changes),
  `PanelLibraryStateTests` (Now Playing, the target menu, display names, history, library counts,
  the update dot, the issue report's facts), `PanelCollectionActionsTests`, `LibrarySortTests`,
  `LibraryFilterTests`, `LibrarySelectionTests` (ticks, ranges and the hold-and-sweep gesture),
  `LibraryGridGeometryTests`, `LibraryTileRulesTests`, `TileGridLayoutTests` (at least three
  columns, arrow keys held at the ends), `InstalledBrowserModelTests` (the reopen state and its
  cadence, Favorites and collections as views, a 10,000-wallpaper library filtered as the user
  types, covers, the selection's life, clicks, keys, Delete, batch actions and notices, the sweep
  and edge scrolling, the one animated tile, the import popover and pill) and
  `InstalledPageRenderTests` (the page, footer, empty states and popovers in every language and
  appearance at the narrowest column, the scroll offset restored).
- Inspector: `InspectorPolicyTests`, `InspectorWordingTests`, `InspectorInputTests`,
  `InspectorFlowTests` (Preview with unsent text, Restore all defaults, sections, the app's words
  against an author's markup, host states as text, file and folder notes, every symbol drawn
  exists), `InspectorSliderTests` (VoiceOver, keys and the pointer each reach the saved edit; a
  drag previews and the release saves once; colours saved after a quiet period),
  `InspectorRenderTests` (the inspector and the whole panel with it open at 760×560 in every
  language; a slider's VoiceOver, key and pointer changes reach the bridge),
  `PropertyLabelDocumentTests` (the label allowlist: entities, emphasis, colours, lists, broken
  markup, scripts and controls dropped, links only to allowed hosts, registered images only,
  limits), `PlacementGeometryTests`, `PlacementDraftsTests`, `PresetsBarStateTests` and, on the
  controller, `PanelPropertyRowsTests` (author markup reduced to words, engine tokens as readable
  and translated words, the curated phrases, modified marks, Restore all and Apply availability,
  display cards, measured folders, relabelling in a new language, audio and media delivery status),
  `PanelPropertyDraftTests`, `PanelPropertyFilesTests`, `PanelPropertyPreviewTests` (described
  under Preview), `PanelDisplayPositionTests` (one axis at a time, refused values reach no bridge
  call, scene and video only, Center, a preview step that neither saves nor waits),
  `PanelPresetsTests`, `PanelImagePlacementTests`, `PanelLetterboxTests` (the Black bars card for
  an installed video only, the suggestion following the target display without a second probe,
  staging the recomputed factor and refusing a stale card, file or selection),
  `PanelCompatibilityTests`, `PanelWallpaperSettingsTests` (each setting a typed call; Fit with
  blurred backdrop saved for the one display it was chosen for, offered for scenes and videos,
  and noted only where the native video player draws it), `PanelSceneRetryTests`,
  `SceneReportsTests` and `WallpaperEditorStateTests` (locale scaling, invalid raw text,
  independent drafts, held drag steps).
- Steam Workshop and downloads: `PanelWorkshopActionsTests`, `PanelWorkshopSubscriptionsTests`,
  `PanelWorkshopTileTests`, `PanelWorkshopUpdateTests`, `PanelDownloadActionsTests` (Download and
  apply and the display it targets, retained requests, the account stage, secrets reaching only
  the job that asks, pause, cancel, retry, clearing, logging out, locating a copy, reinstalling),
  `PanelDownloadQueueTests` (the toolbar button's ring, speed, percent and time left, pixiv saves
  in the shared list), `WorkshopSearchTriggerTests`, `WorkshopFilterCatalogTests`,
  `WorkshopListStateTests`, `WorkshopBrowserModelTests` (the search pause, pasted links and bare ids,
  sorts and filters, lists and authors, pagination that never navigates and clamps to Steam's page
  limit, double clicks, the remembered scroll offset), `WorkshopPreviewCoordinatorTests` (stills
  first, animations only for tiles on screen, released when hidden), `WorkshopInspectorTests`,
  `WorkshopItemDownloadTests`, `TileDownloadStateTests`, `ResultPagerTests`, `DownloadsModelTests`
  and `DownloadDialogResolutionTests` (the download dialog's stages, Not now, the hand-off card, a
  rejected account, late failures, the first-run guide keeping its own sign-in), and
  `WorkshopBrowserRenderTests` (the page, inspector, empty states, dialog stages and Downloads list
  in every language at both sizes, shrinking with the inspector open, a tile's VoiceOver label, a
  download that resumes or pauses with the Downloads list open redrawn in place).
- Lazy lists: `scripts/tests/test_panel_lazy_lists.py` fails for a `LazyVStack`, `LazyHStack`,
  `LazyVGrid`, `LazyHGrid` or `List` that draws more than one top-level `ForEach`, the shape that
  kept a resumed download's row stale; a `ForEach` inside a separate subview is not seen by it.
- pixiv: `PanelPixivActionsTests`, `PixivPanelStateTests`, `PixivBrowserModelTests`,
  `PixivListSummaryTests` and `PixivBrowserRenderTests`; see [Pixiv](#pixiv).
- Settings: `SettingsSearchTests` (matches, counts, folding disclosures, the panel's language, the
  first-sentence note), `SettingsEditingModelTests` (a control shows its draft until its change
  has run, a refusal snaps back and reaches the banner, controls wait while the Mac is busy except
  the one whose change runs, appearance and language never wait, a new snapshot keeps disclosures
  and the scroll position), `SettingsEntryControlsTests`, `QuickSettingsTileTests`,
  `AppearanceSettingsTests`, `PanelGeneralSettingsTests`, `PanelPerformanceSettingsTests` (values
  refused or clamped as their controls are, the condition choices, app rules, a mute from the menu
  bar reaching the open panel), `PanelSettingsValuesTests`, `QualityPresetTests`,
  `QualityReportTests`, `ConditionOverrideTests` (On battery names the strongest rule that
  pauses or stops wallpapers on battery and nothing plugged in or already done by the choice,
  each rule's row says In effect now, the published state reaches the panel's readers),
  `PanelStorageActionsTests`, `StorageSettingsModelTests`,
  `AboutSettingsTests`, `UpdatePresentationTests`, `PanelSupportPromptTests`,
  `DisplaysSettingsModelTests`, `DisplaysSettingsDraftsTests`, `DisplaysRowLayoutTests`,
  `PanelDisplayActionsTests`, `PanelDisplayLayoutActionsTests`, `PanelAutomationActionsTests`,
  `PanelPlaylistActionsTests`, `PanelPlanActionsTests`, `PlaylistEditTests`,
  `PanelHotKeyActionsTests`, `ShortcutsRecorderModelTests` (only the recording row takes a press, a
  registered shortcut's press is read as its combination and never runs its action),
  `LibrarySettingsPresentationTests`, `SettingsSectionsRenderTests` and `SettingsBRenderTests`
  (every section in the narrowest and widest column, light and dark, in every language).
- First-run guide and the one-time prompts: `FirstRunModelTests`, `FirstRunDraftTests`,
  `SteamSignInPhaseTests`, `SupportPromptPresenterTests`, `WelcomeRenderTests` and
  `PanelPerformanceDataTests` (the Settings switch round-trips and **Show in Finder** writes the
  report it would send, the performance data question asked once of someone who finished the
  guide earlier and answered from the presenter, the guide answering it only once its
  Preferences page was shown and committing its switch as a draft); see
  [first run](../features/first-run.md).
- Sharing: `PanelSharingTests` (a Workshop wallpaper shares its Workshop page with the website,
  any other id has no Share, the app is shared with the website in the panel's language, **Star on
  GitHub** in About and in the star prompt open the repository and answer the star prompt).

Not covered: the Settings section list's selection highlight, the toolbar's glass and the tabs
on it, popover placement, sheets on a real window, hover,
pressed and focus rings, real pointer gestures (double clicks, modifier clicks, the hold-and-sweep
and edge scrolling, slider drags; the logic behind each is tested through the models with a
manual clock), the colour panel, Command-F in a real window, VoiceOver speech and reading order,
Reduce Motion, animation smoothness and full-screen or Split View transitions. Those need an
on-screen window and are on [manual-smoke.md](manual-smoke.md).

## Pixiv

`Tests/Unit/Pixiv/` and the panel's pixiv classes (`PanelPixivActionsTests`,
`PixivPanelStateTests`, `PixivBrowserModelTests`, `PixivListSummaryTests`,
`PixivBrowserRenderTests`) cover decoding of pixiv's answer shapes, search and ranking addresses, ratings
including R-18 and R-18G, request pacing, the session cookie reaching
`https://www.pixiv.net` only, sign-in, log out, a keychain refusal and expiry
against an in-memory store, resumable thumbnail and download transport, the
download queue (concurrency, cancel, retry, shutdown) and packaging (sniffed
formats, scaled display copies, staging reclaim). None of it reaches pixiv: its
signed-in answers and the real sign-in page are not covered
([pixiv](../features/pixiv.md#verification)).

## Playlist

`PlaylistPlannerTests` (candidates, order, shuffle rounds, day/night boundaries),
`PlaylistStoreTests` (persistence, custom intervals, the trigger defaulting for older
records and starting a fresh wait, reordering, plans copied
across displays and detached on manual edit, cleanup when wallpapers or
collections go, a shuffle round kept across a relaunch and dropped with its playlist,
Random Wallpaper's own round per display and pool, kept apart from the playlist's),
`PlaylistSchedulerTests` (fake clock, library and activation;
no renderer: failure cooldowns, paused catch-up, a newer manual command
outranking a failed automatic switch, a rotation yielding to a waiting Apply, a manual choice holding a
due rotation, a display the user emptied staying empty until a wallpaper, Change now or Resume,
a relaunch finishing its shuffle round without a repeat, an unlock changing an
unlock rotation once, waiting for a display that cannot play yet for 30 seconds at
most, and leaving timed rotations, cleared displays and a hand-chosen wallpaper alone),
and in Panel `PanelPlaylistActionsTests` and `PanelPlanActionsTests` (settings reach the
named display's playlist, values no control offers are refused, button and drag sorting
with a stale drag refused, Resume, Change now, clearing only the named display's history,
saved playlists), `PanelLibraryActionsTests` (Now Playing's Next wallpaper: a rotating
playlist moves along, a display without one takes the library's next wallpaper),
`DisplaysSettingsModelTests` (the Custom interval field, the Resume row, announced moves),
`PlaylistEditTests` (the How often menu's unlock choice and named times) and
`ShellModelTests` (Recently used clearing only the target display).
What each covers: [playlists](../features/playlists.md#verification).

## Preview

`WallpaperPreviewSessionTests` — hidden-load deferral, pause composition,
replacement and close generation guards, failure teardown, reload, readiness
timeout and pointer conversion, using injected surfaces.
`WallpaperPreviewLivePropertiesTests` — the preview following the property draft with
an injected surface and a wait the test ends by hand: a burst costing one read and
one push of the newest draft, an identical or picture-only change pushing nothing,
the picture note appearing and clearing, a hidden, still loading or not yet ready
preview taking the draft once when it can, a paused one taking it too, other
wallpapers, a closed or replaced session and a late read being ignored, a failed push
or unreadable draft logged once while the preview plays on, reload starting from the
new baseline and dropping open-time text, videos left alone, Web entries kept whole,
and the window's status line; a drag followed with no quiet period, the steps that arrive
during a read costing one more, and a hidden preview ignoring a drag too.
`PropertyPreviewSchedulerTests` — trailing edge, one run
in flight per key with the newest queued behind it, cancel, independent keys, a failing
wait, and a zero delay running at once with no wait while a later edit with a delay waits
again. `LivePropertyPayloadTests` — merging the draft over the started
values for scene and Web payloads, frozen ids restored, key order not a change,
invalid documents refused. `PropertyDraftHookTests` — every draft-changing call names
its wallpaper after the change is stored, and a failed call announces nothing
(`WallpaperPresetStoreTests` checks a preset's edits and apply do too).
`LivePropertyEditingTests` — the desktop switch: off until chosen, either explicit value
kept, kept per preference domain, announced on each write and out of backups.
`PanelPropertyPreviewTests` — the panel's edits reaching the bridge's property preview
through a double bridge and a wait the test ends by hand: one update per burst and none with
the switch off, every kind of draft edit followed, a wait that outlives the switch dropped,
Apply and Revert dropping the waiting update (and Apply's own text commits starting none),
turning the switch off putting the saved look back on exactly the wallpapers that were shown
an edit (not an applied or deleted one, and again after a refusal), videos and Web pages
left alone, and a refused update logged rather than shown. The displays that may be drawing
an edit (the ones showing the wallpaper and its mirrors, none while the update waits or the
switch is off) are known until Revert, Apply, the switch or a deletion ends it, which also tells
the app to take the desktop's picture again, and a wallpaper that could not be put back keeps
them. The drags (`previewProperty`):
a step reaches the displays at once with its value and the other steps still on show, in a
fixed order, and saves, flags and announces nothing as an edit; with the switch off it reaches
only what follows the draft; it is refused for the values an edit is refused for (range,
`NaN`, an infinity, a boolean, text, a malformed colour) and, besides, for any kind but a
slider or colour, a disabled or unknown property and a wallpaper the library lacks, with no
bridge call and nothing held; it does not wait behind the running command; the edit that
ends the drag, taken or refused, a restore of the property or of every default, Revert,
Apply, another wallpaper's inspector and an Apply in progress each end the step so no update
keeps showing it; and a refusal that repeats is logged once. `DragStepPumpTests` and
`InspectorSliderTests` cover the controls: quick steps of a pointer drag show the first at
once and the newest after the interval, the release saves the newest once and drops a step
still waiting, waits for the step already on its way, a drag that ends on its starting value
or is cut off still saves the last value shown, a key press or a VoiceOver step saves
without showing a step, a burst of colours is one drag that saves only the last while a
single pick is saved after a quiet period without a step, and a switch saves without one. `WallpaperEditorStateTests` also covers the held
steps: newest per property, one wallpaper's, never a draft, ended by a discard.
`PanelGeneralSettingsTests`
holds the setting (off by default, kept). The bridge's own bookkeeping is in the Rust
`property_preview` tests ([renderer](renderer.md)).
`WallpaperPreviewRequestTests` — installed-path bounds, symlink escape, stale
manifests, resource checks, copying unapplied values without changing bridge
state, asking the bridge for the steps of a drag until it ends, and naming the pictures
and files a preview holds. `WebWallpaperPreviewSurfaceTests`
use real offscreen WebKit for typed properties, a second delivery changing only the
edited property, a staged file keeping its value, isolated temporary storage and
mute. `InspectorFlowTests` and `PanelLibraryActionsTests` drive
the inspector's Preview action without opening a window, and `WallpaperPreviewLayoutTests`
check the 480-point content view in English, Chinese and Japanese, the window size
for 16:9, ultrawide, 4:3 and portrait displays on ordinary and tiny screens, and
the stage (shape, centring, bars and the surface following it) without an
`NSWindow`. Rust `wallpaper_preview` tests cover read-only draft export and Web
combo types. Not covered: native window presentation, how the stage looks in a
real window on a portrait or ultrawide display, scene or video first frames in
that window, OS visibility events, and a real renderer taking the document in the
preview window (the renderer's side is in
[scene regressions](scene-regressions.md)); the visible follow, the feel and the rate of a
drag under load, whether the system colour panel's changes arrive as a drag while it is open, and a
desktop following an edit on one or several displays, a mirror, after Revert and with the switch
turned off, are in the [manual smoke](manual-smoke.md) and have not been run.

## Steam

- `SteamCMDSetupTests` — against isolated preferences and directories,
  `URLProtocol` archives, the real system `tar` and owned child processes:
  publication and replacement, strict package manifests and both checksums, HTTP
  encoded versus decoded lengths, duplicate package paths, zip backslash
  normalization, execute permissions, traversal/link/archive-size boundaries,
  monotonic progress, network failures, signature-policy blocking, cancellation
  with no late writes, and retained blocked candidates surviving relaunch. An
  installation-to-downloader regression runs the published executable through the
  real PTY downloader and asserts imported manifest and media bytes.
- `SteamCMDRuntimeValidationTests` (Workshop folder) — arm64 only; Intel-only
  copies are rejected and need a native reinstall; Mach-O load commands and
  nested executable dependencies.
- `SteamCMDApprovalTests` use isolated fixtures: exact SHA-256 receipts, policy
  failure rejection, stale candidates, changed resources, private copies,
  quarantine scope and explicit discard. `SteamCMDReportedFailureTests` — which
  reported reasons count as credential rejection and which are only a connection
  that can be retried.

Not covered: whether Valve's current distribution passes this Mac's policy. The
opt-in `SteamCMDLiveInstallTests` check that with a temporary native package
install and a no-login smoke run (see [README.md](README.md#opt-in-layers)).

## Support

`SupportPromptStoreTests` — a downloaded wallpaper qualifies only after a
successful activation, a pending prompt survives relaunch and further downloads,
and a presented prompt never returns. Across the four prompts: one a day in
priority order, the performance data question only for someone who finished the
guide without it, the subscriptions offer only for someone signed in to Steam who
finished the guide without meeting the import (spent by the guide's card or a Steam
Community sign-in), the star prompt after 14 days and 5 days of use (one day counts
once) and not after the star was chosen, and state saved by earlier builds still
loads. `Support/` also holds the shared fixtures
(`TemporaryDefaults`, `TestAppLanguage`, bridge snapshots).

## Telemetry

`TelemetryServiceTests`, `TelemetrySamplerTests` and `TelemetryClientTests` run
against a fake uploader, a fake counter source, a `URLProtocol` stub and a
temporary spool folder. They cover:

- nothing written or sent while it is off;
- one upload a day, carrying only rows not sent before;
- rows kept after a failed upload;
- local deletion and the deletion request when turned off, asked for again at the
  next launch until confirmed;
- a report built from home paths, user names, local folders and pixiv ids that
  carries none of them;
- the previous run's ending, length and memory pressure;
- frame rows as deltas between two readings;
- paused, covered, switched and invalidated windows reporting nothing;
- counters always turned off again;
- the POST and its user agent.

Not covered: the live website endpoint, and the energy cost of a frame window
([telemetry](../features/telemetry.md#frame-windows)).

## SystemMedia

`AdapterSystemMediaProviderTests`, `SystemMediaTransportTests`,
`FallbackSystemMediaProviderTests`, `AppleScriptMediaProviderTests`,
`MediaArtworkTests`, `SceneMediaSinkTests` and `SystemMediaEventCodecTests` run
against fake streams, injected script results and a manual timer scheduler. They
cover fragmented messages and timeline
interpolation, consumer lifetime and late callbacks, unexpected exit without a
restart loop, the adapter-to-AppleScript fallback, artwork caching and
downscaling, the cleared cover reaching scenes before metadata, and the wire
format. Not covered: a real player or OS version publishing every field
([media integration](../features/media-integration.md#verification)).

## UserAssets

Behavior: [user files](../features/user-files.md).

`UserAssetStoreTests` — importing a file or directory property into managed
staging (extension filters, one-level directories, file-count limit, no second
copy of unchanged bytes), retained files surviving an unavailable source,
serialized preparation off the main thread with cancellation, authorization
rollback that cannot revoke a newer selection, and purge that keeps every asset
the manifest lists. `DirectoryWatcherTests` — a burst settles into one
notification. `UserAssetPreparationPerformanceTests` — synthetic directory
preparation and main-actor latency.

## WebWallpaper

`Tests/Unit/WebWallpaper/` runs real offscreen `WKWebView`s and injected hosts,
with no desktop window. It covers the page contract (`WebWallpaperPageTests`,
`WebWallpaperLocalRequestTests`, which also covers the file-request fixes in iframe,
`srcdoc` and script-created frames), property payloads and file staging
(`WebWallpaperPropertyPayloadTests`), the author API (`WebWallpaperAuthorAPITests`:
audio, media, random-file and directory listeners), audio delivery, output and
single-owner rules (`WebWallpaperAudioMediaTests`, `WebWallpaperAudioOutputTests`,
`WebWallpaperAudioOwnershipTests`), host lifecycle, crash budget and reload
recovery (`WebWallpaperHostLifecycleTests`, `WebWallpaperRecoveryTests`),
suspension by presentation and by pause, with the first-frame grace (counted only
while the view is in the window), edits drawn on a paused page, and a measured stop of
frames, timers and CSS (`WebWallpaperSuspensionTests`), the frame-rate limit
on `requestAnimationFrame` against a fake display cadence and in a real page with a
measured live change, and the rate a slow or full-refresh page draws at
(`WebWallpaperFramePacingTests`), a page rebuilt across a fast display's refresh with
its render scale, pause and limit (`WebWallpaperHostLifecycleTests`), the render scale on
`devicePixelRatio` with its resize event, start-of-document value and descriptor
following (`WebWallpaperRenderScaleTests`, plus the render-scale cases of
`WebWallpaperHostLifecycleTests`), pointer routing
(`WebWallpaperMouseRoutingTests`), pointer-move pacing and coalescing
(`WebWallpaperMoveThrottleTests`, and the interval a page asks for in
`WebWallpaperPageTests`), the opt-in Web Inspector switch
(`WebWallpaperInspectionTests`, plus the running and new page cases of
`WebWallpaperHostLifecycleTests`), `requestIdleCallback` where WebKit lacks it
(`WebWallpaperIdleCallbackTests`), the Windows font names a page asks for drawn in macOS
faces (`WebWallpaperFontAliasTests`) and the screen-saver surface
(`ScreenSaverWebSurfaceTests`). Detail and limits:
[web wallpapers](../features/web-wallpapers.md#verification).

## Workshop

### Search and sources

- `WorkshopStoreTests` — pagination follows the displayed query until a draft is
  submitted; a failed page or submission retries its own query; superseded and
  racing requests cannot publish over a newer search; pages are Steam's own pages
  served from cache, capped at Steam's page limit, with the next page prefetched;
  the sidebar defaults match Wallpaper Engine's; Recently updated reaches Steam as
  `lastupdated` with the search text and tags.
- `WorkshopLinkTests` — which pasted text names a Workshop item: bare ids from six
  digits, item page and `steam://` links in their accepted spellings, and the
  look-alikes that must stay searches (other hosts, user info or ports, bad ids,
  free text holding an id or a link); only the wallpapers list reads an id.
- `WorkshopTests` — query and tag encoding, sort mapping, the details request and
  its answers (served, withdrawn and other apps' items), the single-item lookup
  with a distinct reason for a removed, foreign, Application or unreadable row, the
  ids a page names (every marker, first-seen order, uniqueness, junk digits, the
  limit) and which pages count as a changed layout rather than a Steam failure. The two `testLive…`
  cases fetch Steam's real pages and are opt-in
  (`WALLPAPER_MACHINE_NETWORK_TESTS=1`, see
  [README.md](README.md#opt-in-layers)); the page format stays covered offline
  through the real parser against fixture markup.
- `WorkshopSourceTests` (fixture protocol, nothing reaches the network) — Steam's
  session cookie read and never sent off Steam Community, author pages, a
  collection's order, collections marked on browse pages, the sidebar's rules on
  unfiltered pages, age-rating sampling of collections, every subscription page
  read with the session, a page whose entries cannot be read failing instead of
  passing for empty, the store's back history, sign-in, ended session and
  sign-out, the session saved for the next launch and removed with it, an expired
  cookie renewed with Steam's renewal token before a read (and a refused renewal
  ending the session; `SteamWebSessionTests` covers which token is kept and when a
  cookie needs renewing), and a pasted link or id: one tile that no sidebar filter hides, no
  browse page read, failures on the normal retry path, other sources ignoring the
  id, and a browse page whose markup changed: listed from its links or the ids in
  its renamed data, an id Steam does not serve left out, paging estimates, the
  original failure when no item can be listed or Steam failed its own query, and
  collections left alone. `PanelWorkshopActionsTests` (Panel) cover the panel's source
  actions, sign-in through an injected window, opening a collection rather than
  downloading it, and the state's flags for an item looked up from a pasted link and a
  list found on a page Steam changed. Steam's real sign-in
  window, a real lookup against Steam and a real changed page (the markup is
  fixture-built) are not covered.
- `WorkshopThumbnailCacheTests` — one download per URL under concurrent requests,
  disk hits across instances, no cache entry after a failed fetch, the concurrency
  cap, oldest-first pruning, still-frame extraction from animated previews
  (skipping a black fade-in), animations relayed on their own lane, a cache that
  keeps no animation writing stills only, and the source size limit.
  `PanelImagePipelineTests` (Panel) read library covers only for images inside the
  library and fetch only https Steam previews.
- `LibraryPreviewFetcherTests` — which files an Installed cover may be made from
  (inside the library, no symlink out, images only, size limit), a replaced
  preview getting a new cover, and the stamp in a cover's address changing with
  the preview's size or modification time only.

### Downloads

`DownloaderTestCase` is shared by `DownloadQueueTests`, `DownloaderLifecycleTests`,
`DownloaderSessionTests`, `DownloadTelemetryTests`, `SteamCMDRuntimeValidationTests`
and `WorkshopDownloadPersistenceTests`:

- Queue: private terminals per job; transfers side by side up to the slot limit
  once the first sign-in is accepted; serial order without a saved sign-in; a
  "logged in elsewhere" kick re-queuing the job and turning the queue serial; the
  ceiling changing mid-queue (raising starts waiting jobs, lowering never stops a
  running one); FIFO handoff after failure or cancel; shutdown never launching
  queued work. The ceiling is clamped to 1–6, persists across relaunch and
  reaches Swift from the Settings select as a number.
- Sign-in and ownership: per-job secrets, saved-sign-in handoff and relaunch
  without resubmitting secrets, account switching never restoring the previous
  account's credentials, stale credential rejections not erasing a newer session,
  ownership checks (owned, missing, unconfirmed, split output), and an anonymous
  account unable to start a download.
- Menu bar line (`testMenuBarCountsOnlyTransfersThatAreMovingOrWaiting`): a running job and a
  waiting one count, a pausing job (still holding its slot), a paused one and the sign-in
  job do not.
- Content: staging reclaim limited to directories nothing is writing to,
  partial content never published on cancel or incomplete download, scene-asset
  installation keeping only validated assets, pause and checkpoint recovery of
  content and queue order.
- Free space (`DownloaderLifecycleTests`, injected disk): a download that cannot
  fit fails before SteamCMD launches with the needed and available sizes, Try again
  checks again, partial data already staged lowers the requirement, and an unknown
  size, an unreadable disk or a sign-in-only run never blocks. Scene assets use a
  fixed floor, less what a resumed attempt already staged. The floor's real
  footprint is unmeasured.
- Retry (`DownloaderRetryTests`, scripted runtime counting its launches): a
  timeout after the sign-in is retried in the same staging without a new prompt
  and then completes; the budget is three retries, but a silent stall is
  repeated only once; free space is read again before a retry and before
  SteamCMD's own restart; a stall after sign-in is retried on an injected clock,
  and one in a retry's own sign-in is the connection, with no authentication
  retry offered; pause and cancel during the wait keep and discard the partial
  data; access denied, a generic failure, an exit without confirmation, a
  failure or stall while the first sign-in is pending are never retried; a
  failure line is judged only once whole, whether a read stops before its reason
  or the process ends without a newline. Real SteamCMD output for a dropped
  connection is not covered.
- Sleep and wake (`DownloaderRetryTests` on an injected clock and a frozen byte
  meter; `DownloadQueueTests` with a private `NotificationCenter`): a transfer
  silent for the grace period after a wake is relaunched in the same staging without
  a prompt, one that receives bytes after the wake or never woke is left alone, a
  wake while signing in or a watch left by a process that has since been replaced
  never restarts anything, a restart uses the retry budget, and only running jobs
  are told; a manager dropped without `shutdown()` takes its observer off the
  center. A real sleep and wake during a live download is not covered.
- `DownloadTelemetryTests` — download-speed sampling, including real `nettop`
  streaming (detail in [renderer.md](renderer.md)); `DownloaderLifecycleTests`
  report progress from disk growth against the listed size and stay
  indeterminate without one, never let the bytes shown fall (a shrinking tree, a
  restarted network meter, a SteamCMD relaunch inside the run, which then moves
  on from where it was even when its own meter stays below that), and give a time
  left only after four seconds of history and not at the 99% cap, on an injected
  clock. `TransferEstimatorTests` cover the pace itself (smoothing, the stall
  floor, counters that start over, the 99-hour cap); the panel's wording of the
  estimate is in `PanelDownloadQueueTests` and `DownloadsModelTests`.
- Backup exclusion (`ClientPathsBackupTests`, `DownloaderSessionTests`,
  `WorkshopDownloadPersistenceTests`, `WallpaperImportStagingTests`): the saved
  sign-in folder, the staging of a running download or import, the folder of kept
  partial downloads and `Cache` carry the exclusion flag, also after the sign-in
  is replaced and on a later launch, and a launch flags the sign-in and download
  folders an earlier version left unflagged without creating them; the library,
  user files and scene assets and the support folder itself never do. What Time Machine then skips is not
  covered (it needs a backup run).
- `WorkshopDownloadIntentTests` — a download request retained across setup,
  account and shared-resource consent, surviving browsing and relaunch, removal
  preventing resumption, and explicit consent including reinstall. Reinstall from
  Workshop is covered for an id that is not a Workshop number (Steam is not asked),
  an item Steam no longer serves (the installed folder untouched), an Application,
  the current version queued through the ordinary queue, and a repeat while a
  download runs or waits for setup doing nothing.
- `WorkshopApplyOnArrivalTests` — Download and apply with the two-display test
  bridge and `finishInstall` standing in for the arrival: the wallpaper applied once
  and only on the asked display; the person's own choice for that display, made
  before or while the apply waits its turn, withdrawing it with a note, while a
  playlist change or a choice for the other display does not; two asks for one
  display, where the later one is applied whichever wallpaper arrives first and
  asks for different displays leave each other alone; copying to, swapping or
  applying a layout naming the display withdrawing it, while a copy from it or a
  layout for the other display does not; the hour; a failed
  apply or a display that went away leaving the display alone and saying why; a
  failed library rescan; an Application, a collection or an unusable display
  getting a plain download; a scene waiting for its shared assets and being
  dropped with a note when their job ends without them; cancel and dismiss; a
  failed download; and a relaunch restoring the downloads but not the choice.
  `PanelDownloadActionsTests` covers what the panel accepts, and
  `WorkshopInspectorTests` and `WorkshopItemDownloadTests` where the inspector offers
  the button and what it says. Not covered: a real download followed by the apply (needs a Steam
  sign-in and a display), and the assets job's completion calling the same
  settle step (needs a finished SteamCMD job).

### Updates

`WorkshopUpdateStoreTests` — what counts as outdated, recorded downloads and
imports against `project.json` dates, non-Workshop ids never sent, results kept
across a relaunch, a download making an item current, the daily limit and its
switch, a failed check keeping what was known, and forgetting deleted items;
`PanelWorkshopUpdateTests` — only an outdated wallpaper is marked and can be
updated, and a reinstall needs an installed wallpaper and the user's yes before
Steam is asked; `ImportTests` covers the swap that replaces an installed tree,
including a copy missing its entry file or with a manifest that does not parse,
and a folder whose `project.json` is a link left alone;
`InspectorPolicyTests` and `InspectorWordingTests` cover where the inspector and the
Compatibility check offer Reinstall from Workshop. Not covered: the reload of a wallpaper on screen
after its update or reinstall (needs a renderer), and a real reinstall (needs a
Steam sign-in).

## What native tests do not establish

macOS acceptance and restoration of native wallpaper selections, live GitHub
release install and Applications replacement, how Finder draws the disk-image
window, Steam CDN throughput, live-account session reuse, Mission Control cache
refresh, real audio capture and any visual timing. Those stay on
[manual-smoke.md](manual-smoke.md).
