# pixiv illustrations

The **pixiv** page browses pixiv's illustration rankings and tag search and saves
any page of a work to the library as a still wallpaper that applies like any
other. Browsing needs no account; signing in to pixiv adds the works pixiv shows
only to members and, when the account allows them and the **Mature (R-18)** box
is ticked, R-18 works. R-18G works are never shown.

Every request is made by the app itself (`PixivService` over `PixivTransport`),
never by the panel's views, and every download is kept by the app
(`PixivDownloadQueue`). The artwork belongs to its artist; the inspector says so
and each saved wallpaper links back to the work on pixiv.

## Browsing

With the page's search bar empty the page shows a ranking; typing tags searches
pixiv instead, and the menu in the page's header follows: rankings while the field is
empty, search orders once it is not. Typing searches after a short pause, and Return
or **Refresh** asks again at once from the first page.

| Listing | What pixiv is asked | Page |
| --- | --- | --- |
| Daily, Weekly, Monthly, Rookie ranking | `ranking.php?mode=<ranking>&content=illust&format=json` | 50 works |
| Daily R-18, Weekly R-18 ranking | the same with `mode=daily_r18` / `weekly_r18`, only while signed in with Mature ticked | 50 works |
| Tag search, Newest first / Oldest first | `/ajax/search/illustrations/<tags>` with `s_mode=s_tag`, `type=illust` and `order=date_d` / `date` | 60 works |

Only the rankings that accept `content=illust` are offered, so every entry is a
single still illustration. pixiv answers a popularity order with the newest works
unless the account has Premium, so no popularity order is offered. Manga,
animations (ugoira), ranking slots pixiv withholds from the visitor
(`mask_reason`) and entries that are not illustrations are dropped as they are
read; a malformed entry is dropped instead of failing its page. A ranking or
search that fails to open empties the grid instead of leaving the listing before
it on show, where Next would page the one that failed; **Retry** asks for it again.

The Filters sidebar (the header's **Filter** button, see
[control-panel](control-panel.md#filtering)) holds the pixiv account and these
groups:

| Group | Choices | Default | Applied by |
| --- | --- | --- | --- |
| Orientation | Any orientation, Horizontal, Vertical | Any | pixiv for search (`ratio`), the app for rankings |
| Minimum size | Any size, 1920 × 1080, 2560 × 1440 or 3840 × 2160 or larger, either way round | Any | pixiv for search (`wlt` / `hlt`), the app for rankings and the long side |
| Age rating | Everyone (G), Questionable (PG-13), Mature (R-18) | Everyone | the app; Mature also switches search to `mode=all` or `mode=r18` |
| AI-generated | Hide AI-generated works | off | pixiv for search (`ai_type=1`); rankings hold none |

A work is rated Mature when pixiv restricts it to adults (`xRestrict` 1, or any
entry of an R-18 ranking), Questionable when pixiv's own site blurs it as
sensitive or grades it suggestive (sanity level 4 or more, or a `sexual` grade
above 0), and Everyone otherwise. R-18G (`xRestrict` 2, or `grotesque` in an
R-18 ranking) is its own rating, which no box offers and no query admits.

Pages are cached per listing (`PixivStore`), so paging back and changing a
filter only the app applies cost no request; the page after the one on show is
fetched ahead of time. The summary line names the listing and how many works on
the page the filters hide, and a page whose works are all hidden offers **Clear
filters** and **Next page**. JSON requests are spaced at least 350 ms apart and
carry an honest user agent (`WallpaperMachine/<version> (macOS; pixiv browser)`);
thumbnails come from `i.pximg.net`, which answers only requests that name pixiv
as their referrer, through a thumbnail cache of their own
(`Cache/PixivThumbnails`, 256 MB, six fetches at a time), which the panel's image
pipeline reads only for `i.pximg.net` addresses and decodes at the size a tile draws.

A general HTTP 403 is reported as a denied request, not as a confirmed rate limit, and
the error asks users to check access in a browser and their network/proxy connection (a
working browser does not prove the app's requests are accepted); HTTP 429 has separate
rate-limit advice. Failed HTTP responses log only the status code, never URLs, searches,
cookies or response bodies, for the [diagnostics report](diagnostics.md#diagnostics-report).
R-18 ranking denials have the account-specific handling described below.

## Saving a page

Selecting a tile fetches the work's page list; the inspector shows the page
whole, the artist's name (a link to their pixiv page), a page stepper for works with
several, **Download** (or **Download page N**) and **View on pixiv**; a saved page
offers **Apply wallpaper** (or **Reapply wallpaper**) as its primary button and **Show
in library**. Double-clicking a tile downloads the page the inspector shows, and
applies it once it is in the library. Downloads run two at a time in the order asked
for, each with progress on its tile and in the toolbar's downloads button and shared
Downloads popover; while one runs, a toolbar pill leads back to this page. They can be paused, resumed, cancelled or retried. Queue order and original-image checkpoints survive quitting and
relaunch in the app's `Downloads/Pixiv` directory; restored jobs wait for an
explicit **Resume download**. No pixiv session cookie is stored with the queue.

Resuming a partial original with an ETag or Last-Modified validator sends HTTP Range and
If-Range: a matching partial response continues at the saved byte offset, and a full
response replaces the old partial bytes. A server that supplies no usable validator
starts that original again. Cancel removes the job from the saved queue at once, then
discards its checkpoint when the transfer stops, so it cannot return as paused if the app
exits during that cleanup; starting that page again discards any partial bytes left
behind. Clearing finished jobs keeps paused work. The byte limit applies to the whole
original, including bytes retained before pausing.

A page is saved as a `web` project, since the renderer plays scene, video and web
projects only (`PixivWallpaperPackager`, with the page, properties and sizes of
`StillImageWallpaper`, which pictures imported from disk share):

- the folder, and so the wallpaper id, is `pixiv-<work id>-p<page>`;
- `illustration.<jpg|png|gif>` is the original exactly as pixiv serves it, named
  after its first bytes rather than its address, and at most 64 MB;
- `display.jpg` is a scaled copy shown instead when the original's long side
  exceeds 8,192 px, which a web view would decode whole;
- `preview.jpg` is a 512 px preview for the library;
- `index.html` shows the image with no text from pixiv in it, and
  `project.json` carries the title (with "(page/pages)" for works of several
  pages), a description linking the work, the rating as `contentrating`, up to
  20 of pixiv's tags (minus the words Installed's filters already use) and a
  `pixiv` block recording the work, page, author and original address.

The manifest gives each wallpaper two properties: **Image fit** (Fill, Fill,
keep the top, Fit with blurred backdrop, Fit, Original size) and **Background
color**. Pages at least 6:5 wide start on Fill and squarer or taller ones on Fit
with blurred backdrop. The labels stay English in the manifest like any
wallpaper's, and the panel translates exactly these for `pixiv-` and `image-` wallpapers (see
[localization](../localization.md)). The project is written to a staging folder
beside the library and moved in whole, so the library never lists a half-written
wallpaper; a copy already in the library is kept with its saved options, and
staging a crash left behind is removed at the next launch. After the move the
library reloads, waiting for any wallpaper being applied to finish first.

## Signing in and R-18 works

**Sign in to pixiv…** in the Filters sidebar's pixiv account group, or the link in the
page's header (it shrinks to a symbol, then leaves, on a narrow page), opens pixiv's own sign-in page in a window of its own (`WebSignInWindowController`, the one Steam's
sign-in for [subscriptions](workshop-downloads.md#subscriptions) uses too). The page
runs in a private website data store that disappears with the window; the app
reads exactly one thing from it, the `PHPSESSID` cookie pixiv sets on
`.pixiv.net` once someone has signed in, and only in its signed-in shape
(account id, underscore, token). The password, and anything else typed into the
page, stays between the page and pixiv. Closing the window cancels.

The session is then checked with pixiv (`/touch/ajax/user/self/status`). The
account's name comes from that answer or, failing that, from its profile
(`/ajax/user/<id>`), and whether its viewing restrictions allow R-18 works from
the answer's `user_x_restrict` when pixiv includes it. A session pixiv confirms
is saved as a generic password in the login
keychain (service `app.wallpapermachine.pixiv`) and sent, as a `Cookie` header
added by hand, with every request to `https://www.pixiv.net` and nothing else:
never to the image host, never logged, and never part of the panel's state.
At launch the saved session is read off the main thread and confirmed in the
background. Releases share one designated requirement (see
[build](../build.md#release-signing)), so an update reads what the version
before it saved; a locally built, ad-hoc signed app is a different app to the
keychain, and macOS asks once whether it may read the item.

Signed in, the Mature (R-18) box can be ticked; ticking it adds R-18 works to
search and the two R-18 rankings to the menu. Unticking it, or signing out,
returns an R-18 ranking to its all-ages counterpart (`PixivQuery.sanitized`; the
page's menu offers the R-18 rankings only by the rules in `PixivQuery+Panel.swift`). When pixiv reports that the account hides R-18 works,
the popover says to turn them on under **Viewing restrictions** in pixiv's
settings. pixiv refuses its R-18 rankings with 403 to anyone it does not know
to be an adult; the page then says whether a sign-in is missing or the account
hides R-18 works, and checks whether pixiv ended the session.

A session pixiv no longer recognises is dropped, here and in the keychain, with
a note to sign in again; a failure to reach pixiv keeps it. **Log out** forgets
the session in the app and the keychain, reloads what an anonymous visitor
sees and deselects an R-18 work; pixiv itself keeps the session until it expires
or is ended on pixiv. If the keychain refuses the session, the sign-in lasts
until the app quits and the popover says so. Some third-party sign-in providers
refuse to run inside another app's web view; signing in with a pixiv ID or email
and password always works.

## Code

| Part | Where |
| --- | --- |
| Models, ratings, queries, failures | `App/Services/Pixiv/PixivModels.swift` |
| Requests and decoding | `App/Services/Pixiv/PixivService.swift`, `PixivTransport.swift` |
| Browse state, account | `App/Services/Pixiv/PixivStore.swift`, `PixivSessionStore.swift` |
| Downloads and packaging | `App/Services/Pixiv/PixivDownloadQueue.swift`, `PixivWallpaperPackager.swift` |
| Panel actions and state | `App/Views/ControlPanel/Model/PanelController+Pixiv.swift`, `PixivBrowseState.swift`, `PixivTile.swift`, `PixivQuery+Panel.swift` |
| Sign-in window | `App/Views/ControlPanel/WebSignInWindow.swift` |
| Page, inspector and toolbar pill | `App/Views/ControlPanel/Pixiv/` |

## Verification

`Tests/Unit/Pixiv/` covers decoding against pixiv's answer shapes, addresses, ratings and
query sanitising, request pacing, the session reaching only `www.pixiv.net`, sign-in, log
out and expiry against an in-memory keychain, the download queue and packaging.
`PanelPixivActionsTests`, `PixivPanelStateTests`, `PixivBrowserModelTests`,
`PixivListSummaryTests` and `PixivBrowserRenderTests` (Panel) drive the page's actions,
model and views with a fixture pixiv and a closure in place of the sign-in window. Nothing in
the suite reaches pixiv or opens a window, so the real sign-in page and pixiv's
signed-in answers are checked by hand; see [Testing](../testing/README.md).
