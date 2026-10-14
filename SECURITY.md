# Security policy

WallpaperMachine runs on your desktop, signs in to Steam and pixiv, plays
wallpapers other people made and updates itself. If you find a way any of that
can be turned against the person using it, please tell us privately first.

## Report a vulnerability

Use **[Report a vulnerability](https://github.com/TheNightlyGod/WallpaperMachine-intel/security/advisories/new)**
on the repository's Security tab. Only the maintainers see the report, and the
fix and advisory are prepared with you there. If you can't use GitHub, email
support@wallpapermachine.app with "Security" in the subject.

Please don't open a public issue, discussion or pull request about a
vulnerability before a fix is released.

A useful report has:

- what an attacker can do, and what they need first: a wallpaper the user
  applies, a position on the network, a local account;
- steps or a proof of concept, with the app version (Settings → About) and your
  macOS version;
- for a wallpaper, its Workshop ID, or its files if it isn't published.

You'll hear back within a week. When the fix ships, the advisory credits you,
unless you would rather stay anonymous.

## Supported versions

Only the latest release gets security fixes. The app checks for new versions
itself and offers **Restart to Update**; builds from source should follow `main`.

## In scope

- The app, its lock-screen extension and its renderer, including how they handle
  a downloaded scene, video or web wallpaper: a wallpaper that reads or writes
  files, reaches the network or runs code beyond what the app means it to.
- The control panel's web view: script injection through wallpaper titles,
  Workshop or pixiv data, or messages from another origin.
- Steam and pixiv sign-ins leaving the Mac, or becoming readable by other apps.
- The [updater](docs/features/updates.md#installing) installing
  anything other than a release whose SHA-256 matches.
- [Diagnostics reports](docs/features/diagnostics.md) that leak what they promise
  to replace: home folder paths, the Mac user name, Steam account names.
- This repository's release workflows and the files they publish.

## Out of scope

- Steam, the Steam Workshop, pixiv and Wallpaper Engine themselves: report those
  to Valve, pixiv or Wallpaper Engine's developers.
- A wallpaper that is only offensive or misleading to look at: report it on the
  Workshop.
- The first-launch prompt from macOS: the download is signed but not yet
  notarized, as the [README](README.md#quick-start) says.
- The website, wallpapermachine.app: email support@wallpapermachine.app.

## Check a download

Each release's disk image is built by GitHub Actions from a tagged commit and
published with a SHA-256 checksum and a build provenance attestation. To check
one came from this repository's workflow:

```sh
gh attestation verify WallpaperMachine-*-x86_64.dmg --repo TheNightlyGod/WallpaperMachine-intel
```
