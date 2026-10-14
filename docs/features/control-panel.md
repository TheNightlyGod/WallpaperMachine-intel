# Control panel

The app window is a bundled HTML/CSS/JS interface rendered by `WKWebView` from
[`WebUI/`](../../WebUI), served over the app-private `mwe-ui:` scheme and driven
by [`App/Views/ControlPanel/`](../../App/Views/ControlPanel). Menus, windows,
file pickers and security confirmations stay native — the web layer never draws
a system dialog and renderer content is never loaded into the web view. The
runtime structure (scheme handler, snapshot, action bridge, crash recovery) is in
[architecture](../architecture.md#control-panel-wkwebview-and-the-javascript-bridge).

Documented separately: the [first-run guide and support prompt](first-run.md),
[live preview, properties, presets, image placement, the compatibility check and
the black-bar check](wallpaper-properties.md), [local backup and restore](backup-restore.md), and
[app updates and What's New](updates.md).

## Language

The app ships in English, Simplified Chinese (简体中文), Traditional Chinese
(繁體中文) and Japanese (日本語), including navigation, filters, wallpaper options,
download and sign-in guidance, settings, accessibility labels, menus and dialogs.
**Settings → General → Language** offers **System (Auto)** (default, follows the
macOS language list) and every shipped language under its own name.

- Choosing a language switches the panel immediately, without a reload, and is
  remembered. The **Import → Choose files** picker follows immediately too,
  including a language chosen in the [welcome guide](first-run.md#first-run). Native menus and other
  dialogs use the new language after fully quitting and reopening the app,
  because macOS fixes a process's localization at launch. Returning to **System
  (Auto)** hands the choice back to macOS.
- Missing keys fall back to English. Wallpaper titles, descriptions, creator
  names, custom property labels and upstream diagnostic details remain as
  supplied; the panel translates its own labels and recognized Wallpaper Engine
  UI tokens, not authored prose. The one exception is a property or choice
  label that the wallpaper's own translation table covers: it follows the
  language, also in an inspector that is already open (see
  [Properties](wallpaper-properties.md#properties)). Steam filter
  values and bridge action identifiers do not change when labels are translated.

How the language is resolved, how the layers fit together and how to add a
language: [Localization](../localization.md).

## Layout

| Region | Contents |
| --- | --- |
| Top tabs | **Discover**, **pixiv**, **Installed**, **Settings** |
| Top bar | Sits in the window's title-bar strip beside the traffic lights: tabs on the left, the product mark and name centered, target-display picker and a downloads button (only while there is download activity) on the right. In windows up to 840px wide the name hides and only the mark stays. Its background drags the window and follows the system double-click action |
| Browser column | Filter button, search field, sort menu, tile grid, result summary, and on Discover the Workshop pagination with an editable page number. A Discover page is one Steam page of 30 tiles, at most 1,000 pages |
| Left sidebar | Filters on every library page, mirroring Wallpaper Engine's sidebar: Show only, Type, Age rating, Resolution and Tags tick boxes on Discover; the same boxes minus Resolution (plus Favorites, Active and Update available in Show only) on Installed, applied to the library in the page; the pixiv account and pixiv's own filters on pixiv. The toolbar's Filter button opens and closes it, and that choice is remembered per page across launches |
| Inspector | Preview, title, kind, creator, actions, tags, and the selected wallpaper's options and properties ([wallpaper properties](wallpaper-properties.md)). Its width is a function of the window width alone and cannot be dragged: 260px at the 760px minimum, growing with the window to 420px from about 1830px (`--inspector-width` in `panel.css`), the same on Discover and Installed. Nothing is stored, so a given window size always yields the same layout. The preview is capped at 220px, or 180px in windows up to 640px tall |
| Activity bar | Global pause/resume, import activity and unseen results, download progress (not a playback timeline). Playback remains available when any display has an assignment, even if the target display is empty; with no assignments it is disabled and reports **No wallpaper playing**. Long summaries truncate visually but keep their full accessible names |

In full-screen mode and either Split View tile, the top bar stays in the content
area below macOS's native chrome and the empty toolbar that aligns the windowed
traffic lights is hidden. The layout switches only after a successful transition,
so a canceled entry or exit leaves the current layout intact and the restored
window bounds unchanged.

The visual direction combines Wallpaper Engine's image-first gallery, filtering
and right-hand property workflow with macOS window chrome and controls; it does
not reproduce Windows window decorations. Filled accent color is reserved for
primary actions, selection and status, so Filter does not compete with Apply or
Download. Light/dark mode, surface tone and custom accent preferences continue to
apply ([appearance](appearance.md)).

Wallpapers appear as square, image-first tiles with a transparent title overlay.
Tiles keep their size on hover or keyboard focus and rise above their neighbours
with a shadow instead of enlarging; selection is an outer accent ring with a
surface-coloured gap so blue artwork does not hide it. Both library tabs fill the
grid with as many columns as the browser column can hold at a preferred tile size
(154px) that shrinks with the column, and never fewer than three, so a narrower
window shows smaller tiles and more of them. The grid reserves its scrollbar
gutter, so the column count is a pure function of its width and cannot flap, and
it scrolls vertically for whatever rows that takes. At the narrowest browser width
captions stay on one line and hide the type sublabel; Installed's sidebar grows
as needed to keep **Active on target display** on one line in every language.

Discover tiles show cached still thumbnails first and then, for tiles on screen,
Steam's animated preview once it loads; the animation lifecycle, and why the
panel never reads animation pixels back, are in
[Workshop downloads](workshop-downloads.md#tile-thumbnails). An installed copy of
the same wallpaper shows its library preview on Installed.

Installed tiles are stills as well, so a library of animated GIF previews costs
nothing at rest. The scheme handler serves each wallpaper's own preview file as a
512px JPEG cover (`mwe-ui://library-thumbnail/<id>`), made once by a
`WorkshopThumbnailCache` of its own (`Cache/LibraryThumbnails`, 128 MiB, four at a
time, no animation kept) through `LibraryPreviewFetcher`, which reads only an
image inside the library up to 32 MiB and follows no symlink out of it. A cover is
keyed by the file's path, modification time and size, and its address carries a
stamp of the same two facts (`v=`, `LibraryPreviewFetcher.coverStamp`), so a
preview that an update or reinstall replaced is covered again, while a rescan
that replaced none (every download, import and delete rescans) leaves each tile's
image, address and page node alone. `LibraryCoverStamps` reads the stamps off the
main thread after each rescan and asks for a fresh snapshot only when one is new
or changed; until a tile's is read the snapshot says `coverPending` and the tile
shows no image, never the full-size preview. If a cover cannot be made the tile
shows the preview file itself, and tries the cover again when the preview
changes. Building the snapshot touches no file: a tile is offered the file to
animate (`animated`) by its extension alone (`gif`, `webp`, `apng`).

An animated preview plays on one Installed tile at a time: the tile the pointer
has rested on for 160ms, or the tile keyboard focus is on (a mouse click alone
does not count). Sweeping across the grid, dragging a selection and a preview
that is a single picture start nothing, and moving between one tile's own buttons
keeps it playing. Leaving the tile, losing window focus, hiding the page or
changing tab releases the animation. The inspector's artwork is the preview file
itself, so the selected wallpaper still animates there.

The window never shrinks below a 760×560 content area (capped by the visible
screen on small displays). `ControlPanelWindow.minimumContentSize` owns that
floor and `AppDelegate.windowWillResize` enforces it, because the SwiftUI hosting
controller resets `contentMinSize` once it attaches.

Arrow keys, `Home` and `End` move focus across the grid; `Escape` closes an open
popover or leaves selection mode. The sort menu and its actions wrap as one group
after Filter and search; at a narrow browser width Installed's Import becomes a
named icon button. Errors keep their original details and **Dismiss**;
**Reconnect** is offered only before the first snapshot or when the native bridge
is unavailable, not for an ordinary operation failure.

A wallpaper that was left out of the session because the app quit unexpectedly twice
while loading it gets its own banner under the error line, one row per wallpaper:
a sentence naming it and **Try again**. It is a warning, not an error, so it has no
Dismiss; it goes away when the wallpaper is retried or applied, and a retry the engine
refuses shows the reason in the error line and keeps the row. The menu-bar menu repeats
the state as a disabled line. See [crash recovery](crash-recovery.md).

## Tabs

- **Discover** browses the Steam Workshop. See [Workshop downloads](workshop-downloads.md).
- **pixiv** browses pixiv's illustration rankings and tag search in the same grid,
  sidebar and inspector, and saves a page of a work as a still wallpaper. See
  [pixiv](pixiv.md).
- **Installed** shows the local library.
- **Settings** replaces the browser with a sectioned settings view: **Performance**
  (the section Settings opens on), General, Appearance, Displays, Library & Steam,
  Storage and About.
  - **General** starts with the [Language](#language) picker, then startup and
    desktop (including the switch for using the wallpaper as the macOS desktop
    picture and the optional five-minute Mission Control picture update; see
    [desktop picture](desktop-picture.md#leaving-macoss-own-wallpaper-alone), and the
    off-by-default switch that lets the displays follow a wallpaper's pending property
    edits as they are made; see [edits on the
    desktop](wallpaper-properties.md#showing-edits-on-the-desktop)),
    keyboard shortcuts (see [automation](automation.md)) and lock-screen groups.
    Battery behavior is one choice on Performance, not a General toggle.
    **Launch at login** is disabled with its reason while the app is outside
    Applications. When the user has switched WallpaperMachine off in System Settings →
    General → Login Items, macOS keeps it off however often the app registers it
    again: the switch stays usable but off, a note says to allow it there, and
    **Open Login Items…** opens that pane. Switching it on again while the note is
    showing changes nothing, because only the user can allow the item there; turning
    the switch off unregisters the item only while it is on. System Settings does not
    tell the app when the user allows it, so while the note is showing the panel reads
    the status again each time it becomes the key window: allowing the item there and
    coming back clears the note and the button. The first-run Preferences page carries
    the same note.
  - **Performance** opens with a live energy readout for the app, then quality
    (presets, frame-rate limit, render scale) directly beneath it, then playback
    (occlusion, other-app audio, display sleep, playing only on the display in use,
    battery, low battery, Low Power Mode, heat, Focus, app rules; the battery, low-battery,
    Low Power Mode and heat choices can each lower quality instead of pausing, and the page names
    which one is lowering it). Video backend, scene controls and the experimental switches
    stay under **Advanced**. See [Performance settings](performance.md). The
    inspector of an installed wallpaper adds its measured energy grade, and on a
    Mac with a battery its share of a charge per hour, once it has one
    ([Per-wallpaper energy rating](performance.md#per-wallpaper-energy-rating)).
  - **About** leads with the app version (`MARKETING_VERSION` in `project.yml`) and
    the Git revision. **Check for Updates** reads the latest GitHub Release;
    download and restart-install happen only after confirmation (see
    [updates](updates.md)). The application menu item **Check for Updates…** opens
    this section.
  - **Storage** holds [Backup](backup-restore.md) and ends with
    **Troubleshooting**: Detailed logging, *Allow inspecting web wallpapers*
    (Safari's Web Inspector on the running pages) and the diagnostics report
    export. See [Logs and diagnostics reports](diagnostics.md) and
    [inspecting a web wallpaper](diagnostics.md#inspecting-a-web-wallpaper).

Settings use lightly bounded, keyed groups with dividers between related rows.
Rows wrap within their available width, and below a 480px content width controls
stack beneath their labels while switches stay inline. Live backend, quality,
power and installation readouts sit apart from the saved preference controls, and
unknown, preparing and fallback results stay distinct. Explicit lock-screen
unavailability disables its switch; language and appearance remain usable if
renderer settings are unavailable. Snapshot updates preserve active drafts,
selection, disclosures and scrolling. Settings text is non-selectable throughout
(version readouts, paths, release notes and status messages included); form
controls keep their normal editing and keyboard behavior.

The panel's web view sets WebKit's inactive scheduling policy
(`WKPreferences.inactiveSchedulingPolicy = .suspend`), which WebKit applies when
it considers the view inactive. Minimized or app-hidden windows keep their page;
a snapshot skipped while hidden is delivered when revealed. Closing the window
(close button or Command-W) releases its hosting controller and web view instead
of retaining a hidden page. Reopening, including from the Dock, rebuilds the page
on the last native navigation section from the existing library, playback and
download stores. Installed's search text, sort key and direction, Show only and
exclude boxes, and the library grid's scroll offset come back too (see
[Reopening the panel](#reopening-the-panel)); disclosures and uncommitted input
start fresh. Imports and Workshop downloads run in app-owned stores, so releasing
the page never cancels them.

The panel opens on the Space you are on rather than switching you to the Space it was
last left on, and so do What's New, the wallpaper preview and the Steam and pixiv sign-in
windows. A minimized panel comes back from the Dock when it is opened from the status
menu, the Dock icon or Command-comma, or when the app is activated; the green button still
offers full screen. The wallpaper itself keeps playing on every Space as before.

### Reopening the panel

The page reports Installed's filters and the grid's scroll offset to native (the
`viewState` action) as they change: a click on a box or the sort menu at once, typing
and scrolling at most every 400 ms, and when the page is hidden. Native validates the
report (`PanelViewState`: a known sort key, search text up to 200 characters, at most
32 tags of 128 characters each for the required and the excluded list, scroll offsets
of 0 to 1,000,000 for the Installed, Discover and pixiv grids, 8 KB encoded) and keeps
the last valid one in memory on `ControlPanelNavigation`, which outlives the window.
An invalid report is dropped and the previous one stays. The action is acknowledged
without a snapshot, so scrolling never rebuilds or pushes one.

A new page receives the stored report once, inside the reply to its first `ready`
(`restoreViewState`), and applies it to the first full snapshot. The same happens when
WebKit restarts a crashed page. The page then:

- puts back the search text, sort key, direction and both tag lists;
- drops a required tag that no wallpaper in the library carries any more, so a library
  that changed in between shows its wallpapers instead of an empty grid. It keeps the
  tag while the library is still loading, and keeps excluded tags, which only hide;
- scrolls the grid to the stored offset for the page on show, limited to what the grid
  holds. Another page's offset waits unused.

Nothing is written to disk, so a fresh launch starts clean. Property drafts, the
selection, disclosures and the Installed collection filter are not restored. A later
`ready` from the page's Reconnect button never replaces what the person did since.

## Thumbnail corner marks

Installed and Discover show status marks at the thumbnail's upper-left corner:

- A pink heart identifies a local favorite, including the same item when it
  appears in Discover. Use the heart button on an Installed tile (visible on hover
  or keyboard focus), or the inspector's favorite action, to toggle it. This is
  the app's saved favorite list, not Steam-account favorites.
- A green trophy identifies **Approved** wallpapers. Discover uses Steam's
  `Approved` tag. Installed reads `approved: true` or an `Approved` tag from the
  local `project.json`, off the snapshot thread; wallpapers without that local
  metadata have no trophy, and the app does not fetch missing approval metadata
  for imported wallpapers.
- A download arrow on Installed marks a Workshop wallpaper whose author has
  published an update ([Updates](workshop-downloads.md#updates)).
- Discover also retains a check for items already in the library.

Multiple marks stack vertically. On Installed they move aside when the
multi-select check appears, and the Active badge sits alongside rather than
covering them. Tile accessibility labels announce the marks.

## Selection versus apply

Selecting a tile only selects it: the inspector updates and nothing changes on
screen. Activation is explicit.

- **Apply wallpaper** activates the selected wallpaper on the current target
  display; for the wallpaper already active there it reads **Reapply wallpaper**.
  An Installed tile shows an **Applying** ring while its apply runs and a quiet
  mark while it waits behind another apply.
- **Apply to all displays** (an installed wallpaper's inspector, shown only when two
  or more enabled independent displays exist) puts the wallpaper on every one of
  them in a single step, whichever display is targeted, and is unavailable once they
  all show it. It is all-or-nothing: if one display fails, the others are put back
  as they were and the inspector says so. It refuses, before changing anything, a
  wallpaper with unapplied property edits (the single-display Apply commits them
  first; use the inspector's **Apply changes** or **Revert** before this one). Mirrors
  follow their source and disabled displays are left alone. See
  [Apply to every display](display-layouts.md#apply-to-every-display).
- **Reapply wallpaper** restarts the wallpaper on the target display: it takes the
  wallpaper off the display and loads it afresh, for one that froze, went blank or
  shows stale content. It is the only Library or inspector control that restarts a
  running wallpaper: double-clicking its tile, choosing it in **Recently used** or
  going back to it with **Previous wallpaper** leave it running. Settings has the
  other restart, **Retry** on the row of a scene that stopped drawing
  ([scene rendering](scene-rendering.md#retry)), and the banner's **Try again**
  opens a wallpaper held back after a crash
  ([crash recovery](crash-recovery.md#what-the-user-sees)). Reapply first checks
  that the wallpaper's files, the display and any unfinished setting edit are still in
  order, and refuses without touching the display when they are not, so a
  wallpaper whose files are gone does not leave the display empty. It waits its
  turn like any Apply and counts as your choice (an automatic rule leaves the
  display alone afterwards), but not as a new apply: the display's history and
  the [support offer](first-run.md#first-wallpaper-support-prompt) are unchanged. The log
  notes it as a `reapply:` line ([diagnostics](diagnostics.md#wallpaper-activations)).
- A wallpaper you apply is never replaced by an automatic change that arrives
  while it waits for its turn on that display: the display's playlist, an
  automatic rule or an update reloading files gives way. The playlist tries
  again one interval later, a rule's event counts as handled, and a reload
  loads the new files at the next update or launch. A newer Apply of yours
  still replaces an older one that is waiting. The log notes each time one gives
  way (`activation yielded to a waiting user choice`), and every activation and
  reload logs who asked and how it ended ([diagnostics](diagnostics.md#wallpaper-activations)).
- **Download and apply** (a Discover wallpaper's inspector) is the one place a
  download applies on its own: it applies the wallpaper to the display targeted
  at the click once it has arrived, unless you chose another wallpaper for that
  display meanwhile, and says so in the inspector when it did not. See
  [Download and apply](workshop-downloads.md#download-and-apply).
- Double-clicking a tile on the Installed tab activates it as well and does not
  close the window. On Discover, double-click downloads the tile (or applies it
  once it is in the library); see
  [Workshop downloads](workshop-downloads.md#one-decision-per-download).
- Apply is unavailable when the target display is disabled, is mirroring another
  display, or when the wallpaper kind cannot be rendered (Application or Unknown).
- Background display refreshes and automatic presentation and audio-policy updates
  wait for an in-flight Apply, and Apply waits for an update already running, so
  switching wallpapers does not invalidate itself when its own windows trigger a
  policy update. Explicit Play/Pause can still interrupt an Apply.
- A successful apply leaves the window open until the user closes it (close button
  or Command-W). **Settings → General → Hide window after applying a wallpaper**
  (off by default) hides the app after each successful apply instead, so the new
  wallpaper is visible; the choice is stored in the app's defaults.

The inspector follows Wallpaper Engine's centered hierarchy: square preview, title,
creator (Discover), facts (type, size, subscribers), utility actions and tags. For
installed wallpapers the circular play button overlapping the preview is **Apply
wallpaper** (or **Reapply wallpaper**); **Download** remains a full-width action on
Discover. The utility row holds **Show in Finder**, favorites and Trash on
Installed (plus **Reinstall from Workshop…** for a Workshop wallpaper; see
[Reinstall from Workshop](workshop-downloads.md#reinstall-from-workshop)), or
**View on Steam Workshop** on Discover. The inspector scrolls
independently; **Apply changes** and **Revert** (see
[Properties](wallpaper-properties.md#properties)) stay visible in a fixed footer
while editing.

Below the compatibility note, an installed wallpaper that can run (not
Application) shows **Not working? Report on GitHub**. It opens the repository's
new-issue form in the browser with the wallpaper's title, Workshop link or id,
type, app version and, while it is on screen, the backend drawing it (with the
renderer's fallback reason) pre-filled. When the panel saw this wallpaper fail
(its download, or the last attempt to apply it), an error notice takes the link's
place with **Report this problem on GitHub**, whose issue also carries the error;
an apply failure stays until an apply succeeds. Nothing is submitted by the app:
the user edits and sends the issue on GitHub. Neither is shown when the snapshot
carries no `https` repository URL.

### Sharing a wallpaper

A Workshop wallpaper (its id is all digits), installed or on Discover, has **Share…**
in the utility row. It opens the system share menu under the button with the
wallpaper's title, its Steam Workshop page and the website's home page (the Chinese
page for either Chinese app language). The page sends only the id and the button's
frame; `WebPanelSharing.swift` builds both links from fixed parts, so nothing the page
says becomes a URL. Local wallpapers have no share button: they have no page to
share.

## Previous and recently used

The activity bar's **Previous wallpaper** returns the target display to its last
successfully applied wallpaper. Repeated presses continue backward instead of
alternating between two wallpapers. Missing or unsupported library entries are
skipped; a failed application leaves history intact. The menu bar, global
keyboard shortcuts and [automation](automation.md) offer the same command.

**Recently used** in the activity bar lists up to 50 distinct wallpapers used on
that display, newest use first, and applies one when chosen. The menu bar shows
the latest ten. **Clear history** clears only the target display's recent list and
back history. Neither action deletes wallpaper files. Successful automatic
playlist changes are included; reapplying an unchanged assignment adds nothing.

### Menu bar, one display at a time

With one display that can show its own wallpaper the menu bar keeps a flat list:
Previous Wallpaper, Next Wallpaper, Random Wallpaper and Recently used act on that display. Above
them, after Play/Pause, **Mute Wallpapers** silences every wallpaper at once and is ticked while it
is on ([Mute all wallpapers](performance.md#playback)); it is one item for the whole Mac, shown
the same way with two or more displays, and shown while it is on even with nothing playing so it can
be turned off. With two or more
(enabled, independent and connected; a mirror or a disabled display is not
listed) the menu has one submenu per display, named as the panel names it and ordered
the main display first, then left to right as the screens sit; screens with the same
name get (2), (3). Each submenu holds that display's own Previous, Next, **Random Wallpaper**
(a random wallpaper other than the one it shows, from the whole library; left out when no
other wallpaper can play) and Recently used (the wallpaper on the display is ticked), then **Remove from Display** while it
shows a wallpaper or **Start Again** once it is empty (it applies the wallpaper that
was removed, the newest in the display's history, and is left out when the display has
none), then **Open in Control Panel**, which makes that display the panel's target.
Removing is the same choice as Eject in Settings → Displays, so a playlist leaves the
display empty ([a display you cleared](playlists.md#a-display-you-cleared)); it is a
menu-only command and has no `wallpapermachine://` link. Choosing an item acts on the
display named by its submenu, never on the panel's target display. Whichever layout, while
Workshop downloads run a line under **Control Panel** counts them and opens Discover
([the download queue](workshop-downloads.md#the-download-queue)).

`WallpaperHistoryStore` saves per-display history in the
`WallpaperMachine.wallpaperHistory` preference. It survives relaunch, is pruned
when wallpapers are deleted in the app, and remains local to this Mac (it is not
included in [backup packages](backup-restore.md)). History records successful assignment and saving; it
does not certify every frame a wallpaper subsequently displays.

## Deleting wallpapers

Deletion always moves the managed library copy to the Mac's Trash after a
confirmation sheet; imported source folders are never touched, and a wallpaper
playing on a display is ejected first. A disconnected display, or a wallpaper
folder removed outside the app, can keep its assignment: once the library has been
scanned the renderer leaves that display empty rather than failing every apply,
and reinstalling the wallpaper brings the assignment back.

- Single: the trash button in the inspector's action row (next to **Apply
  wallpaper**), or `Delete`/`Backspace` on a focused tile.
- Batch: **Select** in the Installed toolbar switches the grid into selection
  mode, where every tile shows a check box and clicking a tile toggles it;
  `Shift`-click extends across the visible range and **Select all** in the summary
  row selects every tile matching the current filters. Outside selection mode the
  check box appears on hover and `Cmd`-click toggles it. The summary row shows the
  count with **Clear** and **Move N to Trash**; `Delete` acts on the selection from
  the grid, `Escape` or **Done** leaves selection mode. One confirmation covers the
  whole batch, every wallpaper is trashed independently, the library refreshes
  once, and any wallpaper that could not be removed is reported in the error
  banner while the rest are gone.
- Drag-select: holding a tile still for 350ms checks it and sweeping on checks
  every tile from the pressed one to the one under the pointer, in grid order;
  sweeping back unchecks the overshoot, and resting near the grid's top or bottom
  edge scrolls it. Starting on a checked tile clears instead. Once a selection is
  under way, in selection mode, or when the press starts on a check box, moving
  onto another tile starts the sweep without the hold; otherwise a drag that moves
  before the hold completes does nothing. The click ending a sweep is ignored, so
  it never toggles the last tile or changes the inspector.
- Teaching it: while a selection or selection mode is active, the summary row shows
  a tip about the gesture with **Got it**, until the user sweeps across two or more
  tiles or presses **Got it**. That is stored natively (`dragSelectLearned` action
  and snapshot field, like `welcomeSeen` in the [first-run guide](first-run.md#first-run)), because the panel's web storage is not
  persistent. Afterwards selection mode keeps a one-line reminder, and the
  **Select** tooltip and each check box's tooltip mention the gesture too.

## Target display

The top bar picker chooses which display Apply acts on. Disabled and mirrored
displays are listed but not selectable, annotated `(disabled)` or `(mirrored)`.
Per-display enablement, independent/mirror mode, mirror source, scaling, scale
factor, frame rate, mute and volume live in **Settings → Displays**, beside each
independent display's **Playlist** (see [playlists](playlists.md)). When the frame-rate
ceiling in force is below the saved frame rate, the field notes `Limited to {fps} fps
by Performance settings` and can open Settings → Performance. The ceiling is the one the
engine reports (`effectiveFrameRateCap`): the Performance cap lowered by the
reduced-quality frame rate while that is in force, whether from the battery, Low Power
Mode, heat or a low battery. The inspector's per-display frame-rate field shows the same
note. Saved frame rates are never rewritten.

The inspector's per-display sections also hold **Horizontal position**, **Vertical
position** and **Center** for scene and video wallpapers: where the wallpaper sits on
that display, followed live while a slider is dragged and saved when it is released, per
wallpaper and per display (see
[display position](wallpaper-properties.md#display-position)). They are not on the
Settings → Displays page, and a mirror display is always centred.

**Copy or swap wallpapers** under an independent display transfers its current
wallpaper to another eligible screen or exchanges their assignments, and
**Apply to all displays** in the inspector puts one wallpaper on every eligible
screen at once. **Display
layouts** below the display sections saves and reapplies named arrangements.
Unavailable layouts stay visible with their missing resource, and all targets are
validated before changes. These operations preserve existing playback rules and
use the normal command queue. See [Multi-display wallpaper layouts](display-layouts.md)
for recovery, history, saved settings and the per-Space boundary.

**Automatic wallpaper selection → Follow desktop Space** adds an experimental
wallpaper/playlist picker for each regular desktop on the display. The current
desktop is marked, reordered desktops keep their UUID-based choice, and
unavailable desktops can be forgotten. Fullscreen app Spaces keep the previous
selection. See [Space-based wallpaper choices](spaces.md) for transition, pause and
lock-screen ownership limits; this mode does not create or switch Spaces.

A display the app has never configured starts enabled with the primary display's
wallpaper, so a newly connected monitor shows a wallpaper without a trip to
Settings. Turning **Enable wallpaper** off saves that choice under the display's
identity, and it stays off when the display reconnects. A display switched to
mirroring shows its source even if it kept an earlier wallpaper; applying that
wallpaper again does not make it independent.

The renderer titles displays by CoreGraphics vendor and model numbers
(`Vendor 1552 - Model 41055 (1 - Primary)`). `DisplayTitleResolver`
(`App/Services/Desktop/`) replaces that label with `NSScreen.localizedName` — the
name System Settings shows, such as **Built-in Retina Display** — keeping the
renderer's `(id - Primary)` suffix. Renderer display ids are `primary`, a live
CoreGraphics id or `identity:{json}`, so the resolver matches the live id inside
the title suffix and the identity UUID against `NSScreenNumber` /
`CGDisplayCreateUUIDFromDisplayID`. It applies to the target picker, Settings →
Displays, mirror-source menus and the inspector's per-display sections; a display
without a matching screen keeps the renderer label. The renderer's own titles and
ids are unchanged, so nothing persisted or sent over the bridge moves.

## Filtering

Both library pages share one filter sidebar on the left of the grid (the inspector
keeps the right). Its only switch is the toolbar's **Filter** button, the first
control in the toolbar: a funnel glyph, the label "Filter" and, when filters are
active, their count in a pill. Open, it reads as pressed (`aria-expanded`) beside
the sidebar; closed, the sidebar leaves the layout and the grid takes its column.
The sidebar itself has no collapse control and no rail. Each page remembers its own
choice natively (`filters` action, `filtersCollapsed` in the snapshot; the panel's
web storage is not persistent) and restores it on the next launch. Closing never
changes the search or the filters. Collapsed groups retain their state and show
their own active count: Show only counts selected tags, and exclude groups count
visible boxes that differ from that page's defaults. **Clear** restores those
defaults; hidden or unknown tags are not claimed to be represented by the sum of
visible group counts.

- **Installed:** the sidebar carries Discover's boxes and rules (see below),
  applied in the page to each wallpaper. **Show only** starts with Favorites,
  Active on target display and Update available, then Approved, Audio responsive
  and Customizable; **Type** (Scene, Video, Web) reads the wallpaper's kind; **Age
  rating** and **Tags** read its `project.json`, which `LibraryMetricsService`
  turns into Steam's tags (`tags` in the snapshot: the manifest's genre tags,
  `contentrating`, `Approved`, `Audio responsive` for
  `general.supportsaudioprocessing` and `Customizable` for user properties beyond
  `schemecolor`); a wallpaper without a genre counts as Unspecified. A manifest
  carries no resolution or Workshop category, so those boxes are Discover-only.
  The Show only boxes start unticked and a ticked one requires its tag; every other
  box starts ticked (a library hides nothing by default) and an unticked box hides
  every wallpaper carrying that tag, case-insensitively. Search matches titles and
  tags, and filtering never activates a wallpaper. The toolbar's sort menu offers
  Name, Type, Favorites, File size and Date added, with a direction button beside
  it; choosing a key starts in the direction people ask for it (names A→Z;
  favorites, largest and newest first), and names break ties. File size is the
  wallpaper folder's total and Date added is when the folder entered the library
  (download or import), both measured off the main thread by
  `LibraryMetricsService` and re-checked only after a library reload; wallpapers
  not yet measured sort last.
- **Discover:** the sidebar is Wallpaper Engine's own filter list — Show only
  (required tags), then Type, Age rating, Resolution and Tags as tick boxes whose
  unticked entries are excluded (see [workshop-downloads](workshop-downloads.md)).
  Sort opens on Most popular this year; the other orders are listed there too.
- **pixiv:** the sidebar starts with the pixiv account (sign in, or who is signed
  in and **Log out**), then Orientation, Minimum size, Age rating and
  AI-generated; its Mature (R-18) box waits for a sign-in. The toolbar menu lists
  rankings while the search field is empty and search orders once it is not. See
  [pixiv](pixiv.md#browsing).

An empty result offers recovery for the actual restriction: **Clear search**,
**Clear filters** (plus **Show filters** when hidden), or **Clear search and
filters**. A Workshop response with no restrictions offers Refresh instead of an
ineffective Clear. First loading, Workshop failure/Retry and an empty local library
keep their own states; a refresh can leave existing results visible.

### Local collections

Installed's sidebar also has named local **Collections**, separate from Steam's
Workshop collections and the author's tags. Create, rename or delete a group; add
selected wallpapers through **Add to collection…**, remove selected members, or
toggle membership in the inspector. A collection filter composes with search and
the existing filters. Deleting a collection leaves its wallpapers installed.
Collections can feed [playlists](playlists.md#collections-and-saved-playlists).

## Downloads and import

Discover tiles show their own download ring (progress, cancel, sign-in needed,
retry; see [Download state on the tile](workshop-downloads.md#download-state-on-the-tile)).
Several tiles download at once and the activity bar sums them. The downloads
popover opens from the activity bar, from the top-bar downloads button while
downloads exist, and from **Show in downloads** in the inspector. The import
popover opens from **Import** in the Installed toolbar; imports copy source files
into the library and leave the originals untouched, with a duplicate policy of
**Skip duplicates**, **Keep both copies** or **Replace if changed**. Closing a
popover, or the window,
never cancels work: `LibraryImportStore` runs the import for the app, not for the
page. Quitting cancels and awaits an active local import.

An import takes Wallpaper Engine project folders, a Steam library, a Wallpaper
Engine folder, a project's own files, videos (`mp4`, `m4v`, `mov`, `webm`, `mkv`,
`avi`), HTML files and pictures (`jpg`, `jpeg`, `png`, `gif`, `webp`, `heic`,
`heif`, `tif`, `tiff`, `bmp`, `avif`, at most 512 MB). A picture becomes a still
`web` wallpaper with the id `image-<file name>`, packaged the way pixiv pages are
(`StillImageWallpaper`; see [pixiv](pixiv.md#saving-a-page)): the original kept as
`image.<ext>`, a 512 px `preview.jpg`, and a `display.jpg` shown instead when the
format is not one a web view shows as it is (`jpg`, `png`, `gif`, `webp`) or the
long side exceeds 8,192 px. Its **Image fit** and **Background color** labels are
translated like pixiv's. A picture ImageIO cannot measure or scale is reported and
not imported. A Workshop preset folder is imported as one self-contained wallpaper
built on its base, found next to it (a Steam library) or already in the library; see
[Workshop presets](workshop-downloads.md#workshop-presets). Files dropped on the
Dock icon, or opened with WallpaperMachine from Finder (`CFBundleDocumentTypes` in
`Info.plist`, rank Alternate, so the app never becomes a default), are imported the
same way with **Skip duplicates**, and the window opens on Installed with the
import in the activity bar.

A chosen folder is searched for projects where Steam and Wallpaper Engine keep
them, so the right subfolder need not be found first. It may itself be a project
(it holds a `project.json`) or hold project folders; otherwise these folders
inside it are read: `steamapps/workshop/content/431960`, and the
`projects/myprojects` and `projects/defaultprojects` of a Wallpaper Engine
install. The pick can be the Steam library, `steamapps`, `steamapps/common`, the
install (`wallpaper_engine`), a copy of it from another computer (`Wallpaper
Engine`, or the folder holding that copy), its `projects` folder, or either half.
Each project keeps its folder name as its library id, except a Workshop project
copied under another name: when the folder name is not a Workshop id, the id in
the project's `project.json` (`workshopid`, else the item its `workshopurl` link
names) becomes the library id, so update checks, the Steam link and duplicate
detection work for it. Only a whole positive number counts, and digits in a
folder name are never taken for an id; anything else keeps the folder name. When
that id is already installed the duplicate policy decides, so nothing is renamed
or overwritten, and the log records each recognition. Choosing a project's own
`project.json`, `scene.json` or `.pkg` file imports the folder that holds it when
that folder has a `project.json`; any other file is handled as before. Links are
never followed: not a chosen file, not its folder, not the manifest beside it,
and a searched folder that resolves outside the chosen one is ignored. A large
`defaultprojects` folder imports every project in it, each failure listed
separately in the report.

**Keep both copies** never copies what the library already holds. Before it files a
candidate under a new id, it compares it with the installed item of the same id:
the same folders and files, of the same sizes, with the same bytes (a project's
`project.json` is read first, and reading stops at the first difference). Finder's
`.DS_Store` files do not count, nor does the `.mwe-user-assets` folder the app
writes into an installed web wallpaper once you pick a file or folder for one of its
properties. A match is reported as skipped and nothing is
copied, so importing a multi-gigabyte project twice costs one read of it and no
second copy; any difference makes the second copy as before. A video or HTML file
is compared with the copy the library kept, and a picture with its kept original
(`image.<ext>`). Anything that cannot be shown identical counts as different: a
link or special file, a very large tree, a file that cannot be read or that changes
while it is read. A preset is assembled on its base, so it never matches the folder
it came from. The comparison can be cancelled with the import and leaves nothing
behind.

**Replace if changed** brings in a newer copy of a project that is already installed
without deleting anything first. It compares the same way, so identical content is
skipped and reported as before, and a project the library lacks is added. A changed
one is copied to the import's temporary directory and checked as every import is,
then swapped with the installed folder in one step (`RENAME_SWAP`): the library never
lacks the id, the old tree ends up in the temporary directory, which is removed, and
a failure or a cancel before the swap leaves the installed project exactly as it was.
The installed item must be a real folder holding a regular `project.json`; a link, a
file, or a folder without a manifest is reported (`Could not replace <id> …`) and
left alone, since it is not a wallpaper's to discard. It need not be able to play, so
a damaged install can be repaired from its source. The wallpaper's saved options,
user files and collections are keyed by its id and stay with the new files. A
replaced project counts as imported and is also listed in `Report.replacedIDs`: once
the library has been rescanned, `LibraryImportStore.reloadReplaced` reloads each one
on every display showing it (the same reload a Workshop update uses), so the display
shows the new files rather than what it had loaded. A quit waits for the import's own
file work to be cancelled and cleaned up, but not for the rescan or a reload, which
can last as long as a scene takes to load: it starts none that has not begun, and the
next launch loads what the displays show afresh. The Dock icon and Finder's Open
With never replace; they stay on **Skip duplicates**.

A local import's temporary directory holds an ownership marker and a live file
lock. Startup reclaims abandoned marked directories; an unmarked legacy directory
must have a valid task name and an entire inspected tree older than 24 hours, and
active or uncertain directories are kept.

Busy imports show indeterminate progress. If an import finishes while its popover
is closed, a result button stays in the activity bar until viewed and closed (or
another popover is opened). Counts and each failure stay available inside Import. A
popover opened from the activity bar keeps that anchor while open and retains the
displayed report across snapshots that omit it. The unread indicator lasts only for
the page session; an old report in the first snapshot is not announced as a new
result. Already-installed shared resources offer re-download as a secondary action
rather than another recommended primary.
