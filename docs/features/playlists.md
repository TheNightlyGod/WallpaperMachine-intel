# Playlists

Each display can change wallpaper on its own: a rotation through a set of
wallpapers every so often or each time the Mac is unlocked, or one wallpaper by day
and another by night. Nothing
changes until the user turns it on; an unconfigured display is **Off**.

## Where it lives

**Settings → Displays → a display → Playlist** holds the display's playlist.
Mirrored displays show their source and have none. **Changes on its own** picks
the mode:

| Mode | Rows | What happens |
| --- | --- | --- |
| **Off** | — | The wallpaper changes only when the user changes it. |
| **Rotate wallpapers** | **Wallpapers** (All wallpapers, Favorites, This display's list, or a local collection), **Order** (In order, Shuffle), **How often** (every 5, 10, 15 or 30 minutes, every hour, every 2, 3, 6 or 12 hours, every day, **Each time the Mac is unlocked**, or **Custom**: any whole number of minutes from 1 to 10,080, one week), and for a time, **Wait for the video to finish** | After each interval, or each time the Mac is unlocked, the display moves to the next wallpaper. |
| **Day and night** | **Day wallpaper**, **Day starts at**, **Night wallpaper**, **Night starts at** | The day wallpaper takes over at the day time and the night wallpaper at the night time. |

A new rotation defaults to every 30 minutes, in order, and does not wait for videos; day
starts at 07:00 and night at 19:00. A rotation set to change when the Mac is unlocked has no timer and no next-change
date (see [below](#each-time-the-mac-is-unlocked)); choosing a time again brings the timer
back.

For weekday schedules, sunrise/sunset, system appearance or temporary Focus
playlists, use [Automatic wallpaper selection](automation.md#automatic-selection)
in the same display section. An automatic wallpaper choice stops its playlist;
an automatic saved-plan choice replaces it. Manual playlist edits share the
wallpaper command queue, so an activation already running cannot overwrite a
newer edit. Distinct field edits are retained rather than coalesced.

All wallpapers and Favorites follow the library order; a list keeps the order its
wallpapers were added in. Only wallpapers that can play count, so a wallpaper that
left the library or cannot run on macOS is skipped. In order moves to the one
after the wallpaper on screen and wraps; Shuffle shows every wallpaper once, in a
new random order each round, and never picks the one on screen, and a relaunch
carries on with the round it was in (see [Storage](#storage)). A day that starts
after its night (say day 22:00, night 06:00) wraps past midnight. The two times must
differ: a day that started when the night does would have no length, so choosing the
other one's time is refused with a message and both times stay as they were. Times are local
clock times, so a daylight-saving day still switches at the time on the clock.

**Change now** moves a rotating display along at once and starts a fresh
interval; the row's note says roughly when the next change is due, or, for a rotation that
waits for the unlock, that it changes then, or, for a change that waits for a video to
finish, the latest time it is made ([below](#waiting-for-a-video-to-finish)). The menu bar's
**Next Wallpaper**, on the display it is shown for, the **Next wallpaper** button on the
panel's Now Playing bar (for the target display), and a link, Shortcuts action or
shortcut key asking for the next wallpaper, on the panel's target display unless one is
named, do the same for a display that rotates, and otherwise take the next wallpaper
in library order. All of them are asked for, so they also change a display that is
paused or covered; only the timer's own changes wait for a pause (see below). When the playlist has
nothing else to change to (its only wallpaper is already on screen), Change now, the
Now Playing button and a link, keyboard shortcut or Shortcuts action asking for the next
wallpaper say so
instead of succeeding without a change.

This display's list is edited from Installed: the list button in a wallpaper's
details adds it to, or removes it from, the list of the target display, and a
selection's **Add to playlist** adds every selected wallpaper. In Settings, drag a
wallpaper above or below another to reorder the list, or use its **Move up** and
**Move down** buttons with the keyboard. **Remove** changes membership. Reordering
is saved immediately, keeps the next-change deadline and detaches an applied saved
plan, like other manual edits. A stale reorder is refused if membership or order
changed while it was being dragged; it never overwrites a concurrent edit.
Wallpapers moved to Trash leave every list and every day or night choice.

### Playing from Installed

**Play** at the end of Installed's view chips, and **Play** and **Shuffle** in a
local collection's context menu in the Filters sidebar, turn the view on show (All
wallpapers, Favorites or that collection) into the target display's rotation. Installed's
**Play** keeps the order the target display already uses; the menu in the same capsule names
and ticks that order and plays in the one chosen (**In order** or **Shuffle**). In the context menu,
**Play** plays in order and **Shuffle** shuffled. The display changes to its first wallpaper at
once, keeps its interval or unlock trigger, and a display you emptied is filled again;
when it already shows the only wallpaper the source has, the rotation is set and the
wallpaper stays. A source with no wallpaper that can play is refused and nothing
changes. The buttons are unavailable while the view is empty or the target display
is a mirror or disabled. While the target display rotates, Now Playing names the
source and its **Playlist** button shows the order, interval and next change, with
**Change now**, **Stop** and **Settings…** ([Now Playing](control-panel.md#now-playing)).

### Collections and saved playlists

Local collections are created and filled from Installed (see
[Local collections](control-panel.md#local-collections)); they hold no wallpaper files.
A collection can feed more than one display, and membership changes are read when the
next switch is chosen. Removing a wallpaper from the library removes it from
collections and saved playlists too.

Each display's Playlist disclosure has **Saved playlist** and **Save as…**.
Saving keeps a named copy of the mode, source, order, trigger, interval and day/night
choices; choosing it applies a copy to an enabled independent display. A rotating
copy on a timer becomes due immediately, also on a display that is only out of sight,
but waits while that display is paused; one
that changes when the Mac is unlocked waits for the next unlock. Manual
edits detach the display's copy from the saved plan. Renaming a plan preserves its
identity; deleting it leaves active copies and their deadlines intact. Deleting a
collection turns playlists using it into empty explicit lists, never All wallpapers.

Collections and plans have stable UUIDs; duplicate names do not merge them.
They live in the `WallpaperMachine.collections` and
`WallpaperMachine.playlistPlans` defaults. The existing per-display playlist and
next-change stores remain the source of active playback state.

## When a change happens

A change the timer brings only happens while wallpapers are playing. One that falls
due while the user paused playback, a Playback & Power choice, an app
rule or a Focus paused every wallpaper, the screen is locked or the displays sleep
waits, and happens once when it can play again; missed intervals are not caught up one by one.

A display that is only out of sight (windows cover it, a full-screen app or a hidden
Space is in front of it, or it is not the one in use; see
[Playback](performance.md#playback)) is not waited for: its change happens behind
the windows, so the desktop already shows the new wallpaper when you come back to it,
instead of switching in front of you. It changes once while it stays out of sight, so
a long full-screen session does not load a wallpaper every interval; when it shows
again, the next change is a whole interval later rather than at once. A saved
playlist chosen meanwhile still applies at once, and an edited one may change it
again. Only a successful switch counts as that out-of-sight change: if playback
pauses before selection, the due change waits until playback can resume, even if
the display remains covered. A switch selected while covered that succeeds during
a global pause or lock still counts as the hidden change; resuming behind the
same windows does not allow another rotation. If no alternative is available or every attempt
fails, the rotation tries again after its interval. Returning to the desktop
starts a full interval even when the previous deadline is still in the future.
Day and night switches at its boundary in the same way. A rotation set to
change when the Mac is unlocked still waits for the display to show (see
[below](#each-time-the-mac-is-unlocked)).

The timer sleeps on the continuous clock, so a change that fell due
while the Mac slept happens on wake. Nothing is polled: `PlaylistScheduler` arms
one timer for the earliest change and re-evaluates when playback, presentation
(of every display together or of one display alone), the library, the playlists,
the clock or the time zone change.

Every switch runs through the display's command slot, the same one the panel's
Apply and the menu bar use, so the latest request for a display wins, and the
next wallpaper is chosen when the switch's turn comes. A playlist never
replaces a wallpaper you chose: if your Apply is waiting for its turn on that
display, or is running there, the playlist's change (Change now included) gives way
at once, is not retried, and the rotation tries again one interval later. It does
not queue up behind your Apply, which would replace the wallpaper you just got. In Day and night, a wallpaper the
user applies by hand stays until the next half of the day, and choosing a
different day or night wallpaper applies at once. A relaunch inside the same half of
the day (an app update, the library's drive coming back) is not a new period, so the
wallpaper applied by hand is still left alone (see [Storage](#storage)).

A wallpaper you apply to a rotating display is also left alone for a while: the
rotation's next change waits at least `min(interval, 5 minutes)` from your choice
(`PlaylistScheduler.noteManualChoice`), so a change that was a minute away does
not replace it. Any wallpaper you apply yourself counts: the panel's Apply, one
from the menu bar's recently used list, **Previous** or **Random Wallpaper**, a link,
Shortcuts action or shortcut key that applies one, a display layout or a copy to another display,
and applying the wallpaper already on screen. A deadline further away than that is
never shortened, so a long interval keeps its rhythm, and a paused display whose
deadline already passed is pushed back too, so it does not swap the moment
playback resumes. **Change now** and **Next Wallpaper** on a rotating display are
unchanged (they start a full interval), and the playlist's own changes and an
automatic rule's never count as a choice.

A rotating playlist skips a wallpaper whose application throws an error and tries
another in the same change, at most five distinct wallpapers. Failed items wait
15 minutes before becoming candidates again; they do not count as successful
shuffle picks, and a shuffle round is over once every wallpaper that can be picked has
been shown, so one that keeps failing does not hold the round open and turn every later
pick into a plain random one. A successful choice starts the usual interval. If nothing succeeds,
the next attempt waits for that interval instead of looping through the library.
Cancellation, a replaced playlist, a disconnected display, or a newer command for
that display ends retries. If a failed operation nevertheless changed the reported
assignment, the scheduler stops rather than guessing whether it rolled back.

**Temporarily skipped** under the display's playlist lists the failures.
**Allow these wallpapers again** clears the cooldowns; applying an item manually
is always available. Cooldowns are per display and last only for this run of the
app. Day/night still attempts its exact chosen wallpaper once per period; it never
substitutes an unrelated one. These rules handle errors returned by Apply, not a
later visual defect in a wallpaper that was accepted successfully.

### Waiting for a video to finish

**Wait for the video to finish** (a rotation on a timer; `DisplayPlaylist.waitsForClipEnd`,
off by default) keeps a timed change from cutting a clip. When a change falls due while a
video wallpaper plays on the display, the change waits until that clip reaches the end of
the pass it is in and starts over, then happens through the display's command slot as usual,
and the next interval counts from then. Only a plain video (the
[video player](performance.md#video-playback) or the WebM player) has an end to wait
for: a scene, a web page or a picture changes on time, and so does a rotation that changes when
the Mac is unlocked, which has no row for it. The video host tells the scheduler about the
display's own clip only (`PlaylistScheduler.WatchClipEnd`, wired to
`NativeVideoWallpaperHost.watchClipEnd`), so a mirror's copy never adds a change, and a second
report of the same end changes nothing. Nothing is polled.

The wait has a limit, `PlaylistScheduler.clipEndLimit(minutes:)`: as long as the interval, but
at least 10 minutes and at most an hour. A longer clip, or one that stopped advancing without
failing, is changed then. A clip that fails ends the wait at once, so a broken clip cannot
hold the playlist; so does one that leaves the display (another wallpaper or desktop takes its
place), and the change then waits only if what took its place is a video too. The usual rules
still come first: nothing waits or changes while wallpapers are paused or the screen is locked,
and the wait starts again, with a fresh limit, when they play again; a display out of sight
changes behind the windows without waiting, since nobody sees the clip cut. A wallpaper you
apply ends the wait and holds the change back for a while, as above; **Change now**, and
turning the option off, make the change at once.

While the change waits, the **Next change** note (and Now Playing's playlist) says it comes when
the video finishes, and by what time at the latest (the limit), instead of naming the
deadline that has passed. The scheduler notes the wait in `PlaylistStore.clipWaits`, run
state that is never saved; it posts `PlaylistStore.clipWaitsDidChangeNotification`, which only
the panel follows, so noting a wait never runs the scheduler's evaluation again from inside
itself.

### A display you cleared

Taking the wallpaper off a display (**Eject** in Settings → Displays, **Remove from
display** in a wallpaper's details, or **Remove from Display** in the menu bar's submenu
for that display) is a choice too: the playlist does not undo it by
filling the display again at the next change. `BridgeStore.removeWallpaperFromDisplayAsync`
reports the removal, and the app delegate puts the display's playlist on hold
(`PlaylistStore.holds`, the `removedWallpaper` reason) when the playlist is Rotate or
Day and night. A display on hold has no deadline and no timer, and its playlist row
reads **Playlist paused** with a **Resume playlist** button.

The wait ends when:

- any wallpaper is on the display again, whoever put it there (an Apply, a link, a
  rule, a Space, a Focus); a rotation then counts a whole interval from that moment,
  and Day and night leaves what is on screen until its next boundary;
- **Change now** or **Next Wallpaper** asks a rotating display for a change;
- **Resume playlist** is chosen: a rotation fills the display now and starts a fresh
  interval, and Day and night applies the wallpaper for the current half of the day as
  soon as the display can play;
- the playlist is turned **Off**, a saved playlist is applied to the display, or a Focus
  ends and restores its playlist.

Only the user's own removal holds a playlist. The ejects the app makes itself (deleting
a wallpaper, reloading or reapplying one after an update, recovering a display layout,
restoring after a Focus) never do, and a change already waiting in the command queue
when the display is emptied finds the hold and leaves the display empty. The hold is
kept across launches, so a relaunch does not fill a display that was cleared. It is
run state like the shuffle round: it is not part of a backup.

### Each time the Mac is unlocked

**How often → Each time the Mac is unlocked** makes a rotation change when the Mac is
unlocked instead of on a timer (`DisplayPlaylist.trigger` is `unlock`; every other choice
is `interval`, and so is a stored trigger this build does not know). Such a display has no next-change date and no timer, its
row's note reads "Changes when you unlock the Mac, while wallpapers are playing.", and
its interval is kept unused, so **Custom** shows it again. Locking the Mac, a screen
saver or display sleep never changes a wallpaper; only the lock clearing does.
**Change now** and **Next Wallpaper** still work, and do not start a timer.

The signal is `WallpaperPresentationPolicy`, which already keeps a corrected copy of the
session's lock state (re-read from the window server on every evaluation while it counts
as locked). When that state goes from locked to unlocked the policy calls
`onSessionUnlocked` once, after it has settled the new presentation, and the app delegate
passes it to `PlaylistScheduler.noteUnlock()`. The edge comes from the corrected state, not
from the `com.apple.screenIsUnlocked` notification, so an unlock whose notification was
lost still counts at the next evaluation. A session that was already locked when the app
started has not been seen to unlock, so only the unlocks after that count.

`noteUnlock()` treats a second report within 2 seconds as the same unlock, then opens a
30-second window (`unlockDebounce`, `unlockGrace`). Every display whose rotation waits for
the unlock changes once in it, as soon as wallpapers are playing there. A display that
cannot play at the moment (covered, re-enumerating after wake, or its presentation still
resuming) is retried by the evaluations the app already runs on every presentation change
until the window closes and is then left alone, never changed minutes later; a display that
appears within the window is covered too. The change goes through the display's command
slot like any other, so it waits behind the presentation resume the unlock itself
triggers. While playback is paused nothing changes, and nothing is replayed afterwards. A
display the user cleared (see above) is not refilled by an unlock, and a wallpaper chosen
by hand, **Change now**, or a wallpaper put on the display by anyone else while the window
is open counts as the display's answer to that unlock. An unlock that no display waits for
is forgotten, so choosing the setting later never acts on an unlock that is over.

## Random Wallpaper

**Random Wallpaper** is a command, not a playlist mode: the menu bar (after **Next
Wallpaper**, for the display whose menu it is), a `wallpapermachine://random` link, the
Shortcuts app and an optional shortcut key change a display to a random wallpaper other
than the one it shows ([automation](automation.md#commands)). It draws from every
wallpaper that can play, or from the favorites only (`from=favorites`, **Choose from** in
Shortcuts), and never from one the app is holding back after a crash
([crash recovery](crash-recovery.md)). It does not need the display to have a playlist,
and it leaves a playlist's settings, order and next-change date alone.

Like a shuffled playlist it goes through the whole pool before it repeats a wallpaper, but
it keeps a round of its own for each display and pool, so Random never uses up or restarts
a shuffled playlist's round and the other way round. **Next Wallpaper** is unchanged: the
playlist's order for a display that rotates, otherwise the next one in the library. A pick
is the user's own choice, so it holds a rotation back for a few minutes like any wallpaper
chosen by hand and lifts a hold left by removing the wallpaper
([a display you cleared](#a-display-you-cleared)). The pick is made when the display's turn
in the command queue comes, from whatever the display shows then, and the round only
remembers a pick once it has been shown, so one that failed to load can come up again. When
the pool holds nothing but the wallpaper on screen, the command fails with a message
instead of changing nothing; the menu leaves **Random Wallpaper** out in that case.

## Storage

`PlaylistStore` keeps every display's playlist in the `WallpaperMachine.playlists`
default (JSON; missing fields decode with defaults, so a playlist saved before the
trigger existed rotates on its interval, one saved before **Wait for the video to finish**
existed does not wait, and an interval outside 1–10,080 minutes falls back to 30) and each display's next change in
`WallpaperMachine.playlistNextChange`, so a relaunch neither restarts a long interval
nor skips a change that fell due while the app was closed. A display whose playlist is
waiting after the user removed its wallpaper is kept in `WallpaperMachine.playlistHolds`,
so a relaunch leaves it empty.

The half of the day a Day and night display is settled for (its wallpaper was applied, or
one chosen by hand stays until the next boundary) is kept in
`WallpaperMachine.playlistSettledPeriods`, with the two start times and the two wallpapers
it was settled under. A relaunch picks it up only while the display still has those, so a
manual choice survives a relaunch inside the period, and a day or night wallpaper or time
changed just before quitting still applies when the app starts again. It is written only
when it changes, and it is run state like the hold: it is not part of a backup.

A saved playlist (plan) this build cannot read, one saved by a newer build or damaged, does
not take the others with it: the readable ones load, and saving, renaming or deleting a plan
writes the unread one back as it was saved (`PreservedJSON`).

Shuffle's round, the wallpapers a display has shown since the round began, is kept in
`WallpaperMachine.playlistRounds` for each display that rotates in Shuffle order, so a
relaunch neither repeats a wallpaper it just showed nor starts the round over. It is
saved with the source, collection and order it was drawn from and picked up again only
when the display still has the same ones. Changing the source, collection or order,
turning the playlist off or to Day and night, applying a saved playlist, ending a Focus,
or restoring a backup that replaced the playlist starts a fresh round. Editing a list
keeps the round, and deleting a wallpaper drops it from the round. A finished round is
not saved, an in-order rotation saves nothing, and a round holds at most 2,048
wallpapers (the newest). It is run state like the hold: it is not part of a backup.

[Random Wallpaper](#random-wallpaper)'s rounds are kept in the same default, in a `random`
field filed under `<display>|<pool>` (`primary|all`, `primary|favorites`), each with its pool as
its signature, so a round filed under a pool this build does not have is ignored. They are saved as
soon as a pick is shown, need no playlist, are dropped when a wallpaper is deleted, and a
finished round or a round of nothing is not saved. They use the same 2,048-wallpaper cap and are
left out of a backup too.

## Code

| Part | Where |
| --- | --- |
| Model | `App/Services/Playlist/WallpaperPlaylist.swift` |
| Candidates, next pick, day and night | `App/Services/Playlist/PlaylistPlanner.swift` |
| Persistence and dates | `App/Services/Playlist/PlaylistStore.swift` |
| Timer and switching | `App/Services/Playlist/PlaylistScheduler.swift`, wired in `AppDelegate.startPlaylistScheduler` |
| The end of a video's pass | `NativeVideoWallpaperHost.watchClipEnd`, and `watchNextLoop` in `NativeVideoPlayer.swift` and `Shared/WebMPlayer.swift` |
| Panel actions | `editPlaylist`, `playPlaylist`, `addToPlaylist`, `removeFromPlaylist`, `reorderPlaylist`, `clearPlaylistFailures`, `skipPlaylist`, `resumePlaylist` in `App/Views/ControlPanel/Model/PanelController+Playlists.swift`; the menus' rules in `Model/PlaylistEdit.swift` |
| Panel | Settings → Displays in `App/Views/ControlPanel/Settings/Sections/DisplaysPlaylistRows.swift`, with drag and button ordering in `DisplaysOrderEditor.swift` and the page state in `Settings/DisplaysSettingsModel.swift`; the inspector's playlist item and Installed's **Add to playlist** in `Inspector/` and `Library/`; Installed's Play and its order menu in `Library/InstalledScopeBar.swift`, the collection's Play and Shuffle in `Library/CollectionsFilterGroup.swift`; Now Playing's playlist in `Shell/NowPlayingPlaylist.swift` |
| Collections and saved-plan actions | `WallpaperCollectionStore.swift`; `createCollection` … `removeFromCollection` in `Model/PanelController+Collections.swift` and `savePlaylistPlan` … `applyPlaylistPlan` in `Model/PanelController+Playlists.swift`; the sidebar's `Library/CollectionsFilterGroup.swift` and the Saved playlists group in `Settings/Sections/DisplaysGroups.swift` |

## Verification

`PlaylistPlannerTests` (candidates, order, shuffle rounds, day and night
boundaries including a wrap past midnight and a daylight-saving day, decoding),
`PlaylistStoreTests` (persistence, a fresh wait after a new rhythm, removal from
every playlist, re-dating without a change, persisted reorder and stale-order
rejection, a shuffle round surviving a relaunch and being dropped when its source,
collection, order or mode changes, when the playlist behind it is gone or was
restored, and for an in-order rotation, pruned for deleted wallpapers, capped, and
ignored when unreadable), `PlaylistSchedulerTests` (a waited interval, a change that fell due
while paused happening once, day and night with
a manual choice left alone, Change now, nothing playable, bounded failure skipping,
cooldown expiry, cancellation, manual-command precedence and a rotation giving
way to a waiting Apply, rescheduled one interval later, a manual choice holding a
due rotation for min(interval, 5 minutes) without ever shortening a later deadline
or touching Off and Day and night, a display the user emptied staying empty at a due
change or a day and night boundary until a wallpaper, Change now or Resume ends the
wait, and a change waiting in the queue leaving it empty, and a relaunch finishing
the shuffle round it was in without repeating a wallpaper, an unlock changing an unlock
rotation once and ignoring a double report, waiting for a display that cannot play yet but
only for the 30-second window, leaving timed rotations, cleared displays and a hand-chosen
wallpaper alone, and never dating a display, and a rotation that waits for videos: the change
waiting for the clip and made when it starts over, its limit reached through the scheduler's own
timer, the wait noted for the panel and cleared, a wallpaper that is not a video
changing on time, nothing watched with the option off, a pause ending the wait and playing again
waiting once more, a display out of sight changing without waiting, a hand-chosen wallpaper,
Change now or turning the option off ending it, and one change per display for one end) and
`PanelPlaylistActionsTests` and `PanelPlanActionsTests` (the actions' validation, the trigger
and the held state, Next change naming the latest time while a change waits for a video, and
Play: the source, order and kept interval, the change at once, an emptied
display filled, and a source with nothing that can play refused) with `PanelLibraryActionsTests` (Now Playing's Next wallpaper). `WallpaperPresentationPolicyTests` checks the unlock edge: once per unlock, also
when the notification was missed, after a wake or a user switch, and never at start or
stop. `WallpaperBackupTests` checks that a backup carries the trigger and the video option and
rejects an unknown trigger or an option that is not a yes or no. `NativeVideoWallpaperHostTests`
checks the video host's side: a watch answers once for the display's own clip and never for a
mirror's, needs that wallpaper playing with an end to wait for, is silent once cancelled, and ends
when the clip fails or the display moves on; `WebMPlayerTests` checks where a WebM pass ends and
that its watch is told once at the wrap, and never once cancelled or while held; and the opt-in
`NativeVideoPlayerMediaTests` check the same with the real looper, including an item rebuilt for
a colour option.
`PlaylistStoreTests` also covers Random Wallpaper's round: no repeat of the wallpaper on screen
and every wallpaper once per round (over many seeds), surviving a relaunch, one round per display
and pool, separate from the playlist round, kept without a playlist, pruned and capped, and ignored
when unreadable or filed under an unknown pool. `WallpaperDisplayTransferIntegrationTests` checks
that only the user's removal reports
one, not a delete or a reload, and that the menu bar's removal clears only the named
display, waits behind a switch asked for first and refuses a mirrored or disabled display.
`DisplaysSettingsModelTests` drives the reorder buttons and drag and drop, including a stale
drag refused without overwriting the newer list, the Resume row, and the How often menu's
Custom field and unlock choice; `PlaylistEditTests` covers the menus' rules and
`SettingsBRenderTests` draws every row in every language. Real switching on a desktop, and the order of the
operating system's unlock events against a display waking, are not covered by these tests.
