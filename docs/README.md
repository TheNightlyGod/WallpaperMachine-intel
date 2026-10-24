# Documentation

Product behavior is documented per feature under `features/`; how the code is
organized and how it runs is in the two reference documents; how to build, test,
release and contribute is in the process documents; test strategy and evidence
live under `testing/`.

## Getting started

| Document | Purpose |
|---|---|
| [../README.md](../README.md) | What the app is, feature tour, FAQ, build quickstart, sponsor list; follows the website |
| [../README.zh-CN.md](../README.zh-CN.md) | README.md in 简体中文; changes with it, wording follows the app's zh-Hans catalog and the website's /zh/ pages |
| [../SPONSORS.md](../SPONSORS.md) | Supporter pricing and benefits for users; follows the website's pricing page, policy in LICENSING.md |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Contributor working agreement and day-to-day loop |
| [../CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) | Conduct expected in issues, discussions, pull requests and reviews; how it is enforced |
| [../SECURITY.md](../SECURITY.md) | Private vulnerability reporting, supported versions, scope, checking a download |
| [build.md](build.md) | Toolchain, dependencies, build, package, install, troubleshooting |

## Reference

| Document | Purpose |
|---|---|
| [architecture.md](architecture.md) | Runtime architecture and module boundaries, including the SwiftUI control panel's controller, actions and window hosting |
| [repository-layout.md](repository-layout.md) | Directory map and where new code goes |
| [container-readers.md](container-readers.md) | `Renderer/Media`: the project's own MP4 and Matroska/WebM readers, what they parse and refuse, their limits, and how they are tested |
| [sound-decoding.md](sound-decoding.md) | `Renderer/Sound`: how a scene's sounds are decoded, remixed, resampled and looped for the output device, which decoder serves which file, and how that is tested |
| [localization.md](localization.md) | Language resolution, the string catalogs and the panel's live language switch, how to add or remove a language |

## Process

| Document | Purpose |
|---|---|
| [conventions.md](conventions.md) | Code, test, documentation, commit and pull-request rules |
| [release.md](release.md) | Versioning, release specs, notes generation, CI pipeline, in-app updater contract |
| [../CHANGELOG.md](../CHANGELOG.md) | Published versions, newest first; written by `scripts/release_notes.py` |
| [development-tools.md](development-tools.md) | Optional diagnostic tools (Peekaboo, Instruments, `xctrace`), the safe setup check, and when a desktop run needs authorization |
| [../AGENTS.md](../AGENTS.md) / [../CLAUDE.md](../CLAUDE.md) | Agent rules; CLAUDE.md is a symlink, not a separate policy |
| [../LICENSING.md](../LICENSING.md) | GPL-3.0-only source policy, Supporter model (free signed download; sponsor place and priority support), Mac App Store questions, component licenses, distribution blockers |
| [../LICENSE](../LICENSE) | GNU GPL version 3 text, the license of this repository's source |

## Testing

| Document | Purpose |
|---|---|
| [testing/README.md](testing/README.md) | Test strategy, verification tiers, how to run each layer, evidence policy |
| [testing/coverage.md](testing/coverage.md) | Domain-by-domain inventory of what the native tests assert, and their limits |
| [testing/renderer.md](testing/renderer.md) | `check_renderer.py`, headless GPU probes and their environment variables, Rust and C++ test binaries, known limitations |
| [testing/scene-regressions.md](testing/scene-regressions.md) | Regressions that must stay covered in what a scene looks like and does: cameras, scripts, layers, alpha, text, puppets, shaders |
| [testing/runtime-regressions.md](testing/runtime-regressions.md) | Regressions that must stay covered at runtime: native Metal, video, continuous playback, frame pacing, audio, host and display, startup |
| [testing/manual-smoke.md](testing/manual-smoke.md) | Manual release smoke checklist |
| [testing/power-benchmark.md](testing/power-benchmark.md) | Configuration manifest, per-process CPU/GPU, whole-machine and package-power measurement, runtime counters, condition matrix and comparison rules for power claims |
| [testing/verification-log.md](testing/verification-log.md) | Dated verification history, ten newest entries |
| [testing/archive/](testing/archive/) | Retired verification-log entries, one file per month, written by `scripts/log_verification.py`; historical only |
| [testing/wallpaper-corpus.md](testing/wallpaper-corpus.md) | Local regression corpus checklist |
| [testing/wallpaper-fixes.md](testing/wallpaper-fixes.md) | Triaging and fixing a wallpaper that looks wrong: download, Wallpaper Engine frames, probe scenes, test-first fix, before/after comparison, cleanup |
| [testing/wallpaper-engine-reference.md](testing/wallpaper-engine-reference.md) | Comparing a wallpaper with Wallpaper Engine's own frames from a Parallels Windows VM (`scripts/we_reference.py`): capture, render, compare, noise floor |

## Archive

Historical records kept for provenance, never for current guidance. `rg` skips
`docs/archive/` and `docs/testing/archive/` through the repository `.ignore`
file; pass `rg -u` to search them deliberately.

| Document | Purpose |
|---|---|
| [archive/improvement-plan.md](archive/improvement-plan.md) | 2026-09 power-first source review and work-package plan (Chinese) |
| [archive/implementation-progress.md](archive/implementation-progress.md) | Task-by-task implementation record for that plan |

## Product features

| Document | Purpose |
|---|---|
| [features/control-panel.md](features/control-panel.md) | The native window: language, tabs, toolbar, grid and inspector, pages and Settings, selection versus apply, Now Playing, target display, filtering and local collections, recently used, deleting, downloads and import |
| [features/first-run.md](features/first-run.md) | The first-run guide over the window, the one-time support prompt after the first downloaded wallpaper, the later star prompt and the performance data question |
| [features/wallpaper-properties.md](features/wallpaper-properties.md) | Inspector properties, live preview, property presets, image placement, the compatibility check and the black-bar check |
| [features/library-location.md](features/library-location.md) | Settings → Storage → Wallpaper library location: moving the library and downloads to another folder or an external drive and back, what moves, the copy now and the switch at the next launch, a drive that is not connected |
| [features/backup-restore.md](features/backup-restore.md) | The Settings → Storage backup package (settings, allowlisted preferences, chosen user files) and restoring it |
| [features/updates.md](features/updates.md) | In-app update checks, download and verification, installing, and the What's New window |
| [features/workshop-downloads.md](features/workshop-downloads.md) | Discover, SteamCMD setup, download queue |
| [features/automation.md](features/automation.md) | Weekday/time/solar/appearance rules, temporary Focus choices, global shortcuts, Shortcuts actions for wallpapers/playlists/presets, and `wallpapermachine://` links |
| [features/display-layouts.md](features/display-layouts.md) | Saved multi-display wallpaper arrangements, copy/swap, preflight and recovery, Shortcuts, backup, mirror sets, AirPlay and a closed lid, and the per-Space boundary |
| [features/spaces.md](features/spaces.md) | A different wallpaper for each desktop: choices by desktop UUID, windows kept on their desktop, saved posters for the others, visit/manual/Focus semantics and verification limits |
| [features/wallpaper-switching.md](features/wallpaper-switching.md) | The switch hold: the previous picture stays on screen, then fades, while a newly chosen wallpaper loads; which switches it covers, its limits and Reduce Motion |
| [features/desktop-picture.md](features/desktop-picture.md) | The static desktop picture macOS shows (Mission Control, after quit): posters, the journal of originals, refused writes, macOS 27, restoring on quit |
| [features/playlists.md](features/playlists.md) | Per-display rotation and day/night selection, local collection sources, reusable named plans, scheduling and storage |
| [features/pixiv.md](features/pixiv.md) | pixiv page: rankings and tag search, saving a page as a still wallpaper, pixiv sign-in and R-18 works |
| [features/audio-response.md](features/audio-response.md) | Audio response setting, system-audio capture permission, spectrum analysis and what scene and web wallpapers receive |
| [features/web-wallpapers.md](features/web-wallpapers.md) | HTML/JS wallpapers hosted in a web view, host protocol, limits |
| [features/user-files.md](features/user-files.md) | Files and folders chosen for wallpaper properties: the managed copy, its lifetime and cleanup, lock-screen publication and the inspector |
| [features/media-integration.md](features/media-integration.md) | Now-playing metadata and covers for scene and web wallpapers: the bundled MediaRemote adapter first, AppleScript as fallback |
| [features/lock-screen.md](features/lock-screen.md) | Experimental animated lock screen and wallpaper-as-screen-saver |
| [features/appearance.md](features/appearance.md) | Theme, accent and tone, the window's native materials, the app icon, and brand asset generation |
| [features/performance.md](features/performance.md) | Energy readout and per-wallpaper ratings, quality and playback settings, video playback, experimental switches, and background work only while it has a consumer |
| [features/scene-rendering.md](features/scene-rendering.md) | The scene renderer (Native Metal only, and what a scene it cannot draw does), scene render optimisation, skipping frames that would repeat, renderer memory and repeated-work reduction |
| [features/crash-recovery.md](features/crash-recovery.md) | The load journal (a wallpaper that was being opened when the app died twice in a row is held back at launch, how strikes, the settle window and release by Apply, the panel's Try again or an update work, the banner and menu line), SIGTERM and SIGHUP as a quit, broken pipes, the one-copy-per-library lock and what a second launch does, and the limits |
| [features/telemetry.md](features/telemetry.md) | Send performance data: what a report holds (no free text, Workshop ids only), the daily upload, 60 s frame windows and their cost, local files, deletion when turned off, and the website endpoint |
| [features/diagnostics.md](features/diagnostics.md) | Application log format, load tagging and the line each wallpaper activation leaves, detailed logging, retention, how the log says the previous session ended, and the diagnostics report users attach to bug reports |

## Maintaining these docs

Add every new document to the table for its group and remove deleted ones: a
document that is not listed here does not exist as far as readers are
concerned. The writing rules — one topic per file, naming, grounding claims in
the repository, the verification log, no disposable artifact paths as evidence —
are in [conventions.md](conventions.md#documentation).
