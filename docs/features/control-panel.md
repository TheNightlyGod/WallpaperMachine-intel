# Control panel

The app window is a native SwiftUI interface in
[`App/Views/ControlPanel/`](../../App/Views/ControlPanel), hosted in an AppKit window.
Menus, the status item, file pickers, confirmation sheets and the sign-in, preview and
What's New windows are AppKit, and renderer content is never drawn into the panel. How it
runs (controller, typed actions, observation, window hosting) is in
[architecture](../architecture.md#control-panel-swiftui).

Documented separately: the [first-run guide and support prompt](first-run.md),
[live preview, properties, presets, image placement, the compatibility check and
the black-bar check](wallpaper-properties.md), [local backup and restore](backup-restore.md), and
[app updates and What's New](updates.md).

## Language

The app ships in English, Simplified Chinese (简体中文), Traditional Chinese
(繁體中文), Japanese (日本語) and Korean (한국어), including navigation, filters, wallpaper options,
download and sign-in guidance, settings, accessibility labels, menus and dialogs.
**Settings → General → Language** offers **System (Auto)** (default, follows the
macOS language list) and every shipped language under its own name.

- Choosing a language switches the panel immediately, without relaunching, and is
  remembered. The **Import → Choose wallpapers** picker follows immediately too,
  including a language chosen in the [welcome guide](first-run.md#first-run). Native menus,
  alerts and other dialogs use the new language after fully quitting and reopening the app,
  because macOS fixes a process's localization at launch. Returning to **System
  (Auto)** hands the choice back to macOS.
- Missing keys fall back to English. Wallpaper titles, descriptions, creator
  names, custom property labels and upstream diagnostic details remain as
  supplied; the panel translates its own labels and recognized Wallpaper Engine
  UI tokens, not authored prose. The one exception is a property or choice
  label that the wallpaper's own translation table covers: it follows the
  language, also in an inspector that is already open (see
  [Properties](wallpaper-properties.md#properties)). Steam filter
  values and identifiers do not change when labels are translated.

How the language is resolved, how the layers fit together and how to add a
language: [Localization](../localization.md).

## Layout

The window has no sidebar: the app's name leads the title bar, the pages are tabs in its
middle, the page fills the window under them and, on the library pages, an inspector
column sits on the right. A Now Playing bar runs along the bottom of the window. The
title bar is one colour across the whole window, the page's, inspector included
([Window material](appearance.md#window-material)).

| Region | Contents |
| --- | --- |
| Name | Beside the traffic lights: the app's mark, **WallpaperMachine** and the version, as the web panel had them. Under 960 points only the mark stays, with the name and version as its tooltip; VoiceOver reads "WallpaperMachine" and the version |
| Tabs | In the middle of the title bar: **Library** (Installed), **Steam Workshop**, **pixiv** and **Settings**, each as wide as its name; in a window under 960 points they show their symbols alone, with the names as tooltips and VoiceOver labels, so the toolbar's tools keep their places. The page on show is tinted with the accent; VoiceOver reads them as buttons, that one as selected, in a group named **Main navigation** ([Pages and Settings](#pages-and-settings)) |
| Toolbar | The window title, not drawn in the title bar (the tabs stand for it) but used by the Window menu and Mission Control, names the place on show: **All wallpapers**, **Favorites**, the collection's name, **Steam Workshop**, **pixiv**, or the Settings section's name (**Search results** while searching Settings). The subtitle counts All wallpapers (with the number of updates), Favorites and a collection, and says nothing while the library loads. On the right: activity pills while there is something to report (an import in progress or a result not yet looked at, which opens Import; SteamCMD setup in progress; pixiv saves, which lead to the pixiv page), the target-display menu (named by the screen alone; its items, tooltip and VoiceOver value keep the renderer's full title, and two screens of one name keep it on the button too), the downloads button and **Wallpaper details**, which shows and hides the inspector; Settings shows neither the menu nor **Wallpaper details**. The downloads button appears once there is download activity, rings itself with the batch's mean progress while anything transfers, and carries the batch summary (status, percent, network speed, time left, **needs attention**) as its label and tooltip. |
| Page | Installed, Steam Workshop and pixiv open with one full-width search bar at the top (Command-F puts the keyboard in it), which stays in place when moving between them; VoiceOver names it for what it searches (**Search installed wallpapers**, **Search Steam Workshop**, **Search pixiv by tag**). Settings' search field heads its section list instead. **Installed**: a row of view chips, **All wallpapers** (its count, and an accent dot while Workshop updates exist, whose tooltip and VoiceOver value say how many) and **Favorites** (its count; it is Installed's own Favorite filter), lit for the view on show, plus the shown collection's chip, which puts the collection away ([Local collections](#local-collections)); then a header row (**Filter** with its count, the sort menu and its direction, then **Select**, **Refresh** and **Import**; in a narrow column the controls keep their places and drop their words, which stay as tooltips and VoiceOver names), the tile grid and a footer (how many a search or filter leaves, **Update N wallpapers**, the selection tools, the drag-select tip, or *Loading your library…*; with none of these it is not shown, since the subtitle counts the view). **Steam Workshop** (the Discover page): a header with its lists (**Wallpapers**, **Collections**, **Your subscriptions**; one menu in the narrowest column), Filter, sort and Refresh (it searches from the page's search bar, which an author's or a collection's list leaves out); then the grid and a footer with the result summary and the pager (Previous, an editable page number with the number of pages, Next). A Workshop page is one Steam page of 30 tiles, at most 1,000 pages. **pixiv**: see [pixiv](pixiv.md#browsing) |
| Filters sidebar | A floating panel at the page's leading edge, opened from the page's **Filter** button on Installed, Discover and pixiv ([Filtering](#filtering)) |
| Inspector | A column of the page along its trailing edge (not the system's inspector column, which gave the title bar a second shade): preview, title, facts, actions, tags, and the selected wallpaper's options and properties ([wallpaper properties](wallpaper-properties.md)). 300 points wide; dragging its leading edge resizes it from 260 to 420. It starts open in a window 960 points wide or more and closed in a narrower one, and follows the width once a resize has settled, until the person opens or closes it with **Wallpaper details**: that choice then holds whatever the width, also across a visit to Settings, which has none. Nothing is stored. The top of an installed wallpaper's inspector is washed with a blurred copy of its still (never the animation); the sections below are collapsible cards |
| Now Playing | The bar along the bottom of the window, on every page: the target display's wallpaper, which opens its details, and the playback controls ([Now Playing](#now-playing)) |

Full screen and Split View need nothing of the panel's own: the toolbar and the traffic
lights are the system's, and the layout is the same in a full-screen
Space or either Split View tile.

The visual direction combines Wallpaper Engine's image-first gallery, filtering
and right-hand property workflow with macOS window chrome and controls; it does
not reproduce Windows window decorations. Filled accent color is reserved for
primary actions, selection and status, so Filter does not compete with Apply or
Download. Symbols are SF Symbols. Light/dark mode, surface tone and custom accent
preferences continue to apply ([appearance](appearance.md)).

Wallpapers appear as square, image-first tiles with the title (12 pt semibold) and the
kind (11 pt) beneath. A tile lifts 2 points with a shadow on hover (not under Reduce
Motion) and draws a focus ring under keyboard focus; selection is an accent ring with a
surface-coloured gap so blue artwork does not hide it. Each grid fills its width with as
many columns as fit at a preferred tile size (140 points, 14-point gaps) that shrinks
with the column, and never fewer than three, so a narrower window shows smaller tiles
and more of them; the column count is a pure function of the width. The grids are lazy:
only the rows near the screen are built. While a trackpad or wheel scroll (and its glide)
is under way, tiles ignore the pointer: no lift, no hover controls, no live preview; they
come back under the pointer when the scroll stops, so content moving under a still pointer
does not cost frames. On Installed, the target display's tile wears an
accent **Active** capsule with a small equalizer that moves only while playback runs
and the window is on screen; a wallpaper that another enabled, independent display shows
wears a dark **Other display** capsule.

Discover tiles show cached still thumbnails first and then, for tiles on screen,
Steam's animated preview once it loads; the animation lifecycle, and why the
panel never reads animation pixels back, are in
[Workshop downloads](workshop-downloads.md#tile-thumbnails). An installed copy of
the same wallpaper shows its library cover on Discover.

Installed tiles are stills as well, so a library of animated GIF previews costs
nothing at rest. Each wallpaper's own preview file becomes a 512 px JPEG cover,
made once by a `WorkshopThumbnailCache` of its own (`Cache/LibraryThumbnails`,
128 MiB, four at a time, no animation kept) through `LibraryPreviewFetcher`, which
reads only an image inside the library up to 32 MiB and follows no symlink out of it,
and `PanelImagePipeline` decodes it at the size the tile draws. A cover is keyed by
the file's path, modification time and size, and the tile asks for it with a stamp of
the same two facts (`LibraryPreviewFetcher.coverStamp`), so a preview that an update
or reinstall replaced is covered again, while a rescan that replaced none (every
download, import and delete rescans) leaves each tile's image alone.
`LibraryCoverStamps` reads the stamps off the main thread after each rescan and
announces only a new or changed one; until a tile's is read the tile shows no image,
never the full-size preview. If a cover cannot be made the tile shows a downsampled
copy of the preview file, and tries the cover again when the preview changes.
Building the rows touches no file: a tile is offered an animation by its preview's
extension alone (`gif`, `webp`, `apng`).

An animated preview plays on one Installed tile at a time: the tile the pointer
has rested on for 160 ms, or the tile keyboard focus is on (a mouse click alone
does not count). Sweeping across the grid, dragging a selection and a preview
that is a single picture start nothing, and moving between one tile's own buttons
keeps it playing. Leaving the tile, hiding the window, filtering the tile away or
changing page releases the animation. The inspector's artwork is the preview file
itself, so the selected wallpaper still animates there.

The window never shrinks below a 760×560 content area (capped by the visible
screen on small displays). `ControlPanelWindow.minimumContentSize` owns that
floor and `AppDelegate.windowWillResize` enforces it, because the SwiftUI hosting
controller resets `contentMinSize` once it attaches.

Arrow keys, `Home` and `End` move focus across a grid, and `Return` or `Space` on a
focused tile acts as a click. `Escape` cancels a collection's name field, then closes an
open popover, then leaves selection mode. `Command-F` puts the keyboard in the page's
search field (on Settings, the one above its sections). Errors show in a banner at the top of the page
with their original details, which can be selected and copied, and **Dismiss**; VoiceOver
announces them.

A wallpaper that was left out of the session because the app quit unexpectedly twice
while loading it gets its own banner row under the error line, one row per wallpaper:
a sentence naming it, which VoiceOver reads out when the row appears, and **Try again**. It is a warning, not an error, so it has no
Dismiss; it goes away when the wallpaper is retried or applied, and a retry the engine
refuses shows the reason in the error line and keeps the row. The menu-bar menu repeats
the state as a disabled line. See [crash recovery](crash-recovery.md).

## Pages and Settings

The tabs open the pages:

- **Library** shows the local library on the Installed page. Its chips choose
  **All wallpapers** or **Favorites**, and the Filters sidebar's **Collections** group a
  local collection. Favorites is Installed's own Favorite filter and a collection is its
  collection filter, so Favorites can also be set from the [Filters sidebar](#filtering)'s
  Show only box, and the chips follow. The view chosen survives a visit to another tab.
- **Steam Workshop** opens the Discover page, which browses the Steam Workshop. See
  [Workshop downloads](workshop-downloads.md).
- **pixiv** browses pixiv's illustration rankings and tag search in the same grid,
  Filters sidebar and inspector, and saves a page of a work as a still wallpaper.
  See [pixiv](pixiv.md).
- **Settings** replaces the page with a sectioned settings view, described
  below.

Settings lists its sections down the page's leading edge, a 220-point column headed by
its search field (**Search settings**), each with a System Settings-style tile: a white SF Symbol on a coloured rounded
square. Settings opens on **Quick Settings** in every window; a section the app asks
for (**Check for Updates…**, an update notice) is shown once, even when the window
opens afterwards. The sections, in order, are Quick Settings, General, Appearance,
Desktop & Lock Screen, Playback & Power, Performance, Displays, Keyboard shortcuts,
Library & Steam, Storage and About. Each section opens with a header: its tile at
44 points, its name and a one-line purpose. Groups are titled cards of rows, as
System Settings draws them: the title and its explanation on the left, the control
at the trailing edge. A long explanation keeps its first sentence under the title;
the rest opens in a popover from the ⓘ beside the title.

- **Search** filters rows across every section by their own words in the language
  on show (titles, explanations, keywords, choices and button labels). The page then
  lists every section with a match, one under another, with only the matching rows;
  the section list counts the matches per section and dims the rest; disclosures holding a
  match open for the search and fold again when it clears. `Escape` clears the field,
  and **No settings match “…”.** shows when nothing matches.
- **Quick Settings** collects Control Center-style tiles that switch the same
  preferences as their full rows and stay in sync with them: **Open at Login**,
  **Mute All**, **Lock Screen** and **Screen Saver** (both experimental),
  **Desktop Picture**, **Active Display Only** (shown with two or more enabled
  displays, or while on), **Hide After Applying** and **Live Edits**. A tile that
  cannot be switched is disabled with its reason (Desktop Picture leaves the reason to
  its row). Below the tiles are modules with
  segmented controls: the **Quality** preset (Low, Medium, High; Custom shows when
  the values match none), **On battery** (on a Mac with a battery, or when it is
  not Keep running), **When windows cover the desktop** and **Appearance**
  (System, Light, Dark). Each module has a chevron to its full section. While a
  condition lowers quality, Quality names it under its segments in place of its hint,
  and On battery does too while the Mac runs on battery, so a choice another rule
  overrides never reads as the one in force ([performance](performance.md)). On
  battery also names a low-battery, Low Power Mode or heat rule that pauses or stops
  wallpapers, and that rule's Playback & Power row says **In effect now**; Focus
  filters and app rules keep to their own rows
  ([performance](performance.md#low-battery-low-power-mode-heat-and-focus)).
- **General** starts with the [Language](#language) picker (Interface), then Startup
  (**Launch at login** and **Hide window after applying a wallpaper**), Help (the
  [welcome guide](first-run.md), **Show again**) and Reset (**Reset all settings**,
  **Reset…**). Reset asks first; once confirmed, every setting the Settings pages
  offer returns to a fresh install's default: language, appearance, shortcuts, launch
  at login, desktop and lock-screen switches, playback, power and app rules, the
  engine's performance and scene choices, logging, web inspection, Steam update checks
  and download count, and performance data. Content is kept: the library, favorites,
  playlists, collections, presets, displays and their wallpapers, the storage location
  and sign-ins, as is macOS's own "Click wallpaper to reveal desktop". A setting that
  fails to reset does not stop the others; the first failure goes to the banner.
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
- **Appearance** holds the window's look: appearance, accent color, surface tone,
  app icon and **Reset appearance** ([appearance](appearance.md)).
- **Desktop & Lock Screen** holds the Desktop group (the switch for using the
  wallpaper as the macOS desktop picture and the optional five-minute Mission Control
  picture update; see [desktop picture](desktop-picture.md#leaving-macoss-own-wallpaper-alone);
  keeping windows in place when clicking the wallpaper; and the off-by-default switch
  that lets the displays follow a wallpaper's pending property edits as they are made;
  see [edits on the desktop](wallpaper-properties.md#showing-edits-on-the-desktop)),
  then the Lock screen and Screen saver groups.
- **Playback & Power** holds the Playback group (mute all, occlusion, other-app
  audio, display sleep, playing only on the display in use, battery, low battery,
  Low Power Mode, heat, Focus, app rules) and the **What these settings change**
  disclosure. The battery, low-battery, Low Power Mode and heat choices can each
  lower quality instead of pausing, and the page names which one is lowering it. See
  [Performance settings](performance.md).
- **Performance** opens with a live energy readout for the app, then quality
  (presets, frame-rate limit, render scale, 2D scene resolution) directly beneath it. Video backend,
  scene controls and the experimental switches stay under **Advanced**. See
  [Performance settings](performance.md). The inspector of an installed wallpaper
  adds its measured energy grade, and on a Mac with a battery its share of a charge
  per hour, once it has one
  ([Per-wallpaper energy rating](performance.md#per-wallpaper-energy-rating)).
- **Displays** holds each display's settings ([Target display](#target-display)).
- **Keyboard shortcuts** holds the shortcut rows and the **Shortcuts app and
  links** disclosure (see [automation](automation.md)).
- **About** opens with the app icon, name and version (`MARKETING_VERSION` in
  `project.yml`) and the Git revision. **Check for Updates** reads the latest GitHub
  Release; download and restart-install happen only after confirmation (see
  [updates](updates.md)). The application menu item **Check for Updates…** opens
  this section. **Spread the word** has **Share WallpaperMachine…** and **Star on
  GitHub** ([one-time prompts](first-run.md#star-prompt-the-performance-data-question-and-the-subscriptions-offer)).
- **Storage** holds the wallpaper files chosen for properties, **Clear unused
  caches…** with the shader cache, logs and completed downloads,
  [Backup](backup-restore.md), and ends with **Troubleshooting**: Detailed logging, *Allow inspecting web wallpapers*
  (Safari's Web Inspector on the running pages), the diagnostics report
  export and [Send performance data](telemetry.md) with **Show in Finder** (the report
  the next upload would send) and **What is sent**. See
  [Logs and diagnostics reports](diagnostics.md) and
  [inspecting a web wallpaper](diagnostics.md#inspecting-a-web-wallpaper).

Rows wrap within their available width, and in a narrow column a control too wide
for the row goes under its label. Live backend, quality, power and installation
readouts sit apart from the saved preference controls, and unknown, preparing and
fallback results stay distinct. A control shows the value just chosen until its
change has run, then what the stores report; a refused change puts the old value back
and reports the reason in the banner. While a wallpaper command runs, the controls
that would change the renderer wait, except the one whose change is running.
Explicit lock-screen unavailability disables its switch; language and appearance stay
usable before the renderer's settings arrive. A new snapshot keeps drafts,
disclosures and the scroll position. Settings text is non-selectable throughout
(version readouts, paths, release notes and status messages included); form
controls keep their normal editing and keyboard behavior.

A minimized, app-hidden or covered window keeps its state and does no panel work:
nothing in it animates, the energy readout does not sample and other displays'
options are not fetched; showing it again picks up the current state. Closing the
window (close button or Command-W) releases its hosting controller and the panel's
controller instead of keeping a hidden panel. Reopening, including from the Dock,
builds a fresh panel on the last native navigation section from the existing library,
playback and download stores. Installed's search text, sort key and direction, Show
only and exclude boxes, and the grids' scroll offsets come back too (see
[Reopening the panel](#reopening-the-panel)); disclosures and uncommitted input start
fresh. Imports and Workshop downloads run in app-owned stores, so closing the window
never cancels them.

The panel opens on the Space you are on rather than switching you to the Space it was
last left on, and so do What's New, the wallpaper preview and the Steam and pixiv sign-in
windows. A minimized panel comes back from the Dock when it is opened from the status
menu, the Dock icon or Command-comma, or when the app is activated; the green button still
offers full screen. The app keeps its Dock icon while any of these windows is open, on screen
or minimized, and leaves the Dock when the last one closes. The wallpaper itself keeps playing
on every Space as before.

### Reopening the panel

Installed's model reports its filters and the grid's scroll offset to
`ControlPanelNavigation.viewState` as they change: a click on a box or the sort menu at
once, typing and scrolling at most every 400 ms, and when the page goes away; the
Discover page merges its own scroll offset into the same value. `PanelViewState.normalized()`
checks each report (a known sort key, search text up to 200 characters, at most 32 tags of
128 characters each for the required and the excluded list, scroll offsets of 0 to
1,000,000 for the Installed, Discover and pixiv grids, 8 KB encoded) and the navigation
keeps the last valid one in memory, where it outlives the window. An invalid report is
dropped and the previous one stays. Reporting builds nothing and reaches no store.

A new window restores the stored state once. Installed:

- puts back the search text, sort key, direction and both tag lists;
- drops a required tag that no wallpaper in the library carries any more, once the
  library has loaded, so a library that changed in between shows its wallpapers
  instead of an empty grid. It keeps excluded tags, which only hide, and a tag the
  person ticked after the restore;
- scrolls the grid to the stored offset once the grid has settled, limited to what it
  holds.

Discover restores its own offset the same way; pixiv starts at the top. Nothing is
written to disk, so a fresh launch starts clean. Property drafts, the selection,
disclosures and the library view (Favorites or a collection) are not restored.

## Thumbnail corner marks

Installed and Discover tiles wear status marks as small round badges:

- A pink heart identifies a local favorite, including the same item when it
  appears in Discover. On Installed it is the heart button in the tile's upper-right
  corner, shown while the wallpaper is a favorite and otherwise on hover, keyboard
  focus or in selection mode; it and the inspector's favorite button toggle it. This
  is the app's saved favorite list, not Steam-account favorites.
- A green trophy identifies **Approved** wallpapers. Discover uses Steam's
  `Approved` tag. Installed reads `approved: true` or an `Approved` tag from the
  local `project.json`, read off the main thread by `LibraryMetricsService`; wallpapers without that local
  metadata have no trophy, and the app does not fetch missing approval metadata
  for imported wallpapers.
- A download arrow on Installed marks a Workshop wallpaper whose author has
  published an update ([Updates](workshop-downloads.md#updates)).
- Discover also retains a check for items already in the library.

On Discover the marks stack in the upper-left corner. On Installed the trophy and the
update arrow sit in the lower-right corner, clear of the selection check in the
upper-left corner, which the Active or Other display capsule sits beside. VoiceOver
reads the marks with the tile.

## Selection versus apply

Selecting a tile only selects it: the inspector updates and nothing changes on
screen. Activation is explicit.

- **Apply wallpaper** activates the selected wallpaper on the current target
  display; for the wallpaper already active there it reads **Reapply wallpaper**.
  An Installed tile shows an **Applying** spinner while its apply runs and a quiet
  play mark while it waits behind another apply.
- **Apply to all displays** (the inspector's **More actions** menu of an installed
  wallpaper, offered only when two or more enabled independent displays exist) puts the wallpaper on every one of
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
- Double-clicking a tile on the Installed page activates it as well and does not
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

The inspector follows Wallpaper Engine's hierarchy: preview (16:10, rounded), title,
facts (kind and size; on Discover the creator and subscribers too), actions and tags.
For an installed wallpaper the filled accent button is **Apply wallpaper** (or
**Reapply wallpaper**), beside the favorite button and **More actions**, a menu with
**Preview wallpaper**, **Show in Finder**, **Apply to all displays**, adding it to or
removing it from the target display's playlist, **Reinstall from Workshop…** for a
Workshop wallpaper (see
[Reinstall from Workshop](workshop-downloads.md#reinstall-from-workshop)), **Report this
problem on GitHub** and **Move wallpaper to Trash**. On Discover the primary action is
**Download** (with **Download and apply** where it can apply), and **View on Steam
Workshop** and **More by this author** sit below. The inspector scrolls on its own;
**Apply changes** and **Revert** (see [Properties](wallpaper-properties.md#properties))
stay visible in a footer while editing. Its texts can be selected and copied.

Below the compatibility note, an installed wallpaper that can run (not
Application) shows **Not working? Report on GitHub**. It opens the repository's
new-issue form in the browser with the wallpaper's title, Workshop link or id,
type, app version and, while it is on screen, the backend drawing it (with the
renderer's fallback reason) pre-filled. When the panel saw this wallpaper fail
(its download, or the last attempt to apply it), an error notice takes the link's
place with **Report this problem on GitHub**, whose issue also carries the error;
an apply failure stays until an apply succeeds. An installed scene waiting for the
shared scene resources offers neither report: their notice, with **Get shared
resources**, is the way forward (see
[Shared scene resources](workshop-downloads.md#shared-scene-resources)). Nothing is
submitted by the app: the user edits and sends the issue on GitHub. The same report is in the inspector's
**More actions** menu.

### Sharing a wallpaper

A Workshop wallpaper (its id is all digits) has **Share…**: in the Installed
inspector's **More actions** menu, and beside **View on Steam Workshop** on Discover.
It opens the system share menu with the wallpaper's Steam Workshop page, and its title
and the website's home page (the Chinese page for either Chinese app language) as the
message. `PanelController+Sharing.swift` builds both links from fixed parts and the
Workshop id, so nothing a wallpaper or Steam says becomes a URL. Local wallpapers have
no Share: they have no page to share.

## Now Playing

The bar along the bottom of the window shows the target display's wallpaper: its
still, its title, and the display's name beside a small equalizer that moves only
while playback runs and the window is on screen. When the target display is empty it
says **Nothing on this display** and the hint to pick a wallpaper; VoiceOver reads the
global playback state (**Playback running** or **Playback paused**) as the bar's
value. The wallpaper's part of the bar lights on hover and, clicked, opens its details
above it: the still at 16:9, a *Now Playing* caption, the title (selectable), its kind,
the display's full name, the playback state and **Show in library**, which shows the
wallpaper selected on Installed. Its controls:

- **Previous wallpaper**, play/pause, **Next wallpaper** and **Recently used**
  (below). Play/pause acts on every wallpaper and is enabled whenever any display
  has an assignment, even if the target display is empty; with no assignments it is
  disabled and reports **No wallpaper playing**.
- **Next wallpaper** changes the target display the way Change now does when a
  rotating playlist runs there: it moves along at once with a fresh interval
  ([playlists](playlists.md#where-it-lives)). Otherwise it takes the library's next supported
  wallpaper, the rule of the Next wallpaper keyboard shortcut ([automation](automation.md)).
  A playlist with nothing else to change to says so.

## Previous, next and recently used

**Previous wallpaper** on the Now Playing bar returns the target display to its
last successfully applied wallpaper. Repeated presses continue backward instead of
alternating between two wallpapers. Missing or unsupported library entries are
skipped; a failed application leaves history intact. The menu bar, global
keyboard shortcuts and [automation](automation.md) offer the same commands.

**Recently used** on the bar opens a popover above it that lists up to 50 distinct
wallpapers used on that display, newest use first, and applies one when chosen. The
menu bar shows the latest ten. **Clear history** clears only the target display's
recent list and back history. Neither action deletes wallpaper files. Successful
automatic playlist changes are included; reapplying an unchanged assignment adds
nothing.

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

- Single: **Move wallpaper to Trash** in the inspector's **More actions** menu, or
  `Delete` (either key) on a focused tile.
- Batch: **Select** in Installed's header row switches the grid into selection
  mode, where every tile shows a check and clicking a tile toggles it;
  `Shift`-click extends across the shown order and **Select all** in the footer
  ticks every tile the current search and filters show. Outside selection mode the
  check appears on hover and `Command`-click (or `Control`-click) toggles it. The
  footer shows the count with **Select all**, **Clear**, **Add to playlist**,
  **Move N to Trash** and **Add to collection…**; `Delete` acts on the selection from
  the grid, and `Escape` or **Done** leaves selection mode and clears the selection.
  The selection survives a change of view, search or filter. One confirmation sheet
  covers the whole batch, every wallpaper is trashed independently, the library
  refreshes once, and any wallpaper that could not be removed is reported in the
  error banner while the rest are gone.
- Drag-select: holding a tile still for 350ms checks it and sweeping on checks
  every tile from the pressed one to the one under the pointer, in grid order;
  sweeping back unchecks the overshoot, and resting near the grid's top or bottom
  edge scrolls it. Starting on a checked tile clears instead. Once a selection is
  under way, in selection mode, or when the press starts on a check box, moving
  onto another tile starts the sweep without the hold; otherwise a drag that moves
  before the hold completes does nothing. The click ending a sweep is ignored, so
  it never toggles the last tile or changes the inspector.
- Teaching it: while a selection or selection mode is active, the footer shows a
  tip about the gesture with **Got it**, until the user sweeps across two or more
  tiles or presses **Got it**. That is stored in the app's defaults
  (`WallpaperMachine.dragSelectLearned`, like `welcomeSeen` in the
  [first-run guide](first-run.md#first-run)). Afterwards selection mode keeps a
  one-line reminder, and the **Select** tooltip mentions the gesture too.

## Target display

The toolbar's target-display menu chooses which display Apply acts on, and which display
Now Playing shows. In a wide window the button names the chosen display next to its icon; a
narrow window shows the icon alone and the help names the display. Disabled and mirrored displays are listed but not selectable, annotated
`(disabled)` or `(mirrored)`; the menu waits while a wallpaper command runs. A target that
can no longer be chosen stays stored (the menu bar and automation read it) and the menu reads
**Target display** until another is picked.
Per-display enablement, independent/mirror mode, mirror source, scaling, scale
factor, frame rate, mute and volume live in **Settings → Displays**, beside each
independent display's **Playlist** (see [playlists](playlists.md)). When the frame-rate
ceiling in force is below the saved frame rate, the field notes it and names what set
it: `Limited to N fps by Performance settings` with a button to Settings → Performance
while the Performance cap holds it, or `Limited to N fps while the battery is low` (on
battery, in Low Power Mode, while the Mac is hot) with a button to Settings → Playback &
Power while a Reduced quality choice does. The ceiling is the one the engine reports
(`effectiveFrameRateCap`): the Performance cap lowered by the reduced-quality frame rate
while that is in force. The inspector's per-display frame-rate field shows the same
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

Installed, Discover and pixiv share one **Filters sidebar**. The page's **Filter**
button opens and closes it: a funnel symbol, the label "Filter" and, when filters are
active, their count in a badge; the button is tinted with the accent while any filter
applies or the sidebar is open, and VoiceOver reads the count and whether it is open.
The sidebar is a 260-point column at the page's leading edge, a floating panel (glass
from macOS 26), with the search bar and grid narrowing beside it. It slides out from
the window's leading edge and back
(a fade under Reduce Motion). Its header holds **Filters**, the count, **Clear** and,
at its top-right corner, the sidebar button that closes it. One sidebar serves the
window: it stays open from one library page to the next, showing that page's
filters, and waits out Settings, which has none. In a window under 960 points
there is no room for it beside the inspector, so opening one of them closes the
other. It is not a popover: it holds neither the support prompt nor other popovers
back. It starts closed and nothing is stored; closing never changes the search or
the filters. Each page's groups are listed below. Tags render as chips that start
out filtering nothing: a click selects one (accent fill and a check) so only
wallpapers carrying that tag are shown, several selected must all be carried, and a
second click lets it go. Option-click, or **Hide this tag** in the chip's context
menu, hides every wallpaper carrying it instead (struck through in red); a click
lets that go too. The Tags group's **Reset** puts its chips back.
Groups fold open and shut with a short animation (none under Reduce Motion).
Collapsed groups retain their state and show their own active count:
Show only counts selected tags, and exclude groups count visible boxes that differ
from that page's defaults. **Clear** restores those defaults; hidden or unknown
tags are not claimed to be represented by the sum of visible group counts.

- **Installed:** the sidebar opens with the **Collections** group
  ([Local collections](#local-collections)), then carries Discover's boxes and rules
  (see below), applied in the page to each wallpaper. **Show only** starts with Favorites,
  Active on target display and Update available, then Approved, Audio responsive
  and Customizable; **Type** (Scene, Video, Web) reads the wallpaper's kind; **Age
  rating** and **Tags** read its `project.json`, which `LibraryMetricsService`
  turns into Steam's tags (the row's `tags`: the manifest's genre tags,
  `contentrating`, `Approved`, `Audio responsive` for
  `general.supportsaudioprocessing` and `Customizable` for user properties beyond
  `schemecolor`); a wallpaper without a genre counts as Unspecified. A manifest
  carries no resolution or Workshop category, so those boxes are Discover-only.
  The Show only boxes start unticked and a ticked one requires its tag; Type and Age
  rating are boxes that start ticked (a library hides nothing by default) and an unticked box hides
  every wallpaper carrying that tag, case-insensitively. Search matches titles and
  tags, and filtering never activates a wallpaper. The header's sort menu offers
  Name, Type, Favorites, File size and Date added, with a direction button beside
  it; choosing a key starts in the direction people ask for it (names A→Z;
  favorites, largest and newest first), and names break ties. File size is the
  wallpaper folder's total and Date added is when the folder entered the library
  (download or import), both measured off the main thread by
  `LibraryMetricsService` and re-checked only after a library reload; wallpapers
  not yet measured sort last.
- **Discover:** the sidebar is Wallpaper Engine's own filter list — Show only
  (required tags), then Type, Age rating and Resolution as tick boxes whose
  unticked entries are excluded, and the Tags chips (see [workshop-downloads](workshop-downloads.md)).
  Sort opens on Most popular this year; the other orders are listed there too.
- **pixiv:** the sidebar starts with the pixiv account (sign in, or who is signed
  in and **Log out**), then Orientation, Minimum size, Age rating and
  AI-generated; its Mature (R-18) box waits for a sign-in. The page's menu lists
  rankings while the search field is empty and search orders once it is not. See
  [pixiv](pixiv.md#browsing).

An empty result offers recovery for the actual restriction: **Clear search**,
**Clear filters** (plus **Show filters** while the sidebar is closed), or **Clear search and
filters**. A Workshop response with no restrictions offers Refresh instead of an
ineffective Clear. First loading, Workshop failure/Retry and an empty local library
keep their own states; a refresh can leave existing results visible.

### Local collections

The **Collections** group at the top of Installed's Filters sidebar lists named local
collections with their sizes, separate from Steam's Workshop collections and the
author's tags; choosing one shows it on Installed (its chip joins the view chips and
the Filter count includes it), choosing it again or pressing its chip shows every
wallpaper again, and a collection deleted while it is shown returns the page to All
wallpapers. **New collection…** under the list creates one with an inline name field
(a refused name says why under the field), and a collection's context menu
(and its VoiceOver actions) offers **Rename…**, inline, and **Delete…**, which asks
in a confirmation sheet. Add selected wallpapers through **Add to collection…** in
Installed's footer (or **New collection…** there, named from the selection), remove
selected members of the shown collection, or toggle membership in the inspector's
Collections card, whose **New collection…** creates one holding the wallpaper. A
collection filter composes with search and the existing filters. Deleting a
collection leaves its wallpapers installed. Collections can feed
[playlists](playlists.md#collections-and-saved-playlists).

## Downloads and import

Discover tiles show their own download ring (progress, cancel, sign-in needed,
retry; see [Download state on the tile](workshop-downloads.md#download-state-on-the-tile)).
Several tiles download at once and the toolbar's downloads button sums them (its
ring and label carry the batch's progress and summary). The Downloads popover opens
from that button, which appears while downloads exist, and from **Show in
downloads** in the inspector; it always hangs from the toolbar button. The Import
popover opens from **Import** in Installed's header row; imports copy source files
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
import shown as an activity pill in the toolbar.

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
is closed, a result pill stays in the toolbar until its popover has been opened and
closed; a report that arrives while the popover is open needs no pill. Counts and
each failure stay available inside Import. A popover opened from the pill keeps the
pill, its anchor, in the toolbar while it is open, and keeps showing its report when
the store forgets it. The pill's memory lasts as long as the window; a report that was
already there when the window opened is not announced as a new result.
Already-installed shared resources offer re-download as a secondary action rather
than another recommended primary.
