# App updates

The app updates itself from the repository's latest GitHub Release: it checks on
its own, opens a window with the notes of every version since the running one, and
downloads and restart-installs only after the user confirms, unless they chose
automatic updates. This page is
what the app does; what the Build workflow publishes for it to read (manifest,
notes marker, signing, assets) is in
[release](../release.md#what-the-in-app-updater-expects).

## Checking for updates

**Settings → About** is the update surface: an **Updates** group with the status,
one action button, a progress bar while downloading, the **Automatically download and
install updates** switch ([automatic updates](#automatic-updates)) and the latest
release's notes
([Pages and Settings](control-panel.md#pages-and-settings) lists the rest of About).
**Check for Updates…** in the application menu opens About and starts the same check.

The app checks at launch once the library has loaded (whether or not it loaded
cleanly, since the update may be the fix), every six hours after, because a
menu-bar app can run for weeks (a Mac that slept through the interval checks as
soon as it wakes), and on **Check for Updates**. An unattended check that finds an
update opens [the update window](#the-update-window), once per version per launch;
with [automatic updates](#automatic-updates) on it downloads the update instead and
opens nothing. A version the user skipped is never offered by an unattended check.
The status menu keeps an entry for an available update (**WallpaperMachine x.y.z
Available…**, which opens the update window) or a downloaded one (**Restart to
Update to x.y.z**), so **Remind Me Later** only closes the window.

The window brings the app forward, so it waits for a moment that it would not
interrupt (`UpdatePromptGate`). It is held while wallpapers are suspended (display
asleep, session locked, or an app rule or the Focus filter pausing them), while any
display's wallpaper is paused because a full-screen app or other windows cover it,
and while the app quits. The signals are the ones [Playback](performance.md#playback) describes:
with **When windows cover the desktop** on **Keep running**, only a display
fully hidden by a full-screen app holds it, and with **Pause** a maximized window
does too. A display paused only because **Only play on the display I’m using** is on
and the pointer is elsewhere does not hold it; a full-screen app or covering windows on
that display still do. When the control panel is the key
window the update window is allowed even while wallpapers are paused, since the person
is already in the app. A held window does not count as offered: it appears once, with
no new network check, when wallpapers present again or when the control panel becomes
key, and the log notes `update prompt deferred: <reason>` when
it starts waiting. Nothing else changes while it waits: the status menu entry is already
there, and **Check for Updates…** is never held.

### What a check reads

A check reads the Latest release's update manifest, not the REST API: anonymous
API requests are limited to 60 an hour per public IP, shared with every app and
device behind that address. The manifest is a release asset,
`https://github.com/WallpaperMachine/WallpaperMachine/releases/latest/download/WallpaperMachine-update.json`
(`AppUpdateConfiguration.latestManifestURL`). github.com redirects it to the file
on the release marked Latest (drafts never resolve), and such a download does not
count against the API limit. It is the release object in the API's shape, so
`GitHubReleaseParser` reads both. Unlike the API, the manifest also carries the
newest `CHANGELOG.md` sections in every translation (`changelog`), which the update
window reads; what it carries and who writes it is in
[release](../release.md#what-the-in-app-updater-expects). The API is asked only
when the Latest release has no manifest (404) or one the parser rejects; a manifest
that is rate-limited, fails or redirects off the GitHub hosts listed under
[Downloading](#downloading) is an error, not a reason to spend an API request.

**Mirrors.** Where GitHub can't be reached (typically mainland China without a VPN),
the check asks public GitHub download proxies for the same manifest, in the order of
`AppUpdateConfiguration.mirrors` (`ghfast.top`, `gh-proxy.com`, `gh.llkk.cc`). Each
takes the whole GitHub URL after its own
(`https://ghfast.top/https://github.com/…`). Only an unreachable route moves on: a
request that fails to connect, times out or answers with an error status. GitHub's own
answers (a rate limit, a missing repository) stand and are never taken to a mirror. A
mirror is asked only for the manifest, never the API, and anything it answers other
than a readable manifest counts as a dead route. The way that last worked (GitHub or
a mirror) is tried first by the next check and the next download, for as long as the
app runs, so a Mac that can't reach GitHub doesn't wait out its 30-second timeout
every time. When every route fails, the error reported is GitHub's. The mirrors are
untrusted transport: what installs is decided by the signature and version checks
under [Installing](#installing), so a mirror can withhold an update but never
substitute one. A release page a manifest names is opened only on `github.com`;
any other falls back to GitHub Releases. Using the mirrors sends the device's IP
address and the requested GitHub URL to those third parties, and only after GitHub
itself has failed.

With a manifest a check spends no API request; without one it spends one (two when
`/releases/latest` is 404). A 403 with `x-ratelimit-remaining: 0` or a
`retry-after` header, or a 429, from either source is a distinct `rateLimited`
error: About shows the reset time from `retry-after` (else `x-ratelimit-reset`),
and until then every check, automatic or **Retry**, fails locally without a
request, so retrying cannot keep the shared quota exhausted. When GitHub names no
reset time there is nothing to wait for and the next check goes out.

A release is an update when its tag parses as `x.y.z` (a leading `v` is allowed;
three numeric parts, no suffix such as `-beta` or `nightly`), it is not a
prerelease and it is above the running version. The image to download is the asset
named exactly `WallpaperMachine-<x.y.z>-arm64.dmg`
(`AppUpdateConfiguration.assetName(for:)`), then another product disk image naming
`arm64`, then any product disk image. Only `.dmg` assets whose name contains the
product name qualify: the `.sha256` sidecar, zips, feeds and blockmaps are never
downloaded. With no matching asset the app falls back to opening GitHub Releases
for a manual update: About says the version is available from GitHub Releases and
offers **Open GitHub Releases**, not a download.

A completed check has two normal no-update outcomes: a latest release at or below
the running version is **Up to date**, and a repository without an eligible
published release shows **No published update is available yet. You can keep using
this version.** Both offer **Check Again**. A fresh check clears any previous
available release and its notes. When `/releases/latest` returns 404 the client
checks the repository endpoint and requires a valid repository response before
treating the release as absent; repository 404s, failed requests and malformed
responses stay errors and are never reported as **Up to date**. Errors are
classified (network, rate limit, release metadata, verification, permission, other)
and About words each one, with **Retry** and **Open GitHub Releases**.

### Release notes in About

The Updates group shows the newest published release's body as a **What's new in
x.y.z** disclosure, whether or not that release is newer than the running build. A
body with nothing to say produces no disclosure rather than an empty one.
`ReleaseNotes.parse` ignores everything from `<!-- release-notes-end -->` onwards,
turns each heading into a section title and each bullet into a line, and keeps a
plain paragraph after a list as an untitled section. Links keep their text,
emphasis markers and inline-code backticks are removed, a bullet's trailing issue and
commit references (`(closes #76) (bb75725)`) are dropped and the **Full changelog**
compare link is skipped. The
release body is English only, so the lines are English; section titles the panel
knows (**New**, **Fixed**, and so on) are translated.

## Downloading

Only **Download Update** in About, **Install Update** in the update window or an
automatic update starts a download; a check never fetches the image. The image is streamed under its asset name into `Updates/` in the app's
Application Support folder (`ClientPaths.supportURL`), and About shows percent and
bytes. Only an image this launch downloaded is ever installed, so `Updates/` holds at
most that one: a new download first deletes every image there, and each launch
deletes the ones earlier launches left (installed, abandoned or unfinished) before its
first check. `GitHubReleaseDownload` enforces:

- HTTPS on `github.com`, `api.github.com` and the `objects`, `release-assets` and
  `github-releases` hosts under `githubusercontent.com` (default port only), plus
  the [mirrors](#what-a-check-reads)' hosts for a request relayed through one, for
  the manifest as for the image: every redirect must stay on them, and one that
  leaves ends that source's request. The image URL the manifest names must be on
  GitHub's hosts; a mirror is only another way to fetch that URL.
- A `sha256:` digest for the image, from the manifest (or from GitHub when the API
  was asked). An image that comes without a usable digest is refused as
  unverifiable before the request starts, never installed unchecked.
- The bytes are hashed as they arrive. An answer other than HTTP 200 (or a valid
  206 when resuming), a size above
  1 GiB (`maximumDownloadBytes`), a byte count that differs from the published
  `size` (or `Content-Length`) and a SHA-256 that differs from the digest each fail
  the download. Each request stalls out after 60 seconds without data and times
  out after 30 minutes in total.
- Sources take turns: the route that last worked first, then GitHub and each mirror.
  A source that fails, stalls, closes early or answers with an unusable status hands over
  to the next. While another source is left in the first round, one still below
  32 KiB/s after 30 seconds (`GitHubReleaseDownload.slowSourceRate`) gives way too,
  so a trickling connection to GitHub doesn't hold the image for half an hour. The
  next source resumes with `Range: bytes=<n>-` and must answer 206 from exactly
  that byte; one that sends the whole image (200) replaces what was written. Bytes
  that add up to the wrong size or digest are thrown away and the next source
  starts over. The download ends once every source in a row has failed without
  exceeding the highest byte offset reached, so repeated truncated responses that
  ignore Range cannot keep it retrying forever. Nothing is kept between downloads.

Before a download becomes ready, the app inside is copied out and checked for its
signature and newer version using the same checks as installation. Finder only
reveals this verified app, never the original image: a mirror could repackage a
genuine app alongside unsigned installers. Restart-install checks a fresh copy
again before replacing the running app.

A finished download leaves About on **Version x.y.z is ready** with **Restart and
Install** and **Show in Finder**. When the installed copy cannot be replaced in
place (next section), the app reveals the verified application in Finder as soon
as the download is verified, so the user can move it to Applications manually.

## Installing

Installing is confirmed by **Restart and Install** in About (which asks **Restart
and install this update?** in a confirmation sheet first), **Install Update** or
**Install and Relaunch** in the update window, or **Restart to Update to x.y.z** in the
status menu, which installs at once; an automatic update installs on its own
([below](#automatic-updates)). The install runs the *running* version's code, so a
change to the installer reaches users only after the update that carries it. A failed
install started from the update window or the menu closes the window and opens About,
which explains it and offers **Retry installation** and **Open GitHub Releases**.

**Where it can install.** The installed copy must live in `/Applications` or
`~/Applications`, and this user must be able to write both the bundle and its
folder. A copy anywhere else, or one a standard account cannot replace (for
example installed by an administrator), gets the manual path above; asking to
install it anyway reports a permission error.

**Homebrew.** A copy installed with `brew install --cask wallpapermachine` is the
release's own app, put in `/Applications`, and updates the same way. The cask
declares `auto_updates`, so `brew upgrade` leaves the app to this updater unless run
with `--greedy`, and `brew list --versions` keeps showing the version Homebrew
installed. What the cask needs from a release is in
[release](../release.md#homebrew).

**Preparing.** About shows **Preparing update…** with **Cancel**. A worker actor
attaches the image read-only and out of sight (`hdiutil attach -nobrowse -readonly
-noautoopen`) at a private mount point in a `mwe-update-<uuid>` directory of the
temporary folder, finds its single `WallpaperMachine.app` without following
symbolic links (so the `Applications` link is never traversed), copies it out with
`ditto --noqtn` and detaches the image whatever happens. The copy must carry the
bundle identifier `app.wallpapermachine` and a readable
`Contents/MacOS/WallpaperMachine` before anything is replaced. Its signature must
then be intact throughout the bundle (strict validation, every architecture and all
nested code) and satisfy `AppUpdateConfiguration.signingRequirement`, which names the
releases' signers: this identifier, signed with the project's Developer ID (every release
after 1.8.2) or with the project certificate (1.0.2 through 1.8.2)
([release signing](../build.md#release-signing)). Copies older than 1.8.0 accept only the
project certificate, so they refuse a Developer ID release as unverifiable; they are
updated by downloading the image. The digest proves the image is the one
the release lists; the signature proves who built it, so a release asset someone replaced
is refused as unverifiable, never installed, and so is a copy signed any other way, ad hoc
included ([release](../release.md#what-the-in-app-updater-expects)). Its
`CFBundleShortVersionString` must also be above the running version: a genuine older
release passes the signature check, so this is what stops a mirror relaying it as the
latest from rolling the app back. Cancelling
stops the process, detaches the image, removes the staging directory and leaves
the update ready to start again.

**Replacing.** The app then starts a detached helper script and quits. The helper
waits for the app to exit, copies the new app beside the old one as a hidden
`.WallpaperMachine.app.update-<pid>` (the helper's pid), renames the old one aside,
moves the new one in and only then deletes the old one. Any failed step puts the
old app back and removes the partial copy; whichever version is in place has its
quarantine attribute cleared and is reopened, so a failed install relaunches the
previous version rather than leaving no app. One kernel file lock (the hidden
`.WallpaperMachine.app.update.lock` beside the app, kept for reuse) owns each
destination for the helper's lifetime, so a second replacement is refused while
one runs. If the app has not quit and relaunched within 45 seconds the app cancels
the helper and reports that the install timed out; **Retry installation** is
enabled only after cancellation confirms the old helper has stopped.

`Tests/Unit/GitHub/AppUpdateTests.swift` covers checking, the manifest and API
paths, the mirror fallback and its route memory, rate limits, asset selection,
digest verification, resuming across sources, the signature and version checks
(an unsigned, altered, foreign-signed or older copy is refused), installing from a real
disk image and the replacement helper's success, failure and locking.
`UpdatePromptGateTests` covers when the unattended update window is held and that a
held one is offered exactly once afterwards.

## The update window

The window an available update opens (`UpdateWindow`, a SwiftUI view in its own
nonmodal window) shows the app's Dock icon, **A new version of WallpaperMachine is
available!** and **WallpaperMachine x.y.z is now available—you have a.b.c. Would you
like to download it now?** Below that, a scrolling box lists every release above the
running version up to the available one that the manifest carries (its 20 newest
changelog sections), newest first: each opens with its version
as a linked badge (the comparison with the previous version on GitHub) and its date,
then its sections (**Highlights**, **Breaking Changes**, **Features**,
**Improvements**, **Bug Fixes**) and bullets, with each bullet's issue and commit
references as links. Links open only through `ExternalLink`, so only GitHub's.

The notes come from the manifest's `changelog`. **English / 简体中文 / 한국어** on the
right of the **Release notes** row above the box picks the translation for this window
only and returns the notes to the top (the title bar holds only the window buttons); it never changes the app's
language. The window opens on the app's effective language (Settings → General →
Language): Simplified or Traditional Chinese opens on the Chinese notes, Korean on the
Korean ones (English for releases before 1.5.7), and English, Japanese or Brazilian
Portuguese on the English ones; section headings the catalogs know are translated for
Japanese, Traditional Chinese and Brazilian Portuguese. When the manifest has no changelog (the API path,
or a release published before it carried one), when it does not parse, or when it
lacks the available version, the window shows the release body's English notes for
the available version alone. `AppReleaseHistory` parses the changelog with the same
strict rules publishing applies ([release](../release.md#release-notes-and-the-changelog)).

- **Install Update** downloads the update with a progress bar in place of the
  checkbox, then quits and reopens on the new version (**Preparing update…** while
  the image is copied out). It is consent to both steps: closing the window or
  **Remind Me Later** during the download does not call the install off. When the
  installed copy cannot be replaced in place, the verified application is revealed in Finder instead
  and the window closes. A failed download closes the window and opens About.
- A downloaded update reads **A new version of WallpaperMachine is ready to install!**
  and offers **Install and Relaunch**. A release without a disk image offers **Open
  GitHub Releases**.
- **Skip This Version** records the version (`WallpaperMachine.updates.skippedVersion`);
  unattended checks offer it no more, and a newer release is offered as usual. About
  and the status menu still show it.
- **Remind Me Later**, Escape and the close button close the window; the version is
  offered again on the next launch, also when the window was opened from the status menu.
  **Check for Updates…** while the window is open brings it forward instead of checking,
  and its main button is disabled whenever no version is available.
- **Automatically download and install updates in the future** turns on automatic
  updates, the same setting as About's switch.

There is no window after an update: the post-update What's New window and the bundled
`CHANGELOG.md` and release banners were removed, so the notes are read before
updating, and About keeps the latest release's notes.

### Automatic updates

**Automatically download and install updates** in Settings → About, or the checkbox
in the update window, is off by default and saved at once
(`WallpaperMachine.updates.automatic`). With it on, an unattended check that finds a
downloadable update the user has not skipped downloads it without opening a window,
and a downloaded update installs, quitting and reopening the app, the next time nobody
is at the Mac: when the displays sleep or the session locks
(`WallpaperPresentationPolicy.isUnattended`; an app rule or the Focus filter does not
count). A release without a disk image, or a copy that cannot be replaced in place
([Where it can install](#installing)), still opens the update window, since it cannot
install itself. While the update window is open, the six-hourly check waits, so it
never clears the release the window shows. Until it installs, the status menu offers **Restart to Update to
x.y.z**.

`AppReleaseHistoryTests` covers parsing the changelog (headings, translations, links)
and which releases the window shows; `UpdateWindowTests` covers the language switch; `AppUpdateTests` covers the manifest's changelog,
the plain reading About shows and that the skipped version and the automatic setting
persist.
