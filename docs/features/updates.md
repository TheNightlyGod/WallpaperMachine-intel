# App updates

The app updates itself from the repository's latest GitHub Release. Background
checks, downloads and results never open a window or steal focus: the menu bar panel,
traditional menu and control panel keep updates discoverable. The three update modes
separate notification, automatic downloading and unattended installation. This page is
what the app does; what the Build workflow publishes for it to read (manifest,
notes marker, signing, assets) is in
[release](../release.md#what-the-in-app-updater-expects).

## Checking for updates

**Settings → About → Updates** shows the status, last successful check, progress,
a mode picker and localized release notes. The default left-click menu bar panel has
an update row; the control panel also has a passive banner. Both open About. The
traditional right-click menu retains the update window and restart actions.
**Check for Updates…** opens About and starts a manual check, regardless of the
background schedule (but not during a download or installation).

After the library load finishes (even if it failed), the updater restores its local
state and checks when the saved six-hour deadline is due. It continues checking while
the app runs; sleeping does not reset the deadline. Repeated launches do not repeatedly
spend bandwidth, and concurrent requests share one check. A failed check preserves
the last candidate and its notes, reports the failure and keeps the last successful
check time; it never claims an offline machine is up to date. A complete downloaded
package does not prevent discovering a newer candidate.

There are no automatic update windows and no notification-permission request.
**Remind Me Later** records a per-version, 24-hour postponement across launches,
keeps a complete download and suppresses unattended installation. The main banner
stays out of the way during that postponement; About and the menu bar remain available.
A manual download/install can clear the postponement. **Skip This Version** also
prevents automatic downloading and installation of that version and discards its
cached package; a newer release is eligible normally. Neither choice hides the
manual update controls or notes.

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
available release and its notes only when the server confirms no release (a verified
ready package is retained). A transient failure retains both. When `/releases/latest` returns 404 the client
checks the repository endpoint and requires a valid repository response before
treating the release as absent; repository 404s, failed requests and malformed
responses stay errors and are never reported as **Up to date**. Errors are
classified (network, rate limit, release metadata, verification, permission, other)
and About words each one, with **Retry** and **Open GitHub Releases**.

### Release notes in About

The Updates group opens with one status row: a mark for the kind of news (up to
date, update on offer, working, failed), the status line, the last successful check
under it, and the next action (**Check Again**, **Download Update**, **Restart and
Install**, **Cancel**, **Retry**) at its trailing edge. **Remind Me Later**, **Skip
This Version**, **Open GitHub Releases** or **Show in Finder** sit in a row beneath
it when they apply, then **Update mode**. **Release notes** is its own card below
Updates, with the English / 简体中文 / 한국어 menu at its title (this page only,
never the app's language; a new app language brings its own translation again). Its
newest version is open; the versions before it fold behind **Earlier versions**,
which names their range. Both the card and the update window draw a version with
`ReleaseNotesEntryView`: the number links its GitHub comparison and the date is
written in the panel's language; About leaves out the issue and commit references
the window links. While updating, they show the available history newer than the
installed version; otherwise About keeps the latest release.
At most 20 recent versions are available from the manifest, not an unlimited history.
Missing or unreadable history falls back to the English release body. A body with
nothing to say produces no notes in About and an explicit empty state in the window.
`ReleaseNotes.parse` ignores everything from `<!-- release-notes-end -->` onwards,
turns each heading into a section title and each bullet into a line, and keeps a
plain paragraph after a list as an untitled section. Links keep their text,
emphasis markers and inline-code backticks are removed, a bullet's trailing issue and
commit references (`(closes #76) (bb75725)`) are dropped and the **Full changelog**
compare link is skipped. The
release body is English only, so the lines are English; section titles the panel
knows (**New**, **Fixed**, and so on) are translated.

## Downloading

**Download Update** in About or the update window, or either automatic-download mode,
starts a download; discovery itself never fetches the image. About shows percent,
bytes and a Cancel action. Cancelling is not an error and postpones automatic attempts
for this version for 24 hours, rather than immediately restarting the download.

`Updates/` under `ClientPaths.supportURL` holds at most one complete candidate and a
versioned, atomically written `state.json`. Only fully downloaded and verified packages
get a cache record. A later launch checks the recorded size and SHA-256 again and
validates a freshly extracted signed app before restoring ready state. An incomplete,
missing or corrupt package is discarded; partial downloads are not resumed across
launches. Installed, skipped and superseded packages are removed. Cached paths cannot
escape the update directory, and extracted temporary apps are not trusted across launches.
`GitHubReleaseDownload` enforces:

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
  ignore Range cannot keep it retrying forever. Incomplete bytes are not reused by a new
  download; complete verified packages can be reused across launches.

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

Installing is confirmed by **Restart and Install** in About (with a confirmation
sheet), **Install and Relaunch** in the update window, or **Restart to Update to x.y.z**
in the traditional menu. **Download Update** alone no longer immediately restarts from
the window. Full automatic mode installs on its own only under the conditions
[below](#automatic-updates). Failures stay visible through the passive update status
and the current details; they never automatically bring About forward.
The install runs the *running* version's code, so these improvements reach an older
copy only after the update carrying them is installed.

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
latest from rolling the app back. The signed bundle's version must also exactly match
the offered version. Its actual minimum macOS version and executable architecture
must support this Mac; a declared minimum in the manifest must agree with the signed
bundle. Explicitly incompatible manifest metadata prevents downloading; old manifests
without the new fields still get the signed-bundle check before installation.
Cancelling stops preparation, detaches the image, removes staging and leaves the update
ready. Automatic installs recheck eligibility after preparation and immediately before
starting the replacement helper, so a wake, unlock, postponement or mode change keeps
the app running. Once the helper is handed off, unavailable controls are disabled.

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
`AppUpdatePolicyTests` covers mode migration and unattended-install eligibility;
`AppUpdatePersistenceTests` covers cache integrity and path boundaries. Store tests
also exercise cross-launch restoration, postponement, cancellation, operation-specific
retry and the two installation eligibility rechecks.

## The update window

The window an available update opens (`UpdateWindow`, a SwiftUI view in its own
nonmodal window) shows the app's Dock icon, **A new version of WallpaperMachine is
available!** and **WallpaperMachine x.y.z is now available—you have a.b.c. Would you
like to download it now?** Below that, a scrolling box lists every release above the
running version up to the available one that the manifest carries (its 20 newest
changelog sections), newest first: each opens with its version
as a link (the comparison with the previous version on GitHub) and its date,
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

- **Download Update** downloads and verifies the package without immediately quitting.
  Progress and Cancel stay in the window. A failure keeps the window with its error
  and Retry; retrying a download does not first fetch release metadata again. For a
  manually requested download that cannot install in place, Finder reveals only the
  verified application. Background discovery never opens Finder.
- A downloaded update reads **A new version of WallpaperMachine is ready to install!**
  and offers **Install and Relaunch**. A release without a disk image offers **Open
  GitHub Releases**.
- **Skip This Version** records the version (`WallpaperMachine.updates.skippedVersion`);
  unattended checks offer it no more, and a newer release is offered as usual. About
  and the status menu still show it.
- **Remind Me Later** and Escape close the window and postpone this version for 24 hours.
  Closing with the window button merely closes it; it does not change the mode. No
  window is reopened automatically on a later launch. **Check for Updates…** while
  the window is open brings it forward; the main action is unavailable during work.
- **Update mode** selects the same three modes as About.

An installation intent is persisted before quitting. On the next launch the actual
running version, not the helper's existence, confirms success. A passive **Updated to
version…** notice links back to the notes and can be dismissed. If the previous version
still runs, the version is held back from automatic retries and the update entry asks
for attention. No post-update window opens; changelog images are not bundled.

### Automatic updates

**Update mode** (`WallpaperMachine.updates.mode`) offers:

- **Check and notify**: background checks; manual download and restart.
- **Download automatically**: background checks and downloads; manual restart.
- **Download and install automatically**: background checks and downloads, then restart
  installation only while the displays sleep or the session is locked.

A confirmed fresh installation defaults to the third mode, visibly explained in the
first-run preferences and changeable immediately. Existing users keep their choice:
the legacy `WallpaperMachine.updates.automatic` true maps to full automatic, false or
an uncertain existing installation maps to notification only. Missing preferences alone
are not proof of a fresh install; existing support data prevents silently opting in.
Migration is saved once. The mode is not part of wallpaper backups.

Automatic installation also requires a completed first-run guide, a replaceable app,
no shutdown in progress, no skip or active postponement and no blocking failure for
this version. Full-screen apps, Focus rules and wallpaper pauses are not installation
opportunities. It never wakes a sleeping machine or requests elevated privileges.
A wake or unlock during preparation cancels the automatic handoff and keeps the
verified download ready. Failed verification or installation is not repeatedly retried
on every lock: use the visible manual retry or wait for a newer release. Network
failures retain bounded source fallback and wait for the next scheduled/manual check.
Copies that need a manual install remain passive until the person acts.

`AppReleaseHistoryTests` covers changelog parsing and language fallback;
`UpdateWindowTests` covers the language selector. Menu panel model/controller tests
cover update visibility, routing and stopping observation when the panel closes.
The ordinary test gate does not establish desktop or live-release fidelity.
