# Building WallpaperMachine

Authoritative build document. Everything here is driven by `scripts/build.py` and
`scripts/package.py`; the Xcode project itself is generated from
[`project.yml`](../project.yml) and must never be edited by hand.

## Prerequisites

| Requirement | Detail |
|---|---|
| Hardware | Apple Silicon only. `project.yml` sets `ARCHS: arm64`, and release disk images are named `-arm64`. |
| macOS | The app runs on macOS 15 or later (`project.yml` pins `deploymentTarget.macOS` and `MACOSX_DEPLOYMENT_TARGET` to `15.0`; `scripts/build.py` passes the same value to the renderer as `OWE_MACOSX_DEPLOYMENT_TARGET`); building needs Xcode 26, so macOS 15.6 or later. Bundled Homebrew dylibs keep the release they were built on, so a package made on a newer macOS requires that newer release (see [packaging](#packaging-and-installing)); CI builds the published image on a `macos-15` runner for that reason. The lock-screen extension stays off below macOS 26. |
| Xcode | A full Xcode selected with `xcode-select`. The build reads `xcode-select -p` for the toolchain and `xcrun --sdk macosx --show-sdk-path` for the SDK. Command Line Tools alone are not enough. Xcode 26 installs the Metal Toolchain separately (Xcode asks on first launch, or `xcodebuild -downloadComponent MetalToolchain`); the lock-screen extension compiles a Core Image kernel with it. |
| Homebrew | Provides every renderer dependency; `brew --prefix` is queried at build time. |
| XcodeGen | `xcodegen` must be on `PATH`. Every build runs `xcodegen generate --use-cache`, which regenerates the project when `project.yml` changed. |
| Python | `python3` 3.11 or newer runs all of `scripts/` (`hashlib.file_digest` is the newest API they use). The `/usr/bin/python3` that macOS and Command Line Tools ship is 3.9, so install Homebrew's `python`, which puts a newer `python3` ahead of it on `PATH`. |
| Rust | `cargo` must be on `PATH` for the renderer stage. Install it with rustup, which reads `Renderer/rust-toolchain.toml` and builds with the stable release pinned there, as CI does. Homebrew's `rust` formula ignores that file and builds with its own release. Raise the pin in a change of its own: it rebuilds every crate and starts CI's renderer cache afresh. |

Homebrew packages the renderer links against, exactly as listed in
`build_environment()` in `scripts/build.py`:

```sh
brew install quickjs-ng libpng brotli lz4 nlohmann-json argparse
```

QuickJS-NG 0.18 changed its interrupt callback from `JSRuntime*` to `JSContext*`.
The script engine accepts either signature and keeps its execution deadline in
the opaque host state, so older local packages and current CI packages both work.

Plus the build tooling those packages are compiled and consumed with:

```sh
brew install rustup python cmake ninja pkg-config xcodegen
```

Homebrew's `rustup` is keg-only, so put it on `PATH` (in `~/.zprofile`, for
example), then install the toolchain `Renderer/rust-toolchain.toml` pins from
inside `Renderer/`:

```sh
export PATH="$(brew --prefix rustup)/bin:$PATH"
cd Renderer && rustup toolchain install
```

Steam Workshop downloads additionally need SteamCMD, which the app installs and
manages itself at run time; it is not a build dependency. See
[features/workshop-downloads.md](features/workshop-downloads.md#steamcmd-setup).

FFmpeg is not used any more: video plays with the app's own container readers and
VideoToolbox, sounds with AudioToolbox and a vendored public-domain Ogg Vorbis
decoder, and nothing links or bundles a `libav*` library (the check is recorded in
[../LICENSING.md](../LICENSING.md#components-and-their-licenses)). The Homebrew `ffmpeg` formulas, `mwe-ffmpeg` and
`dav1d` that an earlier checkout installed are not needed and can be uninstalled;
nothing in the build looks at them.

## The build environment

`scripts/build.py` does not rely on your shell environment for the renderer. It
copies the current environment and overrides the variables below, so the same
command produces the same build from a terminal, an editor, or CI.

| Variable | Value | Why |
|---|---|---|
| `PATH` | `$(brew --prefix)/bin` prepended | Finds Homebrew `cmake`, `ninja` and friends ahead of anything else. |
| `CMAKE_PREFIX_PATH` | `;`-joined `opt/<package>` roots plus the Homebrew prefix | CMake resolves each dependency from its own keg, including keg-only ones like `quickjs-ng`, instead of guessing. |
| `PKG_CONFIG_PATH` | `:`-joined `opt/<package>/lib/pkgconfig` | `pkg-config` consumers (lz4, and Brotli for the vendored FreeType) find the matching `.pc` files. |
| `OWE_NIX_LIBRARY_PATH` | `:`-joined `opt/<package>/lib` plus `<prefix>/lib` | The vendored scene engine's build scripts use this to locate native libraries to link. |
| `LIBCLANG_PATH` | `$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib` | Rust `bindgen`/`uniffi` need `libclang` from the selected Xcode toolchain. |
| `SDKROOT` | `xcrun --sdk macosx --show-sdk-path` | Pins C/C++/Rust compilation to the selected macOS SDK. |
| `CC` / `CXX` | `/usr/bin/clang`, `/usr/bin/clang++` | Apple Clang, not a Homebrew LLVM that happens to be first on `PATH`. |
| `MACOSX_DEPLOYMENT_TARGET` | `15.0` | Set for `xcodegen` and `xcodebuild`. Deliberately **not** in cargo's environment: cargo builds proc-macro crates for the host and dlopens them in the running compiler, and a pinned host dylib is rejected at load with `mis-aligned LINKEDIT`, which the compiler reports as `can't find crate for <macro>`. |
| `OWE_MACOSX_DEPLOYMENT_TARGET` | `15.0` | The same value under a name cargo ignores. The renderer crate's build script passes it as `CMAKE_OSX_DEPLOYMENT_TARGET`, so the C++ engine keeps the minimum the app links against. |
| `GIT_SHORT_COMMIT` | `git rev-parse --short HEAD` in the repository root | Stamps the build with the revision it was built from; Settings shows it as `Git revision`. The renderer build runs with `Renderer/` as its working directory, so HEAD is resolved against the repository root explicitly. |

## Stages and outputs

```sh
python3 scripts/build.py                          # Debug, everything
python3 scripts/build.py --configuration Release  # Release, everything
python3 scripts/build.py --swift-only             # skip the renderer
python3 scripts/build.py --renderer-only          # renderer + bindings only
python3 scripts/build.py --compile-app-icon DIR   # only compile AppIcon.icon + Assets.xcassets into DIR
python3 scripts/build.py --app-icon DIR           # build with that output instead of compiling the icon
python3 scripts/build.py --no-app-icon            # build without the icon, for --install-app-icon to add
python3 scripts/build.py --install-app-icon DIR   # only put that output into the built app and re-sign it
python3 scripts/build.py --xcode-setting N=V      # also pass build setting N=V to xcodebuild (repeatable)
```

`--configuration` accepts `Debug` (default) or `Release`.

`--compile-app-icon` runs `actool` with the arguments Xcode uses for this target and
writes `Assets.car`, `AppIcon.icns` and `partial-info.plist`. `--app-icon` builds
with `AppIcon.icon` excluded (`EXCLUDED_SOURCE_FILE_NAMES`, empty
`ASSETCATALOG_COMPILER_APPICON_NAME`), then copies those files into the bundle,
merges the Info.plist keys and re-signs it ad hoc. `--no-app-icon` and
`--install-app-icon` are the two halves of `--app-icon`, so the release build can
compile while the icon is still being compiled elsewhere. They exist because on macOS 15
Xcode 26's `actool` crashes on most `.icon` compiles: CI compiles the icon on
macOS 26 ([release.md](release.md#build-buildyml)), and a local build on macOS 15
can do the same (see Troubleshooting). A build on macOS 26 never needs them.

1. **Renderer** — `cargo build --workspace --release` in `Renderer/`.
   The Rust crates and the C++ scene engine are always built in release mode,
   independently of `--configuration`. Output lands in
   `Renderer/target/release`, including the static library
   `libwallpaper_bridge.a` the app links as `-lwallpaper_bridge`.
2. **Swift bindings** — `Renderer/target/release/uniffi-bindgen generate
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
   the pinned BSD-3-Clause sources under `ThirdParty/mediaremote-adapter`, and
   includes its Perl entry point and license as app resources. Building or
   testing does not launch that helper.

Products:

| Path | Contents |
|---|---|
| `build/Build/Products/Debug/WallpaperMachine.app` | Debug app, used by `scripts/test.py` |
| `build/Build/Products/Release/WallpaperMachine.app` | Release app; this is the bundle the user runs, who quits and reopens it to load a new build |
| `Renderer/target/release/` | Renderer static library (`libwallpaper_bridge.a`, which contains the shader layer) and `uniffi-bindgen` |
| `Renderer/target/release/` | The shader layer on its own (`libwm_shader.a`), built only by `scripts/check_renderer.py` and `scripts/check_rust.py` for the C++ and Rust tests |
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
| `--swift-only` | Only Swift, resources, or `project.yml` changed. | `Renderer/target/release/libwallpaper_bridge.a` and `App/Bridge/Generated` must already exist from an earlier full build. |
| `--renderer-only` | Iterating on Rust/C++ or the uniffi interface without needing an app bundle. | Nothing further; it stops after regenerating bindings. |

`--renderer-only` prints a success verdict after the renderer and binding stages finish.

## Packaging and installing

```sh
python3 scripts/package.py --configuration Release            # bundle, sign, write the disk image
python3 scripts/package.py --configuration Release --check    # preflight only; the bundle is unchanged
python3 scripts/package.py --configuration Release --install  # also copy the app to ~/Applications
```

CI adds `--require-deployment-target`, `--sign-identity` and `--notarize` (see the
preflight and [Release signing](#release-signing)).

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
   - The notice payload must exist: repository `LICENSE`, `LICENSING.md`,
     `ThirdParty/received-licenses/wallpaper-engine-for-macos.GPL-2.0.txt`, `ThirdParty/provenance.json`, the
     Xcode-bundled `Resources/LICENSE` (mediaremote-adapter, BSD-3-Clause) and
     the extension's `Phosphene-LICENSE.txt`, and a `LICENSE*`/`COPYING*`/
     `COPYRIGHT*`/`NOTICE*` file in every Homebrew keg the link closure
     reaches. Otherwise `MISSING Missing license payload:` lists what is
     absent.
   - `THIRD-PARTY-NOTICES.txt` must be generated: `python3 scripts/notices.py`'s
     generator runs against the bundle's license closure (Homebrew libraries,
     compiled-in code, every linked Rust crate; needs Homebrew, Cargo and a
     populated cargo registry) and a tool failure or an empty closure stops
     packaging (`Third-party notices could not be generated`). A component whose
     license text cannot be found does not stop it by default: the output names
     it (`MISSING LICENSE TEXT NOT FOUND for N of M components: …`) and the file
     marks it. `--require-notices` makes that an error too; it is the gate for a
     build that is distributed.
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
   - A `minos` says nothing about the system libraries a file loads, so every
     one the app, the extension or a library to bundle loads unconditionally
     must be in `SYSTEM_LIBRARIES` (`scripts/package.py`), the `/usr/lib`
     libraries known to ship with macOS 15.0; the app's and extension's own
     executables may also load Apple frameworks and the Swift runtime, which
     Xcode links at the deployment target. Anything else, such as the
     `/usr/lib/libhvf.dylib` that macOS has only from 15.4, stops packaging
     before the bundle changes: dyld would refuse to start the app on an older
     release. A weak load is not checked.
1. **Dylib relocation.** Starting from the app and extension binaries, it walks `otool -L` transitively. Every dependency under
   the Homebrew prefix is copied into `Contents/Frameworks`, including a
   sibling a Homebrew library loads through `@rpath` and its own
   `@loader_path/../lib` rpath (Brotli's decoder, which the app loads for
   FreeType, loads its common library that way; only rpaths that stay inside the
   prefix are followed), given an
   `@rpath/<name>` install name, and rewritten in its dependents with
   `install_name_tool -change`. Absolute `LC_RPATH` entries pointing into the
   Homebrew prefix or the repository are deleted, and
   `@executable_path/../Frameworks` (or `@executable_path/../../../../Frameworks`
   for the embedded `.appex`) is added instead.
   `python3 scripts/check_licenses.py` walks the same `otool -L` closure
   (read-only, on an unpackaged or a packaged app) and adds the compiled-in
   and Rust-crate inventories; see [testing](testing/README.md).
2. **License payload.** The root `LICENSE` is copied in as
   `WallpaperMachine-LICENSE.txt`, `LICENSING.md` as `LICENSING.md`,
   `ThirdParty/received-licenses/wallpaper-engine-for-macos.GPL-2.0.txt` (the terms the imported renderer arrived under, not the license of the code now) as `Imported-Renderer-GPL-2.0-LICENSE.txt`,
   `ThirdParty/provenance.json` as `provenance.json`, each bundled keg's notices
   under `Licenses/<formula>-<version>/`, the notices of the third-party
   code statically linked into the renderer under
   `Licenses/renderer-third-party/`, and the generated
   `THIRD-PARTY-NOTICES.txt` (the license text of every third-party component
   in the closure, including each linked Rust crate; the disk image carries only
   the bundle, so the file travels inside the app). `Licenses/` is rebuilt on
   every run.
3. **Signing.** Inside out: each bundled dylib, each framework in
   `Contents/Frameworks` (the MediaRemote adapter), each extension with
   [`Extension/WallpaperExtension.entitlements`](../Extension/WallpaperExtension.entitlements),
   then the app with
   [`Packaging/WallpaperMachine.entitlements`](../Packaging/WallpaperMachine.entitlements)
   are signed with `--sign-identity` (default `-`, ad hoc), and the result is checked
   with `codesign --verify --deep --strict`. A Developer ID identity signs every piece
   with the hardened runtime (`--options runtime`) and a secure timestamp, as
   notarization requires; ad hoc and other certificates sign without the runtime,
   whose library validation would refuse libraries that carry no team. Each bundle gets
   exactly its repository entitlements, not what Xcode signed in: Xcode adds
   `com.apple.security.get-task-allow` to the extension even in a Release build, and
   Apple does not notarize that. Release builds use the Developer ID; see
   [Release signing](#release-signing).
   A valid signature does not say what it signs, so the bundle is then read back
   against its [contract](#bundle-contract).
4. **Dependency audit.** Every binary is re-scanned. A remaining Homebrew-prefixed
   load command fails with `Unbundled dependency: …`; an `@rpath` dependency with
   no matching file in `Contents/Frameworks` fails with `Missing bundled
   dependency: …` (Swift runtime libraries are exempt).
   With `--notarize PROFILE`, the app is then zipped and sent to Apple with
   `xcrun notarytool submit --wait`, and the ticket is stapled to the bundle, so the
   copy a user drags out of the image opens without a network connection
   ([Release signing](#release-signing)).
5. **Disk image.** The version is read from the bundle's
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
   volume icon is the app's `AppIcon.icns`. A Developer ID identity then signs
   the image itself, and `--notarize` has Apple notarize it and staples its
   ticket too.
6. **Verification and checksum.** The image is mounted read-only and out of
   sight: the bundle in it must be `app.wallpapermachine` at the version the name
   claims, pass `codesign --verify --deep --strict`, meet the same
   [contract](#bundle-contract) as the build and, when notarized, still carry its
   stapled ticket; the `Applications` link and the window layout must be there.
   Only then is `WallpaperMachine-<version>-arm64.dmg.sha256` written, in the format
   `shasum -a 256 -c` reads: stapling changes the image's bytes, so a checksum
   written earlier would not match the published file. Verification also reads the
   mounted signed bundle's identifier, version, minimum macOS and executable architectures.
   Packaging writes these to `WallpaperMachine-<version>-arm64.dmg.metadata.json`, with
   the final image name, size and SHA-256. This internal build artifact lets the Linux
   publish job generate compatibility fields without mounting a DMG or guessing from
   source settings. The metadata sidecar is transferred with the image, not published
   as a release asset. The in-app updater depends on the image name; see
   [release.md](release.md). The notices the bundle carries are listed in
   [../LICENSING.md](../LICENSING.md#notice-payload).
7. **`--install`.** Copies the bundle to `~/Applications/WallpaperMachine.app`.
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
signed facts back from the artifact itself, after signing (step 3) and again on
the app inside the mounted image (step 6), because re-signing or copying can drop
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
  it). The host must not be sandboxed, and every key and value of
  [`Packaging/WallpaperMachine.entitlements`](../Packaging/WallpaperMachine.entitlements)
  must be in its signature: under the hardened runtime, Apple Events to Music and
  Spotify (`com.apple.security.automation.apple-events`) and the system audio tap
  (`com.apple.security.device.audio-input`) fail without a prompt when they are
  missing. Packaging signs them in, not Xcode, so debug builds and the test host
  run as before.
- **Signing:** the app and the extension must both be signed, and both ad hoc or
  neither. When neither is ad hoc their team identifiers must match (a self-signed
  certificate has none, and two absent teams match).
- **Developer ID:** when the host is signed with a Developer ID, the host and every
  extension must carry the hardened runtime and no `com.apple.security.get-task-allow`,
  and every dylib and framework in `Contents/Frameworks` must be signed by the same
  team: Apple refuses to notarize anything else, and the runtime's library validation
  would refuse to load a library signed ad hoc or by another team.

Entitlements the signature adds beyond the repository files are only a
`WARN`, because Xcode and signing profiles inject some; a debuggable build's
`com.apple.security.get-task-allow` is the usual one, and an error under a
Developer ID. Tests:
`scripts/tests/test_bundle_contract.py` (a synthetic bundle with injected
signature readers, plus the readers against small binaries signed with
`codesign`) and `scripts/tests/test_dmg.py` (the contract runs on the mounted
app).

### Release signing

The published image is signed with the project's Developer ID,
`Developer ID Application: … (DT6YQU64FF)`, and notarized by Apple: the app is
notarized and stapled before it goes into the disk image, and the image is then
signed, notarized and stapled itself, so a downloaded copy opens on its first launch
without **Open Anyway**, offline included. Every piece is signed with the hardened
runtime and a secure timestamp ([Signing](#packaging-and-installing)), and the
app's designated requirement is
`identifier "app.wallpapermachine" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = DT6YQU64FF`.
It names the team, not a certificate, so it is the same for every release and
survives renewing the Developer ID certificate: macOS keeps the system-audio and
Apple Events permissions across an in-app update.

The switch from the self-signed project certificate `WallpaperMachine Code Signing`
(SHA-1 `2BDF4E2431B7EDEB731DE288726C896480A0FA82`, valid to 2046), which signed
1.0.2 through 1.8.2, changed the designated requirement once. The first Developer ID
release therefore asks for those permissions again, and macOS asks once before it
hands the pixiv and Steam sign-ins saved in the keychain to the new signature (a
sign-in that is refused is asked for again). Updating from an ad-hoc build (1.0.1
and older) did the same. The keychain asked far more often before: it keeps an item
in the partition of the build that saved it, and `securityd` gives a partition to a
team only for code under an Apple anchor (`teamid:DT6YQU64FF` for the Developer ID).
A project-certificate release had its own partition, its code hash, so after every
update between them macOS asked for the login keychain password before the new
version could read a saved sign-in, at launch, even after **Always Allow**
([#163](https://github.com/MMFoundation/WallpaperMachine/issues/163)); Developer ID
releases share one. Only copies from 1.8.0 on install a Developer ID release
from the in-app updater: `AppUpdateConfiguration.signingRequirement` accepts both
the project certificate and the Developer ID from 1.8.0 on, while older copies refuse
it as unverifiable and have to be updated by downloading the image
([updates](features/updates.md#installing)). Every installed copy checks an update
against the requirement it shipped with, so a signer stays in the requirement for
as long as releases are signed with it, and replacing the team (not just renewing the
certificate) needs a release whose requirement accepts both teams first.
`TelemetryEnvironment` counts a copy that meets
`AppUpdateConfiguration.developerIDRequirement`, or carries the project certificate as
its leaf, as a release ([telemetry](features/telemetry.md#what-a-report-holds)).

`.github/workflows/build.yml` imports the certificate and the notary credentials into
a temporary keychain from five repository secrets before it compiles anything, and fails
when any is missing or Apple refuses the key, rather than shipping a build Gatekeeper
holds:

| Secret | Holds |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | The Developer ID Application certificate with its private key, as a base64 PKCS#12 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | That PKCS#12's password |
| `NOTARY_API_KEY` | The text of an App Store Connect team API key (`AuthKey_<id>.p8`, Developer role) |
| `NOTARY_API_KEY_ID` | That key's ID |
| `NOTARY_API_ISSUER` | The issuer ID shown above the team keys in App Store Connect |

The API key becomes the `WallpaperMachine Notary` profile of
`xcrun notarytool store-credentials` in that keychain (storing it checks it with Apple),
and packaging runs with `--sign-identity "Developer ID Application" --notarize
"WallpaperMachine Notary" --notary-keychain <the temporary keychain>`. The private key
is kept only by the maintainer, outside the repository. To export it, choose the
**Developer ID Application** certificate in Keychain Access, **File → Export Items…**
as a `.p12`, and store `base64 -i <file>.p12` as the first secret. The workflow also
imports both of Apple's Developer ID intermediates, so the chain builds whichever one
issued the certificate; one the `.p12` already carries (an export usually includes
its issuer) is skipped.

Create the certificate with the **G2 Sub-CA** profile type in the Apple Developer
portal. One made with **Previous Sub-CA** ends with that intermediate on 2027-02-01;
a G2 one lasts longer (the portal shows the date; the one created on 2026-11-02 ends on
2027-12-02). Code signed with a secure timestamp stays valid after its certificate
expires, and the designated requirement names the team, so replacing an expiring
certificate means exporting the new one into the first two secrets and nothing else.
Never revoke a Developer ID certificate that signed a release: Gatekeeper then refuses
every copy it signed.

To sign and notarize locally, save a profile once with
`xcrun notarytool store-credentials "WallpaperMachine Notary"` (the same API key, or an
Apple ID with an app-specific password and `--team-id DT6YQU64FF`), then run
`python3 scripts/package.py --configuration Release --sign-identity "Developer ID
Application" --notarize "WallpaperMachine Notary"`. When the keychains hold more than
one valid Developer ID certificate (an old one beside its renewal), packaging stops
before it changes anything and lists their SHA-1s; pass one of them as
`--sign-identity`. Without `--notarize`, the build is signed but Gatekeeper calls it
`Unnotarized Developer ID`. A refused submission prints
Apple's log: each issue names the file and the reason. A submission Apple has not
finished within the 50 minutes packaging waits stops it with the submission's id;
`xcrun notarytool history --keychain-profile "WallpaperMachine Notary"` lists them all.
`stapler staple` and `stapler validate` (including the check of the app inside the
mounted image) both ask Apple's CloudKit ticket service, so a dropped connection
(`The network connection was lost`, stapler error 68) or a ticket the service does not
serve yet is retried three times, after 15, 30 and 60 seconds, before packaging fails.
A new team's first submissions are held for hours (the team's first ones, on
2026-11-02, were still `In Progress` after two hours), so a release waits until they
are `Accepted`; later ones take minutes.

## Runtime data locations

The app never writes into the repository. Managed wallpapers live by default at
`~/Library/Application Support/WallpaperMachine/Library`; imports copy files into
the library wherever it is kept and leave the originals untouched. Sibling directories under
`~/Library/Application Support/WallpaperMachine/` hold scene assets
(`SceneAssets`), the private SteamCMD runtime (`SteamCMD`) and the optional saved
Steam sign-in (`SteamSession`). Settings → Storage can move `Library` and the
partial downloads to another folder, such as an external drive
([library location](features/library-location.md)); everything else stays.
Setting `WALLPAPER_MACHINE_HOME` relocates the whole tree, which is how tests stay
isolated from your real library.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cargo`/CMake stops with a missing header, library or `.pc` file | One of the Homebrew packages above is not installed, so its `opt/<package>` root contributed nothing to `CMAKE_PREFIX_PATH`/`PKG_CONFIG_PATH` | Install the package list, then rebuild. |
| `cargo`/CMake configure fails once, immediately after the environment changed, and an unmodified retry succeeds | The renderer's CMake configure step is not robust to a changed `CMAKE_PREFIX_PATH`/`PKG_CONFIG_PATH` on its first run in a directory | Retry the same command once before investigating. Running `cargo` with a bare shell environment fails outright for the same reason |
| `brew: command not found` or `xcode-select` failure during startup | `build_environment()` shells out to `brew --prefix`, `xcode-select -p` and `xcrun` before any stage runs | Install Homebrew; select a full Xcode with `sudo xcode-select -s /Applications/Xcode.app`. |
| Linker reports `library 'wallpaper_bridge' not found`, or Swift cannot find the generated bridge module | `--swift-only` was used without an earlier full build, so `Renderer/target/release` and `App/Bridge/Generated` are empty | Run `python3 scripts/build.py` once without `--swift-only`. |
| `xcodegen: command not found` | XcodeGen missing; both `scripts/build.py` and `scripts/test.py` regenerate the project | `brew install xcodegen`. |
| Renderer changes have no effect on the app | The run used `--swift-only` | Rebuild without the flag. |
| `Unbundled dependency:` or `Missing bundled dependency:` during packaging | A new native dependency is reachable from a binary but was not copied into `Contents/Frameworks` — usually loaded through an `@rpath` name with no Homebrew `lib/<name>` counterpart | Add the library to the Homebrew package list so the relocation walk can find it, then repackage. Never ship the bundle with the audit bypassed. |
| `Packaging requires fresh, unrelocated build output` | The bundle in `build/` was packaged before; incremental builds keep `Contents/Frameworks` and the rewritten load commands, and packaging never undoes them | Clean and rebuild as the [preflight](#packaging-and-installing) describes: `--all` deletes the delivered Release app, so preview with `--dry-run` and keep a copy first. |
| `Missing license payload:` during packaging | A repository notice file, an Xcode-bundled notice, or a keg `LICENSE*`/`COPYING*` file is absent | Restore the listed file; the payload list is in [Packaging and installing](#packaging-and-installing). |
| `Third-party notices could not be generated` during the preflight | `cargo tree --offline` failed (a missing lockfile or an unpopulated cargo registry) or no `--app` closure could be read | Run a build once so the registry is populated, then rerun; `python3 scripts/notices.py` shows the same failure on its own. |
| `LICENSE TEXT NOT FOUND for N of M components` during packaging | A crate's published source carries no license file (supply it under `Packaging/notices/<crate>/`, as was done for the `objc2` and `uniffi` crates), or a keg ships none | Not an error unless `--require-notices` is set. Add the upstream project's license files under `Packaging/notices/<crate>/` (`LICENSE*`), recording where they were copied from, and rerun; `python3 scripts/notices.py` lists the gaps. |
| `An installation already exists: …` | `--install` will not replace `~/Applications/WallpaperMachine.app` | Quit and remove the installed copy, then rerun. |
| `CodeSign` fails with `resource fork, Finder information, or similar detritus not allowed in object file` | The built `.app`/`.appex` **directory** in `build/` picked up `com.apple.FinderInfo` or File Provider xattrs (`com.apple.fileprovider.fpfs#P`). It comes from the file provider syncing the checkout's parent directory, not from anything committed: source files carry only `com.apple.provenance`, which codesign accepts | `xattr -cr build/Build/Products/<configuration>` and rerun the same command. It recurs on synced checkouts; clearing the products directory is the fix, not a rebuild |
| `CompileMetalFile` fails with `cannot execute tool 'metal' due to missing Metal Toolchain` | Xcode 26 ships the Metal compiler as a separate download, and the selected Xcode does not have it; the extension compiles `Shared/WallpaperEngineColor.ci.metal` | `xcodebuild -downloadComponent MetalToolchain` once for that Xcode. CI's `prepare-build` action does this when `xcrun metal` cannot run |
| `codesign --verify --deep --strict` fails | A dylib or the extension was modified after signing | Rerun packaging on a fresh build rather than re-signing pieces by hand. |
| `Missing disk image input:` or `… not twice …` during the preflight | The DMG background under `Packaging/dmg/` or the bundle's `AppIcon.icns` is missing, or the 1x and 2x PNGs no longer pair up | `python3 scripts/brand.py --dmg`, then rerun packaging; the preflight stopped before the bundle was touched. |
| `Could not detach …` while packaging | Something kept the volume busy past the retries (a Finder window on a leftover mount, an indexer), or a mount from an interrupted run is still attached | `hdiutil info` lists attached images; `hdiutil detach -force <device>` the leftover, then rerun packaging on a fresh build. |
| `CompileAssetCatalogVariant` fails on `AppIcon.icon` with exit 65 on macOS 15 (actool exits 255 or dies with `IBPlatformToolFailureException`) | Xcode 26's `actool` crashes on most `.icon` compiles on macOS 15; the asset catalog alone is unaffected | Compile the icon on macOS 26 with `--compile-app-icon DIR` and build with `--app-icon DIR`, as the release workflow does. |

## Related documents

- [testing/README.md](testing/README.md) — how to verify a build.
- [testing/renderer.md](testing/renderer.md) — headless renderer and GPU checks.
- [release.md](release.md) — versioning, CI, notes, and the published disk image.
- [repository-layout.md](repository-layout.md) — where each source tree lives.
