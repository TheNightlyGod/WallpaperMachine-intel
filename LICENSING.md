# Licensing, Supporter model and distribution status

Recorded: 2026-10-16 (first recorded 2026-09-14).
Status: source policy decided (GPL-2.0-only); Supporter model decided (a free
signed download, and a one-time Supporter purchase for a sponsor place and
priority support); **binary distribution still blocked** by the Apache-2.0
dependencies listed under [Remaining blockers](#remaining-blockers).

This document is the project's own record of what it has checked and decided.
It is not legal advice and it does not claim clearance that has not been
obtained. Where a statement below rests on a third party's text, the primary
source is linked.

## Summary

| Question | Answer |
|---|---|
| Under which license is this repository's source offered? | GNU GPL version 2 only, the text in the root [`LICENSE`](LICENSE). See [Source license](#source-license-gpl-20-only). |
| Is anything sold? | Only the Supporter purchase: a one-time payment for a sponsor place and priority support. The signed download is free and no copy of the software is sold. See [Supporter model](#supporter-model-free-signed-download-paid-sponsorship-and-support). |
| Can it be distributed today? | No. Homebrew's GPLv3 FFmpeg was replaced, but Apache-2.0 components, both Khronos/Vulkan libraries and Rust crates, remain in the link closure of every build. See [Remaining blockers](#remaining-blockers). |
| Is a Developer ID signed, notarized build available? | No. `scripts/package.py` signs ad hoc, or with a self-signed project certificate for releases. Signing is a platform mechanism, not a license grant. See [Signing and notarization](#signing-and-notarization). |
| Can it be listed on the Mac App Store? | Not as the app is built today, and not without first settling the GPLv2 question. See [Mac App Store](#mac-app-store). |
| Does publishing this source resolve the blockers? | No. Distribution of the combined program is what the licenses govern; posting the repository changes nothing about it. |

## Source license: GPL-2.0-only

This project's original contributions are offered under GNU GPL version 2 only,
except where an existing notice specifies different terms. Third-party code
retains its own licenses; the root license does not replace them. The root
[`LICENSE`](LICENSE) is a verbatim copy of `upstream/renderer/LICENSE`, supplied
so source recipients receive the applicable GPLv2 text.

Why version 2 only: the vendored renderer declares `license = "GPL-2.0-only"`
in its `Cargo.toml`
(https://github.com/bigsaltyfishes/wallpaper-engine-for-macos/blob/main/Cargo.toml),
and the application shell in `App/` is a derived work of that renderer's
`app/WallpaperEngine` sources. GPLv2-only code cannot be relicensed by anyone
but its copyright holders, and the "or any later version" option is one the
upstream authors did not grant
(https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility). This project
therefore inherits GPL-2.0-only for the whole program and applies it to its own
contributions so that the whole is under one license.

What the root `LICENSE` does and does not do:

- It states the terms under which this project's own code (`App/`, `Extension/`,
  `Shared/`, `Tests/`, `scripts/`, `project.yml`, `Formula/`) is
  offered, and it is the same license the vendored GPL code is already under.
- It does not transfer, merge or relicense anyone's copyright. The
  bigsaltyfishes projects, the FFmpeg authors, the mediaremote-adapter authors,
  Phosphene and every other holder named in `upstream/provenance.json`
  and in the notices under `upstream/` keep their copyright and their own
  license terms. Third-party notices are retained where they were found and are
  bundled by `scripts/package.py` (see [Notice payload](#notice-payload)).
- It is not a grant from third parties: where a third party's license is
  incompatible with GPLv2, the presence of this file resolves nothing.

The derived application shell and independently implemented extension and
Workshop browser are recorded in `upstream/provenance.json` under
`applicationShell`, `lockScreenExtension` and `workshopBrowser` as GPL-2.0-only.
The browser is independently implemented; no code from the GPLv3 Unayung/wallpaper-engine-mac project
(https://github.com/Unayung/wallpaper-engine-mac/blob/main/LICENSE) was
copied, translated or adapted, because GPLv2-only and GPLv3 code cannot be
combined into one distributed program
(https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility).

## Supporter model: free signed download, paid sponsorship and support

The website (https://www.wallpapermachine.app) offers WallpaperMachine in two
tiers. Neither changes the license of the software, and no copy of the software
is sold:

1. **Free.** A signed, ready-to-run download, built by this project from a
   tagged revision, signed with this project's Apple Developer ID and notarized
   (once that is implemented; see
   [Signing and notarization](#signing-and-notarization)), or the complete
   source in this repository to build yourself.
2. **Supporter.** A one-time purchase through Paddle.com, the website's
   reseller and Merchant of Record, that buys two things and no software:
   - a **sponsor place**: a name and picture on the website's sponsor wall
     (https://www.wallpapermachine.app/#sponsors) and in the
     [README's sponsor list](README.md#thank-you-to-every-supporter), shown
     only if the Supporter turns it on;
   - **priority support**: wallpaper-compatibility questions and feature
     requests, asked on the website's supporter forum, answered ahead of
     general requests.

The website's terms (https://www.wallpapermachine.app/terms/) state that the
license published in this repository, not those terms, governs the source
code, the signed download and anything built from the source. Its refund
policy (https://www.wallpapermachine.app/refunds/) ends only the sponsor place
and priority support; the download stays free and building from source is
unaffected.

What the GPL permits and requires here, from the license text and the FSF's
own answers:

- Distributing copies gratis and charging for them are both allowed
  (https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowMoney,
  https://www.gnu.org/philosophy/selling.html). Activities other than copying,
  distribution and modification are outside the license (GPLv2 section 0), so
  support and a sponsor listing are services the GPL does not regulate; GPLv2
  section 1 expressly allows offering warranty protection for a fee.
- When a binary is offered for download, offering equivalent access to copy
  the corresponding source from the same place counts as distributing the
  source (GPLv2 section 3;
  https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowDownloadFee).
- No further restrictions may be imposed on recipients' exercise of the rights
  the GPL grants (GPLv2 section 6). That covers the terms of every channel a
  copy is distributed through, an app store's as much as this project's own
  (https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement).
- Requiring everyone who obtains a copy to pay this project, or to notify it,
  is not allowed (https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowRequireFee).
- Anyone may sell copies, modified or not, but only under the GPL: recipients
  must receive the source and the same rights
  (https://www.gnu.org/licenses/gpl-faq.html#GPLCommercially).

The policy that follows from that:

- **The software is never the product.** The download is free and the source
  is here. Nothing in the app checks for, unlocks or changes with a Supporter
  purchase: there is no license key, no Supporter build and no feature gate.
- **Recipients keep every GPL right.** Anyone who receives the signed download
  may run it, study and modify its source, redistribute it, and sell copies
  themselves, gratis or for any price, under GPLv2. No further restriction is
  imposed (GPLv2 section 6). Supporters receive exactly the license everyone
  else does, and a refund takes none of it back.
- **No restrictive EULA.** The signed download ships with the GPLv2 text and
  the third-party notices and with no additional end-user agreement. There is
  no anti-redistribution clause, no reverse-engineering prohibition, no
  per-seat or per-device term, and no claim of ownership over third-party
  code (the FFmpeg project's checklist items 11-13 at
  https://ffmpeg.org/legal.html describe exactly the terms that would be
  incompatible). The website's account and checkout terms cover the Supporter
  purchase only.
- **Corresponding source travels with every binary.** Each signed download is
  produced from a Git tag `vx.y.z` ([docs/release.md](docs/release.md)). The
  complete corresponding source for that exact binary—including this repository,
  vendored code, all covered linked dependencies, modifications, `project.yml`,
  build/install scripts and the FFmpeg formula—is offered alongside the
  download with equivalent access and no fee (GPLv2 section 3(a) and its
  download provision). Mirror the exact dependency source, not merely links to
  third-party servers. A future section 3(b) written-offer route would instead
  require an offer valid for at least three years to any third party, subject to
  its source-distribution cost limit; it is not the selected route.
  GPLv2 expressly includes scripts controlling compilation and installation.
- **Sponsorship and support are services, not license conditions.** The
  sponsor place is a listing and priority support is time and attention. The
  software works identically with or without them.
- **Warranty.** The GPLv2 disclaimer (sections 11 and 12) applies unless this
  project states otherwise in writing. GPLv2 section 1 allows warranty
  protection to be offered for a fee; if a support tier does so, that is a
  written commitment of this project alone and binds no upstream author.

The Supporter model is distinct from release readiness: it describes how the
signed download would be offered once distribution is lawful. Until the
blockers below are resolved, there is no signed download to offer. The
Supporter purchase sells no software and does not change that.

### Mac App Store

The website shows a Mac App Store listing as coming soon. That channel has two
open questions of its own, independent of the Apache-2.0 blockers:

- **License.** In 2010 the FSF found that the App Store Terms of Service's
  Usage Rules restrict how recipients may use and distribute a program, which
  GPLv2 section 6 forbids, and Apple removed GNU Go rather than change them
  (https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement).
  This project has not reviewed Apple's current terms against section 6.
  Unless such a review shows they add no further restriction, a listing needs
  an additional permission from the copyright holders of the GPL-2.0-only
  code, the upstream renderer's included. This project has none.
- **App Review.** Apple's App Review Guidelines
  (https://developer.apple.com/app-store/review/guidelines/) require Mac App
  Store apps to be sandboxed (2.4.5(i)), not to download additional code
  (2.4.5(iv)), to take updates only through the Mac App Store (2.4.5(vii)) and
  to use public APIs only (2.5.1). The app is not sandboxed (only its
  lock-screen extension is), downloads SteamCMD at runtime, updates itself
  from GitHub Releases, and uses private interfaces: CoreGraphics and
  HIServices symbols for per-Space desktop pictures, MediaRemote, and the
  `WallpaperExtensionKit` ABI.

## Signing and notarization

Not implemented. `scripts/package.py` signs every bundled dylib, each extension
and the app ad hoc (`codesign --sign -`) by default; release builds sign them with
a self-signed project certificate instead
([docs/build.md](docs/build.md#release-signing)), only so the designated
requirement, and with it macOS privacy permissions, survives in-app updates. Both
let the bundle be checked with `codesign --verify --deep --strict`. No Developer
ID certificate is used and no notarization request is submitted.
Implementing them is engineering work that comes after distribution is cleared.

A signature can verify bundle integrity; Developer ID additionally authenticates
the developer through Apple's certificate chain. Neither an ad-hoc signature nor
the self-signed certificate authenticates a developer identity. Neither signing
nor notarization grants third-party copyright permissions or establishes license
compatibility.

## Components and their licenses

Checked 2026-09-21 against the Homebrew formulae installed on the development
machine, the vendored license files, and the dynamic link closure reported by
`otool -L` on a built `WallpaperMachine` binary. Versions are the installed
ones on that date, not pins. The Rust crates and glad were checked 2026-10-16;
see [Rust crates](#rust-crates) for how.

| Component | Where | License | GPL-2.0-only combination |
|---|---|---|---|
| Renderer (`wallpaper-core`, `shader`, `wallpaper-bridge`) | `upstream/renderer`, revision in `provenance.json` | GPL-2.0-only | Same license |
| Scene engine (open-wallpaper-engine) | `upstream/renderer/external/open-wallpaper-engine` | GPL-2.0-only (vendored under the renderer) | Same license |
| Application shell, extension, Workshop browser, control panel, scripts | `App/`, `Extension/`, `Shared/`, `scripts/` | GPL-2.0-only (this project) | Same license |
| Phosphene ABI reference | notice in `Extension/Phosphene-LICENSE.txt` | MIT | Compatible |
| ungive/mediaremote-adapter | `upstream/mediaremote-adapter` | BSD-3-Clause | Compatible; embedded as an unlinked framework |
| miniaudio | `upstream/renderer/external/open-wallpaper-engine/third_party/miniaudio` | Public domain or MIT-0 (choice) | Compatible |
| **spirv_reflect** | `upstream/renderer/external/open-wallpaper-engine/third_party/spirv_reflect`, linked statically (`spirv-reflect-static`) | Apache-2.0 | **Incompatible with GPLv2** (see below) |
| Eigen | Homebrew `eigen` 5.0.1, header-only | MPL-2.0 AND Apache-2.0 AND BSD-3-Clause AND Minpack (Homebrew metadata) | Not audited file by file; the Apache-2.0 portion must be checked for whether any of it is compiled in |
| nlohmann-json, argparse, glm | Homebrew, header-only | MIT | Compatible |
| quickjs-ng | Homebrew `quickjs-ng` 0.16.2, `libqjs` in the verified Debug dependency closure | MIT | Compatible |
| lz4 | Homebrew `lz4` 1.10.0 | BSD-2-Clause | Compatible |
| FreeType | Homebrew `freetype` 2.14.3 | FTL or GPL-2.0-or-later, licensee's choice (`LICENSE.TXT` in the keg) | Compatible under the GPLv2 option; the FTL option is not GPLv2-compatible and is not the one used |
| libpng | Homebrew `libpng` 1.6.58 (FreeType dependency) | libpng-2.0 | Compatible |
| FFmpeg | `Formula/mwe-ffmpeg.rb`, FFmpeg 8.1.2 | LGPL-2.1-or-later as configured | Compatible; see [FFmpeg](#ffmpeg) |
| dav1d | Homebrew `dav1d` 1.5.4 (FFmpeg dependency) | BSD-2-Clause | Compatible |
| **glslang** (`libglslang`, `libSPIRV`, `libglslang-default-resource-limits`) | Homebrew `glslang` 16.6.0 | BSD-3-Clause, BSD-2-Clause, MIT **and Apache-2.0** for parts of glslang proper; GPL-3.0-or-later with the Bison exception for the parser skeleton; an NVIDIA notice for the preprocessor (`LICENSE.txt` in the keg) | **Blocked** by the Apache-2.0 portion until the files under it are identified and either cleared or removed |
| **SPIRV-Tools** (`libSPIRV-Tools`, `libSPIRV-Tools-opt`, loaded by `libSPIRV`) | Homebrew `spirv-tools` 1.4.357.0 | Apache-2.0 | **Incompatible with GPLv2** |
| **Vulkan loader** (`libvulkan`) | Homebrew `vulkan-loader` 1.4.357.0 | Apache-2.0 | **Incompatible with GPLv2** |
| **MoltenVK** (`libMoltenVK`, loaded as the Vulkan ICD) | Homebrew `molten-vk` 1.4.2 | Apache-2.0 | **Incompatible with GPLv2** |
| vulkan-headers, spirv-headers | Homebrew, build-time headers | Apache-2.0 / MIT | Build-time only; whether header inclusion alone creates a covered combination is part of the open review |
| shaderc | Homebrew `shaderc`, in `build_environment()` | Apache-2.0 | Not present in the app's dynamic link closure; its role is limited to the build environment list and is to be confirmed |
| **codespan-reporting** 0.13.1 | Rust crate, a required dependency of naga 29, which the `shader` crate uses for every shader | Apache-2.0 | **Incompatible with GPLv2** |
| **spirv** 0.4.0 | Rust crate, from naga's `spv-out` feature (the Compatibility path's SPIR-V output) | Apache-2.0 | **Incompatible with GPLv2** |
| **miette** 7.6.0, **supports-color** 3.0.2, **supports-hyperlinks** 3.2.0, **supports-unicode** 3.0.0 | Rust crates, from the `shader` crate's `miette` dependency with the `fancy` feature | Apache-2.0 | **Incompatible with GPLv2** |
| **unicode-linebreak** 0.1.5 | Rust crate, from textwrap's `unicode-linebreak` feature, which miette's `fancy` turns on | Apache-2.0 | **Incompatible with GPLv2** |
| **shadow-rs** 2.0.0, **is_debug** 1.1.0 | Rust crates, a dependency of `wallpaper-bridge` | MIT AND Apache-2.0 as declared; the `LICENSE` file each crate ships holds only the MIT text | **Blocked** by the Apache-2.0 half of the declared expression |
| uniffi 0.28.3 (`uniffi`, `uniffi_core`, `uniffi_bindgen`, `uniffi_meta`, `uniffi_udl`, `uniffi_testing`), option-ext 0.2.0 | Rust crates: the Swift bridge, and `dirs` | MPL-2.0 | Compatible through MPL-2.0 section 3.3, which names GPL-2.0 as a Secondary License; none of their source files carries the "Incompatible With Secondary Licenses" notice |
| ffmpeg-next, ffmpeg-sys-next 8.1.0 | Rust crates, the FFmpeg bindings in `wallpaper-core` | WTFPL | Compatible |
| The other 158 linked Rust crates | `upstream/renderer/Cargo.lock` | 150 offer MIT, alone or as a choice; the rest are Zlib (const_format, konst, konst_macro_rules, foldhash), ISC (is_ci), BSD-3-Clause (pp-rs) or BSD-3-Clause OR Apache-2.0 (moxcms, pxfm) | Compatible under the MIT, Zlib, ISC or BSD-3-Clause terms |
| glad (an OpenGL loader generated by glad 0.1.33, with `KHR/khrplatform.h`) | `upstream/renderer/external/open-wallpaper-engine/third_party/glad`, added to the scene engine's CMake project by `add_subdirectory(glad)` in `third_party/CMakeLists.txt` | Not checked | Not part of the app as built; see [glad](#glad) |
| Valve SteamCMD | installed at runtime into the app's support directory, never bundled | Valve's terms | Outside the GPL entirely; see [Rights outside software licenses](#rights-outside-software-licenses) |

"Compatible" in this table means compatible with GPLv2 according to the FSF's
license list (https://www.gnu.org/licenses/license-list.html) or the license's
own text; it is not an audit of every file.

### Rust crates

Checked 2026-10-16 against `upstream/renderer/Cargo.lock` with `cargo tree
--offline --workspace -e normal,no-proc-macro --target aarch64-apple-darwin`.
That resolves features the way `scripts/build.py`'s `cargo build --workspace
--release` does. Each crate's license is the one its manifest declares; no
crate was reviewed file by file. The result is 176 third-party crates, all
compiled into `libwallpaper_bridge.a`, which the app links
(`-lwallpaper_bridge` in `project.yml`). A plain `cargo metadata` walk lists
more crates (git2, url and the ICU crates), because it merges the features of
shadow-rs's build-script use into its normal one. Those crates are not part of
the build.

The table below says which renderer path needs each blocked crate. "Native
Metal" and "Compatibility" (Vulkan through MoltenVK) are the two scene
renderers described in [docs/features/scene-rendering.md](docs/features/scene-rendering.md#scene-renderer):

| Crate | Pulled in by | Needed by |
|---|---|---|
| codespan-reporting | naga 29, as a dependency naga cannot be built without | Every shader compile, for Native Metal (MSL) and for Compatibility (SPIR-V) |
| spirv | naga's `spv-out` feature, enabled in `upstream/renderer/crates/shader/Cargo.toml` | Only Compatibility's SPIR-V output (`ShaderTarget::VulkanSpirv`) |
| miette, supports-color, supports-hyperlinks, supports-unicode | `miette = { features = ["fancy"] }` in `upstream/renderer/crates/shader/Cargo.toml`; the shader crate formats its diagnostics with miette's `GraphicalReportHandler` | Both paths' shader error reports. The three `supports-*` crates come from the `fancy` feature, not from miette's core |
| unicode-linebreak | textwrap 0.16's `unicode-linebreak` feature, which miette's `fancy` turns on (uniffi also uses textwrap, without that feature) | Both paths, through miette |
| shadow-rs, is_debug | `wallpaper-bridge`'s dependency on shadow-rs (`default-features = false`) and its build script | Neither path: the bridge uses only the generated `SHORT_COMMIT` constant, as a fallback for the commit hash it reports |

A Release executable built 2026-10-16 contains code from codespan-reporting,
spirv, miette, the three `supports-*` crates and unicode-linebreak (by their
names in its symbol table). It contains none from shadow-rs or is_debug: their
objects are in `libwallpaper_bridge.a`, and the linker drops them. That
describes one build and clears nothing; both stay in the dependency closure and
are counted as blockers until they are removed or reviewed.

uniffi's `cli` feature is enabled in `wallpaper-bridge`'s normal dependencies
because the package's `uniffi-bindgen` binary needs it. As a result
`uniffi_bindgen` (MPL-2.0) is compiled into the app executable as well.

Not covered: build-dependencies and proc-macros, which run inside the compiler
and are not linked (among them `miette-derive`, Apache-2.0); and the contents
of each crate beyond its declared license.

### glad

`third_party/glad` holds an OpenGL loader generated by glad 0.1.33. It is
added to the scene engine's CMake project without `EXCLUDE_FROM_ALL`, so a full
CMake build of that project would compile it. Nothing in the scene engine's
`src/` includes or links it. `upstream/renderer/crates/core/build.rs` builds
only the `wescene-renderer` target, which does not depend on it, so the
renderer build leaves it uncompiled. No glad object was found in the build
trees and no glad symbol in a Release executable built 2026-10-16. Its license
has not been checked: the generated files carry no license notice of their
own, and `KHR/khrplatform.h` carries a Khronos notice. It has no entry in the
[notice payload](#notice-payload).

## FFmpeg

Homebrew's `ffmpeg@8` is configured with `--enable-gpl --enable-version3
--enable-openssl`. That makes its libraries GPL-3.0-or-later and links
Apache-2.0 OpenSSL, neither of which can be combined with this GPL-2.0-only
program. It is no longer used.

`Formula/mwe-ffmpeg.rb` builds the same FFmpeg release (8.1.2, pinned by URL and
SHA-256) with `--disable-gpl --disable-version3 --disable-nonfree
--disable-autodetect`, so `avcodec_license()` reports "LGPL version 2.1 or
later" and the only libraries underneath it are Apple frameworks, BSD-2-Clause
dav1d and the system zlib/bzip2. FFmpeg itself states that it is LGPL-2.1-or-
later unless the GPL-only parts are enabled (https://ffmpeg.org/legal.html).

The formula is an LGPL build, **not a decode-only build**. FFmpeg's native
decoders and encoders remain, and the VideoToolbox and AudioToolbox hardware
encoders are enabled; the formula's own test asserts that `h264_videotoolbox`
is present. What is left out is the network stack, device inputs, external
encoder libraries and everything gated behind `--enable-gpl`,
`--enable-version3` or `--enable-nonfree`. Describing the build as decode-only
elsewhere is a mistake; the renderer uses decode, but the libraries can encode.

How this project follows FFmpeg's LGPL checklist (https://ffmpeg.org/legal.html):

| Item | State |
|---|---|
| Built without `--enable-gpl` and `--enable-nonfree` | Yes, and without `--enable-version3` |
| Dynamic linking | Yes: the app links `libav*.dylib` and `scripts/package.py` relocates them into `Contents/Frameworks` |
| Corresponding FFmpeg source with the exact configure line | Policy above: the formula records URL, checksum and configure arguments; the tarball is to be mirrored beside each signed download |
| No GPL libraries such as libx264 | None are enabled; `scripts/package.py` refuses libraries whose embedded configuration shows a forbidden flag ([Tooling that enforces this record](#tooling-that-enforces-this-record)) |
| Attribution in the program's about box | Not yet shown. Settings -> About names the renderer and links the GPLv2 text (`App/Views/ControlPanel/Settings/Sections/AboutSettingsSection.swift`); an FFmpeg/LGPL line there is an open item and is not part of this record |
| Do not rename the libraries to obscure names | They keep their upstream names |

FFmpeg's page also notes that companies making money from products that use
patented codecs have been approached by patent licensors. That is a business
risk of offering the signed download beside a paid Supporter purchase,
separate from copyright, and is recorded here rather than resolved.

## Remaining blockers

The FSF's position is that the Apache License 2.0 is not compatible with GPL
version 2 because of its patent-termination and indemnification terms
(https://www.gnu.org/licenses/license-list.html#apache2). These parts of every
current build are under Apache-2.0, in whole or in part, and are loaded into,
or compiled into, the same process as the GPL-2.0-only renderer:

- `libvulkan` (Vulkan loader) and `libMoltenVK` (the ICD the loader opens);
- `libSPIRV-Tools` / `libSPIRV-Tools-opt`, loaded by glslang's `libSPIRV`;
- the Apache-2.0 portion of glslang proper;
- `spirv_reflect`, vendored and statically linked into the scene engine;
- the Rust crates `codespan-reporting`, `spirv`, `miette`, `supports-color`,
  `supports-hyperlinks`, `supports-unicode` and `unicode-linebreak`
  (Apache-2.0), and `shadow-rs` and `is_debug` (declared "MIT AND
  Apache-2.0"), all compiled into `libwallpaper_bridge.a`
  ([Rust crates](#rust-crates)).

Retiring the Compatibility (Vulkan) path does not clear the Rust crates on its
own. `spirv` leaves only if naga's `spv-out` feature is dropped as well.
`codespan-reporting` stays, because naga requires it for every shader,
Native Metal's included. The `miette` group and `shadow-rs`/`is_debug` serve
neither renderer path and stay until their dependencies are changed.

Until each of these is resolved, no binary of this program may be distributed,
sold or given away. Resolution means one of:

1. **Replace** the component with one under a GPLv2-compatible license or with
   code written for this project, and remove the Apache-2.0 code from the link
   closure. For the Vulkan path this is a large engineering change (the
   renderer's native Metal backend exists but does not cover every scene; see
   [docs/features/performance.md](docs/features/performance.md)). For a Rust
   crate it means dropping the feature or dependency that pulls it in, or
   replacing the crate that needs it: naga cannot be built without
   `codespan-reporting`.
2. **Obtain compatible license grants** covering the Apache-2.0 code, or obtain
   a sufficient linking exception or GPLv3-compatible relicense from the
   copyright holders of the GPLv2-only code. A generic endorsement is not enough.
   Grants must come from the actual holders of the code involved—for the renderer that means
   every contributor whose code is in the combined work, not only the current
   repository maintainer; for the Khronos projects that means their
   contributors, not a downstream packager - and has to be kept in writing.
   This project has not requested or received any such permission and will not
   describe one as existing until it does.
3. **A qualified legal opinion** that a particular boundary (for example the
   loader/ICD interface) is an aggregation rather than a combined work. The
   FSF's guidance is that this depends on how the pieces communicate, not on
   the process or container boundary
   (https://www.gnu.org/licenses/gpl-faq.html#MereAggregation); this project
   has no such opinion and does not rely on one.

Nothing here is resolved by publishing the source. The GPL does not require a
modified version to be published at all
(https://www.gnu.org/licenses/gpl-faq.html#GPLRequireSourcePostedPublic), and
publishing one does not make its combination with incompatible code lawful to
distribute. Private use and private builds are unaffected
(https://www.gnu.org/licenses/gpl-faq.html#WhatDoesCompatMean).

Also still open, independent of the Apache-2.0 question: the file-by-file
review of Eigen; the exact set of glslang files under each of its licenses;
the Rust crates beyond their declared licenses, including build-dependencies
and proc-macros; and the license of the unused [glad](#glad) loader.

## Rights outside software licenses

None of the licenses above authorize anything on this list; each is a separate
question for any distribution and for the Supporter model:

- **Valve software.** SteamCMD is downloaded by the user at runtime into the
  app's support directory and is never bundled or redistributed. Use of
  Steam's interfaces is subject to Valve's terms, which this project has not
  reviewed with counsel.
- **Wallpaper Engine assets.** Scene wallpapers need shared resources from a
  purchased Wallpaper Engine installation. They are proprietary, are not
  bundled, and the app does not distribute them.
- **Workshop content.** Wallpapers belong to their creators and are downloaded
  by the user with the user's own Steam account. The app does not host or
  redistribute them.
- **Product naming.** The application is named WallpaperMachine, but the
  website and the README lead with the third-party product name "Wallpaper
  Engine" ("Wallpaper Engine. Meet your Mac."). Settings -> About, the website
  and the README state that the project is not affiliated with Wallpaper
  Engine or Valve. Whether that use of the name can accompany a paid Supporter
  offering is a trademark question this project has not had reviewed.
- **Private Apple API.** The lock-screen extension uses the private
  `WallpaperExtensionKit` ABI, which is not an Apple-supported public API.
  This is a platform-policy and support risk, not a license question, and it
  is unaffected by anything in this document.

## Tooling that enforces this record

As implemented by `scripts/package.py` and `.github/workflows/build.yml`
([docs/build.md](docs/build.md), [docs/release.md](docs/release.md)):

- `scripts/package.py` runs a preflight before touching the bundle. It refuses
  to package FFmpeg libraries whose embedded configuration is not an LGPL
  build (license string other than "LGPL version 2.1 or later", or
  `--enable-gpl`, `--enable-version3` or `--enable-nonfree` present), and it
  refuses when any notice it must bundle is missing. `--check` runs only the
  preflight.
- `.github/workflows/build.yml` used to fail at its first step, citing this
  file. The maintainer removed that step for 1.0.0 (2026-09-26), so CI now
  publishes release disk images while the blockers below are still open.
- Local disk images produced by `scripts/package.py` are labelled as not cleared
  for distribution.

These checks catch the GPLv3 FFmpeg mistake and a missing notice. They do not
and cannot detect the Apache-2.0 problem, which is a matter of what is linked,
not of a string in a library.

### Notice payload

`scripts/package.py` writes the following into the app bundle:

- `Contents/Resources/WallpaperMachine-LICENSE.txt`: the root `LICENSE`;
- `Contents/Resources/LICENSING.md`: this file;
- `Contents/Resources/Renderer-LICENSE.txt`: `upstream/renderer/LICENSE`;
- `Contents/Resources/provenance.json`: `upstream/provenance.json`;
- `Contents/Resources/Licenses/<formula>-<version>/`: every `LICENSE*`,
  `COPYING*`, `COPYRIGHT*` and `NOTICE*` file of each Homebrew keg in the link
  closure;
- `Contents/Resources/Licenses/renderer-third-party/{miniaudio,spirv_reflect}/LICENSE`.

Xcode separately bundles `Contents/Resources/LICENSE` (mediaremote-adapter's
BSD-3-Clause notice) and the extension's `Phosphene-LICENSE.txt`.

No notice from the [Rust crates](#rust-crates) is bundled yet, although the
MIT, ISC and BSD-3-Clause terms of the linked crates ask for their notices to
go with binary copies.

## Implementation record

The native application is named **WallpaperMachine**; its bundle identifier
prefix is `app.wallpapermachine`.

- Renderer source is in `upstream/renderer`, based on revision
  `8c19c002ff37930c68117dd591dfe3f44792e25e`, modified as recorded in
  `upstream/provenance.json`.
- The application shell in `App/` is a derived work of that renderer revision's
  `app/WallpaperEngine` sources, relocated out of `upstream/renderer` so the
  sources this project actively develops are not mixed into vendored
  third-party code. The relocation moves files only: GPL-2.0-only terms and the
  upstream copyright notices continue to apply.
- The native lock-screen extension is in `Extension/`, with
  `Extension/Phosphene-LICENSE.txt` carrying the third-party notice for the
  MIT-licensed [Phosphene](https://github.com/kageroumado/phosphene/tree/8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6)
  protocol/Codable layout used as an ABI reference.
- The Workshop browser and downloader were independently implemented for this
  client.
- System now-playing metadata uses [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
  at revision `73f14ab1568371e6e3c44063f21c34c5e2712c4d`, BSD-3-Clause, vendored
  under `upstream/mediaremote-adapter` with the `src/adapter/stream.m` changes
  recorded in `upstream/provenance.json`, and built as an embedded, unlinked
  framework.
- The control panel's icons are SF Symbols, drawn by macOS at run time; no
  icon artwork is copied into the app or the repository, so no icon notice
  ships.
- FFmpeg comes from `Formula/mwe-ffmpeg.rb` via `python3
  scripts/install_ffmpeg.py`, replacing Homebrew's `ffmpeg@8`.

## Before any distribution

- Resolve every entry under [Remaining blockers](#remaining-blockers) by
  replacement or by written permission from the actual copyright holders, and
  record the outcome here with the evidence.
- Complete the file-level review of Eigen and glslang, review the Rust crates
  beyond their declared licenses, and check glad's license or take it out of
  the scene engine's CMake project.
- Bundle the notices of the Rust crates the app links.
- Implement Developer ID signing and notarization in the release pipeline, and
  remove the unconditional failure from `.github/workflows/build.yml` only
  after the blockers are recorded as resolved.
- Add the FFmpeg/LGPL attribution to Settings -> About.
- Mirror the corresponding source (repository at the tag, FFmpeg tarball) at
  the place the signed download is offered.
- Review Valve's terms and the product-name question with counsel before the
  first public download or Supporter sale.
- Before any Mac App Store listing, settle both questions under
  [Mac App Store](#mac-app-store).
- Keep every third-party notice intact and identify modifications as GPLv2
  section 2(a) requires.

## Local build and use

This build targets Apple Silicon and macOS 15 or later, and requires Xcode and
Homebrew. Packaged renderer libraries are bundled into the app for local use
only and are not cleared for distribution.

- Prerequisites, dependencies and commands: [docs/build.md](docs/build.md).
- Steam sign-in, download and scene-asset behavior:
  [docs/features/workshop-downloads.md](docs/features/workshop-downloads.md).

Dated verification history: [docs/testing/verification-log.md](docs/testing/verification-log.md).

## References

- GNU GPL version 2 text: https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
- GPL FAQ, selling copies: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowMoney
- GPL FAQ, download fees and equivalent source access: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowDownloadFee
- GPL FAQ, no fee may be required of others' recipients: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowRequireFee
- GPL FAQ, selling modified versions commercially: https://www.gnu.org/licenses/gpl-faq.html#GPLCommercially
- GPL FAQ, GPLv2/GPLv3 incompatibility: https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility
- GPL FAQ, what "compatible" means: https://www.gnu.org/licenses/gpl-faq.html#WhatDoesCompatMean
- GPL FAQ, no obligation to publish private modifications: https://www.gnu.org/licenses/gpl-faq.html#GPLRequireSourcePostedPublic
- GPL FAQ, aggregation versus combined work: https://www.gnu.org/licenses/gpl-faq.html#MereAggregation
- FSF license list, Apache 2.0 incompatible with GPLv2: https://www.gnu.org/licenses/license-list.html#apache2
- FSF, selling free software: https://www.gnu.org/philosophy/selling.html
- FFmpeg license and LGPL compliance checklist: https://ffmpeg.org/legal.html
- Renderer license file: https://github.com/bigsaltyfishes/wallpaper-engine-for-macos/blob/main/LICENSE
- FSF, App Store terms and GPL section 6: https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement
- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- WallpaperMachine terms of service (Supporter purchase, Paddle): https://www.wallpapermachine.app/terms/
- WallpaperMachine refund policy: https://www.wallpapermachine.app/refunds/
