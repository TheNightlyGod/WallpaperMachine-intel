# App updates and What's New

The app updates itself from the repository's latest GitHub Release: it checks on
its own, downloads and restart-installs only after the user confirms, and after an
update shows that version's release notes once in a separate window. This page is
what the app does; what the Build workflow publishes for it to read (manifest,
notes marker, signing, assets) is in
[release](../release.md#what-the-in-app-updater-expects).

## Checking for updates

**Settings → About** is the update surface: an **Updates** group with the status,
one action button, a progress bar while downloading and the latest release's notes
([Tabs](control-panel.md#tabs) lists the rest of About). **Check for Updates…** in
the application menu opens About and starts the same check.

The app checks at launch once the library has loaded (whether or not it loaded
cleanly, since the update may be the fix), every six hours after, because a
menu-bar app can run for weeks (a Mac that slept through the interval checks as
soon as it wakes), and on **Check for Updates**. Unattended checks only discover
updates: one alert offers **View Update**, which opens About, or **Later**; an
update the user has already downloaded offers **Restart to Update** instead. Each
version is offered once per launch. Downloading still requires **Download
Update**. The status menu keeps an entry for an available update (**WallpaperMachine
x.y.z Available…**, which opens About) or a downloaded one (**Restart to Update to
x.y.z**), so **Later** only dismisses the alert.

The alert is modal and brings the app forward, so it waits for a moment that it
would not interrupt (`UpdatePromptGate`). It is held while wallpapers are
suspended (display asleep, session locked, or an app rule or the Focus filter
pausing them), while any display's wallpaper is paused because a full-screen app
or other windows cover it, while the What's New window is open and while the app
quits. The signals are the ones [Playback](performance.md#playback) describes:
with **When windows cover the desktop** on **Keep running**, only a display
fully hidden by a full-screen app holds it, and with **Pause** a maximized window
does too. A display paused only because **Only play on the display I’m using** is on
and the pointer is elsewhere does not hold it; a full-screen app or covering windows on
that display still do. When the control panel is the key
window the alert is allowed even while wallpapers are paused, since the person is
already in the app. A held alert does not count as offered: it appears once, with no
new network check, when wallpapers present again, when What's New closes or when the
control panel becomes key, and the log notes `update prompt deferred: <reason>` when
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
`GitHubReleaseParser` reads both; what it carries and who writes it is in
[release](../release.md#what-the-in-app-updater-expects). The API is asked only
when the Latest release has no manifest (404) or one the parser rejects; a manifest
that is rate-limited, fails or redirects off the GitHub hosts listed under
[Downloading](#downloading) is an error, not a reason to spend an API request.

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
emphasis markers and inline-code backticks are removed, a trailing commit
reference is dropped and the **Full changelog** compare link is skipped. The
release body is English only, so the lines are English; section titles the panel
knows (**New**, **Fixed**, and so on) are translated.

## Downloading

Only **Download Update** in About starts a download; a check never fetches the
image. The image is streamed under its asset name into `Updates/` in the app's
Application Support folder (`ClientPaths.supportURL`), and About shows percent and
bytes. `GitHubReleaseDownload` enforces:

- HTTPS on `github.com`, `api.github.com` and the `objects`, `release-assets` and
  `github-releases` hosts under `githubusercontent.com` (default port only), for
  the manifest as for the image: every redirect must stay on them and one that
  leaves ends the request with an error. The image's own URL and its final
  response must be on them too.
- A `sha256:` digest for the image, from the manifest (or from GitHub when the API
  was asked). An image that comes without a usable digest is refused as
  unverifiable before the request starts, never installed unchecked.
- The bytes are hashed as they arrive. An answer other than HTTP 200, a size above
  1 GiB (`maximumDownloadBytes`), a byte count that differs from the published
  `size` (or `Content-Length`) and a SHA-256 that differs from the digest each fail
  the download. A request stalls out after 5 minutes without data, the whole
  transfer after 30 minutes.

A finished download leaves About on **Version x.y.z is ready** with **Restart and
Install** and **Show in Finder**. When the installed copy cannot be replaced in
place (next section), the app instead opens the image in Finder as soon as it is
downloaded, so Finder shows its drag-to-Applications window for a manual install.

## Installing

Installing is a second confirmation: **Restart and Install** in About (which asks
**Restart and install this update?** natively first), **Restart to Update** in the
alert, or **Restart to Update to x.y.z** in the status menu, which installs at
once. The install runs the *running* version's code, so a change to the installer
reaches users only after the update that carries it. A failed install started from
the alert or the menu opens About, which explains it and offers **Retry
installation** and **Open GitHub Releases**.

**Where it can install.** The installed copy must live in `/Applications` or
`~/Applications`, and this user must be able to write both the bundle and its
folder. A copy anywhere else, or one a standard account cannot replace (for
example installed by an administrator), gets the manual path above; asking to
install it anyway reports a permission error.

**Preparing.** About shows **Preparing update…** with **Cancel**. A worker actor
attaches the image read-only and out of sight (`hdiutil attach -nobrowse -readonly
-noautoopen`) at a private mount point in a `mwe-update-<uuid>` directory of the
temporary folder, finds its single `WallpaperMachine.app` without following
symbolic links (so the `Applications` link is never traversed), copies it out with
`ditto --noqtn` and detaches the image whatever happens. The copy must carry the
bundle identifier `app.wallpapermachine` and a readable
`Contents/MacOS/WallpaperMachine` before anything is replaced. The updater checks
that and the digest, not the copy's code signature; signing is the publish side's
concern ([release](../release.md#what-the-in-app-updater-expects)). Cancelling
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
paths, rate limits, asset selection, digest verification, installing from a real
disk image and the replacement helper's success, failure and locking.
`UpdatePromptGateTests` covers when the unattended alert is held and that a held
one is offered exactly once afterwards.

## After an update

On the first launch of a newer version, a separate, nonmodal **What’s New** window
shows the installed version and every release since the last announced version,
newest first. It opens with a 760 × 720-point content area and resizes down to
600 × 480. **English / 简体中文** tabs display one translation at a time for every
release; the initial tab follows the app’s effective language (Settings → General
→ Language, including **System** matching, not the bundle’s launch-time language):
Simplified or Traditional Chinese uses Simplified Chinese notes, English or
Japanese uses English notes. Switching tabs returns to the top of the notes and
does not change the interface language. Notes come from the bundled
`CHANGELOG.md`, so they work offline and cannot describe a newer remote release;
generation and translation are owned by
[the release pipeline](../release.md#release-notes-and-the-changelog).

**Don’t show this window after updates** saves immediately and suppresses all
future automatic post-update windows; it does not disable update checks or hide
the release notes in Settings → About. Closing the window, including Command-W,
leaves WallpaperMachine running. Ordinary relaunches, fresh installs, downgrades
and returning to an already announced version do not show the window.

`WhatsNewStore` persists the highest announced version
(`WallpaperMachine.whatsNew.lastVersion`) and the opt-out in the app’s
preferences. A Mac with no recorded version that has already completed or skipped
the [welcome guide](first-run.md#first-run) is treated as an existing user and sees
only the installed release’s notes, without an invented previous version; a fresh
installation and the permanent opt-out record the version without a window. The
version is recorded only once the window is on screen. When the bundled history
has no section for the installed version, `announcement` returns nil *without*
recording the version, so the next launch repeats the check: recording on a miss
would consume the announcement and a later bundle containing the notes would never
show them. The bundled history is strict: every `##` heading must be a semantic
version, each release needs notes under both `### English` and `### 简体中文` and no
version may repeat, so `## Unreleased`, a `##` line inside notes, a missing
translation or a duplicate fails the whole file and the window does not appear
(publishing rejects that file first).
