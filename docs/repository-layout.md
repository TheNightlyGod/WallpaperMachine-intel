# Repository layout

What each directory holds, where new code goes, and which paths are generated or disposable.
For how the pieces interact at runtime, see [architecture.md](architecture.md).

## Tree

```
AGENTS.md                          agent rules; authoritative for automated contributors
CLAUDE.md -> AGENTS.md              Claude entry point; relative symlink, same rules
CHANGELOG.md                       published versions, newest first; written by scripts/release_notes.py
CODE_OF_CONDUCT.md                 conduct expected in the project's spaces and how it is enforced
CONTRIBUTING.md                    contributor working agreement
LICENSE                            GNU GPL version 3 text; the license of this repository's source
LICENSING.md                       GPL-3.0-only policy, Supporter model, component licenses and distribution blockers
README.md                          product overview after the website, build quickstart, FAQ, sponsor list (written by scripts/update_sponsors.py), documentation index
README.zh-CN.md                    README.md in 简体中文; change both together (same sponsor list block)
SECURITY.md                        private vulnerability reporting, supported versions and scope
SPONSORS.md                        Supporter pricing, benefits and other ways to help; follows the website's pricing page
project.yml                        XcodeGen spec: the only source of truth for targets/settings/versions
WallpaperMachine.xcodeproj/        generated from project.yml by xcodegen; committed, never hand-edited
App/                               WallpaperMachine application target sources only
  WallpaperEngineApp.swift         @main AppKit entry point; no scene/UI logic
  AppDelegate.swift                lifecycle, menu bar, window and shutdown ordering
  Bridge/                          WallpaperPreviewBridge.h (scene C API for previews)
                                   and Generated/ (uniffi output; not hand-edited)
  Logging/                         AppLog.swift (the only Swift logging entry point) and its router
  Services/<Domain>/               domain logic and stores, one folder per domain:
    Appearance/                    AppTheme.swift: theme preference model and store
    Automation/                    keyboard shortcuts, App Intents, links, weekday/solar/appearance selection rules,
                                   temporary Focus choices with restoration, and the menu bar menu's layout
                                   (StatusMenuModel: flat for one display, a submenu per display for more)
    Desktop/                       multi-display copy/swap and recovery, desktop picture APIs, original-wallpaper ledger,
                                   scoped poster sync, read-only Space topology, presentation policy, playback rules,
                                   system conditions, display refresh and the screen shape of a display id
    Diagnostics/                   runtime diagnostics session, diagnostics report, session ledger, counter sampling, energy readout,
                                   memory-pressure log and per-wallpaper energy ratings
    GitHub/                        GitHub release client, update models, update store, installer, what's-new records
    Library/                       ClientPaths (owns the app-support layout), import/deletion, still-image wallpapers,
                                   collections, presets, history, compatibility checks, the video black-bar check, backup and restore
    Lifecycle/                     why the app is quitting (QuitReason, the power-off notice), how long each quit stage takes
                                   (QuitTimings), the deadline each stage gets (QuitSupervisor, QuitMode, the exit fuse)
                                   and SIGTERM/SIGHUP as a quit (TerminationSignalRelay);
                                   ProcessSignals makes a broken pipe a write error;
                                   the one-copy-per-library lock and the second launch's hand-over
                                   (InstanceLock, SingleInstance)
    Localization/                  AppLanguage.swift: shipped-language registry and the language preference store
    LockScreen/                    lock-screen selection overrides, extension registration and configuration publishing
    NativeVideo/                   native video backend: the AVFoundation player and the WebM player's window, the
                                   host, and the format check Apply uses (the admission rule, the layout rules
                                   and the WebM player itself are in Shared/)
    Pixiv/                         pixiv browsing, sign-in session, downloads and still-wallpaper packaging
    Playlist/                      per-display playlists: model, planner, store and the scheduler that switches wallpapers
    Preview/                       isolated live preview inputs, lifecycle, WebKit and scene/video surfaces
    Steam/                         SteamCMD runtime discovery and setup state
    Support/                       the one-time prompts: support after a downloaded wallpaper is applied,
                                   the later star request and the performance data question
    SystemMedia/                   shared now-playing session (MediaRemote, Music/Spotify
                                   AppleScript fallback) and artwork for Web and Scene media integration
    Telemetry/                     Send performance data: report schema, frame windows, local spool, upload;
                                   the daily active count
    UserAssets/                    importing, watching and picking for file/directory wallpaper properties;
                                   owns the app's copies under <support>/UserAssets/ and the derived,
                                   regenerable <project>/.mwe-user-assets/ bridge a page can read
    WebWallpaper/                  WKWebView host windows and page protocol for web wallpapers
    Workshop/                      Workshop query model and sources, browse store, downloader and queue
  ViewModels/                      BridgeStore and editor draft state; observable, no view code
  Views/ControlPanel/              the SwiftUI control panel: root view, navigation types, window factory and
                                   reopen state, and the AppKit sign-in, preview and what's-new windows
    Model/                         PanelController, its typed actions and derived state (PanelController+<Group>.swift),
                                   presentation, store revisions, error banner, action coordinator, dialogs, links
    Shell/                         root view, tabs, detail column (router, toolbar, banners, Filters sidebar, inspector), Now Playing bar
    Library/ Inspector/            the Installed page and the installed wallpaper's inspector
    Discover/ Downloads/           the Steam Workshop page and its inspector; the downloads button, list and dialog
    Pixiv/                         the pixiv page, its inspector and toolbar pill
    Settings/                      Settings infrastructure (rows, groups, search) and the eleven sections
    Welcome/                       the first-run guide and the support prompt
    Components/ Theme/             shared views; accent and surface palettes
    Localization/ Images/          PanelLocale and L(); the image pipeline and animated preview
  Resources/                       Info.plist, string catalogs, Assets.xcassets (tray icon, Dock icon image sets),
                                   AppIcon.icon; app resources only
Extension/                         WallpaperMachineExtension sources, Info.plist, entitlements, bridging header,
                                   its own string catalog (Localizable.xcstrings), third-party notice
Shared/                            contracts compiled into both targets: lock-screen configuration, status and surface
                                   lifecycle, web-wallpaper protocol and screen-saver surface, RuntimeCounters,
                                   WallpaperPresentationAuthority, display power and its re-check burst,
                                   the native video admission and layout rules, the WebM player and its
                                   opening (WebMPlayer, WebMOpening), the recovery budget, and the lock-screen
                                   video planner and player
Resources/StarterWallpaper/        bundled sample wallpaper (Aurora.mp4, preview.jpg, project.json)
Resources/ReleaseBanners/          bundled release banners, x.y.z.jpg and x.y.z.zh-Hans.jpg (or .png), shown by What's New and the release page
Tests/Unit/<Domain>/               WallpaperMachineTests, one folder per App/Services domain plus Panel for
                                   Views/ControlPanel; hosted in the app binary
Tests/UI/                          WallpaperMachineUITests; desktop-driving XCUITest suite
docs/                              all project documentation; see docs/README.md for the index
  features/                        product behavior, one document per feature
  testing/                         test strategy, renderer checks, verification log
  archive/                         retired plans and records; rg skips them (repository .ignore, `rg -u` to search)
scripts/                           developer command line; Python only
  lib/                             shared helpers (glyphs.py status markers, paths.py repo paths,
                                   xcode.py quiet runner: full tool output to artifacts/, failures on screen,
                                   dmg.py drag-to-install disk image, bundle_contract.py signed entitlements and
                                   Info.plist keys of the built app, wordmark.py logo outlines for brand.py)
  tests/                           unit tests for the scripts, run by scripts/test.py
Packaging/dmg/                     disk-image window background (background.png, @2x); generated by scripts/brand.py --dmg
Renderer/                          the renderer, this project's code: the Rust workspace and the C++ scene engine with
                                   the static libraries its CMake includes; .gitignore keeps cargo's target/ out
  Cargo.toml, Cargo.lock,          the Rust workspace: Shader/, Core/ and Bridge/
  rust-toolchain.toml
  Bridge/                          wallpaper-bridge: the UniFFI API the app calls (actor, engine facade, configuration,
                                   library, displays, user assets, logging, power), built as libwallpaper_bridge.a
                                   and the uniffi-bindgen binary
  Core/                            wallpaper-core: the runtime (scene reconciliation, displays, wallpaper windows, media,
                                   audio capture) and owe/, the bindgen FFI to the engine; build.rs builds Engine/
  Engine/                          the C++ scene engine (wescene-renderer): src/ (parsers, scene model, render graph,
                                   Native Metal renderer, scripting, audio, video, platform host), tests/ (googletest
                                   binaries registered in scripts/check_renderer.py), Dependencies/ (targets for the
                                   vendored C libraries in ThirdParty/ and the Homebrew packages)
  Media/                           wmMedia: the container readers (ISO-BMFF/MP4, Matroska/WebM), pure C++ with no Apple or
                                   third-party dependency, their shared byte source, error and cursor types, and tests/
                                   (see container-readers.md)
    Apple/                         wmMediaApple: the platform layer of the readers, ObjC++ over VideoToolbox with C++
                                   headers: codec format descriptions and a decompression session that returns frames in
                                   display order; WebMReader.h/.mm, the Objective-C face of the Matroska reader that
                                   Swift imports (`import WallpaperMedia`, WallpaperMedia.modulemap); its tests/
                                   (vt_frame_decoder_test, webm_reader_test) are built by the engine's tests
  Sound/                           wmSound: the scene-sound path (channel remix, resampler, loop pipeline, the
                                   AudioToolbox decoder and the Ogg Vorbis decoder over the vendored stb_vorbis),
                                   Matroska/ (the audio track of a WebM or Matroska file as PCM), tests/
                                   (see sound-decoding.md)
  Shader/                          wm-shader: the shader layer (Wallpaper Engine shader text to Metal Shading Language,
                                   reflection, the C ABI of include/rs_shader.h behind the `ffi` feature), written
                                   from a clean-room specification; NOTES.md records its choices; tests in src/ and tests/.
                                   wallpaper-core links it as a path crate (`wm-shader` with `ffi`)
  Surface/                         wmSurface: the still preview a wallpaper that cannot be drawn shows instead of an empty
                                   layer (ImageIO and Core Animation, ObjC++ with a C++ header) and the pure rule that
                                   keeps the picture inside the project's folder; tests/ (see scene-rendering.md)
  Testing/                         synthetic video for the renderer tests: a VideoToolbox H.264 encoder (with and without
                                   B-frames) and an AVAssetWriter passthrough writer behind a C++ header, its own test,
                                   and two small embedded clips (VP9 in WebM, H.264 with B-frames in Matroska)
ThirdParty/                        vendored third-party code only, each item under its own license
  provenance.json                  repositories, pinned revisions, modification status, and the record of the imported
                                   renderer's origin and clean-room rewrite
  mediaremote-adapter/             ungive/mediaremote-adapter, BSD-3-Clause; built as an embedded framework
  miniaudio/                       miniaudio 0.11.21 (public domain or MIT-0); the engine's audio output device
  naga/                            naga 29.0.3 (MIT OR Apache-2.0, used under MIT), patched so codespan-reporting is
                                   optional (PATCHES.md lists the differences); a path dependency of Renderer/Cargo.toml
  stb_image/                       stb_image 2.26 (public domain or MIT); the engine's image decoder
  stb_vorbis/                      stb_vorbis 1.22 (public domain or MIT, unchanged); the Ogg Vorbis decoder
  received-licenses/               the GPLv2 texts the imported renderer and scene engine arrived under (a record; that
                                   code is only in Git history)
artifacts/                         Git-ignored: all test and verification evidence
build/                             Git-ignored: Xcode derived data and built products only
.github/FUNDING.yml                the repository's Sponsor button; links the website's pricing page
.github/ISSUE_TEMPLATE/            issue forms (bug report, feature request) and the chooser's links (config.yml);
                                   blank issues stay on for the prefilled link of app versions up to 1.6.0
.github/pull_request_template.md   the pull-request description outline and checklist
.github/workflows/                 CI: build.yml, release.yml, version.yml, warm-caches.yml, supporters.yml,
                                   codeql.yml, claude.yml and claude-code-review.yml
.github/actions/prepare-build/     composite action: Xcode, Homebrew packages and the build caches
```

Git-ignored and machine-local, never committed: `artifacts/`, `build/`, the agent tool
directories and `CLAUDE.local.md` named in `AGENTS.md`, and the root `node_modules/`,
`package.json` and `package-lock.json` (local agent tooling; the repository has no npm build).

Things that must not appear:

- No product code under `ThirdParty/` — it is vendored third-party code only (the MediaRemote
  adapter, the patched `naga` crate, the scene engine's C libraries); renderer code goes in
  `Renderer/`.
- No app-target code under `Shared/`; it must stay compilable with
  `APPLICATION_EXTENSION_API_ONLY`.
- No generated Xcode settings edited in `WallpaperMachine.xcodeproj`; change `project.yml`.
- No test output, logs or `.xcresult` bundles anywhere but `artifacts/`.
- No shell scripts in `scripts/`; the command surface is Python.

## Where does new code go?

| You are adding | Put it in | Notes |
|---|---|---|
| App service or domain logic | `App/Services/<Domain>/` | Reuse an existing domain folder before creating one; a new domain needs a new folder plus a matching `Tests/Unit/<Domain>/` |
| Control-panel view or feature | `App/Views/ControlPanel/<Area>/` | Views and the area's view model in the area folder; a typed action or derived state in `Model/PanelController+<Group>.swift`; a view several areas use in `Components/`. Rules in [conventions](conventions.md#swiftui-control-panel) |
| Observable app state | `App/ViewModels/` | Keep renderer calls behind `BridgeStore`; no views here |
| A language | `App/Services/Localization/AppLanguage.swift`, all three `.xcstrings` | Follow [localization.md](localization.md); the Settings and first-run pickers derive from `AppLanguage.supported` |
| Code shared with the extension | `Shared/` | Only if both targets genuinely need it, and it must build extension-API-only |
| Lock-screen extension behaviour | `Extension/` | Nothing here may depend on app-only APIs or app-private files |
| Unit test | `Tests/Unit/<Domain>/` | Same domain folder name as the code under test |
| UI test | `Tests/UI/` | Runs only via `scripts/test.py --ui`; it takes over the desktop |
| Developer script | `scripts/<name>.py` | `snake_case.py`, argparse flags, no shell wrappers |
| Shared Python helper | `scripts/lib/` | With a test in `scripts/tests/` |
| Documentation | `docs/`, `docs/features/` (product behavior) or `docs/testing/` | Add it to the index in [README.md](README.md); one topic per file |
| Rust crate or scene-engine change | `Renderer/Core/`, `Renderer/Bridge/`, `Renderer/Shader/`, `Renderer/Engine/` | Engine tests in `Renderer/Engine/tests/`, registered in `scripts/check_renderer.py`; Rust tests run by `scripts/check_rust.py` |
| New renderer area (container readers, the sound path, test support such as the synthetic video writer) | `Renderer/<Area>/` | Never under `ThirdParty/`; written from public specifications and Apple documentation, never copied from another implementation. Pure C++17 until a layer needs a platform API; headers are included as `"<Area>/<Header>.hpp"`; tests in `Renderer/<Area>/tests/`, registered in `scripts/check_renderer.py` (`REGRESSION_BINARIES`). The engine build includes it from `Renderer/Engine/CMakeLists.txt` (`Renderer/Testing` from its `tests/CMakeLists.txt`) |
| Generated code | nowhere by hand | Regenerate via `scripts/build.py`; commit only what the tooling produces |
| Evidence, logs, result bundles | `artifacts/` | Disposable; never committed |

## Generated, vendored and ignored

| Path | Status |
|---|---|
| `WallpaperMachine.xcodeproj/` | Generated by `xcodegen generate` from `project.yml`, and committed. Regenerate rather than edit. |
| `App/Bridge/Generated/` | Produced by `scripts/build.py` (`uniffi-bindgen` over `libwallpaper_bridge.a`). Hand edits are overwritten. |
| `ThirdParty/` | Vendored third-party code, governed by `ThirdParty/provenance.json` and [../LICENSING.md](../LICENSING.md). |
| `Packaging/dmg/` | Generated by `python3 scripts/brand.py --dmg` and committed; `scripts/package.py` lays the disk-image window over it. Regenerate rather than edit. |
| `artifacts/` | Disposable, Git-ignored. Test and verification evidence, including the full `xcodebuild`/`cargo` logs the scripts keep off the terminal; removable with `scripts/clean.py`. |
| `build/` | Disposable, Git-ignored. Xcode derived data and built products only. |
| `.ignore` | Paths `rg`/`fd` skip by default: `docs/archive/`, `docs/testing/archive/`, `App/Bridge/Generated/`, `ThirdParty/`. `rg -u` searches them. |

## Naming

| Kind | Convention |
|---|---|
| Swift source | `UpperCamelCase.swift` matching its primary type (`BridgeStore.swift`, `WallpaperSurface.swift`) |
| Swift files holding a family of types | Named after the concept, not one type (`AppTheme.swift`, `AppUpdateModels.swift`) |
| Swift tests | `<Subject>Tests.swift`, in the domain folder of the code under test |
| Python scripts and helpers | `snake_case.py` (`build.py`, `check_renderer.py`, `bump_version.py`, `release_notes.py`, `publish_release.py`, `lib/xcode.py`, `lib/dmg.py`) |
| Python tests | `test_<module>.py` under `scripts/tests/` |
| Control-panel tests | flat in `Tests/Unit/Panel/`, named after the type or area they cover (`PanelErrorStateTests.swift`, `InstalledBrowserModelTests.swift`, `ShellRenderTests.swift`) |
| Markdown under `docs/` | lowercase-hyphenated (`repository-layout.md`, `development-tools.md`); `README.md` is the only uppercase name |
| Root Markdown | uppercase (`README.md`, `AGENTS.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `LICENSING.md`); the license text is the extensionless `LICENSE` |
| Bundle identifiers | `app.wallpapermachine` and `app.wallpapermachine.wallpaper-extension` (plus `.MediaRemoteAdapter`, `.tests` and `.uitests` for the other targets) |
