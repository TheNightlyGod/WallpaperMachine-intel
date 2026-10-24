# A different wallpaper for each desktop

**Different wallpaper for each desktop** gives every desktop (Space) of a display a wallpaper
or saved playlist of its own. It is off by default and is turned on for one display at a time:
on that display's card in **Settings → Displays**, where it sits under **Wallpaper**; with the
**Wallpaper per Desktop** tile in **Settings → Quick Settings** or the first row of **Settings →
Desktop & Lock Screen**, both for the display the Library applies wallpapers to (the row's
**Choose…** opens that display's card); or in the toolbar's target-display menu in the Library. It is the `spaces` mode of the display's
[automatic selection](automation.md), so turning it on takes the place of a time schedule or
an appearance rule on that display, and turning it off leaves the display on the wallpaper it
shows. Only enabled independent displays offer it.

Only the desktop the person is on plays. A desktop they have visited keeps its wallpaper loaded
and paused in a window on that desktop, so a swipe brings in the frame they left and arriving
runs it on from there: no intro plays again and no still picture shows first. A desktop not
visited yet shows a still picture of its own wallpaper until its first visit loads it. A paused
scene, clip or page draws nothing, so the mode costs about as much CPU, GPU and power as one
wallpaper on the display; a kept web page that ignores the pause may still run timers under
WebKit's inactive scheduling. Its real cost is memory, one loaded wallpaper for each different
wallpaper the display's visited desktops show ([below](#keeping-each-desktops-wallpaper)).

## Choosing each desktop's wallpaper

- **Apply on the desktop.** While the mode is on, a wallpaper applied by hand on a display (the
  Library's Apply, a double-click, Previous, a saved layout, copy or swap) becomes the current
  desktop's own: it stays when the person leaves and comes back. The panel opens on the desktop
  the person is on, and the toolbar's target-display button names it (`Built-in Retina Display ·
  Desktop 2`), so going to a desktop and applying is enough. A Focus filter's wallpaper keeps its
  existing [restoration rules](automation.md#focus-selection-and-restoration) and is not saved
  for a desktop. A playlist started by hand still lasts only for the visit.
- **The desktop strip.** Under the switch, the card shows a tile per desktop in their order on
  that display, with the cover of what each shows and the current one outlined. A tile opens a
  chooser with a search field, the installed wallpapers as covers and the saved playlists;
  **Same as Desktop 1** clears the desktop's choice (on Desktop 1 itself the button is **Keep the
  current wallpaper**).
- **A desktop without a choice shows Desktop 1's wallpaper**, including one the person adds. macOS
  gives such a desktop Desktop 1's picture (the display's default picture in the wallpaper store is
  Desktop 1's), and Mission Control's **+** preview shows it before the desktop exists, so following
  Desktop 1 is the only rule under which the picture and the wallpaper that plays agree from the
  start. Its tile shows Desktop 1's cover dimmed and **Same as Desktop 1**. If Desktop 1 has no
  choice either, the display keeps what it shows. "Desktop 1" is whichever desktop comes first now.
- **Turning it on** keeps the wallpaper the display shows as the choice of the current desktop and
  of Desktop 1, where they have none.

Choices are keyed by the Space UUID, not its number: reordering desktops keeps their choices.
Create, remove and arrange desktops in Mission Control; the app only reads the topology and does
not switch or rearrange Spaces. **Refresh Spaces** re-reads it. A disappeared desktop's choice
stays visible as **Unavailable desktop** until it is forgotten; nothing is reassigned by number.

## Entering a desktop

Entering a configured desktop applies its choice once, when playback can run. While paused,
locked or covered, the change waits; only the latest desktop's choice runs after playback
resumes. A wallpaper the display keeps paused for that desktop runs on where it stopped; any
other is loaded. A wallpaper target stops that display's playlist; a playlist target starts a
fresh copy of the saved plan, and playlist progress is not kept for each Space. Leaving for
another regular desktop, even one following Desktop 1, and returning is a new visit. Returning
from a fullscreen app to the same desktop keeps the visit. Visit identity persists across
relaunch, and switching desktops while the app is closed is recognized on its next launch.

## Keeping each desktop's wallpaper

`WallpaperSpaceParking` (`App/Services/Desktop/`) gives each display in this mode the list of
wallpapers its desktops are chosen for, Desktop 1's for one that follows it. When the display
moves on from a listed wallpaper that has drawn, the renderer pauses it and parks it with its
window instead of replacing it, and the web and video hosts do the same with a page or a clip.
When that wallpaper comes back to the display, the parked one becomes the live one again: no
load, no new window and no wait for a first frame (`set_parked_scenes` in the renderer,
`set_display_parked_wallpapers` in the bridge). Desktops that show the same wallpaper share one
loaded copy, whose window is on all of them. A desktop set to a playlist keeps nothing.

A paused scene's frame clock is stopped, a clip is paused and a page is suspended and taken out
of the window tree, as for any paused wallpaper, so a kept wallpaper costs no CPU, GPU or power;
a web page that ignores the pause may still run timers under WebKit's inactive scheduling. The
cost is memory: everything the wallpaper loaded stays loaded, a few hundred megabytes for a scene
([measured footprints](performance.md#2d-scene-resolution)), so a display holds at most one
loaded wallpaper for each different wallpaper its desktops are chosen for, and only once each
has played there. Nothing is saved: after a relaunch only the current desktop is loaded.

A kept wallpaper is let go, and loads again on its next visit, when:

- the Mac reports memory pressure (warning or critical); desktops keep their wallpapers again
  from the next visit once it reports normal ([memory pressure](diagnostics.md#memory-pressure));
- a rule or condition set to **Stop (free memory)** unloads the wallpapers;
- the desktop choices change so no desktop shows it any more, or the mode is turned off;
- its display is unplugged or changes size or scale (a display that only moves takes its kept
  windows along);
- the window server's Space calls are missing, so a window could not be kept on its desktop.

Each change to a display's list is logged with the app's memory footprint (`space parking:
display … keeps … wallpapers`), and the renderer logs each scene it keeps or runs again.

Fullscreen app Spaces are not listed and change nothing. Missing, malformed or ambiguous topology
leaves the switch unavailable and automatic selection waiting; manual commands still work.

## Windows that stay on their desktop

Wallpaper windows normally join every Space (`canJoinAllSpaces`), so the live wallpaper would be
the picture of every desktop: Mission Control and the Spaces bar would show it on each one, and a
swipe would carry the old wallpaper onto the next desktop until its own had loaded.
`WallpaperSpacePinning` (`App/Services/Desktop/`) takes the windows of a display in this mode off
every Space and puts each on the desktops chosen for its wallpaper (the bridge's `scene_windows`
and the hosts name each window's wallpaper):

- **During a swipe** the window leaves with the old desktop. A desktop whose wallpaper is kept
  slides in with that wallpaper's window, paused on the frame it was left on; one that is not
  loaded shows its macOS desktop picture, the poster of its own wallpaper. A wallpaper two
  desktops share is on both, so it stays still between them as a window on every Space does.
- **On arrival** (`NSWorkspace.activeSpaceDidChangeNotification`, which comes once the animation
  ends) a kept wallpaper runs on at once: nothing is hidden or moved and the switch hold takes no
  picture. A wallpaper that is not loaded opens in a new window, which is hidden and kept off the
  other desktops before it is first ordered in (the renderer's `wallpaperLayerInstalled`
  notification with reason `open`). A window that belongs on the new desktop and is not ready
  there is made fully transparent before it moves: a window's alpha reaches the screen only with
  the next Core Animation commit while the move takes effect at once, so the hide is flushed
  (`CATransaction.flush()`) before the move; without it the window arrived opaque and the old
  wallpaper flashed on the new desktop until the run loop turned. Hidden windows stay
  transparent while the desktop's wallpaper loads, so its poster shows through, and fade in over
  0.2 s (none under Reduce Motion) once the scheduler has applied the choice and the
  [switch hold](wallpaper-switching.md) has let go: a scene's first presented frame, a page or a
  clip's own readiness. The wallpaper left behind stays on its own desktops, paused or replaced.
- **A wallpaper no desktop is chosen for** (a Focus wallpaper, a playlist's) follows the person to
  the current desktop as before, except while another wallpaper is on its way there: then it
  stays where it is, so it never shows on the desktop it is leaving for.
- A transparent window is still on screen to the window server and AppKit, so occlusion does not
  suspend the display and the renderer presents its first frame; the hold drops its veil without a
  fade, since nobody sees it, and the [window audit](diagnostics.md#desktop-window-audit) does not
  count the transparency as a fault. A change that waits for playback keeps the window hidden, so
  the desktop's own still shows rather than the old wallpaper's; a load still not ready after 30 s
  is shown anyway and logged.
- In a fullscreen app's Space the windows stay where they were.

AppKit has no public call that moves a window to the current Space: a window ordered in again, or
one that joins every Space and leaves again, goes back to the Space it came from. The move uses the
optional private CoreGraphics calls `CGSCopySpacesForWindows` and `CGSMoveWindowsToManagedSpace`,
resolved with `dlsym`, with each desktop's `ManagedSpaceID` from the topology; a window that
belongs on several desktops is added to and taken off Spaces with `CGSAddWindowsToSpaces` and
`CGSRemoveWindowsFromSpaces`, and without those two it goes to the one the person is on if it is
among them, else to the first. Without the move calls, or while posters are off (the other desktops
would show the person's own picture), the animated lock screen owns the desktop, or topology is
unavailable, every window stays on every Space as before and nothing is kept.

## Pictures of the other desktops

A poster is taken only from a wallpaper that plays, and only the current desktop plays; a kept
wallpaper's window is left out of the poster sync and the switch hold, since its frame belongs to
another desktop. So the poster sync also keeps the last poster of each wallpaper a desktop is set to (`DesktopSpacePosterCache`, one
JPEG per display and wallpaper under `<support>/Cache/SpacePosters/`, about 1 MB each) and writes it to
every desktop set to that wallpaper, and Desktop 1's to every desktop that follows it. A desktop not visited since launch (quitting puts the person's
own pictures back) or whose wallpaper was just chosen shows its own picture straight away, and the
current desktop has it until a fresh poster is taken. Only wallpapers some desktop is set to are kept:
the rest are deleted from memory and disk when the choices change. A desktop set to a playlist, or to a
wallpaper that has not played on that display yet, keeps the picture it had.

In Mission Control and the Spaces bar the other desktops are therefore still: a visited desktop shows
the frame its kept wallpaper paused on, the others their poster. Only a desktop that shows the same
wallpaper as the current one moves, because that window is on the current desktop too. The switch's
explanation in Settings says so in its first sentence, which stays under the title. This is a
deliberate trade-off: a probe on macOS 27.0.1 opened Mission Control, with the Spaces bar collapsed and
held open with its previews, and a window on another desktop got no occlusion change and was never
listed as on screen, while one on the current desktop got both. macOS shows other desktops from
snapshots and tells their windows nothing, so animating them would mean running every kept wallpaper
all the time or polling for Mission Control.

## Focus, mirroring and native lock-screen ownership

Focus wallpaper/playlist choices keep their existing priority. Leaving Focus uses the rule for the
currently visible desktop; if that desktop's identity is unknown, restoration waits rather than
choosing an old Space's wallpaper.

Mirrored or disabled displays do not offer the mode. Displays with a shared system Space group can
still choose different wallpapers, because choices remain per display.

Animated lock-screen wallpaper owns the system Desktop provider across Spaces and conflicts with this
mode. Settings refuses to enable it while a connected independent display uses the mode, and refuses
the mode while that provider is requested or still owned. If restored preferences contain both, the
desktop choices wait until the conflict is resolved. Screen-saver-only mode can continue using the
currently applied per-display content.

## Poster ownership and late frames

`WallpaperSpaceMonitor` reads the optional private `CGSCopyManagedDisplaySpaces` entry point and
decodes `Display Identifier`, `Spaces`, `Current Space` and the current desktop's `ManagedSpaceID`.
The data shape is private and not guaranteed on every macOS version, so the symbol and decoding are
optional; no Accessibility permission, synthetic gesture, Space mutation, plist patch or Dock restart
is used.

Poster requests carry a context containing the current visit, assignment and content revision. Scene,
Web and native-video producers return the context of the original request, and the coordinator rejects
mismatched contexts on receipt and again after asynchronous encoding. Changing out of the mode also
rejects late Space-scoped frames, and scene readback contexts travel alongside the existing request
sequence so retries cannot attribute old pixels to a newer visit.

`DesktopWallpaperLedger` restricts fresh posters to the matching native Space and writes the saved
posters to the others. A scope with no current target holds fresh writes; the public NSWorkspace
fallback has no Space identity and cannot receive a scoped poster. Inactive posters and their original
wallpaper journal remain referenced across renderer replacement gaps. Ejecting the current wallpaper
restores that desktop while preserving other desktops' posters, and normal stop/quit restoration still
restores all original selections using the existing journal and external-change checks. The rest of
the poster service is in [desktop picture](desktop-picture.md).

## Storage and verification

Choices live in the existing `WallpaperMachine.automaticWallpapers` records, under `spaces`; records
without it decode to an empty map. Local backups include them. UUIDs on another Mac or after system
recreation may not match; those choices remain unavailable until explicitly reassigned.
`WallpaperMachine.spaceVisits` is local runtime state, excluded from backups and cleared with handled
events and Focus recovery on successful restore; failed restore journals put that local state back.
The saved posters are a cache and are not backed up.

Topology, the current `ManagedSpaceID`, shared/independent groups, reordered UUIDs, fullscreen Spaces,
malformed topology, persistent visits and notification teardown are covered by
`WallpaperSpaceMonitorTests`, with every desktop's `ManagedSpaceID`; manual overrides, a hand-picked wallpaper becoming the desktop's own,
unmapped visits, a desktop following Desktop 1, rapid queued switches, paused catch-up, the pending choice and Focus exit while
topology is unavailable by `WallpaperAutomationSchedulerTests`; pinning, hiding before a move, the fade,
the hold and the 30 s ceiling, waiting changes, fullscreen Spaces, late windows, the missing private
calls, stop, windows on the desktops of their wallpaper, a shared wallpaper on several desktops and the
fallback without the calls for that, hiding only the window that loads, a wallpaper on its way and a
window hidden before it opens by `WallpaperSpacePinningTests`; the lists each display keeps, memory
pressure, unloading and refused lists by `WallpaperSpaceParkingTests`; parking a scene that has drawn,
running it again without a job, the same handle, closing on a shorter list, a new size or an unplugged
display, a global resume and closing everything by the renderer's `space_parking_tests`, and the
bridge's lists, scene windows and the first-frame wait it skips by `tests::space_parking` and
`a_wallpaper_the_display_keeps_parked_is_not_awaited`; kept clips and pages by
`NativeVideoWallpaperHostTests` and `WebWallpaperHostLifecycleTests`; the start and end of memory
pressure by `MemoryPressureMonitorTests`; the hold's release and instant drop on a hidden display
by `WallpaperSwitchHoldTests`; the audit's excuses, a kept window off the active Space among them, by `WallpaperWindowAuditorTests`; scoped writes, saved
posters for the other and the current desktop, public-fallback exclusion, late frames and encodes, mode
changes, replacement gaps, current-only ejection and all-Space restoration by `DesktopWallpaperTests`;
the saved posters' relaunch, safe names and pruning by `DesktopSpacePosterCacheTests`; and the switch,
the choices by UUID, reordering, unavailable desktops, forgetting and validation by
`PanelAutomationActionsTests`, with focus after Forget in `DisplaysSettingsModelTests`.

An authorized desktop run on macOS 27.0.1 (one display, three desktops, two scene wallpapers) checked
that the window stays on its desktop and moves with the person, that a swipe shows the destination's
own picture, that Mission Control shows each desktop's own wallpaper, that a warm switch shows the live
wallpaper 0.4–1.0 s after the swipe ends with the poster on screen until then, and that unvisited
desktops get their picture right after launch. A later report of the old wallpaper flashing just
after the swipe, and of the new one jumping from fit to fill, was traced with probe windows on one
desktop (no Space switch): an unflushed hide followed by a move showed the window opaque on arrival,
and a flushed one did not; the jump was the first frame drawn before the scaling arrived (see
`first_frame_scaling` in [renderer testing](../testing/renderer.md)). Neither fix was watched on a
real swipe, since every desktop was covered by windows. A build signed differently from the installed app asks
again for System Audio Recording, and an audio-responsive scene waits for that answer before its first
frame; that is a property of test builds, not of the mode. Multi-display separate Spaces, web and video
wallpapers on a pinned display, VoiceOver and the chooser's search were not checked on the desktop.
Keeping each desktop's wallpaper (no intro on return, the kept frame during a swipe, a shared
wallpaper on several desktops, the extra Space calls, the memory it holds and letting go under real
memory pressure) has not been watched on a desktop yet.
