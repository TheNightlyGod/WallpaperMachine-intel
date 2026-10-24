# Licensing, Supporter model and distribution status

Recorded: 2026-10-22 (first recorded 2026-09-14).
Status: source license GPL-3.0-only (changed from GPL-2.0-only on 2026-10-22, see
[Source license](#source-license-gpl-30-only)); Supporter model decided (a free
signed download, and a one-time Supporter purchase for a sponsor place and
priority support); **binary distribution is not cleared**: the items under
[Before any distribution](#before-any-distribution) are open (see
[Remaining blockers](#remaining-blockers)).

This document is the project's own record of what it has checked and decided.
It is not legal advice and it does not claim clearance that has not been
obtained. Where a statement below rests on a third party's text, the primary
source is linked.

## Summary

| Question | Answer |
|---|---|
| Under which license is this repository's source offered? | GNU GPL version 3 only, the text in the root [`LICENSE`](LICENSE). See [Source license](#source-license-gpl-30-only). |
| Is anything sold? | Only the Supporter purchase: a one-time payment for a sponsor place and priority support. The signed download is free and no copy of the software is sold. See [Supporter model](#supporter-model-free-signed-download-paid-sponsorship-and-support). |
| Can it be distributed today? | Not cleared. The upstream GPL-2.0-only expression has been rewritten and every linked component's declared license is GPLv3-compatible, but two contributors' written permissions are reported and not yet filed, this record has not been reviewed by counsel, and the items under [Before any distribution](#before-any-distribution) are open. See [Remaining blockers](#remaining-blockers). |
| Is a Developer ID signed, notarized build available? | No. `scripts/package.py` signs ad hoc, or with a self-signed project certificate for releases. Signing is a platform mechanism, not a license grant. See [Signing and notarization](#signing-and-notarization). |
| Can it be listed on the Mac App Store? | Not as the app is built today, and not without first settling the GPL question. See [Mac App Store](#mac-app-store). |
| Does publishing this source resolve the blockers? | No. Distribution of the combined program is what the licenses govern; posting the repository changes nothing about it. |

## Source license: GPL-3.0-only

This project's code is offered under GNU GPL version 3 only, except where an
existing notice specifies different terms. Third-party code retains its own
licenses; the root license does not replace them. The root [`LICENSE`](LICENSE)
is the unmodified GPLv3 text published by the FSF
(https://www.gnu.org/licenses/gpl-3.0.txt).

Until 2026-10-22 the project was GPL-2.0-only. It inherited that from the code it
was built on: the renderer it imported on 2026-09-14
(bigsaltyfishes/wallpaper-engine-for-macos at `8c19c002`, whose `Cargo.toml` declares
`license = "GPL-2.0-only"`), that renderer's application shell (the origin of `App/`),
and the scene engine vendored under it (bigsaltyfishes' fork of
waywallen/open-wallpaper-engine at `c4c36357`). GPL-2.0-only code cannot be combined
with GPLv3 code or relicensed by anyone but its copyright holders
(https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility), and no holder of that
code was asked for or gave a grant.

The change rests instead on replacing that code. Between 2026-10-17 and 2026-10-22
every part of the imported renderer, shell and scene engine that carried substantial
upstream expression was rewritten under a clean-room protocol, module by module: a
study session that read the old code wrote a behavior and contract specification
without its expression, deleted the old code, and a separate session that never read
it, its history or the study notes wrote the replacement and its tests from that
specification; every replacement test was shown to fail when the behavior it covers is
broken. `ThirdParty/provenance.json` records each replacement, its specification and its
verification under `renderer.*Replacement` and `sceneEngine.*Replacement` and the later
entries of 2026-10-22. The measure used to find upstream expression is runs of 8 or
more consecutive lines (gaps of at most 2) that also occur in the import snapshot. On
2026-10-22 the tree has no such run outside:

- the generated Swift bindings in `App/Bridge/Generated/`, which `uniffi-bindgen`
  produces from the exported API's names and types;
- the license texts themselves (see below) and nothing else in the rewritten renderer (then
  under `upstream/renderer`; since 2026-10-23 in `Renderer/Core`, `Renderer/Bridge` and
  `Renderer/Engine`, see [Implementation record](#implementation-record));
- 30 lines in `App/`: Apple's standard `Info.plist` keys with Xcode build variables, and
  property assignments and a five-field struct in `App/ViewModels/BridgeStore.swift`
  whose names are dictated by the exported API.

Interface names, field lists, API signatures and one-line idioms still match in places;
they are facts of the interfaces the code implements, not copied expression. Three
small contributors to the imported code were checked line by line: the code of wjj-8283's
two scene-engine commits (non-finite audio sanitizing, horizontal flip) was cut and
re-implemented from a specification on 2026-10-22 by a session that had not seen it; the
handful of lines that came out the same are dictated by the interface (two threshold
constants, the flip's command name and one call, a mirrored coordinate `1 - x`, and an
`isfinite` filter); of OiCkilL's four commits, what remains is
declarations (`std::weak_ptr<SceneMaterial> material;`, a method signature), the
`if (material == nullptr) continue;` idiom, the name `synchronizeStatusItem` with a
standard `DispatchQueue.main.async { [weak self] in` guard, and the signature of
AppKit's `applicationShouldHandleReopen`.

What the root `LICENSE` does and does not do:

- It states the terms under which this project's code (`App/`, `Extension/`,
  `Shared/`, `Renderer/` (the rewritten renderer and scene engine among it), `Tests/`,
  `scripts/` and `project.yml`) is offered.
- It does not transfer or relicense anyone else's copyright. The mediaremote-adapter
  authors, Phosphene, naga and every other holder named in `ThirdParty/provenance.json`
  and in the notices under `ThirdParty/` keep their copyright and their own license terms.
  Third-party notices are retained where they were found and are bundled by
  `scripts/package.py` (see [Notice payload](#notice-payload)).
- The upstream projects' GPLv2 texts are kept, renamed, as
  `ThirdParty/received-licenses/wallpaper-engine-for-macos.GPL-2.0.txt` and
  `ThirdParty/received-licenses/open-wallpaper-engine.GPL-2.0.txt`: they record
  under which terms the imported code was received, not the terms of any code in the tree.
  The imported code itself remains in this repository's Git history under those terms.
- Three people besides the maintainer contributed to the project's own code after the
  import, while it was GPL-2.0-only. Their contributions are under the terms they gave
  them, and offering them under GPL-3.0-only needs each one's permission:
  - **Morax** (163 commits; about 91,000 lines at HEAD across `App/`, `Tests/`, the Rust
    bridge and core crates, the scene engine including its Native Metal renderer
    `Scene/MetalRender`, and `scripts/`). The maintainer holds Morax's permission to offer
    all of these contributions under GPL-3.0-only (given to the maintainer personally; not
    filed in this repository).
  - **Henry Yang** (3 commits; about 130 lines, mostly the bridge's
    `actor/snapshots.rs` and `actor/state.rs` and `tests/metal_scene_draw_smoke.mm`, a few in
    `App/` and `Extension/`). No permission is filed.
  - **Hi-Jiajun** (3 commits, `50dd988f0`, `d53864e34`, `ca5b7b1bb`; about 370 lines of the
    solar automation: `SolarLocationTracker.swift`, the `WallpaperAutomation*` sources and
    tests, `DisplaysGroups.swift`). No permission is recorded.
  On 2026-10-22 the maintainer decided to offer Henry Yang's and Hi-Jiajun's small
  contributions under GPL-3.0-only without a filed permission, accepting that either may
  object; should one ask, their lines are replaced. That is the maintainer's decision, not a
  grant (see [Remaining blockers](#remaining-blockers)).

The application shell, extension and Workshop browser are recorded in
`ThirdParty/provenance.json` under `applicationShell`, `lockScreenExtension` and
`workshopBrowser`. The browser is independently implemented; no code from the
Unayung/wallpaper-engine-mac project
(https://github.com/Unayung/wallpaper-engine-mac/blob/main/LICENSE) was copied,
translated or adapted.

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
  conveying and modification are outside the license (GPLv3 sections 2 and 9), so
  support and a sponsor listing are services the GPL does not regulate; GPLv3
  section 4 expressly allows offering support or warranty protection for a fee.
- When a binary is offered for download, offering equivalent access to copy
  the corresponding source from the same place counts as conveying the
  source (GPLv3 section 6(d);
  https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowDownloadFee).
- No further restrictions may be imposed on recipients' exercise of the rights
  the GPL grants (GPLv3 section 10). That covers the terms of every channel a
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
  themselves, gratis or for any price, under GPLv3. No further restriction is
  imposed (GPLv3 section 10). Supporters receive exactly the license everyone
  else does, and a refund takes none of it back.
- **No restrictive EULA.** The signed download ships with the GPLv3 text and
  the third-party notices and with no additional end-user agreement. There is
  no anti-redistribution clause, no reverse-engineering prohibition, no
  per-seat or per-device term, and no claim of ownership over third-party
  code (terms of that kind are what the GPL forbids). The website's account and checkout terms cover the Supporter
  purchase only.
- **Corresponding source travels with every binary.** Each signed download is
  produced from a Git tag `vx.y.z` ([docs/release.md](docs/release.md)). The
  complete corresponding source for that exact binary—including this repository,
  vendored code, all covered linked dependencies, modifications, `project.yml`,
  build/install scripts—is offered alongside the
  download with equivalent access and no fee (GPLv3 section 6(d)). Mirror the
  exact dependency source, not merely links to third-party servers. A future
  section 6(b) written-offer route would instead require an offer valid for at
  least three years to anyone who possesses the object code, at no more than the
  cost of physically performing the conveying; it is not the selected route.
  GPLv3's Corresponding Source (section 1) expressly includes the scripts used to
  control compilation and installation.
- **Sponsorship and support are services, not license conditions.** The
  sponsor place is a listing and priority support is time and attention. The
  software works identically with or without them.
- **Warranty.** The GPLv3 disclaimer (sections 15 and 16) applies unless this
  project states otherwise in writing. GPLv3 section 4 allows warranty
  protection to be offered for a fee; if a support tier does so, that is a
  written commitment of this project alone and binds no upstream author.

The Supporter model is distinct from release readiness: it describes how the
signed download would be offered once distribution is lawful. Until the
blockers below are resolved, there is no signed download to offer. The
Supporter purchase sells no software and does not change that.

### Mac App Store

The website shows a Mac App Store listing as coming soon. That channel has two
open questions of its own, independent of the license-compatibility items:

- **License.** In 2010 the FSF found that the App Store Terms of Service's
  Usage Rules restrict how recipients may use and distribute a program, which
  GPLv2 section 6 forbids, and Apple removed GNU Go rather than change them
  (https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement).
  GPLv3 section 10 carries the same rule. This project has not reviewed Apple's
  current terms against it. Unless such a review shows they add no further
  restriction, a listing needs an additional permission from every copyright
  holder of the program's GPL code, Morax and Henry Yang included, and of any
  third-party GPL component. This project has none.
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
ones on that date, not pins. The Rust crates were checked 2026-10-17;
see [Rust crates](#rust-crates) for how.

| Component | Where | License | Combination with GPL-3.0-only |
|---|---|---|---|
| Renderer (`wallpaper-core`, `wallpaper-bridge`) | `Renderer/Core`, `Renderer/Bridge` (rewritten; origin in `provenance.json`) | GPL-3.0-only (this project) | Same license |
| Shader layer (`wm-shader`: Wallpaper Engine shader text to Metal Shading Language, reflection, the C ABI the scene engine calls) | `Renderer/Shader` (a member of the `Renderer/Cargo.toml` workspace), linked into `libwallpaper_bridge.a` | GPL-3.0-only (this project; clean-room, see the [implementation record](#implementation-record)) | Same license |
| Scene engine (rewritten from the imported open-wallpaper-engine fork) | `Renderer/Engine` (rewritten; origin in `provenance.json`) | GPL-3.0-only (this project) | Same license |
| Application shell, extension, Workshop browser, control panel, scripts, new renderer code | `App/`, `Extension/`, `Shared/`, `Renderer/`, `scripts/` | GPL-3.0-only (this project) | Same license |
| Phosphene ABI reference | notice in `Extension/Phosphene-LICENSE.txt` | MIT | Compatible |
| ungive/mediaremote-adapter | `ThirdParty/mediaremote-adapter` | BSD-3-Clause | Compatible; embedded as an unlinked framework |
| miniaudio | `ThirdParty/miniaudio` | Public domain or MIT-0 (choice) | Compatible |
| stb_image | `ThirdParty/stb_image/stb_image.h`, v2.26 | Public domain or MIT, licensee's choice (end of the header) | Compatible |
| stb_vorbis | `ThirdParty/stb_vorbis`, v1.22 (nothings/stb commit `1ee679ca`), unchanged, linked statically (`stb_vorbis`) | Public domain (Unlicense) or MIT, licensee's choice (`LICENSE` there and the end of `stb_vorbis.c`) | Compatible |
| nlohmann-json, argparse | Homebrew, header-only | MIT | Compatible |
| quickjs-ng | Homebrew `quickjs-ng` 0.16.2, `libqjs` in the verified Debug dependency closure | MIT | Compatible |
| lz4 | Homebrew `lz4` 1.10.0 | BSD-2-Clause | Compatible |
| FreeType | Homebrew `freetype` 2.14.3 | FTL or GPL-2.0-or-later, licensee's choice (`LICENSE.TXT` in the keg) | Compatible under the GPL-2.0-or-later option, used under GPLv3 |
| libpng | Homebrew `libpng` 1.6.58 (FreeType dependency) | libpng-2.0 | Compatible |
| naga 29.0.3 | Rust crate, a patched copy vendored in `ThirdParty/naga` (`ThirdParty/naga/PATCHES.md`): the shader translator and validator the `wm-shader` crate (`Renderer/Shader`) uses for every shader; built with `glsl-in` and `msl-out` only | MIT OR Apache-2.0, used under MIT | Compatible under the MIT terms; the patch makes Apache-2.0 `codespan-reporting` an optional dependency `wm-shader` does not enable, so it is no longer linked, and dropping `spv-out` removed the Apache-2.0 `spirv` crate |
| uniffi 0.28.3 (`uniffi`, `uniffi_core`, `uniffi_bindgen`, `uniffi_meta`, `uniffi_udl`, `uniffi_testing`), option-ext 0.2.0 | Rust crates: the Swift bridge, and `dirs` | MPL-2.0 | Compatible through MPL-2.0 section 3.3, whose Secondary Licenses include GPL-2.0 "or any later version", so GPLv3; none of their source files carries the "Incompatible With Secondary Licenses" notice |
| The other 140 linked Rust crates | `Renderer/Cargo.lock` | 136 offer MIT, alone or as a choice; the rest are Zlib (foldhash), BSD-3-Clause (pp-rs) or BSD-3-Clause OR Apache-2.0 (moxcms, pxfm) | Compatible under the MIT, Zlib or BSD-3-Clause terms |
| Valve SteamCMD | installed at runtime into the app's support directory, never bundled | Valve's terms | Outside the GPL entirely; see [Rights outside software licenses](#rights-outside-software-licenses) |

"Compatible" in this table means compatible with GPLv3 according to the FSF's
license list (https://www.gnu.org/licenses/license-list.html) or the license's
own text; it is not an audit of every file.

Removed on 2026-10-17, each from the source tree, the build and the link closure (the
commits are in this repository's history, and `ThirdParty/provenance.json` records them).
They were removed under the earlier GPL-2.0-only policy, which Apache-2.0 and the GPL-3.0
family could not join; every one of them is GPLv3-compatible, so bringing one back is a
product decision, not a license question:

| Component | License | Removed by |
|---|---|---|
| `spirv_reflect` (vendored, `spirv-reflect-static`) | Apache-2.0 | `19aeb2e8` |
| Vulkan Memory Allocator (`vk_mem_alloc.h`, vendored) | MIT | `19aeb2e8` |
| The Vulkan renderer, its wrapper and swapchain code, the SPIR-V shader target | project code | `19aeb2e8` |
| `spirv` 0.4.0, Rust crate (naga's `spv-out` feature) | Apache-2.0 | `19aeb2e8` |
| glslang (`libglslang`, `libSPIRV`, `libglslang-default-resource-limits`) | BSD-3-Clause, BSD-2-Clause, MIT, Apache-2.0 for parts, GPL-3.0-or-later with the Bison exception for the parser skeleton | `19aeb2e8` (linking), `a289d5e9` (Homebrew dependency) |
| SPIRV-Tools (`libSPIRV-Tools`, `libSPIRV-Tools-opt`) | Apache-2.0 | `19aeb2e8` (linking), `a289d5e9` (Homebrew dependency) |
| Vulkan loader (`libvulkan`) | Apache-2.0 | `19aeb2e8` (linking), `a289d5e9` (Homebrew dependency) |
| MoltenVK (`libMoltenVK`, the Vulkan ICD) and `MoltenVK_icd.json` | Apache-2.0 | `19aeb2e8` (use), `a289d5e9` (bundling) |
| vulkan-headers, spirv-headers, shaderc (Homebrew, build-time) | Apache-2.0 / MIT | `a289d5e9` |
| FFmpeg 8.1.2 (`libavformat`, `libavcodec`, `libavutil`, `libswresample`, built by `Formula/mwe-ffmpeg.rb`; the formula and `scripts/install_ffmpeg.py` are deleted) | LGPL-2.1-or-later as configured | `3c55d52b` (audio decoder), `f0e3b270` (video backend, engine link), `d2c891aa` (Rust decoder, link lines), `b6ba0c32` (app link flags, formula, installer, preflight, CI cache) |
| dav1d (Homebrew, FFmpeg's AV1 decoder) | BSD-2-Clause | `b6ba0c32` |
| `ffmpeg-next`, `ffmpeg-sys-next` 8.1.0, Rust crates (the FFmpeg bindings in `wallpaper-core`) | WTFPL | `d2c891aa` |
| `hermit-abi`, `num_cpus`, `pkg-config`, `vcpkg`, Rust crates (build dependencies only `ffmpeg-sys-next` pulled in) | MIT OR Apache-2.0 (`vcpkg`: MIT/Apache-2.0) | `d2c891aa` |

### Rust crates

Checked 2026-10-17 (and again after the FFmpeg crates left, `d2c891aa`) against `Renderer/Cargo.lock` with `cargo tree
--offline --workspace -e normal,no-proc-macro --target aarch64-apple-darwin`.
That resolves features the way `scripts/build.py`'s `cargo build --workspace
--release` does. Each crate's license is the one its manifest declares; no
crate was reviewed file by file. The result is 148 third-party crates (naga counted among them, as the
vendored copy in `ThirdParty/naga`), all compiled into `libwallpaper_bridge.a`,
which the app links (`-lwallpaper_bridge` in `project.yml`).

Native Metal is the only scene renderer ([docs/features/scene-rendering.md](docs/features/scene-rendering.md#scene-renderer)).
The Compatibility renderer (Vulkan through MoltenVK) and its SPIR-V shader target are
deleted: the `spirv` crate (Apache-2.0) left the closure with naga's `spv-out` feature
(`Renderer/Cargo.toml`'s workspace dependency builds naga with `glsl-in` and `msl-out`),
and `codespan-reporting` left earlier through the vendored naga's optional dependency.

A Release executable built 2026-10-16, before codespan-reporting and spirv left the
closure, contained code from both, among others (by their names in its symbol table). That
describes one build and clears nothing by itself; the closure check below is what
reports the current state.

uniffi's `cli` feature is enabled in `wallpaper-bridge`'s normal dependencies
because the package's `uniffi-bindgen` binary needs it. As a result
`uniffi_bindgen` (MPL-2.0) is compiled into the app executable as well.

Not covered: build-dependencies and proc-macros, which run inside the compiler
and are not linked; and the contents
of each crate beyond its declared license.

## FFmpeg

FFmpeg is no longer used. It was removed on 2026-10-17 (`3c55d52b`, `f0e3b270`,
`d2c891aa`, `b6ba0c32`; [Components and their licenses](#components-and-their-licenses)
lists them), so the app links, bundles and caches no `libav*`, `libsw*` or
`libpostproc` library, no FFmpeg bindings and no dav1d, and the repository has
no FFmpeg formula or installer. Checked on the Release
app built from `b6ba0c32` has no `libav*` among its Mach-O dependencies (`otool
-L` on the app executable and on the lock-screen extension lists only
`liblz4`, `libfreetype` and `libqjs` outside Apple's libraries, and
`Contents/Frameworks` of a built bundle holds only the unlinked
`MediaRemoteAdapter.framework` until packaging), and no `_av_*`, `_avcodec_*`,
`_avformat_*`, `_sws_*` or `_swr_*` symbol is undefined in it.

What replaced it, all written for this project or taken from the system:

- Video: the project's own MP4/QuickTime and WebM/Matroska readers
  (`Renderer/Media`) feed VideoToolbox, which decodes H.264, HEVC, VP9 and, where
  the Mac has the hardware, AV1. The app's own players (AVFoundation, and the WebM
  player) play a plain video wallpaper and the lock screen; the scene engine
  plays a scene's video textures with the same readers and decoder.
- Sound: AudioToolbox decodes MP3, AAC, FLAC, WAV and the rest the system reads;
  Ogg Vorbis is the vendored, public-domain `stb_vorbis`; remixing, resampling and
  looping are `Renderer/Sound`.

What stopped working with it: VP8, AV1 on a Mac without an AV1 hardware decoder,
4:2:2 video, a fragmented MP4 and a container other than the four above. Each now
fails with a reason that starts "format not supported: " where the format is the
cause, and the wallpaper keeps its last picture.

Before this change the project had already replaced Homebrew's `ffmpeg@8`
(configured with `--enable-gpl --enable-version3 --enable-openssl`, so
GPL-3.0-or-later with Apache-2.0 OpenSSL, neither of which could be combined with
the program while it was GPL-2.0-only) by an LGPL-2.1-or-later build of the same
release. Neither is part of the product now; an optional FFmpeg fallback for the lost
formats is a separate, later decision.

FFmpeg's command-line tools are not part of the repository, the build or any
distribution. A developer may have `ffmpeg` or `ffprobe` installed: the test fixtures
under `Tests/Unit/NativeVideo` and `Renderer/Sound/tests` record the commands that
generated them (embedded as bytes, so no test needs the tool), and the container
readers' optional corpus checks compare with `ffprobe` when it is present
(`docs/container-readers.md`). That is use of a tool by a developer, not a
dependency of the program.

The earlier note about patented codecs (that FFmpeg's page says companies
making money from products using them have been approached by patent licensors) was
recorded while FFmpeg's software codecs were bundled. The program now carries no
codec implementation of its own beyond `stb_vorbis` (Vorbis) and delegates the rest
to Apple's VideoToolbox and AudioToolbox. That is a statement of what is bundled, not
a legal conclusion: Apple's terms for those frameworks and the business risk of a
signed download beside a paid Supporter purchase have not been reviewed by counsel.

## Remaining blockers

Since 2026-10-22 the program is GPL-3.0-only. GPLv3 is compatible with the
Apache License 2.0, the GPL-3.0 family, LGPL, MPL-2.0 and the permissive licenses
(https://www.gnu.org/licenses/license-list.html); what it cannot be combined with is
code available only under GPL-2.0-only
(https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility). `scripts/check_licenses.py`
applies that policy: GPL-2.0-only and unknown licenses fail.

Open before any distribution:

1. **Contributor permissions.** The maintainer holds Morax's permission for all of
   Morax's contributions; it is not filed here. Henry Yang's and Hi-Jiajun's small
   contributions are offered without a permission by the maintainer's decision of
   2026-10-22 (see [Source license](#source-license-gpl-30-only)). A counsel review would
   weigh both.
2. **A run of the closure check on the app to be distributed.**
   `python3 scripts/check_licenses.py --enforce` on that Release app, with the outcome
   recorded here.
3. **The Rust crates beyond their declared licenses**, including build-dependencies and
   proc-macros.
4. **A qualified legal review** of this record, before charging money or calling
   distribution cleared. None has been obtained, and nothing here is a legal opinion.

The state on 2026-10-17, before the change of license: `python3 scripts/check_licenses.py
--enforce` on a Release app built from `b6ba0c32` reported 177 components with 0
Apache-2.0, 0 GPL-3.0 family, 0 unknown and 0 not named in this file; after the shader
layer was replaced (`7141a105`), 174 components with the same zeros. Under the current
policy Apache-2.0 and the GPL-3.0 family no longer fail; the count of unknown licenses
and of GPL-2.0-only components is what matters. On 2026-10-22, after the change,
`python3 scripts/check_licenses.py --skip-app` on the tree reports 172 components (24
compiled-in or statically linked inventory entries, 148 third-party and 3 first-party Rust
crates) with 0 GPL-2.0-only, 0 incompatible, 0 unknown and 0 not named in this file. With
`--enforce` on a Release app built from `2794fa3f2` it reports 174 components (3 Mach-O roots,
5 third-party libraries, 24 inventory entries, 148 third-party Rust crates) with the same zeros.
That app was built locally to verify the change, not for distribution.

Should a GPL-2.0-only component enter the closure, the check reports it and no binary
may be distributed until it is replaced, or its copyright holders grant use under
GPLv3 in writing. A generic endorsement is not enough: a grant must come from the
actual holders of the code involved and be kept in writing.

Nothing here is resolved by publishing the source. The GPL does not require a
modified version to be published at all
(https://www.gnu.org/licenses/gpl-faq.html#GPLRequireSourcePostedPublic), and
publishing one does not make its combination with incompatible code lawful to
distribute. Private use and private builds are unaffected
(https://www.gnu.org/licenses/gpl-faq.html#WhatDoesCompatMean).

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
  when any notice it must bundle is missing, or any Homebrew keg it bundles ships
  no license file, and it generates `THIRD-PARTY-NOTICES.txt` (below); a generation
  failure refuses too, a component whose license text is not found only with
  `--require-notices`. `--check` runs only the preflight. (It used to refuse FFmpeg
  libraries whose embedded configuration was not an LGPL build; no FFmpeg library
  is linked now.)
- `.github/workflows/build.yml` used to fail at its first step, citing this
  file. The maintainer removed that step for 1.0.0 (2026-09-26), so CI now
  publishes release disk images while the items under [Before any distribution](#before-any-distribution) are open.
- Local disk images produced by `scripts/package.py` are labelled as not cleared
  for distribution.
- `python3 scripts/check_licenses.py` lists the license of every Mach-O
  dependency of the built app (`otool -L`, walked recursively from the main
  executable, the extension and `Contents/Frameworks`), of the third-party code compiled or statically linked into the
  renderer (a source inventory: `Renderer/Core/build.rs`, the scene engine's CMake
  `find_package` targets and the C libraries in `ThirdParty/`, against a hand-kept license table
  in the script) and of every linked Rust crate (`cargo tree`, the same set as
  [Rust crates](#rust-crates); a vendored path crate under `ThirdParty/`, naga,
  counts as third party with the license its
  `Cargo.toml` declares). It classifies SPDX expressions against one
  policy table (today GPL-3.0-only: GPL-2.0-only, GPLv3-incompatible and unknown licenses fail) and prints any failing component, and any component
  this file does not name. It is report-only by default; `--enforce` exits 1.
  It needs a built app, Homebrew and Cargo, so the routine gate does not run it.
- `python3 scripts/notices.py` reuses that closure and writes `THIRD-PARTY-NOTICES.txt`:
  for every third-party component its name, version, SPDX license and the license text
  taken from the component itself (a crate's `LICENSE*` files in the cargo registry or
  under `ThirdParty/`, the Homebrew keg's license files, a vendored library's file or the
  notice at the end of its header). Of a dual `MIT OR Apache-2.0` crate the MIT text is
  written, the option this project uses; files are matched to the license by what they
  say, not by name. A component with no text found is marked `LICENSE TEXT NOT FOUND`;
  `--enforce` exits 1 on one. `scripts/package.py` runs the same generator.

The packaging checks catch a missing notice. A GPL-2.0-only component is a matter of
what is linked, not of a string in one library; `scripts/check_licenses.py` reports
it from the link closure, in report-only mode unless `--enforce` is given. Its
license table carries no entry for FFmpeg or dav1d, so a `libav*` library or CMake
package that returns is reported as unknown.

### Notice payload

`scripts/package.py` writes the following into the app bundle:

- `Contents/Resources/WallpaperMachine-LICENSE.txt`: the root `LICENSE`;
- `Contents/Resources/LICENSING.md`: this file;
- `Contents/Resources/Imported-Renderer-GPL-2.0-LICENSE.txt`:
  `ThirdParty/received-licenses/wallpaper-engine-for-macos.GPL-2.0.txt`, the terms under which the imported renderer
  was received, not the license of the code now;
- `Contents/Resources/provenance.json`: `ThirdParty/provenance.json`;
- `Contents/Resources/Licenses/<formula>-<version>/`: every `LICENSE*`,
  `COPYING*`, `COPYRIGHT*` and `NOTICE*` file of each Homebrew keg in the link
  closure;
- `Contents/Resources/Licenses/renderer-third-party/{miniaudio,stb_vorbis}/LICENSE`;
- `Contents/Resources/THIRD-PARTY-NOTICES.txt`: generated by `scripts/notices.py`, one
  entry per third-party component of the link closure (Homebrew libraries, the
  compiled-in code, every linked Rust crate, mediaremote-adapter and the Phosphene ABI
  notice), each with its SPDX license and the license text taken from the component. The
  disk image carries only the app bundle, so the file travels inside the app.

Xcode separately bundles `Contents/Resources/LICENSE` (mediaremote-adapter's
BSD-3-Clause notice) and the extension's `Phosphene-LICENSE.txt`.

The generated file closes the gap that the [Rust crates](#rust-crates) had no notice
in the bundle, although the MIT, ISC and BSD-3-Clause terms of the linked crates ask for
their notices to go with binary copies. Checked 2026-10-17 (`scripts/notices.py
--skip-app --enforce`): 155 components, every one with its license text. Twenty-nine
crates publish no license file of their own (`block2`, `dispatch2`, `kameo`, `objc2`
and 18 more `objc2-*` crates, `siphasher` and the six `uniffi` crates); their texts
were copied unchanged on 2026-10-17 from the projects' own repositories
(madsmtm/objc2 `LICENSE-MIT.txt`, mozilla/uniffi-rs `LICENSE`, tqwewe/kameo
`LICENSE-MIT`, jedisct1/rust-siphash `LICENSE-MIT`) into `Packaging/notices/<crate>/`,
which the generator reads for any component whose own source lacks a text; the crates
offering several licenses carry the MIT text, the option this project uses.
`package.py --require-notices` makes any future gap an error; the release workflow does
not pass it yet.

## Implementation record

The native application is named **WallpaperMachine**; its bundle identifier
prefix is `app.wallpapermachine`.

- Renderer source is in `Renderer/`. It was imported into `upstream/renderer` from revision
  `8c19c002ff37930c68117dd591dfe3f44792e25e` and has since been rewritten as
  recorded in `ThirdParty/provenance.json` (see [Source license](#source-license-gpl-30-only)).
  On 2026-10-23 the rewritten crates and scene engine moved out of `upstream/` into
  `Renderer/Core`, `Renderer/Bridge` and `Renderer/Engine`, and the vendored third-party code
  into `ThirdParty/` (`renderer.firstPartyRelocation2026_10_23`); files moved only, and the
  engine's module layout and file names still follow the imported engine's.
- The application shell in `App/` began as that renderer revision's
  `app/WallpaperEngine` sources, relocated out of `upstream/renderer`; its
  remaining matching lines are listed under [Source license](#source-license-gpl-30-only).
- The native lock-screen extension is in `Extension/`, with
  `Extension/Phosphene-LICENSE.txt` carrying the third-party notice for the
  MIT-licensed [Phosphene](https://github.com/kageroumado/phosphene/tree/8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6)
  protocol/Codable layout used as an ABI reference.
- The Workshop browser and downloader were independently implemented for this
  client.
- The container readers in `Renderer/Media` were written for this project from the public
  ISO/IEC 14496-12/-15, Matroska element and RFC 8794 EBML specifications and the VP9 and
  AV1 bitstream specifications. Their Apple layer (`Renderer/Media/Apple`, the codec format
  descriptions, the VideoToolbox decoder wrapper and `WebMReader`, the Objective-C face of the Matroska reader that the app's WebM player and the lock-screen extension use) and the scene engine's native video
  backend (`Video/NativeVideoBackend.cpp` and
  `Video/VideoTextureSourceFactory.cpp`) were written from Apple's public VideoToolbox, Core
  Media and Core Video headers and documentation. `Video/ClockedVideoSource.cpp` began as the
  clock, queue, seek and promotion logic of the engine's open-wallpaper-engine
  `FfmpegVideoTextureSource.cpp` (GPL-2.0), and was rewritten clean-room on 2026-10-18 with the
  rest of the text, audio and video runtime (`sceneEngine.mediaRuntimeReplacement`). No code from FFmpeg, libav, libwebm, libmatroska, libvpx, mp4v2,
  Bento4, GPAC or any other implementation was copied into the new code. FFmpeg was removed
  on 2026-10-17 ([FFmpeg](#ffmpeg)): the native backend is the only video decoder.
- The sound path in `Renderer/Sound` (channel remix, resampler, loop pipeline the AudioToolbox and Ogg Vorbis decoder adapters, and `Renderer/Sound/Matroska`, which decodes the audio of a WebM or Matroska file: Opus, AAC and MP3 packets through an AudioToolbox AudioConverter, Vorbis packets re-framed as an in-memory Ogg stream for stb_vorbis, written from the Matroska, RFC 6716, RFC 7845 and RFC 3533 specifications and Apple's documentation) was written for this project from the documented behaviour of a conventional downmix, the mathematics of windowed-sinc resampling and Apple's AudioToolbox documentation. No code from FFmpeg, libswresample, libvorbis, opus or any other implementation was copied; Ogg Vorbis decoding is the public-domain stb_vorbis, vendored unchanged. FFmpeg no longer decodes scene sounds, and no longer decodes the audio of a plain video wallpaper on the desktop, where the app's own players play it (AVFoundation, or the WebM player over the sound decoders above); the scene engine no longer builds a plain-video scene at all (removed 2026-10-17), so it decodes no plain video's audio anywhere.
- The still preview in `Renderer/Surface` (`wmSurface`: the rule that picks a project's preview file inside the project's own folder, and an ImageIO decoder that lays the picture over a surface's layer as a Core Animation sublayer) was written for this project from Apple's ImageIO and Core Animation documentation. No code from any other implementation was copied. It is linked into the app and, through the scene engine, into the lock-screen extension, and it adds no third-party dependency.
- The shader layer in `Renderer/Shader` (the Rust crate `wm-shader`: the preprocessor, the
  converter from Wallpaper Engine's HLSL-flavoured GLSL to GLSL 450, the legalizer that lays out
  resources and interfaces for naga, the Metal back end and reflection, and the C ABI the scene
  engine calls) replaced the shader crate that came with the imported renderer, in the commit
  `7141a105` (2026-10-17). It was written under a clean-room protocol: one session studied the
  retired crate and wrote plain-prose specifications (contract, preprocessor, dialect and types,
  legalization and structure, pipeline and back end, and a first amendment list); separate sessions
  that never opened the retired crate, its history or the study notes wrote the code and its tests
  from those specifications, naga's public documentation and Apple's Metal documentation; a
  verification session compared the two as black boxes; only the swap session, which deleted the
  retired crate, read both. The specification files and their SHA-256 are in
  `ThirdParty/provenance.json` (`renderer.shaderCrateReplacement`). The retired crate's source is
  gone from the tree (`upstream/renderer/crates/shader`); it remains in Git history, under
  GPL-2.0-only, as does all other replaced code. The only third-party dependency of the new crate is the vendored naga; the crates
  the retired one used for tokens, string storage and static registration (`logos`, `smol_str`,
  `linkme`) are no longer linked.
- The Rust bridge's configuration and project-data domains
  (`Renderer/Bridge/src/config` and `src/project`) and their local
  contract tests were independently reimplemented from physically separated
  behavior/declaration inputs. Separate reviews examined the source, the test
  obligations and the implementation agents' actual tool records; no original
  implementation or protected-test input was found in those recorded authoring
  sessions. Existing serialized formats and public interfaces are preserved.
  This bounded replacement does not establish independence of the remaining
  bridge, renderer, application interfaces or retained tests, and does not supply
  contributor grants or legal clearance. Its contract identities and verification
  scope are recorded under `renderer.bridgeConfigurationReplacement` and
  `renderer.bridgeProjectReplacement` in `ThirdParty/provenance.json`.
- The bridge path-value module, render-settings lookup and mesh contract tests
  now use independently authored replacements from separate behavior/declaration
  inputs. The lookup's three activation callers migrated together; the old
  private helper and imported mesh-test bodies were removed while retained
  project-side coverage stayed in place. Path tests assert returned values and
  transitions rather than environment-query counts. Scope and procedural
  qualifications are recorded under `renderer.bridgePathsReplacement`,
  `renderer.renderSettingsLookupReplacement` and
  `renderer.sceneMeshContractTestsReplacement` in `ThirdParty/provenance.json`.
  These were bounded source replacements; the completion of the rewrite is the
  entry below.
- Bounded independent replacements also cover the core descriptor/model/pointer
  tests and the bridge's inherited logging lifecycle, login operations and power
  reader/callback boundaries. Project-side formatting/retention, login cache and
  approval behavior, event-driven power supervision and their existing regression
  coverage remain. The separate source-only writer and integration scopes are
  recorded under `renderer.coreDisplayContractTestsReplacement`,
  `renderer.bridgeLoggingLifecycleReplacement`, `renderer.bridgeLoginOperationsReplacement`
  and `renderer.bridgePowerBoundaryReplacement` in `ThirdParty/provenance.json`.
  Existing interface/ordinary-expression treatment is described under
  [Source license](#source-license-gpl-30-only).
- The library scanner/filter/thumbnail unit and inherited options-draft operations
  also use separately authored replacements. Web support, retained position/media/
  property features and their regression coverage remain. The thumbnail comparison
  uses independently generated synthetic inputs and complete original/replacement
  returned bytes, not private wallpapers or the transform as its own oracle.
  Scope, retained-code integration and filesystem/reference limitations are under
  `renderer.bridgeLibraryReplacement` and `renderer.bridgeOptionsDraftReplacement`
  in `ThirdParty/provenance.json`.
- The rewrite was completed between 2026-10-19 and 2026-10-22: the scene engine's remaining
  declarations, build files, Apple bindings and runtime headers, every inherited C++ test file
  (the scene schema, model and texture, text object, script, shader, particle, cursor input,
  dump-tool, corpus and audio tests), and the Rust crates' remaining scene, bridge actor, API,
  facade, configuration and display code and their tests. Each part followed the protocol
  under [Source license](#source-license-gpl-30-only); `ThirdParty/provenance.json` records it
  under `renderer.cleanRoomCompletion2026_10_22`. Main's renderer fixes made after the import
  were carried over as behavior, each by a separate implementer from a behavior specification
  with a regression test, and compared with Wallpaper Engine's own frames: on nine scenes the
  rewritten renderer is within noise of main's, better on one shot and slightly worse on one.
- System now-playing metadata uses [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
  at revision `73f14ab1568371e6e3c44063f21c34c5e2712c4d`, BSD-3-Clause, vendored
  under `ThirdParty/mediaremote-adapter` with the `src/adapter/stream.m` changes
  recorded in `ThirdParty/provenance.json`, and built as an embedded, unlinked
  framework.
- The shader translator [naga](https://github.com/gfx-rs/wgpu) 29.0.3 is vendored
  under `ThirdParty/naga` (its `LICENSE.MIT` and `LICENSE.APACHE` ship with it; this
  project uses it under the MIT option) with the patch listed in
  `ThirdParty/naga/PATCHES.md`, recorded in `ThirdParty/provenance.json`.
- The control panel's icons are SF Symbols, drawn by macOS at run time; no
  icon artwork is copied into the app or the repository, so no icon notice
  ships.

## Before any distribution

- Run `python3 scripts/check_licenses.py --enforce` on the Release app that would
  be distributed and record the outcome here with the evidence; resolve anything
  it reports by replacement or by written permission from the actual copyright
  holders.
- Review the Rust crates beyond their declared licenses.
- Pass `--require-notices` to `scripts/package.py` in the release workflow, so a new
  dependency without a license text stops a release (every current component has one;
  see [Notice payload](#notice-payload)).
- Implement Developer ID signing and notarization in the release pipeline, and
  remove the unconditional failure from `.github/workflows/build.yml` only
  after the review above is recorded as done.
- Mirror the corresponding source (the repository at the tag) at the place the
  signed download is offered.
- Review Valve's terms and the product-name question with counsel before the
  first public download or Supporter sale.
- Before any Mac App Store listing, settle both questions under
  [Mac App Store](#mac-app-store).
- Keep every third-party notice intact and mark modified files as GPLv3
  section 5(a) requires.

## Local build and use

This build targets Apple Silicon and macOS 15 or later, and requires Xcode and
Homebrew. Packaged renderer libraries are bundled into the app for local use
only and are not cleared for distribution.

- Prerequisites, dependencies and commands: [docs/build.md](docs/build.md).
- Steam sign-in, download and scene-asset behavior:
  [docs/features/workshop-downloads.md](docs/features/workshop-downloads.md).

Dated verification history: [docs/testing/verification-log.md](docs/testing/verification-log.md).

## References

- GNU GPL version 3 text: https://www.gnu.org/licenses/gpl-3.0.html
- GNU GPL version 2 text (the imported code's terms): https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
- GPL FAQ, selling copies: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowMoney
- GPL FAQ, download fees and equivalent source access: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowDownloadFee
- GPL FAQ, no fee may be required of others' recipients: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowRequireFee
- GPL FAQ, selling modified versions commercially: https://www.gnu.org/licenses/gpl-faq.html#GPLCommercially
- GPL FAQ, GPLv2/GPLv3 incompatibility: https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility
- GPL FAQ, what "compatible" means: https://www.gnu.org/licenses/gpl-faq.html#WhatDoesCompatMean
- GPL FAQ, no obligation to publish private modifications: https://www.gnu.org/licenses/gpl-faq.html#GPLRequireSourcePostedPublic
- GPL FAQ, aggregation versus combined work: https://www.gnu.org/licenses/gpl-faq.html#MereAggregation
- FSF license list (Apache 2.0 is compatible with GPLv3, not with GPLv2): https://www.gnu.org/licenses/license-list.html#apache2
- FSF, selling free software: https://www.gnu.org/philosophy/selling.html
- Imported renderer's license file: https://github.com/bigsaltyfishes/wallpaper-engine-for-macos/blob/main/LICENSE
- FSF, App Store terms and GPL section 6: https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement
- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- WallpaperMachine terms of service (Supporter purchase, Paddle): https://www.wallpapermachine.app/terms/
- WallpaperMachine refund policy: https://www.wallpapermachine.app/refunds/
