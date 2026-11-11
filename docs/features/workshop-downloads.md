# Workshop browsing and downloads

Workshop browsing and downloading are implemented independently of the Steam
client. Browsing needs no Steam login and no Steam Web API key; downloading needs
a login, because Steam enforces that the account owns Wallpaper Engine. Signed in to
Steam Community ([subscriptions](#subscriptions)), the Workshop is browsed as that
account, so the lists match what Steam shows it. The
bundled Aurora Drift video wallpaper (`Resources/StarterWallpaper`) can be applied
from Installed without any download. Credentials for a download are entered only
in the app's own local prompts, or not at all with a [QR-code
sign-in](#signing-in-with-a-qr-code), which downloads without SteamCMD.

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

### Removing a downloaded wallpaper

An installed wallpaper's Steam Workshop inspector offers **Move to Trash**. It uses
Installed's confirmation and removal action: after confirmation, the wallpaper stops
playing, its library copy moves to the Trash, and its saved library metadata is
removed. The Workshop page stays open and offers downloading again once the library
refreshes. Removing the local copy does not unsubscribe from the item on Steam.
Collections and wallpapers that are not installed do not offer removal.

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
Installed's search, given a link or id whose item is not installed, offers **Show in
Steam Workshop**, which opens the wallpapers list with that item and puts its id in the
search field (`PanelController.lookUpWorkshopItem(id:)`), from whatever list was on show
([filtering](control-panel.md#filtering)). It is offered only for an id the field looks up
by itself, six digits or more (`WorkshopLink.isBareItemID(_:)`).

### Searching in another language

Steam matches search words against titles and tags that are mostly English, so a search
typed in another of the app's languages finds little. With **Settings → General →
Translate Workshop searches into English** on (the default, stored as
`WallpaperMachine.translatesWorkshopSearches`, kept by a [backup](backup-restore.md) and
cleared by Reset all settings), such a search is translated on this Mac with the system's
Translation framework and Steam is searched with the English words
(`WorkshopSearchTranslator`). The search field, and a reopened panel, keep what was typed.
While the words are being translated the page says **Searching Steam Workshop…** and the
window's subtitle drops its count, as they do while Steam answers. A
line under the lists says **Searched in English for “…”** with **Search “…” instead**,
which searches the words as typed; a sort, a filter, another list or a reopened panel
then keeps them as typed until the text changes (the Workshop store keeps that choice, not
the panel window). Open on Steam opens the English search. Turning the switch off applies
from the next search: the one on show keeps its line, whose **Search “…” instead** still
works, and a list the Workshop opens or reads again by itself (another list, Back, a Steam
sign-in) is searched as typed.

The language is read on the device (`WorkshopSearchLanguage`): kana makes a search
Japanese and Hangul Korean; Han characters alone are Japanese only when Apple's language
recognizer is at least 90% sure, else Chinese, Traditional when ICU's
Traditional-to-Simplified transform changes them. Mixed text such as "anime 女孩" is read
by its CJK characters. Portuguese is read only while the app itself is in Portuguese,
from three letters on and at 90% or more, because short Portuguese and English queries
(names, a word cut short while typing) look alike. English, links, item ids, text over
256 characters and anything while the switch is off are sent as typed, and so is a
search whose translation fails or changes nothing (a name such as "Totoro"). The last 100
answers are kept in memory for the panel window, so a sort or another page translates
nothing again.

A search is translated only from a language already downloaded for translation
(`LanguageAvailability` reports it installed); one that is not downloaded is never asked
for, because that would put the system's download prompt in the middle of a search. The
Settings row says which languages are ready and offers the others in a **Download…** menu,
by their own names; choosing one shows the system's prompt, and nothing downloads
without it. The row reads the languages only while the switch is on: when it appears, when
the switch or Reset all settings turns it on, and again when the Language menu changes
the app's language (Portuguese is listed only while the app is in Portuguese). Downloaded languages are the system's and serve every app. Before macOS 26 a
translation session exists only inside SwiftUI's `.translationTask`, so the panel's
`TranslationTaskHost` lends one to `TranslationSessionHost`, which serves every queued job
for the session's languages before asking for another, and a search no session answers
within five seconds is sent as typed; from macOS 26 a search between
downloaded languages uses `TranslationSession(installedSource:target:)` directly, and only a
download still needs the panel's session.

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
reuses the disk cache; flipping to another page drops pending animation requests and
releases the animations of tiles that left. An installed copy shows the library's
still and never animates. The inspector shows Steam's 512 px still for the selected
item, with its animation played over it while the window is on screen; hiding the
window releases the animation's bytes and showing it again reloads them from the disk
cache.

## Collections, authors and subscriptions

A segmented control leading Discover's header chooses what it lists: **Wallpapers**
(the browse page above), **Collections**, **Your subscriptions** or **Your favorites**. In the narrowest
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
them; Your favorites has an order menu of its own ([favorites](#favorites)). The filters apply everywhere: Steam applies them to the two lists,
and `WorkshopService.matching` applies the same rules to the other sources'
pages, which can therefore show fewer than 30 tiles, or none while Steam's count
says more exist; such a page says the filters hide everything on it and offers
the next page, even when filters differ from their defaults. A personal list whose
unfiltered total is zero offers **Browse Workshop** instead of blaming the sidebar:
the Filter badge counts changes from defaults, including allowing more age ratings.
The line above the grid links **Open on Steam** to the Steam page
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
in. A profile that is private or has nothing to show is simply empty. An installed
Workshop wallpaper's **More actions** menu offers **More by this author** too: the
library keeps no author, so unless Discover still holds the item, its details are read
from the public details endpoint first, and Discover then opens on the author's list
with Back returning to the list it showed.

### Subscriptions

Steam shows an account's subscriptions only to that account, so **Your
subscriptions** needs a Steam Community sign-in. This is a different sign-in from
SteamCMD's (see [Steam sign-in](#steam-sign-in)), and the app never sees the
password: **Sign in to Steam…** opens Steam's own sign-in page in a window
(`WebSignInWindowController` with its `.steam` site, the same one pixiv uses; a page
that does not load is replaced by its reason and **Retry**, see
[pixiv](pixiv.md#signing-in-and-r-18-works)) and
takes the `steamLoginSecure` cookie Steam sets, and with it the
`steamRefresh_steam` renewal token Steam sets on `login.steampowered.com` when the page
set one for the same account. The session (`WorkshopStore.steamWebSession`) is kept in
the login keychain as one generic password (`KeychainSteamWebSessionStore`, service
`app.wallpapermachine.steam-community`), read once at launch off the main thread, so
the sign-in survives quitting; **Sign out of Steam**, or Steam ending the session,
removes it. The cookie is sent only to `steamcommunity.com` over HTTPS (a redirect
anywhere else goes without it, `WorkshopService.redirected`), to read the subscriptions
list (the author page with `browsefilter=mysubscriptions`), and with every other
Steam Community page the Workshop reads: search, collections and authors' pages.
Steam lists those differently for an account than for an anonymous visitor: age-rated
items the account's content preferences allow, and what its store region allows, are
left out for anyone, so signed out a Questionable or Mature search can come back with
far fewer pages than on Steam. Signing in or out reads the list on show again from
its first page (`WorkshopStore.signInToSteamWeb`, `signOutOfSteamWeb`); the details endpoint on
`api.steampowered.com` is still read without a session.

The cookie's own token lasts about a day; the renewal token lasts months. Before a
read with the session, a cookie whose token has run out (its JWT `exp`, read without
checking the signature, within two minutes) is traded for a new one through
`IAuthenticationService/GenerateAccessTokenForApp` on `api.steampowered.com`
(`WorkshopService.renew`): the renewal token goes there alone, in a POST body, and the
request follows no redirect. Concurrent readers wait for one renewal, and the new
cookie is saved. Steam refusing the token (an empty `response`) ends the session like
its sign-in page does; a public list being read then is read anonymously instead of
failing. A session without a renewal token is used until Steam ends it.
The SteamCMD sign-in cannot be reused here: SteamCMD keeps its own machine-bound
client token, which the app does not read.

That page lists rows rather than an author's tiles, so
`WorkshopService.decodeProfileListing` reads an item's id from either layout: an
author tile's `data-publishedfileid`, or a subscription row's own id
(`id="Subscription<id>"`). A page whose paging line counts entries but none can be
read is reported as unreadable instead of being shown as an empty list. So is an
empty, truncated or unrecognized response: zero entries need an explicit zero count,
a page beyond the end, or Steam's empty-list message. A failed refresh keeps the
last loaded tiles, count and subscription marks and offers retry. Without a
session, or when Steam answers with its sign-in page or an explicitly anonymous
personal-list page instead, the session is
forgotten and the grid is emptied, so the panel offers **Sign in to Steam…** and
says it is separate from SteamCMD's sign-in.

Signed in, the line above the grid says so, counts the subscriptions, and leads
with **Download the ones not in your library** as the list's main action beside
**Sign out of Steam**; a list with no subscriptions offers **Browse Workshop**.
**Download the ones not in your library** reads every page of subscriptions (at
most 1,000 pages of 30), drops what is installed, collections and Application
items, and queues the rest as ordinary downloads, which need SteamCMD's own
sign-in as any download does. The
welcome guide's **Import my subscriptions** and its one-time offer to existing users
([first run](first-run.md#star-prompt-the-performance-data-question-and-the-subscriptions-offer))
do the same, signing in first when needed.

Signed in, the Workshop changes the account's subscriptions on Steam too. The inspector
of an item that is not a collection offers **Subscribe on Steam** or **Unsubscribe on
Steam**, and so does the **More actions** menu of an installed Workshop wallpaper, so a
wallpaper tried out first can be subscribed afterwards; that menu item stays disabled
until Steam has answered a subscriptions read for the account
(`WorkshopStore.subscriptionsKnown`), since before then a missing mark may be a
subscription after all (`WorkshopService.setSubscribed`): a POST to
`steamcommunity.com/sharedfiles/subscribe` or `/unsubscribe` with the item, Wallpaper
Engine's app id and a `sessionid` CSRF token that the same request also sends as a cookie
beside `steamLoginSecure`, since Steam only checks that the two match; a fresh random one
serves. The request follows no redirect with the cookie. Steam's `{"success":1}` is the
only answer taken as done; another `success`, an answer that cannot be read or a
connection failure reaches the banner, and Steam's sign-in page or a 401 or 403 ends the
session. The tiles of what the account subscribes to wear a bookmark mark (VoiceOver:
**Subscribed on Steam**), from `WorkshopStore.subscribedIDs`: every page of the
subscriptions is read the first time the Workshop page or an installed Workshop
wallpaper's inspector appears for each sign-in (after a saved one still being restored) and again right after a sign-in, and a subscribe or
unsubscribe Steam accepted updates it, also over a read still in flight; signed out it is
empty. A read that fails leaves the marks as they were, says why in the banner and is tried
again the next time the Workshop page appears. Downloading stays a separate choice: subscribing does not
download, and SteamCMD is not involved. This has not been tried against live Steam from
the development machine, which cannot reach steamcommunity.com; the requests and answers
are pinned against fixtures (`WorkshopSourceTests`).

### Favorites

**Your favorites** lists the wallpapers the signed-in account marked as favorites on the
Workshop, read with the same Steam Community session as the subscriptions, so it needs the
same sign-in and offers the same **Sign in to Steam…** without it. Its page is the account's
own Workshop page with `browsefilter=myfavorites`, which lays its items out as an author's
tiles. Steam sorts it: the bar above the grid says who is signed in and how many favorites
there are, and its order menu offers Steam's four orders, **Date favorited** (Steam's default),
**Alphabetical**, **Date updated** and **Date created** (`WorkshopFavoritesOrder`, Steam's
`sortmethod` values `subscriptiondate`, `alpha`, `lastupdated` and `creationorder`, read off
Steam's own favorites page). Choosing one lists the favorites again from page 1; the order is
kept for the rest of the app's run. Nothing is favorited or unfavorited on Steam from here, and
the list offers no bulk download. A signed-in subscriptions page was not available to check its
sort menu, so Your subscriptions keeps its own order.

### Comments

The inspector of an item that is not a collection and whose author's SteamID is known
shows its newest ten comments, read-only, from Steam's public comment thread
(`steamcommunity.com/comment/PublishedFile_Public/render/<author>/<item>/`, no sign-in and
no cookie), when the inspector shows the item, with how many there are in all and
**Read all comments on Steam**, which opens the item's page. Each comment is the
author's name, how long ago it was posted and its text, read as plain text from the
thread's HTML (`WorkshopService.decodeComments`): markup dropped, `<br>` kept as a line
break, entities decoded. All of it is Steam's text, shown verbatim. Posting is not
offered. A thread that cannot be read says so in place of the comments. Like
subscribing, this was pinned against fixtures, not tried against live Steam.

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

SteamCMD prints no byte counters while it fetches a Workshop item or the shared
scene resources' depot, so progress is measured outside its output: a Workshop
item against the `file_size` Steam's Workshop listing gave for it, the depot
against the size SteamCMD's `Downloading depot 431961 (… files, … MB)` line gives.
That size is the compressed download, about a third of what lands on disk, so the
depot is measured by the bytes the process has received over the network alone,
and by the bytes in its folder only when `nettop` is unavailable. While Steam reports the item as downloading, the app takes two measures
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
indeterminate rather than 0%), **Cancel setup** stands in for **Install SteamCMD**
while setup can still be cancelled (the final step that publishes the installation
cannot be, and shows the install button disabled instead), and a failure retains its details and offers **Try
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
never self-updates mid-download; the app keeps it current instead (below). The
implementation is `App/Services/Steam/SteamCMDPackages.swift`,
`SteamCMDRuntime.swift` and `SteamCMDSetupStore.swift`.

### Keeping SteamCMD current

Steam stops accepting a SteamCMD that falls too far behind Valve's, and a copy run
with `-inhibitbootstrap` never catches up by itself. In October 2026 Valve shipped
a new SteamCMD on the 21st, and copies installed earlier stopped finishing the
sign-in: Steam Guard was approved and SteamCMD still exited (1.6.4). So the app
compares the managed copy (the one under `SteamCMD/` in app support) with Valve's
manifest:

- **Before a download or sign-in starts**, at most once a day
  (`SteamCMDSetupStore.updateCheckInterval`), and when the control panel opens. The
  request waits while the check runs, as it waits for setup ("Checking SteamCMD…"),
  and continues by itself afterwards. A manifest whose `version` differs from the
  one in `package/steam_cmd_osx.manifest` (newer, or one Valve withdrew) is
  installed with every check of **Install SteamCMD** and replaces the copy only once
  it has passed them; a candidate macOS holds for approval waits in Settings while
  downloads go on with the copy already there. The check runs only while no download
  does. The time of each check is recorded before Valve is asked, so an offline Mac
  is not asked again on every download, and a manifest that cannot be read leaves
  the installed copy in use without a message.
- **After a sign-in that ends for no reason Steam gave**: SteamCMD exited before
  Steam accepted the sign-in, with no rejected password or code and no failure
  reason (`WorkshopDownloader.endedBeforeSignInUnexplained`), which is how an
  outdated copy fails. Once no other job runs, the app looks again without waiting
  for the day (at most every ten minutes) and, when that installed a different
  SteamCMD, tries every job that failed this way again, once each; a second failure
  is shown as usual.

A SteamCMD you located yourself (Homebrew, `~/Steam`) is never replaced: update it
the way you installed it. **Reinstall…** in Settings still forces a fresh copy.

Valve's releases are also watched from CI: the
[SteamCMD canary](../../.github/workflows/steamcmd-canary.yml) installs the newest
SteamCMD every day the way the app does (`scripts/steamcmd_canary.py`, including
Valve's code signature), signs in anonymously, and opens an issue when Valve
publishes a version no issue names yet or the sign-in fails, so a release can be
tried with a real account before the app's daily check brings it to everyone.

### Proxies

The app has no proxy setting of its own: every connection follows the macOS
system proxy (System Settings → Network → Details → Proxies). Browsing, thumbnails,
pixiv and updates use `URLSession`/WebKit defaults. SteamCMD reads the same settings
itself: Valve's `steamclient.dylib` calls `SCDynamicStoreCopyProxies` and
`CFNetworkCopyProxiesForURL`, so its HTTP requests and its WebSocket connection
to Steam's servers both go through a configured HTTP/HTTPS system proxy. It
ignores `http_proxy`/`https_proxy` environment variables, and its proxy lookup has
no SOCKS case, so a SOCKS-only system proxy leaves it direct. Passing a proxy to it
from the app is therefore not possible.

A proxy client in rule mode still decides per host name. Its Steam
(`steamserver.net`, `steamcontent.com`, `steamcommunity.com`, `steampowered.com`)
rules decide whether SteamCMD's traffic is proxied; rule sets that send them `DIRECT`
give the same result as no proxy. Route those domains through the proxy, or use
global mode while downloading. A TUN ("enhanced") mode applies the same rules.
In mainland China a direct connection works for sign-in and downloads too (next
section); only Discover, subscriptions and other `steamcommunity.com` pages need
the proxy.

### Download region in mainland China

Steam picks a download region (a "cell") at every sign-in from the address it sees.
For a mainland China address it does not always pick a mainland one: measured from a
mainland connection with no proxy, one fresh SteamCMD sign-in in three came back
with Singapore (cell 35) and fetched every chunk from `cache*-sgp1.steamcontent.com`
across the border. At busy hours that ran at 0.04–0.08 Mbps with hundreds of
failed chunks and never finished, while Steam's mainland partner CDNs
(`xz.pphimalayanrt.com`, `dl.steam.clngaa.com`, `st.dl.eccdnx.com`) delivered the
same 68 MB item in about 3 s. Because a saved sign-in keeps SteamCMD's
`config.vdf`, one unlucky first sign-in held every later download on the far
servers.

So on a Mac whose time zone is in mainland China (`Asia/Shanghai`, `Asia/Urumqi` and
their aliases), every run writes a mainland cell (`CellIDServerOverride` 47,
Shanghai) into the `config.vdf` of its private SteamCMD home before launch, after
the saved sign-in is restored, replacing a far region and leaving every other value,
the cached sign-in included, as it was. A mainland cell Steam already chose is kept.
Steam narrows the hint to its own nearest mainland cell (observed: 47 became 202,
Dongguan), serves its mainland CDNs, and asks for the connection-server list with
that cell, so Hong Kong and Tokyo servers are tried first and sign-in no longer
falls back to US servers when `api.steampowered.com` stalls. From an address outside
mainland China Steam ignores a mainland cell and assigns its own (observed: a
Singapore proxy exit got 35 and Valve's Singapore caches), so a Mac set to a China
time zone abroad, or one whose proxy carries Steam's traffic, downloads exactly as
before. Elsewhere the config is not touched. The implementation is
`App/Services/Steam/SteamCMDDownloadRegion.swift`, called from
`WorkshopDownloader.run`. Downloads on the [QR sign-in](#signing-in-with-a-qr-code)
get the same hint without a config: `SteamCMConnection` lists connection servers for
the mainland cell and puts it in the logon (`cell_id`), and the content servers then
come from the cell Steam answers with, narrowed or, from abroad, replaced.

Where a site is reachable only through a proxy, a request that goes direct usually
fails before the site answers: the network resets or drops the TLS handshake, which
the system reports as "An SSL error has occurred" and its relatives. Such failures
(`ConnectionInterrupted` in `App/Services/Network/`: a failed TLS handshake, an untrusted
or rejected certificate, a refused, lost or timed-out connection, an unresolved name)
are therefore shown as the connection to the failing host having been cut off or
refused, with the advice to turn on the proxy client's system proxy or TUN mode or to
route that domain through the proxy. Workshop browsing, item details, collections,
comments, subscriptions and the Steam session renewal (every `WorkshopService`
request), pixiv, and the [sign-in windows](#subscriptions) use it. Being offline and every
other failure keep the system's own description.

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
- **Order.** Waiting jobs start in the order they were asked for. **Download next** on a
  waiting row moves that job to the front of the line, ahead of every other waiting job and
  behind those that run, so it takes the next free slot; it is offered only when another
  waiting job is ahead of it (`WorkshopDownloadManager.prioritize`). The order is saved with
  the queue (`queue.json`) and outlives a relaunch.
- **Retry failed.** Once two or more downloads stopped with a failure or were cancelled, the
  footer offers **Retry failed (N)**, which tries each again in list order, Steam's and
  pixiv's alike, exactly as its own **Try again** would: partial content is reused where it
  is still there (a cancelled download discarded its own), and Steam's are left out while
  SteamCMD is not ready. The first that cannot start stops the
  batch and says why. One stopped download has only its own **Try again**.
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
  the same intent back at the sign-in step. A job on the QR sign-in does not offer it
  (`DownloadRow.signsInWithQRCode`): its account is the QR sign-in's, changed by
  logging out in Settings.
- **Dialog stages.** The account stage is just the **Steam account name** field,
  the keep-signed-in checkbox and a note that the password and Steam Guard come
  next; a password prompt is the same without the checkbox. Steam Guard stages are
  guide cards: a glyph, a one-line title and numbered steps for whichever method
  Steam asked for — mobile approval, authenticator code or emailed code. A code
  prompt names no method by itself (SteamCMD can ask for a "Steam Guard code" for
  more than one), so the card follows what Steam printed before it: its email
  wording gives the emailed-code card, the mobile app or a "Two-factor code"
  prompt gives the authenticator card, and anything else the general card. Once a
  code is submitted the card gives way to the waiting state until Steam answers,
  so it never asks for a code below a field that is gone. The
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
  `Downloads/Workshop/queue.json` beside the library (`ClientPaths.storageURL`, the
  app support directory unless the [library was moved](library-location.md));
  prerequisite requests use `Downloads/workshop-requests.json` in app support. Quitting pauses active and
  queued downloads after stopping their child processes, and relaunch restores
  them as paused, without starting a login or transfer automatically. Checkpoints
  (Workshop items only; the shared resources keep none) contain only `steamapps`
  and `wallpaper-engine` download content; passwords,
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
and cancellation flow and fetches only Wallpaper Engine's Windows content depot
with `download_depot 431960 431961` (about 360 MB to download). It never runs
`app_update 431960`: updating the whole app also fetched whatever Steam ties to the
account, which one report showed as a 49.6 GB download. Steam confirms the depot
with `Depot download complete : "<folder>"`, a path SteamCMD for macOS prints with
backslashes after the staging folder; the assets are taken from that folder
when it lies inside the run's own staging, else from where SteamCMD puts depots
(`steamapps/content/app_431960/depot_431961` under its staging or Steam home). A
depot download starts over each time, so the shared resources keep no partial
data: a paused or failed attempt keeps nothing, and a checkpoint an earlier
version kept is deleted rather than restored. Only the validated `assets` tree is retained, at
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
`0600`. A run's SteamCMD home, where that cache is restored, stays beside it on this
Mac even when the library is on another disk; only the content SteamCMD fetches is
written beside the library ([library location](library-location.md)). Submitted passwords and Steam Guard codes are sent only to the private
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

## Signing in with a QR code

Downloads can also run without SteamCMD and without a password. **Sign in with a QR
code** (in the download dialog's SteamCMD and account stages, and in Settings →
Library & Steam while no account is signed in) shows a code that the person scans
with the Steam mobile app (Steam Guard → Scan a QR code) and approves there; the
app never sees a password or a Steam Guard code. The sign-in uses Steam's own
authentication service over HTTPS (`IAuthenticationService/BeginAuthSessionViaQR`
and `PollAuthSessionStatus`, `SteamQRSignIn`), asking for a token issued for the
Steam client (`platform_type` 1). Steam renews the code while it waits; the
section shows the newest one, says when the phone has scanned it, and offers
**Show a new code** once a code expires. Its buttons go through the panel's actions
(`PanelController.startSteamQRSignIn`, `cancelSteamQRSignIn`), and closing the
download dialog or the Settings popover stops a code that was not approved, so
nothing signs in once no code is on screen: an approval already on its way back when
the code closes is dropped, not saved. A failed code is kept as its reason (expired,
Steam unreachable, failed) and worded when the section shows it, so the message
follows the panel's language. The dialog does not offer it for the
first-run guide's SteamCMD sign-in request, which a QR sign-in would not complete.
With a SteamCMD sign-in already saved, Settings shows that account and **Log out…**
instead of the QR button, and downloads keep using SteamCMD without reaching the
dialog's account stage: switching to a QR sign-in starts with logging out.

The approved refresh token is kept in the login keychain as one generic password
(`KeychainSteamClientTokenStore`, service `app.wallpapermachine.steam-client`),
beside the Steam Community sign-in and kept the same way; it is never logged or
written anywhere else. A launch restores it off the main thread
(`WorkshopStore.restoreSteamQRSignIn`), and an expired one is removed instead; a
sign-out, a new sign-in or a QR code started while the keychain answers wins over
what it read.
Settings shows the account as signed in, and **Log out…** removes the token as
well as any saved SteamCMD sign-in. The keychain refuses to delete an item another
build saved but lets its data change, so such a token is emptied instead, which a
launch restores as no sign-in; only when the keychain refuses that too does the action
say it could not log out, with the account still signed in. A token Steam refused at
logon is removed the same way. Steam lists the Mac (named
"WallpaperMachine on <Mac name>") under the account's authorized devices, where it
can be revoked from any other device.

While the QR sign-in exists, every Workshop and shared-resources request skips the
SteamCMD and account stages (`WorkshopStore.stage(for:)`) and runs through
`NativeWorkshopDownloader` instead of SteamCMD; a SteamCMD sign-in request
(`steam-sign-in`) still uses SteamCMD. The prerequisite observer tracks the QR
sign-in, so a request waiting at those stages starts as soon as it completes, from
the dialog or from Settings; a QR sign-in also clears the mark of a request the queue
refused for the account it named (`WorkshopStore.steamQRSignInChanged`), which then
goes again, and stays refused if the queue refuses it once more. A request refused
while the QR sign-in exists shows the account stage as **Signed in as …** with
**Continue** instead of SteamCMD's account form. A partial SteamCMD download kept for the item is
discarded once the native worker has taken the item in the queue; a native job the
queue refuses leaves it for SteamCMD. The native worker sits in the same queue,
behind the same `WorkshopDownloadWorker` protocol, so tiles, rows, pausing,
cancelling and **Download next** behave as for SteamCMD. It lays an item out
exactly as SteamCMD does (`<staging>/steamapps/workshop/content/431960/<id>`, in a
claimed `.WallpaperMachine-workshop-` staging folder on the library's volume), so
the import, preset bases and update replacement are the same code. Without it,
nothing changes: SteamCMD, the account form and the password prompts work as above.

Every native job shares one logged-on connection (`SteamNativeSession`), so a batch
signs in once and Steam's one-session-per-account limit never ends a sibling; the
connection closes a minute after the last job, and one that dropped is closed before
another opens. The app's client (`App/Services/Steam/`) logs on to a Steam
connection manager over WebSocket with the token (`SteamCMConnection`); a listed
server that does not answer a ping within ten seconds is passed over for the next
one (up to three). A logon that fails in any way closes its socket, and a request
that is paused or cancelled stops waiting at once instead of at its 30-second
timeout. The logon runs in a task of its own that every waiting job shares, so a job
paused or cancelled while it signs in stops waiting at once and the logon goes on for
the others; one overtaken by a sign-out, a new sign-in or the idle disconnect closes
its connection when it answers instead of adopting it. The client asks the
connection manager for the item's details, then the depot key (first, so that an
account without Wallpaper Engine learns it before anything is fetched) and the
manifest request code, and fetches the manifest and chunks from Steam's
content servers over HTTPS only: a server that lists no HTTPS support is skipped,
and one that answers after another failed is tried first from then on
(`SteamContentClient`). An item must belong to Wallpaper Engine (app 431960), since
a preset's base comes from an author-written file. Before anything is written, the
manifest's exact size must fit on the library's disk with the same allowance a
SteamCMD download gets (`WorkshopDownloader.requiredFreeBytes`); otherwise the job
fails with the same "Not enough free disk space" message. Chunks are fetched six at a time,
decrypted (AES-256, `SteamDepotCrypto`), unpacked by the Rust bridge
(`decompress_steam_content`: zstd, LZMA or zip, with their CRC checked) and checked
against their SHA-1 before they are written; a file path from a manifest that would
leave the download folder fails the download. The shared scene resources read the
current public manifest of depot 431961 from the app's product info (PICS) and
install its `assets` folder like SteamCMD's.

A token Steam refuses at logon (invalid, expired or revoked) is removed from the
keychain, and the job fails with "Steam no longer accepts this QR sign-in"; the next
request falls back to SteamCMD unless the person scans a new code. Steam hands a
depot key only to an account that owns Wallpaper Engine, so a key refused as
AccessDenied, InsufficientPrivilege or Blocked reports the account as not owning it
(`NativeWorkshopDownloader.meansNotOwned`); a plain Fail, or a reply without a
result, proves nothing and reads as the content servers failing. Other failures read as one
of a few phrases in the person's language: Steam unreachable (no answer at all),
sign-ins limited (a logon refused for its rate), sign-in failed (any other logon
refusal), session ended (Steam logged the session off, as when the account signs in
elsewhere), item not offered (its details refused), content servers failed (a
manifest code, the product info or another key refusal, or the servers themselves)
and content did not match, with the technical detail in the log and the failure log
(`NativeWorkshopDownloader.message(for:)`). Native jobs keep no partial download: a
paused or interrupted one fetches the item again when it resumes. **Try again**,
**Retry failed** and a tile's retry ring count the QR sign-in as ready, as they count
an installed SteamCMD (`PanelController.steamDownloadsReady`).

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
and authentication retries are automatic only once, after a sign-in that ended
for no reason Steam gave brought in a different SteamCMD
([Keeping SteamCMD current](#keeping-steamcmd-current)); Steam then asks again as
for any new sign-in. If Steam reports rate limiting,
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
SteamCMD exiting with an error and no reported failure is blamed on the step it
interrupted: before Steam accepted the sign-in it is a sign-in that did not
complete (with **Try again** for the sign-in), after it the download, where the
purchase requirement applies. Logs include the failure category, or for such an
exit its status, step and whether a Steam Guard code was waiting on Steam, never
the raw terminal reason or secrets.

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
which includes space it can reclaim on demand, or the plain free space when that
is higher (some Macs report 0 for important usage on every volume, which would
otherwise read as a full disk). Shared scene resources have no
listed size before SteamCMD starts, so they need a fixed 3 GiB (the content
depot is about 800 MB on disk): a lower bound meant to block only a clearly full
disk. Their depot download cannot resume, so nothing staged counts against it. When the disk is short
the download fails with a message naming what it needs and what is available; its
partial data is kept and **Try again** checks again. Nothing blocks a download
whose size Steam does not list, a sign-in-only run, or a disk whose free space
cannot be read. A preset's base wallpaper is checked before its pass at the size
Steam lists for it ([Workshop presets](#workshop-presets)), and
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
second SteamCMD pass of the same job, staging and sign-in. Before that pass the base's
listing is read from Steam's public details endpoint (`WorkshopDownloader.ItemDetails`):
the status names it and its size ("Downloading “Title” (120 MB), the wallpaper this preset
is based on…", or without the size when Steam lists none, and "Downloading the wallpaper
this preset is based on…" when the listing cannot be read), its progress has that total,
and the disk is checked for it as for any item, so a base that cannot fit stops before
SteamCMD is asked for it. Discover marks a preset's tile with a sliders mark (VoiceOver
reads it as **Preset**). The importer then assembles one
self-contained wallpaper under the preset's id: the base's content (moved from
staging, or cloned from the library, which stays unchanged), the preset's files
over it, and the base's manifest with the preset's title, description, tags,
rating, preview and Workshop id, `dependency` recorded, and each preset value
written into the base property of the same name (`null` headings and undeclared
names are ignored). A value for a `file` or `directory` property is written too but
never used: such a property starts empty and only the user's own pick fills it
([user files](user-files.md#in-the-inspector)), so a preset cannot point a wallpaper at
a folder of the user's. The renderer reads the preset's files where they land, beside
the base's `scene.pkg`: a scene mounts its folder under its package, so a property
naming `files/clip.mp4` finds the clip while packaged files still win. A base
fetched for a preset is not added to the library. If only the base's pass fails
(after the automatic retries in [Prompt and retry
handling](#prompt-and-retry-handling)), the error says the preset downloaded but
its base (Workshop item N) did not, so nothing was added, and gives Steam's own
reason; the partial download is kept and Try again picks up from it. A preset of
a preset, or one naming itself, is rejected without publishing anything. Updating a preset
reassembles it on the current base, and a change to the base alone is an update of the
presets built on it ([Updates](#updates)). Importing a preset folder works the same way with the
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
caught. A difference of a minute or less counts as the same version. An installed
preset carries its base's content, so the base its `project.json` names (`dependency`)
is asked about with the installed items, and a base changed after the preset was
installed offers the preset as an update, with the preset's own details; updating it
fetches the current base again unless the library holds the base as a wallpaper of its
own, which then has to be updated first.

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
