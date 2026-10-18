# Building WallpaperMachine

Authoritative build document. Everything here is driven by `scripts/build.py` and
`scripts/package.py`; the Xcode project itself is generated from
[`project.yml`](../project.yml) and must never be edited by hand.

## Prerequisites

| Requirement | Detail |
|---|---|
| Hardware | Apple Silicon only. `project.yml` sets `ARCHS: arm64`, and release disk images are named `-arm64`. |
| macOS | The app runs on macOS 15 or later (`project.yml` pins `deploymentTarget.macOS` and `MACOSX_DEPLOYMENT_TARGET` to `15.0`; `scripts/build.py` passes the same value to the renderer as `OWE_MACOSX_DEPLOYMENT_TARGET`); building needs Xcode 26, so macOS 15.6 or later. Bundled Homebrew dylibs keep the release they were built on, so a package made on a newer macOS requires that newer release (see [packaging](#packaging-and-installing)); CI builds the published image on a `macos-15` runner for that reason. The lock-screen extension stays off below macOS 26. |
| Xcode | A full Xcode selected with `xcode-select`. The build reads `xcode-select -p` for the toolchain and `xcrun --sdk macosx --show-sdk-path` for the SDK. Command Line Tools alone are not enough. |
| Homebrew | Provides every renderer dependency; `brew --prefix` is queried at build time. |
| XcodeGen | `xcodegen` must be on `PATH`. Every build runs `xcodegen generate --use-cache`, which regenerates the project when `project.yml` changed. |
| Python | System `python3` runs all of `scripts/`. |
| Rust | `cargo` must be on `PATH` for the renderer stage. |

Homebrew packages the renderer links against, exactly as listed in
`build_environment()` in `scripts/build.py`:

```sh
brew install quickjs-ng glslang freetype lz4 vulkan-loader \
  vulkan-headers molten-vk eigen nlohmann-json argparse shaderc spirv-tools glm
python3 scripts/install_ffmpeg.py
```

Plus the build tooling those packages are compiled and consumed with:

```sh
brew install rust cmake ninja pkg-config xcodegen
```

Steam Workshop downloads additionally need SteamCMD, which the app installs and
manages itself at run time; it is not a build dependency. See
[features/workshop-downloads.md](features/workshop-downloads.md#steamcmd-setup).

FFmpeg is not Homebrew's `ffmpeg` formula but the repository's own
`Formula/mwe-ffmpeg.rb`: an LGPL-2.1-or-later library set (`--disable-gpl
--disable-version3 --disable-nonfree --disable-autodetect`; native decoders and
encoders, libdav1d, and VideoToolbox/AudioToolbox; no network or device
support), because Homebrew's build is GPLv3 and links OpenSSL, neither of which
the GPL-2.0-only application may bundle ([../LICENSING.md](../LICENSING.md)).
`scripts/install_ffmpeg.py` publishes the formula into a local git-less tap
(`WallpaperMachine/local`), installs it, and reinstalls it when the formula
file or the installed receipt differs from it; `--check` only reports.
`scripts/package.py` refuses to bundle FFmpeg libraries that are not an LGPL
build (see [Packaging and installing](#packaging-and-installing)).

`mwe-ffmpeg` is keg-only and reached through `pkg-config`, but Homebrew links
any FFmpeg formula that is not keg-only into the shared `/opt/homebrew/include`,
and several other dependencies put that prefix on the include path. Different
majors' `AVFrame` and `AVCodecContext` differ by removed members, so compiling
against one and linking the other is accepted by the compiler and then reads
frame metadata at the wrong offsets at runtime. The renderer's CMake therefore
pins the resolved FFmpeg prefix ahead of every other include directory
(`wescene_prefer_ffmpeg_headers`), and the decode and probe entry points refuse
to run when the loaded libav* majors are not the compiled ones. If you see that
refusal, an include path is reaching a second FFmpeg before the one
`pkg-config` chose.

## The build environment

`scripts/build.py` does not rely on your shell environment for the renderer. It
copies the current environment and overrides the variables below, so the same
command produces the same build from a terminal, an editor, or CI.

| Variable | Value | Why |
|---|---|---|
| `PATH` | `$(brew --prefix)/bin` prepended | Finds Homebrew `cmake`, `ninja`, `glslangValidator` and friends ahead of anything else. |
| `CMAKE_PREFIX_PATH` | `;`-joined `opt/<package>` roots plus the Homebrew prefix | CMake resolves each dependency from its own keg, including keg-only ones like `mwe-ffmpeg`, instead of guessing. |
| `PKG_CONFIG_PATH` | `:`-joined `opt/<package>/lib/pkgconfig` | `pkg-config` consumers (FFmpeg, freetype, lz4) find the matching `.pc` files. |
| `OWE_NIX_LIBRARY_PATH` | `:`-joined `opt/<package>/lib` plus `<prefix>/lib` | The vendored scene engine's build scripts use this to locate native libraries to link. |
| `LIBCLANG_PATH` | `$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib` | Rust `bindgen`/`uniffi` need `libclang` from the selected Xcode toolchain. |
| `SDKROOT` | `xcrun --sdk macosx --show-sdk-path` | Pins C/C++/Rust compilation to the selected macOS SDK. |
| `CC` / `CXX` | `/usr/bin/clang`, `/usr/bin/clang++` | Apple Clang, not a Homebrew LLVM that happens to be first on `PATH`. |
| `MACOSX_DEPLOYMENT_TARGET` | `15.0` | Set for `xcodegen` and `xcodebuild`. Deliberately **not** in cargo's environment: cargo builds proc-macro crates for the host and dlopens them in the running compiler, and a pinned host dylib is rejected at load with `mis-aligned LINKEDIT`, which the compiler reports as `can't find crate for <macro>`. |
| `OWE_MACOSX_DEPLOYMENT_TARGET` | `15.0` | The same value under a name cargo ignores. The renderer crate's build script passes it as `CMAKE_OSX_DEPLOYMENT_TARGET`, so the C++ engine keeps the minimum the app links against. |
| `GIT_SHORT_COMMIT` | `git rev-parse --short HEAD` in the repository root | Stamps the build with the revision it was built from; Settings shows it as `Git revision`. The renderer build runs with `upstream/renderer` as its working directory, so HEAD is resolved against the repository root explicitly. |

## Stages and outputs

```sh
python3 scripts/build.py                          # Debug, everything
python3 scripts/build.py --configuration Release  # Release, everything
python3 scripts/build.py --swift-only             # skip the renderer
python3 scripts/build.py --renderer-only          # renderer + bindings only
python3 scripts/build.py --compile-app-icon DIR   # only compile AppIcon.icon + Assets.xcassets into DIR
python3 scripts/build.py --app-icon DIR           # build with that output instead of compiling the icon
python3 scripts/build.py --xcode-setting N=V      # also pass build setting N=V to xcodebuild (repeatable)
```

`--configuration` accepts `Debug` (default) or `Release`.

`--compile-app-icon` runs `actool` with the arguments Xcode uses for this target and
writes `Assets.car`, `AppIcon.icns` and `partial-info.plist`. `--app-icon` builds
with `AppIcon.icon` excluded (`EXCLUDED_SOURCE_FILE_NAMES`, empty
`ASSETCATALOG_COMPILER_APPICON_NAME`), then copies those files into the bundle,
merges the Info.plist keys and re-signs it ad hoc. Both exist because on macOS 15
Xcode 26's `actool` crashes on most `.icon` compiles: CI compiles the icon on
macOS 26 ([release.md](release.md#build-buildyml)), and a local build on macOS 15
can do the same (see Troubleshooting). A build on macOS 26 never needs them.

1. **Renderer** — `cargo build --workspace --release` in `upstream/renderer`.
   The Rust crates and the C++ scene engine are always built in release mode,
   independently of `--configuration`. Output lands in
   `upstream/renderer/target/release`, including the static library
   `libwallpaper_bridge.a` the app links as `-lwallpaper_bridge`.
2. **Swift bindings** — `upstream/renderer/target/release/uniffi-bindgen generate
   --library …/libwallpaper_bridge.a --language swift --no-format --out-dir
   App/Bridge/Generated`. This writes `WallpaperBridge.swift` plus the FFI header
   and module map. `App/Bridge/Generated` is build output: never edit it, and
   regenerate it whenever the bridge crate's interface changes.
3. **Project generation** — `xcodegen generate --use-cache` rewrites
   `WallpaperMachine.xcodeproj` from `project.yml`, and leaves it (and Xcode's
   incremental build state) untouched when `project.yml` has not changed.
4. **Xcode build** — `xcodebuild -project WallpaperMachine.xcodeproj -scheme
   WallpaperMachine -configuration <cfg> -derivedDataPath build build`. The app
   target embeds the `WallpaperMachineExtension` ExtensionKit extension.
   It also builds and embeds the unlinked `MediaRemoteAdapter.framework` from
   the pinned BSD-3-Clause sources under `upstream/mediaremote-adapter`, and
   includes its Perl entry point and license as app resources. Building or
   testing does not launch that helper.

Products:

| Path | Contents |
|---|---|
| `build/Build/Products/Debug/WallpaperMachine.app` | Debug app, used by `scripts/test.py` |
| `build/Build/Products/Release/WallpaperMachine.app` | Release app; this is the bundle the user runs, who quits and reopens it to load a new build |
| `upstream/renderer/target/release/` | Renderer static libraries (`libwallpaper_bridge.a`, `libshader.a`) and `uniffi-bindgen` |
| `App/Bridge/Generated/` | Generated uniffi Swift bindings |

`build/` is Git-ignored and disposable, but it holds the locally delivered app:
`python3 scripts/clean.py --all` removes it entirely.

Each stage's complete output is written to `artifacts/build/<stage>-<timestamp>.log`
(`cargo`, `bindgen`, `xcodegen`, `xcodebuild-<Configuration>`, plus `actool` and
`codesign` for the app icon); the terminal only shows compile errors, `The
following build commands failed:` and the final product path. Pass `--verbose`
to see the raw stream as well, or open the log named in the failure line.

### Choosing a mode

| Mode | Use when | Requires |
|---|---|---|
| Full (no flag) | Renderer, bridge crate, or first build of a clean checkout. | All prerequisites. |
| `--swift-only` | Only Swift, resources, or `project.yml` changed. | `upstream/renderer/target/release/libwallpaper_bridge.a` and `App/Bridge/Generated` must already exist from an earlier full build. |
| `--renderer-only` | Iterating on Rust/C++ or the uniffi interface without needing an app bundle. | Nothing further; it stops after regenerating bindings. |

## Packaging and installing

```sh
python3 scripts/package.py --configuration Release            # bundle, sign, write the disk image
python3 scripts/package.py --configuration Release --check    # preflight only; the bundle is unchanged
python3 scripts/package.py --configuration Release --install  # also copy the app to ~/Applications
```

CI adds `--require-deployment-target` and `--sign-identity` (see the preflight and
[Release signing](#release-signing)).

`scripts/package.py` takes the already-built bundle at
`build/Build/Products/<configuration>/WallpaperMachine.app`, makes it
self-contained, and wraps it in the drag-to-install disk image
`WallpaperMachine-<version>-arm64.dmg` with its `.sha256` sidecar beside the app.
It exits with `Build the application first using scripts/build.py` when that
bundle is absent.

0. **Preflight**, before anything is modified (`--check` runs only this step
   and leaves the bundle unchanged):
   - The bundle must be fresh build output. A bundle that already carries
     `Contents/Frameworks/*.dylib`, or whose app/extension binaries already
     load a non-Swift `@rpath` dependency, is refused (`Packaging requires
     fresh, unrelocated build output`): packaging is one-way and never deletes
     anything from an existing bundle, and an incremental `scripts/build.py`
     run does not clear `Contents/Frameworks`. The fix is a clean build, but
     **`python3 scripts/clean.py --all` deletes `build/` entirely, including
     `build/Build/Products/Release/WallpaperMachine.app`, the locally delivered
     app.** Preview with `--dry-run`, keep a copy of any app you still need,
     and only then clean and rebuild; nothing cleans automatically.
   - Every FFmpeg library the app links (`libav*`, `libsw*`, `libpostproc`) is
     inspected at the resolved Homebrew file it would copy: the license string
     FFmpeg's configure embeds must be exactly `LGPL version 2.1 or later` and
     the embedded configure line must not contain `--enable-gpl`,
     `--enable-version3` or `--enable-nonfree`. Otherwise it exits 1 with
     `MISSING Refusing to bundle FFmpeg libraries that are not an LGPL build
     (install the project's with python3 scripts/install_ffmpeg.py; see
     LICENSING.md):` and one line per offending library.
   - The notice payload must exist: repository `LICENSE`, `LICENSING.md`,
     `upstream/renderer/LICENSE`, `upstream/provenance.json`, the
     Xcode-bundled `Resources/LICENSE` (mediaremote-adapter, BSD-3-Clause) and
     the extension's `Phosphene-LICENSE.txt`, and a `LICENSE*`/`COPYING*`/
     `COPYRIGHT*`/`NOTICE*` file in every Homebrew keg the link closure
     reaches. Otherwise `MISSING Missing license payload:` lists what is
     absent.
   - The disk image's inputs must be usable: `Packaging/dmg/background.png`, its
     `@2x` twin at exactly twice its pixel size, and the bundle's
     `Resources/AppIcon.icns`. Otherwise `Missing disk image input:` or
     `… not twice …` names the file, and since nothing has been touched yet,
     regenerating the art and rerunning is enough.
   - Every library to bundle is checked with `vtool -show-build` against the
     bundle's `LSMinimumSystemVersion` (the deployment target). A Homebrew
     bottle records the release it was built for, so on a newer host some
     libraries need a newer macOS than the app claims. By default packaging
     prints `MISSING Bundled libraries need macOS <version>…` and later raises
     `LSMinimumSystemVersion` to that release, so macOS declines to open the app
     instead of it failing to load a library. `--require-deployment-target`,
     which the release workflow passes, exits 1 instead.
1. **Dylib relocation.** Starting from `libMoltenVK.dylib` and the app and
   extension binaries, it walks `otool -L` transitively. Every dependency under
   the Homebrew prefix is copied into `Contents/Frameworks`, given an
   `@rpath/<name>` install name, and rewritten in its dependents with
   `install_name_tool -change`. Absolute `LC_RPATH` entries pointing into the
   Homebrew prefix or the repository are deleted, and
   `@executable_path/../Frameworks` (or `@executable_path/../../../../Frameworks`
   for the embedded `.appex`) is added instead.
2. **MoltenVK ICD.** A `MoltenVK_icd.json` is written into the app's `Resources`
   and into each extension's `Resources`, each pointing at the bundled
   `libMoltenVK.dylib` with the correct relative depth, so Vulkan resolves the
   portability driver inside the bundle.
3. **License payload.** The root `LICENSE` is copied in as
   `WallpaperMachine-LICENSE.txt`, `LICENSING.md` as `LICENSING.md`,
   `upstream/renderer/LICENSE` as `Renderer-LICENSE.txt`,
   `upstream/provenance.json` as `provenance.json`, each bundled keg's notices
   under `Licenses/<formula>-<version>/`, and the notices of the third-party
   code statically linked into the renderer under
   `Licenses/renderer-third-party/`. `Licenses/` is rebuilt on every run.
4. **Signing.** Each bundled dylib, then each extension
   (`--preserve-metadata=entitlements`), then the app are signed with
   `--sign-identity` (default `-`, ad hoc), and the result is checked with
   `codesign --verify --deep --strict`. Release builds use the project
   certificate; see [Release signing](#release-signing). Nothing is notarized;
   see [../LICENSING.md](../LICENSING.md#signing-and-notarization).
   A valid signature does not say what it signs, so the bundle is then read back
   against its [contract](#bundle-contract).
5. **Dependency audit.** Every binary is re-scanned. A remaining Homebrew-prefixed
   load command fails with `Unbundled dependency: …`; an `@rpath` dependency with
   no matching file in `Contents/Frameworks` fails with `Missing bundled
   dependency: …` (Swift runtime libraries are exempt).
6. **Disk image.** The version is read from the bundle's
   `CFBundleShortVersionString`, and [`scripts/lib/dmg.py`](../scripts/lib/dmg.py)
   writes `WallpaperMachine-<version>-arm64.dmg`: an HFS+ volume named
   `WallpaperMachine <version>` holding the bundle (copied with `ditto`, so its
   signatures survive; extended attributes and resource forks stay behind, so the
   File Provider attributes described under Troubleshooting never reach the
   image) and an `Applications` link, compressed with LZFSE (`ULFO`). The window
   a user sees is laid out without Finder: the script writes the volume's
   `.DS_Store` itself, so packaging runs headless in CI and needs no Automation
   permission. The window geometry, the Finder constraints behind the
   `.DS_Store` records and the background are documented in `dmg.py`; the
   background is `Packaging/dmg/background.png` and its `@2x` twin, and the
   volume icon is the app's `AppIcon.icns`.
7. **Verification and checksum.** The image is mounted read-only and out of
   sight: the bundle in it must be `app.wallpapermachine` at the version the name
   claims, pass `codesign --verify --deep --strict` and meet the same
   [contract](#bundle-contract) as the build, and the `Applications`
   link and the window layout must be there. Only then is
   `WallpaperMachine-<version>-arm64.dmg.sha256` written, in the format
   `shasum -a 256 -c` reads. The in-app updater depends on the image name; see
   [release.md](release.md). The script labels the image not cleared for
   distribution; [../LICENSING.md](../LICENSING.md) records why.
8. **`--install`.** Copies the bundle to `~/Applications/WallpaperMachine.app`.
   It refuses to overwrite an existing installation: quit and remove the old copy
   first.

The background art is generated, not drawn by hand: `python3 scripts/brand.py
--dmg` renders both PNGs from `scripts/lib/dmg.py`'s window geometry and the
brand palette and changes nothing else. Regenerate it whenever that geometry or
the palette changes. Finder draws icon labels in black on a custom background
whatever the appearance, so the art stays light. `scripts/tests/test_dmg.py`
covers the `.DS_Store` writers and builds and verifies an image of a small signed
bundle; no test can run Finder.

### Bundle contract

[`scripts/lib/bundle_contract.py`](../scripts/lib/bundle_contract.py) reads the
signed facts back from the artifact itself, after signing (step 4) and again on
the app inside the mounted image (step 7), because re-signing or copying can drop
an entitlement or an Info.plist key without breaking the signature. The lock
screen would then just never start on the user's Mac. Any of these exits 1 with
`MISSING … does not match its signing and Info.plist contract:` and one line per
finding:

- **Extension** (every `Contents/Extensions/*.appex`; at least one must exist):
  `com.apple.security.app-sandbox` must be signed in as `true`, and every key and
  value of [`Extension/WallpaperExtension.entitlements`](../Extension/WallpaperExtension.entitlements)
  must be in its signature. That file is the source of truth; no key list is
  repeated in the script, so a new exception added to the file is enforced with
  no script change. Its `CFBundleIdentifier` must be
  `app.wallpapermachine.wallpaper-extension` and `EXAppExtensionAttributes` must
  declare the `com.apple.wallpaper` extension point.
- **Host app:** `CFBundleIdentifier` `app.wallpapermachine`; non-empty
  `NSAppleEventsUsageDescription` and `NSAudioCaptureUsageDescription` (without
  them macOS does not show the permission prompts); `CFBundleURLTypes` registering
  the `wallpapermachine` scheme; `LSMinimumSystemVersion` at least the
  `MACOSX_DEPLOYMENT_TARGET` in `project.yml` (packaging may raise it, never lower
  it). The host must not be sandboxed.
- **Signing:** the app and the extension must both be signed, and both ad hoc or
  neither. When neither is ad hoc their team identifiers must match (a self-signed
  certificate such as the project's has none, and two absent teams match).

Entitlements the signature adds beyond the repository file are only a
`WARN`, because Xcode and signing profiles inject some; a debuggable build's
`com.apple.security.get-task-allow` is the usual one. Tests:
`scripts/tests/test_bundle_contract.py` (a synthetic bundle with injected
signature readers, plus the readers against small binaries signed with
`codesign`) and `scripts/tests/test_dmg.py` (the contract runs on the mounted
app).

### Release signing

The published image is signed with the self-signed code-signing certificate
`WallpaperMachine Code Signing` (SHA-1 `2BDF4E2431B7EDEB731DE288726C896480A0FA82`,
valid to 2046). Its designated requirement is
`identifier "app.wallpapermachine" and certificate root = H"2bdf…fa82"`, the same
for every release, so macOS keeps the system-audio and Apple Events permissions
across an in-app update. An ad-hoc requirement is the build's cdhash, which every
release changes, so updating from an ad-hoc build (1.0.1 and older) asks for
those permissions once more.

The certificate is not trusted by Gatekeeper and replaces no Developer ID: the
first launch still goes through **Open Anyway**. `.github/workflows/build.yml`
imports it from the `SIGNING_CERTIFICATE_P12` (base64 PKCS#12, legacy 3DES
encryption so `security import` reads it) and `SIGNING_CERTIFICATE_PASSWORD`
repository secrets into a temporary keychain and fails when either is missing,
rather than shipping an ad-hoc build. The private key is kept only by the
maintainer, outside the repository. Replacing the certificate changes the
requirement, so the release after a replacement asks for permissions once more; the
same change updates `TelemetryEnvironment.releaseCertificateSHA1`, or every copy of
the next release reports itself as a build from source
([telemetry](features/telemetry.md#what-a-report-holds)).
To sign locally with it, import the PKCS#12 into a keychain in the search list and
pass `--sign-identity "WallpaperMachine Code Signing"`.

## Runtime data locations

The app never writes into the repository. Managed wallpapers live at
`~/Library/Application Support/WallpaperMachine/Library`; imports copy files
there and leave the originals untouched. Sibling directories under
`~/Library/Application Support/WallpaperMachine/` hold scene assets
(`SceneAssets`), the private SteamCMD runtime (`SteamCMD`) and the optional saved
Steam sign-in (`SteamSession`). Setting `WALLPAPER_MACHINE_HOME` relocates the
whole tree, which is how tests stay isolated from your real library.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cargo`/CMake stops with a missing header, library or `.pc` file | One of the Homebrew packages above is not installed, so its `opt/<package>` root contributed nothing to `CMAKE_PREFIX_PATH`/`PKG_CONFIG_PATH` | Install the package list, then rebuild. |
| `cargo`/CMake configure fails once, immediately after the environment changed, and an unmodified retry succeeds | The renderer's CMake configure step is not robust to a changed `CMAKE_PREFIX_PATH`/`PKG_CONFIG_PATH` on its first run in a directory | Retry the same command once before investigating. Do not hand-set `LIBRARY_PATH=/opt/homebrew/lib` to work around it: that puts the non-keg-only FFmpeg back on the link line and reproduces the ABI mismatch above. Running `cargo` with a bare shell environment fails outright for the same reason |
| `brew: command not found` or `xcode-select` failure during startup | `build_environment()` shells out to `brew --prefix`, `xcode-select -p` and `xcrun` before any stage runs | Install Homebrew; select a full Xcode with `sudo xcode-select -s /Applications/Xcode.app`. |
| Linker reports `library 'wallpaper_bridge' not found`, or Swift cannot find the generated bridge module | `--swift-only` was used without an earlier full build, so `upstream/renderer/target/release` and `App/Bridge/Generated` are empty | Run `python3 scripts/build.py` once without `--swift-only`. |
| `xcodegen: command not found` | XcodeGen missing; both `scripts/build.py` and `scripts/test.py` regenerate the project | `brew install xcodegen`. |
| Renderer changes have no effect on the app | The run used `--swift-only` | Rebuild without the flag. |
| `Unbundled dependency:` or `Missing bundled dependency:` during packaging | A new native dependency is reachable from a binary but was not copied into `Contents/Frameworks` — usually loaded through an `@rpath` name with no Homebrew `lib/<name>` counterpart | Add the library to the Homebrew package list so the relocation walk can find it, then repackage. Never ship the bundle with the audit bypassed. |
| `Refusing to bundle FFmpeg libraries that are not an LGPL build` during packaging | The app was linked against Homebrew's GPLv3 `ffmpeg@8` (or another non-LGPL build) instead of `mwe-ffmpeg` | `python3 scripts/install_ffmpeg.py`, then a fresh `python3 scripts/build.py` so the link resolves to the project's build. Never bypass the check; see [../LICENSING.md](../LICENSING.md). |
| `Packaging requires fresh, unrelocated build output` | The bundle in `build/` was packaged before; incremental builds keep `Contents/Frameworks` and the rewritten load commands, and packaging never undoes them | Clean and rebuild as the [preflight](#packaging-and-installing) describes: `--all` deletes the delivered Release app, so preview with `--dry-run` and keep a copy first. |
| `Missing license payload:` during packaging | A repository notice file, an Xcode-bundled notice, or a keg `LICENSE*`/`COPYING*` file is absent | Restore the listed file; the payload list is in [Packaging and installing](#packaging-and-installing). |
| `An installation already exists: …` | `--install` will not replace `~/Applications/WallpaperMachine.app` | Quit and remove the installed copy, then rerun. |
| `CodeSign` fails with `resource fork, Finder information, or similar detritus not allowed in object file` | The built `.app`/`.appex` **directory** in `build/` picked up `com.apple.FinderInfo` or File Provider xattrs (`com.apple.fileprovider.fpfs#P`). It comes from the file provider syncing the checkout's parent directory, not from anything committed: source files carry only `com.apple.provenance`, which codesign accepts | `xattr -cr build/Build/Products/<configuration>` and rerun the same command. It recurs on synced checkouts; clearing the products directory is the fix, not a rebuild |
| `codesign --verify --deep --strict` fails | A dylib or the extension was modified after signing | Rerun packaging on a fresh build rather than re-signing pieces by hand. |
| `Missing disk image input:` or `… not twice …` during the preflight | The DMG background under `Packaging/dmg/` or the bundle's `AppIcon.icns` is missing, or the 1x and 2x PNGs no longer pair up | `python3 scripts/brand.py --dmg`, then rerun packaging; the preflight stopped before the bundle was touched. |
| `Could not detach …` while packaging | Something kept the volume busy past the retries (a Finder window on a leftover mount, an indexer), or a mount from an interrupted run is still attached | `hdiutil info` lists attached images; `hdiutil detach -force <device>` the leftover, then rerun packaging on a fresh build. |
| `CompileAssetCatalogVariant` fails on `AppIcon.icon` with exit 65 on macOS 15 (actool exits 255 or dies with `IBPlatformToolFailureException`) | Xcode 26's `actool` crashes on most `.icon` compiles on macOS 15; the asset catalog alone is unaffected | Compile the icon on macOS 26 with `--compile-app-icon DIR` and build with `--app-icon DIR`, as the release workflow does. |

## Related documents

- [testing/README.md](testing/README.md) — how to verify a build.
- [testing/renderer.md](testing/renderer.md) — headless renderer and GPU checks.
- [release.md](release.md) — versioning, CI, notes, and the published disk image.
- [repository-layout.md](repository-layout.md) — where each source tree lives.
