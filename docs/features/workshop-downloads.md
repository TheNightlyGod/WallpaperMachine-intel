# Workshop browsing and downloads

Workshop browsing and downloading are implemented independently of the Steam
client. Browsing needs no Steam login and no Steam Web API key; downloading needs
a login, because Steam enforces that the account owns Wallpaper Engine. The
bundled Aurora Drift video wallpaper (`Resources/StarterWallpaper`) can be applied
from Installed without any download. Credentials for a download are entered only
in the app's own local prompts.

## Discover

The **Steam Workshop** page (Discover) searches the Workshop and pages through results with
previous/next buttons or by typing a page number and pressing Return. A page is
exactly one Steam page of 30 tiles, and the panel never offers more than 1,000
pages (`WorkshopStore.maxPages`): the page number, the jump field and the
controller's `showWorkshopPage` all clamp to that limit. Steam's public browse page
clamps every query to 1,000 pages of 30 items, so at most 30,000 results are
reachable per query (`WorkshopBrowseState.reachableCount`). Fetched pages are cached per query, so paging back never touches the
network; a new search always starts a fresh cache. Nothing about a page depends
on the window: resizing only reflows the tiles and never re-fetches or re-cuts a
page (grid rules: [control panel](control-panel.md#layout)).

The Filters sidebar (opened from the header's **Filter** button, see [control
panel](control-panel.md#filtering)) mirrors Wallpaper Engine's own filter list, tag
for tag and default for default:

| Group | Boxes | Default |
| --- | --- | --- |
| Show only | Approved, Audio responsive, Customizable | all off |
| Type | Scene, Video, Web; Wallpaper, Preset | all on |
| Age rating | Everyone (G), Questionable (PG-13), Mature (R-18) | Everyone only |
| Resolution | Widescreen (Standard definition, 1280 x 720, 1366 x 768, 1920 x 1080, 2560 x 1440, 3840 x 2160), Ultrawide (standard, 2560 x 1080, 3440 x 1440), Dual monitor (standard, 3840 x 1080, 5120 x 1440, 7680 x 2160), Triple monitor (standard, 4096 x 768, 5760 x 1080, 7680 x 1440, 11520 x 2160), Portrait monitor / phone (standard, 720 x 1280, 1080 x 1920, 1440 x 2560, 2160 x 3840), Other resolution, Dynamic resolution | all on |
| Tags (chips) | Abstract, Animal, Anime, Cartoon, CGI, Cyberpunk, Fantasy, Game, Girls, Guys, Landscape, Medieval, Memes, MMD, Music, Nature, Pixel art, Relaxing, Retro, Sci-Fi, Sports, Technology, Television, Vehicle, Unspecified genre | none selected; Unspecified hidden |

A ticked **Show only** box is sent to Steam as `requiredtags[]`, so every ticked
one must be on an item. A selected Tags chip is sent the same way, so selecting
Anime shows only items tagged Anime; a hidden chip (Option-click or its context
menu) is sent as `excludedtags[]`. Every other box starts ticked and unticking it
sends the tag as `excludedtags[]`: Steam drops an item carrying *any* excluded
tag, so a group with everything ticked filters nothing and unticking Video hides
every Video item. Resolution sub-groups have **All** / **None** shortcuts and
Tags has **Reset**. Application and Asset items are never offered, so
those two tags are always excluded (`WorkshopStore.defaultExcludedTags` holds
the out-of-the-box list: Application, Asset, Questionable, Mature,
Unspecified). A tag is never both required and excluded: selecting a chip stops
hiding it and the other way round. The Filter button's
count is the number of boxes that differ from the defaults; **Clear** restores
them.

Results open on Most popular this year and can be sorted by Highest rated
(Steam's all-time `toprated`), Most popular today / Trending this week / Most
popular this month / Most popular this year (Steam's `trend` sort with a `days`
window of 1, 7, 30 or 365), Most subscribed, Newest (Steam's `mostrecent`, by when an
item was first published), Recently updated (Steam's `lastupdated`, by when it last
changed, so an old wallpaper with a fresh update comes first) or Relevance. Recently
updated reads the search text and every tag filter like the others and ignores the
trending window. Steam's public browse page has no "most voted" sort and silently
treats unknown `browsesort` values as trending, so none is offered. Wallpaper Engine's
"mobile compatible" box has no Steam tag behind it, so it is not offered either.

### Opening an item from a link or id

Pasting a Workshop item's page link (`steamcommunity.com/sharedfiles/filedetails/?id=…`
or `/workshop/filedetails/?id=…`, `http` or `https`), a `steam://url/CommunityFilePage/<id>`
link or a bare id of six or more digits into the search field shows that item as one
ordinary tile instead of sending the text to Steam as search words
(`WorkshopLink.itemID(in:)`). Links are parsed as URLs, never by a pattern over free
text, and ids are validated like any other (digits only, above zero); a short number
such as a year, or a sentence that merely holds an id or a link, is still a search.
Only the wallpapers list does this: collections, authors and subscriptions read the
text as words.

The lookup answers from Steam's public details endpoint, the one that already supplies
every other source's tiles, so the download ring, inspector, Installed mark and update
mark work as on any tile, and a collection opens through **Open collection**. It is a
page of one (`WorkshopService.itemPage`), and Open on Steam goes to the item's page.
The filters' age rating, tags and Type, and the sort, do not apply to an item asked
for by name; the summary line says so while it is on show
(`WorkshopBrowseState.isLookup`). Creator names cost a profile page fetch, so a looked-up tile shows the
generic name; **More by this author** still works from the creator id.

An item that cannot be shown fails like any load: the error banner with **Retry**, and
the list on show stays. The message tells the reasons apart: Steam no longer serves the
item (removed, hidden or an id that never existed), it belongs to another Steam app, or
it is an Application wallpaper, which runs Windows programs and is never offered
(`WorkshopService.lookup`). The panel looks a link up as soon as it is pasted and a bare
id (six digits or more) when Return or Search is pressed, so typing an id never looks up
its prefixes; a link typed by hand and ordinary words wait for the usual short pause.

### When Steam changes the page's markup

The wallpapers list reads Steam's browse page through the render context the page
embeds and the `workshop_browse` query inside it. When Steam renames either (or the
query's `results`), `decodeBrowse` throws `WorkshopLayoutChanged` instead of the generic
failure, and `WorkshopService.browse` falls back to a degraded list instead of an
error: it scans the page's bytes for the ids it names (item links, the
`publishedfileid` key of a row in its JSON, also in the escaped form of the older
`JSON.parse` literal, and the attribute of older tiles; `WorkshopService.itemIDs`),
keeps the first 30 in page order, and asks the public details endpoint for them. The
details endpoint already drops anything that is not a Wallpaper Engine item, so
unrelated links the page carries fall away. The page keeps Steam's own filtering and
order, because the request that fetched it carried them.

The result is marked `isDegraded`: the summary line then says "Steam changed its
Workshop page, so this list may be incomplete." instead of the result count
(`WorkshopBrowseState.isDegraded`), because the totals are only estimates. A full page of ids suggests
one more page; a short one is the last, and a page past the first counts the pages
before it as full. The fallback is logged once per run. The original failure stands,
and no empty list is shown, when the page names no id, when no id belongs to a
Wallpaper Engine item, and when the query is there but Steam answered it with a
failure (`eresult` other than 1: a sign-in or access problem is not a layout change).
`eresult` 10 is Steam's search being overloaded ("Rejected CRE query, because there
are already 501 jobs"): the page is requested twice more, after 1 s and 3 s, for
browsing and collections alike, and only then fails with "Steam’s Workshop is busy.
Try again in a moment." (`WorkshopBusy`) instead of the page-changed message.
Collections, which are read by the same decoder, are not listed this way: their pages
carry every collection's children, so the ids they name are not the page's items.

### Tile thumbnails

Steam's `preview_url` is the full-size preview, and most trending previews are
animated GIFs of roughly a megabyte each. Tiles ask the panel's image pipeline for a
Steam thumbnail instead (`PanelImageSource.steamThumbnail`, https only), which reads
it through `WorkshopThumbnailCache`; the cache downloads the preview **once, exactly
as Steam published it**, and keeps
both halves under `Cache/WorkshopThumbnails` in the app-support folder: one still
frame decoded with ImageIO and stored as a 512px JPEG (`<key>.jpg`) and, when the
preview is animated, the original bytes beside it (`<key>.anim`). A single-frame
preview gets an empty `<key>.still` marker instead. Streaming stops at 24 MiB,
including responses without a declared length. Original animations are relayed
only up to 300 frames, 4,194,304 pixels per frame and 33,554,432 total frame
pixels; larger animations keep their bounded static JPEG instead.

The original is fetched on purpose. Steam's CDN serves it from its edge, whereas
a scaled variant (`?imw=512…`) makes the CDN re-encode the whole GIF on a cold
path, and asking for the scaled variant and then the original for the animation
downloaded every animated tile twice.

Many animated previews fade in from black, so the still is not simply the first
frame: the cache measures the mean luminance of up to eight evenly spaced frames
on a 32px decode and keeps the earliest one that is at least 60% as bright as
the brightest sample. A preview that starts bright, is dark throughout, or is a
still image keeps frame 0.

At most eight previews download at once, concurrent requests for the same tile
share one download, and cache hits cost no network and survive relaunches. The
folder is trimmed to 512 MB oldest-first (stills and animations age
independently; a hit keeps its entry young). The pipeline decodes the still at the
size the tile draws and keeps decoded stills in its bounded memory cache; a tile shows
a placeholder until its image arrives and keeps it for a failed image, and a tile that
scrolls away stops waiting without cancelling a download another tile still needs.

Nothing waits for a tile to ask. `WorkshopStore.onPreviewsAvailable` hands
every Steam page's preview URLs to `WorkshopThumbnailCache.warm` the moment the
page is decoded, and with `prefetchesNextPage` (both set by
`PanelController.start()`) the store fetches the page after the one on
show in the background, so paging forward is served from the page cache and its
tiles from disk. A failed prefetch is silent; the page is loaded normally when
the user gets there.

The animation follows the stills. Discover stills load eagerly, and no animation
is requested until every still on the page has settled (loaded or failed). After
that, for each tile on screen, the panel asks the pipeline for the animation
(`WorkshopPreviewCoordinator`, `LivePreviewScheduler`), six at a time in grid order,
which is normally a local read of the `.anim` file the still pass left
behind (an animation asked for while its still is downloading waits for that
download rather than starting another). It is fetched again, two at a time on its
own lane, only when that copy was pruned; a preview the still pass found to be a
single frame is refused without a request, and a failed animation is not tried
again by scrolling. `AnimatedPreview` replaces the still once its data has arrived
and plays it as authored, black fades included, decoding one frame at a time at the
size it draws and off the main thread, so a page of animations does not slow scrolling;
a load failure keeps the still visible. Under Reduce Motion it shows
the first frame.

The panel never reads animation pixels back: frames go from ImageIO to the screen,
and the bright still is chosen once, in the cache. Scrolling a tile offscreen, hiding
the window or leaving Discover releases its animation, and returning to a visible tile
reuses the disk cache; flipping to another page drops pending animation requests. An
installed copy shows the library's still and never animates. The inspector shows
Steam's 512 px still for the selected item, with its animation played over it.

## Collections, authors and subscriptions

A segmented control leading Discover's header chooses what it lists: **Wallpapers**
(the browse page above), **Collections** or **Your subscriptions**. In the narrowest
column it becomes one menu; the arrow keys move between the segments, and Space or
Return chooses one. An author's wallpapers and a
collection's items are opened from a tile instead: no segment is current, and the
search field gives way to a back button and what is on show; back returns to the
list, page 1, they were opened from (`WorkshopStore.open`, `back` and
`sourceHistory`). Choosing a segment starts a new history. A list that fails to open
empties the grid rather than leaving the list it was to replace on show under its
segment, where Next would page that other list; its error offers **Try again** for the
list that failed.

Only Wallpapers and Collections are searched and sorted by Steam; the others come
in their own order, so the panel hides the search field and the sort menu for
them. The filters apply everywhere: Steam applies them to the two lists,
and `WorkshopService.matching` applies the same rules to the other sources'
pages, which can therefore show fewer than 30 tiles, or none while Steam's count
says more exist; such a page says the filters hide everything on it and offers
the next page. The line above the grid links **Open on Steam** to the Steam page
listing what is on show (`WorkshopStore.browseURL`).
The sources are `WorkshopSource` in `App/Services/Workshop/WorkshopSource.swift`.

### Collections

**Collections** is Steam's browse page with `section=collections`. A collection is
a list, not a download: its tile says Collection and has no download ring,
double-clicking it or **Open collection** in its details opens it, and the
panel's `requestDownload` refuses it. Opening one asks Steam's public
`ISteamRemoteStorage/GetCollectionDetails` for its items in the collection's own
order, then shows them 30 at a time through the details endpoint.

Collections rarely carry tags, and an age rating is a tag. So while Questionable
or Mature is unticked, a collection is shown only when it has a wallpaper among
its first three (`WorkshopService.collectionSample`) and neither it nor any of
those wallpapers carries an unticked tag; the three come from the browse page's
own list of each collection's children, and one details request covers the whole
page. A collection inside a collection is dropped for the same reason, as nothing
vouches for what it holds. Ticking both ratings shows every collection unsampled.

Screening often drops most of a Steam page, so while it is on, a panel page is not
one Steam page: `WorkshopStore.filledPage` fills it to 30 from as many screened
Steam pages as it takes (at most `maxSteamPagesPerPage`), on from where the
previous panel page stopped, and fetches the next Steam page alongside. Next and
Back show each kept collection once, and each Steam page is read once per search.
The page and result counts are estimates from the rate at which pages so far
consumed Steam's, and refine while paging; a page jumped to before the one ahead
of it was shown starts at an estimated Steam page, so it can repeat or skip
collections near its edges. A page whose read limit runs out before any
collection passes is empty but offers Next to read on. A search, refresh or other
list ends a fill in progress before it reads further, so a superseded query's
pages never reach the new one's cache. **Open on Steam** goes to the Steam page
the panel page starts on.

### Authors

A Discover tile's details offer **More by this author** when Steam named the
author's SteamID64. The author's public Workshop page
(`steamcommunity.com/profiles/<id>/myworkshopfiles/?appid=431960`) lists 30 ids a
page with the total and the author's name, and the details endpoint fills them
in. A profile that is private or has nothing to show is simply empty.

### Subscriptions

Steam shows an account's subscriptions only to that account, so **Your
subscriptions** needs a Steam Community sign-in. This is a different sign-in from
SteamCMD's (see [Steam sign-in](#steam-sign-in)), and the app never sees the
password: **Sign in to Steam…** opens Steam's own sign-in page in a window
(`WebSignInWindowController` with its `.steam` site, the same one pixiv uses) and
takes the `steamLoginSecure` cookie Steam sets, and with it the
`steamRefresh_steam` renewal token Steam sets on `login.steampowered.com` when the page
set one for the same account. The session (`WorkshopStore.steamWebSession`) is kept in
the login keychain as one generic password (`KeychainSteamWebSessionStore`, service
`app.wallpapermachine.steam-community`), read once at launch off the main thread, so
the sign-in survives quitting; **Sign out of Steam**, or Steam ending the session,
removes it. The cookie is sent only to `steamcommunity.com` over HTTPS (a redirect
anywhere else goes without it, `WorkshopService.redirected`), to read the subscriptions
list (the author page with `browsefilter=mysubscriptions`).

The cookie's own token lasts about a day; the renewal token lasts months. Before a
subscriptions read, a cookie whose token has run out (its JWT `exp`, read without
checking the signature, within two minutes) is traded for a new one through
`IAuthenticationService/GenerateAccessTokenForApp` on `api.steampowered.com`
(`WorkshopService.renew`): the renewal token goes there alone, in a POST body, and the
request follows no redirect. Concurrent readers wait for one renewal, and the new
cookie is saved. Steam refusing the token (an empty `response`) ends the session like
its sign-in page does. A session without a renewal token is used until Steam ends it.
The SteamCMD sign-in cannot be reused here: SteamCMD keeps its own machine-bound
client token, which the app does not read.

That page lists rows rather than an author's tiles, so
`WorkshopService.decodeProfileListing` reads an item's id from either layout: an
author tile's `data-publishedfileid`, or a subscription row's own id
(`id="Subscription<id>"`). A page whose paging line counts entries but none can be
read is reported as unreadable instead of being shown as an empty list. Without a
session, or when Steam answers with its sign-in page instead, the session is
forgotten and the grid is emptied, so the panel offers **Sign in to Steam…** and
says it is separate from SteamCMD's sign-in.

Signed in, the line above the grid says so, counts the subscriptions, and leads
with **Download the ones not in your library** as the list's main action beside
**Sign out of Steam**; a list with no subscriptions offers **Browse Workshop**.
**Download the ones not in your library** reads every page of subscriptions (at
most 1,000 pages of 30), drops what is installed, collections and Application
items, and queues the rest as ordinary downloads, which need SteamCMD's own
sign-in as any download does. Nothing is subscribed or unsubscribed on Steam. The
welcome guide's **Import my subscriptions** and its one-time offer to existing users
([first run](first-run.md#star-prompt-the-performance-data-question-and-the-subscriptions-offer))
do the same, signing in first when needed.

## One decision per download

Double-click a Discover tile, or choose **Download** in the inspector, once. With
SteamCMD installed and a saved Steam sign-in, nothing else opens: the download
starts and its tile reports it. A dialog appears only for what the download
cannot do alone — installing SteamCMD, the first Steam account name, consent for
shared scene resources, or a password / Steam Guard request that Steam actually
sends — and it closes by itself once Steam is satisfied. **Not now** closes the
dialog without removing the request; that exact request stays quiet until Steam
asks for something else, and the tile's shield or **Continue setup** in the
inspector or Downloads reopens it. The dialog keeps its heading and close action
reachable while long content scrolls; new stages and prompts move focus only when
the previous control is no longer usable, and progress updates never interrupt
typing. A rejected dialog action appears inside the dialog as well as in the
panel's error state, without losing the account or request.

The app-owned `WorkshopStore` observes setup, account and resource readiness even
when no control panel exists. Completing a prerequisite continues a retained
request without reopening the panel. After relaunch, retained requests appear
paused and require **Resume download** before starting another session.

### Download state on the tile

A Discover tile wears its download state as a ring over its thumbnail, the way
Wallpaper Engine's own library does:

| Ring | Meaning | Click |
| --- | --- | --- |
| Percentage inside a filling ring | Transferring; the ring follows the measured bytes | Cancel the download |
| Spinning arc | Signing in, requesting the item, or transferring before any bytes can be measured | Cancel |
| Dimmed download arrow | Waiting for the download ahead of it to finish | Remove from the queue |
| Pulsing shield | Steam or setup needs you | Open the dialog |
| Play mark | Paused, including work restored after relaunch | Resume download |
| Retry mark | Failed or cancelled | Try again |
| Small check in the corner | Already in your library | — |

Before any bytes move, the sweeping ring names the current SteamCMD step inside
it (Preparing, Connecting, Updating, Signing in, Requesting) from the job's
`phase`; a transfer without a percentage yet shows its speed instead, and after
the last byte the full ring reads Finishing while the files are validated and
imported. The full status sentence stays in the tooltip, the inspector and the
downloads list.

Double-clicking a tile that is already in the library applies it, as on the
Installed page.

### Transfer progress

SteamCMD prints byte counters for `app_update` (shared scene resources) but
nothing while it fetches a Workshop item, so Workshop progress is measured outside
its output and compared with the `file_size` Steam's Workshop listing gave for the
item. While Steam reports the item as downloading, the app takes two measures
twice a second and shows the smaller: the bytes that have landed under the private
staging's `steamapps/workshop` tree (allocated blocks, so a sparse file does not
count), and the bytes the SteamCMD process has received over the network since the
transfer began, read from the same per-process `nettop` session that supplies the
speed. Steam can allocate a file's full length before its chunks arrive, which the
network total cannot overstate; compressed chunks make the network total run
slightly behind, which the tree cannot overstate. `nettop`'s first row counts
everything since the process launched (the sign-in), so it only anchors the
timeline and neither the speed nor the total includes it. The ring and the
inspector show that percentage together with received/total bytes and the
measured network speed; the last percent is claimed only by Steam's own success
line, then validation and import follow. An item Steam lists without a size keeps
the spinning arc and the speed; if `nettop` is unavailable the tree alone is used.

The figure only moves forward. Each launch of SteamCMD starts its own network
meter, and the staged tree can weigh less later than it did earlier, so the bytes
and percentage shown never drop below the most the run has shown. After a relaunch
inside a run the new meter counts only what it fetches, so it is added to what was
shown when it started (still capped by the tree): the bar holds its place at the
relaunch and moves on with the first new bytes, even when Steam has little left to
fetch. Beside the
speed, the queue rows, the inspector and the toolbar's downloads button say how long is left
(for example "4 min left"). The estimate is the bytes gained over the last 20
seconds, smoothed so one burst does not swing it, and it stays hidden until four
seconds of history exist, while the pace is under 1 KB/s, at the 99% cap, and for
an item listed without a size. Seconds show under a minute and a half, minutes
under an hour and a half, then hours; the figure is capped at 99 hours. With
several downloads running the downloads button shows the slowest job's time, and only
when every running job has an estimate. The shared scene resources use SteamCMD's
own byte counters for the same estimate.

Downloads never subscribe on Steam, and a download applies nothing unless you
chose [Download and apply](#download-and-apply). Otherwise use **Show in
library**, then Apply — see [Control panel](control-panel.md#selection-versus-apply).

### Download and apply

Under **Download**, the inspector of a Discover wallpaper offers **Download and
apply**: one click that downloads the wallpaper and then applies it to the
display the panel targets when you click. It is offered only where it can work:
not for a collection, an Application, a wallpaper already in the library or
with a download or waiting request, and not while the target display is
disabled or mirroring another. The panel action takes the target from the
panel and refuses such a display with the usual "selected display is
unavailable" message before anything is queued. SteamCMD setup, the account and
consent for shared scene resources come first, exactly as for **Download**.

Applying a wallpaper you did not see arrive would be a surprise, so the choice
is narrow:

- It lives in memory only (`WorkshopStore.applyIntents`), never in
  `workshop-requests.json` or `queue.json`: after a relaunch the downloads are
  restored paused and apply nothing.
- It is bound to the display, to that display's count of **your own** choices
  (`UserCommandQueue.userRevision`, which a playlist, an automatic rule or an
  update reload does not advance) and to an hour (`applyIntentLifetime`).
  Choosing anything else for that display meanwhile, even while the apply waits
  its turn behind another command, withdraws it; a choice for another display
  does not. So do copying, swapping and applying a saved layout, for each
  display they give a wallpaper to ([display layouts](display-layouts.md#missing-resources-and-failure-recovery)),
  and clicking **Download and apply** itself (`UserCommandQueue.noteUserChoice`):
  with two on one display the later click wins whichever wallpaper arrives
  first, and the earlier one stays in the library with the note that you chose
  another wallpaper.
- It survives what a download goes through (waiting for setup, the sign-in, **Change
  account**, **Try again**) and ends on **Cancel**, on dismissing the request,
  or when a plain **Download** of the same wallpaper is asked for later.

When the files are in the library (`WorkshopStore.finishInstall`: record the
install, rescan the library, reload the displays of a replaced wallpaper) the
apply runs from its own task, so a slow activation never holds a download slot.
It is your own Apply: origin `user`, in the display's command slot, counted as
your choice like any Apply. A scene whose shared assets are still downloading
waits for that job and applies when it finishes; if the job ends without
installing them, nothing is applied.

While the choice stands the inspector reads **Will apply when the download
finishes.** When the wallpaper arrives and is not applied, the inspector says why
in a note, and the wallpaper stays in the library: you chose another wallpaper
for the display, the download took more than an hour, or the apply was refused
or failed (a display that went away, a type that cannot be played, a scene
without its shared assets), with the reason. A note stays until the wallpaper is
requested again, **Clear finished** in Downloads clears it, or the target
display shows the wallpaper. The apply is logged like any other
([diagnostics](diagnostics.md#wallpaper-activations)).

## SteamCMD setup

SteamCMD is Valve's command-line download tool. Installing it does not sign you
in. A download can guide you through installing it or locating an existing macOS
runtime; setup also remains available in **Settings → Library & Steam**. Pending
download requests continue once their prerequisites are met. In the download
dialog, installation always shows progress while busy (an unknown total is
indeterminate rather than 0%), and a failure retains its details and offers **Try
again**, unless the retained copy needs explicit approval first.

Setup downloads Valve's HTTPS `client/steam_cmd_osx` package manifest and installs
its universal runtime packages directly. It verifies each package's SHA-256,
SHA-1 filename and size before safe extraction, normalizes Valve's backslash
paths, restores execute permissions and quarantines the extracted files. The
manifest is retained as `package/steam_cmd_osx.manifest`. No Intel bootstrap or
Valve updater is run, and Rosetta is not needed. Every runtime Mach-O must carry
an arm64 slice; all setup and download launches require native execution.
Existing Intel-only copies offer **Install SteamCMD**, with confirmation before
replacing the old installation. Valve changing or removing this manifest can
block new installs; malformed or missing packages fail closed without replacing a
working copy.

Signature, dependency and Gatekeeper checks remain required. Because official
signed SteamCMD is a command-line tool, one-click **Install SteamCMD** does not
wait for an extra Allow step once Valve's signature checks pass. Copies that
Gatekeeper actually rejects stay at the same path across restarts and retries;
you can follow Apple's guidance, or explicitly confirm **Allow this SteamCMD…**.
In that case the app removes quarantine only from that verified copy and records
its content fingerprint. Global Gatekeeper stays enabled, changed files require
another approval, and the app never re-signs SteamCMD or silently grants an
exception. A retained download that is not yet usable can be revealed in Finder or
discarded from Settings.

Valve's packages contain a `Breakpad.framework` whose sealed resources no longer
match its own `CodeResources`, so validation checks the code seal dyld actually
enforces — once per architecture slice, for every Mach-O image including that
framework — instead of a bundle-wide resource verification. No signature is
changed and no system security setting is disabled; Gatekeeper assessment errors
remain hard failures, and the special exit-3 diagnostic for valid non-app code is
not one. Because macOS can still kill a quarantined CLI at launch after that
assessment, a no-login smoke run uses the same private copy path as downloads:
validate the quarantined source, clear quarantine only on a disposable copy,
revalidate it, then launch natively. The installation candidate stays quarantined
and is revalidated before publication.

Downloads and smoke runs use `-inhibitbootstrap`, so a prepared complete runtime
never self-updates mid-download. Reinstall through setup when a newer version is
needed. The implementation is `App/Services/Steam/SteamCMDPackages.swift`,
`SteamCMDRuntime.swift` and `SteamCMDSetupStore.swift`.

## The download queue

Every download also appears in a compact popover opened from the toolbar's
downloads button, which is shown while there is download activity. Each transfer uses a private SteamCMD session and an account that owns
Wallpaper Engine. Closing the popover, the sign-in dialog or the panel never stops
work.

- **Slots.** Up to three downloads run at once by default; **Settings → Library &
  Steam → Downloads at once** chooses 1–6
  (`WorkshopDownloadManager.concurrentDownloadRange`, stored under
  `WallpaperMachine.concurrentDownloads`). Raising it starts queued jobs
  immediately; lowering it lets running transfers finish and only holds back jobs
  that have not started. Each job runs in its own private SteamCMD session and
  staging directory with its own copy of the saved sign-in, and every queued job
  shows why it is waiting (a free slot, the current sign-in, or the previous
  download).
- **Sign-in handoff.** With a saved sign-in on disk every job restores it itself,
  so a batch starts together without waiting for the first job to get through
  Steam's login. Without one, the batch signs in once through the job at the front
  of the queue: the rest wait while that sign-in is in progress (and whenever a
  password or Steam Guard prompt is on screen, so prompts never pile up), and the
  worker saves the session the moment Steam accepts it — not only at the end of
  the transfer — so the waiting jobs start silently from it while the first
  transfer is still running.
- **Serial fallback.** Sessions that cannot share a sign-in run one after another:
  with **Keep me signed in** off each job prompts on its own, and if Steam ends a
  session because the same account signed in from another of the app's sessions
  ("logged in elsewhere"), the ended job goes back in line once behind the running
  one and the queue stays serial for the rest of the app's run
  (`sessionConflictDetected`). A session Steam ends while no sibling is running is
  reported as an ordinary failure with a retry. Settings says when the queue is
  running one at a time.
- **Dropped connections.** A download whose connection drops after sign-in
  retries itself up to three times before it fails (see [Prompt and retry
  handling](#prompt-and-retry-handling)); it keeps its slot while it waits.
- **Sleep and wake.** A connection usually dies with the sleep and SteamCMD says
  nothing, which used to leave the transfer idle until the five-minute inactivity
  limit. When the Mac wakes (`NSWorkspace.didWakeNotification`, observed by the
  manager and passed to every job that holds a slot) a transfer in progress is
  watched for bytes: if none arrive within about 45 seconds it is restarted
  through the same retry path as a dropped connection (see [Prompt and retry
  handling](#prompt-and-retry-handling)); one that keeps receiving is left alone.
  Jobs that are signing in, requesting, finishing or waiting are not touched.
- **Cost of parallelism.** Every job signs in separately, a fixed cost per job, so
  extra slots mainly help batches of small items; large items share the link.
  SteamCMD's `@cMaxInitialDownloadSources` is not set.
- **Diagnosis.** The app log records each start and hold reason, and for every
  session the runtime preparation, whether a saved sign-in was restored, each
  status change, the sign-in handoff and SteamCMD's exit status, so a stalled
  batch can be diagnosed from **Show download logs**.
- **Downloads button.** The toolbar's button carries, as its label and tooltip,
  the running job's status, percentage, speed and time left, or the batch's count,
  mean percentage, summed speed and slowest time left while several run, and it
  rings itself with the batch's mean progress while anything transfers. The queue
  footer states the slot rule.
- **Menu bar.** While downloads run, the menu bar menu has a line right under **Control
  Panel**: **Downloads: 2 in progress, 40%**, or **Downloads: 2 in progress** when a figure
  cannot be given. It counts the downloads that are moving or waiting for a slot or a
  sign-in (`WorkshopDownloadManager.inProgressTransfers`): a paused job, a finished,
  failed or cancelled one and the sign-in that downloads nothing are left out, and so is
  a job that is pausing, which still holds its slot until its session closes. The percent
  is the share of the bytes all of them expect that has arrived, so a large download
  weighs more than a small one (the downloads button averages each job's own percentage
  instead). It appears only when every counted job reports a size; a job that is queued,
  signing in or listed without a size leaves the figure out rather than guessing it,
  and it stops at 99% because only Steam's own success line claims the last percent.
  The line is built each time the menu opens (`StatusMenuModel.DownloadActivity`), so it
  is not live while the menu is open, and nothing runs while the menu is closed. It is
  not offered while the app starts or quits. Choosing it opens Discover, where the
  downloads button and its popover are; the menu has no per-download rows, cancel or
  pause actions.
- **Prompts.** Passwords and Steam Guard codes belong to that exact job; the
  dialog seeds the account per request, so switching requests cannot submit
  another one's sign-in. A submitted secret is cleared from the field immediately
  and is not retained by the panel. **Change account** cancels that job and hands
  the same intent back at the sign-in step.
- **Dialog stages.** The account stage is just the **Steam account name** field,
  the keep-signed-in checkbox and a note that the password and Steam Guard come
  next; a password prompt is the same without the checkbox. Steam Guard stages are
  guide cards: a glyph, a one-line title and numbered steps for whichever method
  Steam asked for — mobile approval, authenticator code or emailed code. The
  mobile-approval steps say to answer **Steam Client** when the Steam app asks
  "Where are you trying to sign in?", because SteamCMD signs in as the client.
  Steam may still require another approval.
- **Accepted sign-in.** When Steam accepts the sign-in the dialog switches to a
  "Signed in" card with the running job's status and progress (or notes that
  shared resources download first), offers **Done** and **Show downloads**, and
  closes by itself six seconds later. The transfer is already running on the tile
  and on the downloads button throughout.
- **Pause, resume, cancel.** **Pause download** releases the transfer's slot and
  retains its downloaded content. **Resume download** starts a fresh private
  SteamCMD runtime and lets Steam validate and reuse its partial content and
  manifests. Resuming a scene asks for shared-resource consent again when those
  assets are missing and no shared-resource job is running. Cancelling discards
  this job's partial data; removing a waiting request prevents it from starting.
- **Persistence.** Pending, paused and failed jobs keep their order in
  `Downloads/Workshop/queue.json` under the app support directory; prerequisite
  requests use `Downloads/workshop-requests.json`. Quitting pauses active and
  queued downloads after stopping their child processes, and relaunch restores
  them as paused, without starting a login or transfer automatically. Checkpoints
  contain only `steamapps` and `wallpaper-engine` download content; passwords,
  terminal state and private SteamCMD runtime files are never included.
  Checkpoint publication retains recoverable pending and previous directories
  until the new checkpoint is published; resume recovers an interrupted
  publication and cancel removes all three copies. The folder holding the queue
  and the checkpoints is excluded from Time Machine (see [Steam
  sign-in](#steam-sign-in)). The separately managed saved
  sign-in remains subject to **Keep me signed in**. An interrupted process can
  lose bytes still in transient staging; the persisted job can still be resumed
  and Steam will redownload any missing content.
- **Finished jobs.** Failed and cancelled jobs stay visible with a primary **Try
  again** action; when SteamCMD is not ready it stays disabled beside the setup
  explanation. Completed jobs collapse behind **Show completed** and can be
  cleared. Clearing history keeps paused jobs. The same popover also lists pixiv
  downloads and their pause, resume, retry and cancel actions.

## Shared scene resources

Scene wallpapers need shared shaders and materials from a purchased Wallpaper
Engine installation; video wallpapers do not. Scene downloads request explicit
consent before downloading missing shared resources, and one resource job is
shared by all waiting scenes. The consent stage of the download dialog ("Shared
resources needed") is a choice between two full-width buttons, each carrying its
title and the one fact that decides it: **Download from Steam** (needs a Steam
account that owns Wallpaper Engine and several gigabytes free while downloading)
and **Use an existing installation** (choose its folder, nothing downloads), with
**Not now** beneath. Steam downloads the full Windows build into temporary
storage — hence the space — and only the shared resources are kept afterwards. No
Windows program is ever run; the Settings page still says so. A resource failure
does not discard an already downloaded wallpaper; scene playback stays
unavailable until its resources are installed.

Scene support is experimental; [web wallpapers](web-wallpapers.md) run in a
built-in web view; Windows application wallpapers are labeled unsupported.

**Download from Steam…** in **Settings → Library & Steam**, or **Get shared
resources** in a scene's details, starts the installation. While the resources
are missing, a scene's details lead with that notice (above any failure, with
**Show in downloads** in place of the button while they download) and offer no
GitHub report, and **Apply**, **Reapply** or **Apply to all displays** on an
installed scene opens this setup instead of asking the renderer for a failure
(`PanelController.getsSceneResourcesInstead(of:)`); the scene is not applied by
itself once the resources arrive. **Locate an installation…** (**Use an existing
installation** in the dialog) instead points at
an existing purchased installation. Installation reuses the private SteamCMD login
and cancellation flow and requests the Windows application with `app_update
431960 validate`. Only the validated `assets` tree is retained, at
`~/Library/Application Support/WallpaperMachine/SceneAssets`; the Windows
executables are removed together with the temporary installation. Steam must
confirm that the installation completed before assets are published. An empty or
incomplete directory is rejected without replacing existing assets, and the basic
shader and material checks are not a compatibility guarantee for any given scene.
Once setup finishes, an already-downloaded wallpaper applies without restarting
the app and without downloading that wallpaper again.

Readiness and the assets folder are looked up once, not on every panel update:
at launch, after assets are located or installed, and whenever the panel comes to
the front (`WorkshopStore.refreshSceneAssetsReadiness`). Assets that Steam
installs or removes while the app runs therefore show up when the user returns to
the panel.

## Steam sign-in

The first-run guide explains that downloads require a Steam account that owns
Wallpaper Engine, with registration and store links ([first-run
guide](first-run.md#first-run)); the download dialog only asks for what the
current download still needs.

The guide can also sign in ahead of any download. `WorkshopStore.requestSignIn`
retains a `WorkshopDownloadRequest` with id `WorkshopStore.signInRequestID`
(`steam-sign-in`) that climbs the same ladder as a download — SteamCMD setup, then
the account — and never the shared-resources stage, then runs
`WorkshopDownloader.signIn`: a private SteamCMD session with `+login <account>
+licenses_for_app 431960 +quit` and no download command (`isSigningInOnly`).
Steam's password and Steam Guard prompts arrive on the job exactly as for a
download and are answered through `submitDownloadInput`; with **Keep me signed in** the
accepted session is saved the same way, so the next download starts silently. The
job takes a queue slot like any other (`WorkshopDownloadManager.signIn`, at most
one at a time), succeeds only once Steam confirms the sign-in before quitting, and
reports "Steam sign-in" as its title; the page hides it from the downloads list
once it has finished.

After authentication, `licenses_for_app` checks the account's active Wallpaper
Engine license in that same session (the command is also recommended by [Valve
support](https://github.com/ValveSoftware/steam-for-linux/issues/6218)). An active
license listing app 431960 confirms ownership; an explicit `No active license
found for appID 431960` response reports no ownership. Missing or unrecognized
output stays **unconfirmed**, never a missing purchase. The guide shows a purchase
link for a non-owner and explains that Pixiv downloads, Workshop browsing, and
viewing existing Wallpaper Engine wallpapers remain available. Both non-owners
and unconfirmed accounts can continue setup or **Check ownership again**,
including after purchasing. Ownership is scoped to the current sign-in job, not
persisted with credentials; a saved account from a previous launch can be checked
again. Steam still authorizes each actual download, so this advisory check cannot
bypass or permanently deny it.

**Keep me signed in on this Mac** is enabled by default for Workshop downloads and
for scene-asset installation. After a successful authentication the app preserves
the Steam-issued cached credentials and machine-authentication files of the last
account at `~/Library/Application Support/WallpaperMachine/SteamSession`. The next
download, including after an app restart, restores only that account's cache and
pre-fills its login name. Cache directories are restricted to `0700` and files to
`0600`. Submitted passwords and Steam Guard codes are sent only to the private
terminal and are never saved. Downloaded content, runtime programs and logs are
not retained in the sign-in cache. The sign-in cache is also marked as excluded
from Time Machine and other backups of this Mac (`ClientPaths.excludeFromBackup`,
re-applied each time the cache is replaced), so a restore or a new Mac asks for a
Steam sign-in again; the same mark covers the staging folders of downloads and
imports in progress, the partial downloads kept under `Downloads/Workshop` and
the thumbnail caches under `Cache`. Every launch applies the mark to the sign-in
and partial-download folders that already exist (`ClientPaths.prepareExcludedFolders`,
which never creates them), so an update protects what an earlier version left
behind without waiting for the next download or sign-in. The wallpaper library, retained user files
and scene assets are backed up as before. Settings → **Library & Steam** shows the
account as **Steam account · Signed in as <name>**; **Log out…** (confirmed
natively, unavailable while downloads run) or turning the option off removes the
local cache without signing other Steam devices out. Steam still controls expiry,
renewal, revocation and any additional security checks, so indefinite
authentication is not guaranteed.

Authentication state is preserved even when an already-authenticated download
fails or is cancelled, and a failed authentication does not replace a previously
saved account. SteamCMD's invalid-cache warning can fall back to a password
prompt; a terminal cached-credential rejection clears the stale cache before an
explicit retry. Every download still uses private temporary staging, and the child
process is stopped before that staging is removed.

The sign-in dialog and the welcome guide's Steam page show step-by-step Steam
Guard help for whichever method Steam asked for (mobile approval, authenticator
code or emailed code), in every shipped language; the download stays open and
continues after verification. The help never suggests disabling Steam Guard or
sharing passwords, verification codes or recovery codes. Valve's
[mobile-authenticator instructions](https://help.steampowered.com/en/faqs/view/6891-E071-C9D9-0134)
describe the supported methods, and
[email-code help](https://help.steampowered.com/en/wizard/HelpWithSteamGuardCode)
covers delivery delays.

## Prompt and retry handling

Password and Steam Guard prompts are read without waiting for a full terminal
buffer, including prompts split across reads or arriving without a trailing
newline. Login failures are processed before credential prompts, and output is
drained before process exit is handled. The five-minute inactivity timeout is a
safety limit, not a substitute for receiving a login prompt. Since SteamCMD prints
nothing while it fetches an item, arriving bytes count as activity too: the
process's network total, the content landed on disk and an asset installation's
own counts each restart the five minutes when they grow. A pass is also stopped
after 30 minutes, but only once its bytes have stopped arriving as well, so a slow
transfer that keeps moving is never cut short. A run that stalls after sign-in
says it stopped receiving the download; only a stall in the run's first sign-in, or
at a prompt that waits for you, points to Steam Guard. A retry that goes quiet while
it signs in again is the connection, since Steam had already accepted the sign-in,
and offers no authentication retry.

After authentication is rejected or times out, **Try again** (or the failed tile's
retry) starts a new private SteamCMD session for the selected wallpaper or asset
installation and for the account name still in the form. The prior process is
stopped and its private staging removed first. Supply a password or a fresh code
when Steam asks: rejected requests are never reused, approval is never bypassed,
and authentication retries are never automatic. If Steam reports rate limiting,
wait before retrying. Workshop content-access errors are a separate failure and
offer no authentication retry.

**Dropped connections.** Once Steam has accepted the sign-in, a Workshop item or
scene-resource download whose connection drops is retried by itself: three
times, after about 2, 8 and 30 seconds (each wait varies by up to 20% so parallel
jobs do not return together), with the status reading "Connection lost; retrying
(n of 3)…". A drop means Steam reporting a timeout, no connection or an
unavailable service for a Workshop item, or the five-minute silence described
above (for scene resources too). A silence is repeated only once, because each
repeat can cost the whole five minutes again; a download whose connection gives no
sign of life therefore fails after about ten minutes, and the three retries are for
drops that Steam reports. The retry is a new SteamCMD launch in the same
private staging, so Steam resumes from its partial manifests and the saved sign-in
is still there: no password or Steam Guard prompt appears. The count starts over
for a preset's base wallpaper. Pause and cancel work during the wait as at any
other time. Once the retries are spent, the download fails with **Try again** and
keeps what was downloaded; a reported drop says the connection dropped, where it
used to be reported with the purchase requirement below. Nothing the user has
to decide is retried: rejected passwords or Steam Guard, rate limits, access
denied, a session ended by a sign-in elsewhere, a rejected saved sign-in, a
generic or unrecognised failure (a removed or private item fails at once), a
sign-in-only run, a failure or silence before Steam accepted the first sign-in,
and SteamCMD exiting without confirming the download. Real SteamCMD output for a
dropped connection has been checked only against a scripted stand-in.

**After sleep.** When the Mac wakes while a transfer is running, the downloader
starts a 45-second watch (`WorkshopDownloader.noteSystemResume`). A byte counter
that grows after the wake ends the watch and changes nothing. If the grace period
passes without a single new byte, the connection is taken to have died with the
sleep and the pass is relaunched through the retry above, with the same count and
waits: a wake restart uses up one of the three retries, and when none is left the
download fails saying the connection stopped responding after the Mac woke. The
watch belongs to the process that slept, so a relaunch (for any reason) starts
without it, and a wake while the run is signing in or requesting is ignored. A
sleep longer than the five-minute limit trips the inactivity check straight
away, since it compares wall-clock dates (from the code; not observed on a real
sleep). The 45 seconds is a guess that leaves Wi-Fi time to rejoin; it has not
been measured on a real sleep.

Parenthesized SteamCMD failures distinguish explicit credential rejection, Steam
Guard, connection/service failures and rate limits, including compact result names
such as `ServiceUnavailable` and `RateLimitExceeded`. A download failure line is
judged only once it is whole, because its reason comes last and decides whether
the connection or the purchase is blamed: a read that ends at `failed` or inside
the parentheses waits for the rest, and output that ends without a newline is
judged when the process exits. Unrecognised reasons do not
establish bad credentials: the app asks to check connectivity and export [a
diagnostics report](diagnostics.md#diagnostics-report) if retries keep failing.
Logs include the failure category, never the raw terminal reason or secrets.

Generic Workshop download failures also explain the purchase requirement: buy
Wallpaper Engine on Steam or sign in with an account that already owns it, then
retry. If that account already owns it, check the wallpaper's Workshop page for
private or removed content. A generic failure does not establish which of these
caused the download to fail.

## Completion and recovery

Completed Workshop downloads are validated and moved atomically into the library
without copying their payload again. Fresh downloads do not request SteamCMD's
optional extra validation pass. These choices reduce local disk work; network
throughput still depends on Steam and your connection. Manual file imports remain
non-destructive copies.

A download interrupted by a crash leaves staging behind. The app reclaims only
staging directories it can prove nothing is writing to.

**Free space.** Before SteamCMD starts, the downloader checks that the disk holding
the library can take the download, so one that cannot fit fails at once instead of
stalling for the inactivity limit and blaming the connection. The check runs on
every start, including a resume and **Try again**, and again before every
automatic relaunch of SteamCMD (a retry after a dropped connection or a wake, or
Steam asking to be started again), so a disk that filled during the first pass
fails the retry with the same message instead of costing another pass. A
Workshop item needs the part of its listed size not already staged, plus 15% for
Steam's staging and 64 MiB of margin; whatever a paused or failed attempt kept as
partial download data is counted from disk, so a retry only needs what is still
missing. Free space is the figure macOS calls available for important usage,
which includes space it can reclaim on demand. Shared scene resources have no
listed size, so they need a fixed 3 GiB less whatever an earlier attempt already
staged for them (counted from disk like an item's partial data, down to the 64 MiB
margin): a lower bound meant to block only a clearly full disk, not yet tuned
against a measured installation. When the disk is short
the download fails with a message naming what it needs and what is available; its
partial data is kept and **Try again** checks again. Nothing blocks a download
whose size Steam does not list, a sign-in-only run, or a disk whose free space
cannot be read. A preset's base wallpaper (size unknown) is not checked, and
parallel jobs are checked one by one, not added together, so a bulk **Download the
ones not in your library** or **Update N wallpapers** can report a shortfall on
some jobs and not on others.

### Workshop presets

A Workshop preset (category **Preset**, "Required items" on its page) is not a
wallpaper by itself: its `project.json` has no `type`, only `"dependency": "<base
id>"` and, under `preset`, values for the base's properties, plus any files those
values point at. After the preset arrives,
`WallpaperImportService.presetBaseToDownload` names the base unless the same
staging or the library already holds it, and `WorkshopDownloader` fetches it in a
second SteamCMD pass of the same job, staging and sign-in (status "Downloading the
wallpaper this preset is based on…"). The importer then assembles one
self-contained wallpaper under the preset's id: the base's content (moved from
staging, or cloned from the library, which stays unchanged), the preset's files
over it, and the base's manifest with the preset's title, description, tags,
rating, preview and Workshop id, `dependency` recorded, and each preset value
written into the base property of the same name (`null` headings and undeclared
names are ignored). The renderer reads the preset's files where they land, beside
the base's `scene.pkg`: a scene mounts its folder under its package, so a property
naming `files/clip.mp4` finds the clip while packaged files still win. A base
fetched for a preset is not added to the library. If only the base's pass fails
(after the automatic retries in [Prompt and retry
handling](#prompt-and-retry-handling)), the error says the preset downloaded but
its base (Workshop item N) did not, so nothing was added, and gives Steam's own
reason; the partial download is kept and Try again picks up from it. A preset of
a preset, or one naming itself, is rejected without publishing anything. Updating a preset
reassembles it on the current base; an update of the base alone does not reach
presets already installed. Importing a preset folder works the same way with the
base found next to it or in the library.

## Updates

`WorkshopUpdateStore` finds installed Workshop wallpapers (numeric ids) whose
authors changed them since they were installed. It sends their ids to Steam's
public details endpoint (`ISteamRemoteStorage/GetPublishedFileDetails`, POST, no
key and no sign-in, up to 100 ids a request) and compares each item's
`time_updated` with when it was installed here: the moment this app finished
downloading it, or, for an item it did not download (an import, or a download
from before installs were recorded), when its `project.json` was last written. An
import copies files, so an item that was already out of date when imported is not
caught. A difference of a minute or less counts as the same version.

It checks at most once a day on its own, after the library loads and from the same
six-hourly loop as app updates, unless **Settings → Library & Steam → Workshop
updates → Check once a day** is off; **Check Now** checks at once. The result is
kept across launches, and a failed check keeps what was known and says why beneath
the row.

An installed wallpaper with an update wears a download mark on its tile, matches
**Show only → Update available** in Installed's filters, and says in its details
when its author changed it, with **Update**. Installed's summary offers **Update N
wallpapers** while any have updates. An update is an ordinary Workshop download
(same queue, sign-in and prerequisites); once it has arrived whole, the importer
swaps the new folder in and the old one out in one step (`renamex_np` with
`RENAME_SWAP`), so the library never lacks the wallpaper and a failure leaves the
old version in place; the old folder is removed with the download's staging. Only a
folder that holds a wallpaper's `project.json` (a real file, not a link) is replaced:
anything else under the item's id is left alone and the download says so. The folder
need not play, which is what lets a reinstall repair it. An update check still running
when the download finishes does not mark it outdated again. The item's saved
options belong to its id and are kept. A display showing it then loads it again:
applying alone would find nothing changed, so it is removed and applied again
through the display's command slot. A wallpaper you are applying on that display
meanwhile is never replaced by this reload: it gives way, and the new files load
at the next update or launch. Moving a wallpaper to Trash forgets its update
and install record.

### Reinstall from Workshop

An installed wallpaper whose id is a Workshop number can be downloaded again
whether or not its author changed it: the inspector's **Reinstall from
Workshop…** (the circular arrows beside Trash), and the same words under the
Compatibility check when its **Installed project** or **Entry resources** check
is unavailable, such as a missing entry file: the installed files are what a
fresh copy repairs. The lock screen, target display, native video and shared
scene resources checks never offer it, because a fresh copy of the wallpaper
leaves those as they are. It asks first (**Reinstall this wallpaper?**), then
`WorkshopStore.requestReinstall` asks Steam's details endpoint for the item, so
what is downloaded is what the Workshop serves now, and hands it to the ordinary
queue. SteamCMD setup, the account, shared scene resources, progress, checkpoints
and the swap are the update path above, so the old folder is never deleted
first: it is swapped out when the new one has arrived whole, a failed download
leaves it in place, and the item's saved options, user files and collections
(all kept by id) survive. A display showing it loads the new files. An item
Steam no longer serves (removed or hidden) says so and nothing changes, and an
Application item is refused. Nothing is offered while a download for the item is
running or waiting for setup, and asking again then does nothing: the download is
where to continue it. A damaged copy whose `project.json` no longer parses does
not appear in the library at all, so it cannot be reinstalled from the panel.
