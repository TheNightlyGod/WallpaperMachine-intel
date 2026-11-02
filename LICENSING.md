# Licensing

How WallpaperMachine's source and its downloads are licensed, where the code came
from, the licenses of the third-party components it contains, and what the
Priority Support purchase is. This is a description, not legal advice. The terms are the
root [`LICENSE`](LICENSE) and the notices of each component; where this file and
those texts differ, the texts govern.

## Summary

| Question | Answer |
|---|---|
| Under which license is the source offered? | GNU GPL version 3 only, the text in the root [`LICENSE`](LICENSE). Third-party code keeps its own license. See [Source license](#source-license-gpl-30-only). |
| Is the app sold? | No. The download is free and the source is here. The only purchase is the optional Priority Support, a paid support service, not software. See [Priority Support](#priority-support-a-paid-service-not-the-software). |
| Where is the source of a download? | This repository at the release's tag `vx.y.z`. See [Corresponding source](#corresponding-source). |
| Which licenses do the bundled components use? | GPLv3-compatible ones only, checked by `scripts/check_licenses.py`. See [Components and their licenses](#components-and-their-licenses). |
| Is the download notarized? | Not yet. See [Signing and notarization](#signing-and-notarization). |

## Source license: GPL-3.0-only

This project's code (`App/`, `Extension/`, `Shared/`, `Renderer/`, `Tests/`,
`scripts/` and `project.yml`) is offered under GNU GPL version 3 only, except where
an existing notice says otherwise. The root [`LICENSE`](LICENSE) is the unmodified
GPLv3 text published by the FSF (https://www.gnu.org/licenses/gpl-3.0.txt). It does
not relicense anyone else's code: every holder named in `ThirdParty/provenance.json`
and in the notices under `ThirdParty/` keeps their copyright and their own terms.

The project began on 2026-09-14 from the GPL-2.0-only renderer
[bigsaltyfishes/wallpaper-engine-for-macos](https://github.com/bigsaltyfishes/wallpaper-engine-for-macos)
(revision `8c19c002`), its application shell (the origin of `App/`) and the scene
engine it vendored (bigsaltyfishes' fork of
[open-wallpaper-engine](https://github.com/waywallen/open-wallpaper-engine), revision
`c4c36357`). GPL-2.0-only code cannot be offered under GPLv3 except by its copyright
holders (https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility), so between
2026-10-17 and 2026-10-22 every part of that code that carried substantial upstream
expression was rewritten under a clean-room protocol: one session read the old code
and wrote a behavior specification without its expression, the old code was deleted,
and a separate session that never saw it wrote the replacement and its tests from that
specification. `ThirdParty/provenance.json` records each replacement, its specification
and how it was verified (`renderer.*Replacement`, `sceneEngine.*Replacement`,
`renderer.cleanRoomCompletion2026_10_22`). What still matches the imported code is
limited to names and signatures dictated by the interfaces, standard `Info.plist` keys
and the generated bindings in `App/Bridge/Generated/`.

The project has been GPL-3.0-only since 2026-10-22. The imported code remains in this
repository's Git history under the terms it was received under, and those GPLv2 texts
are kept as `ThirdParty/received-licenses/wallpaper-engine-for-macos.GPL-2.0.txt` and
`ThirdParty/received-licenses/open-wallpaper-engine.GPL-2.0.txt`: a record of how it
arrived, not the license of any code in the tree.

Contributions are accepted under GPL-3.0-only ([CONTRIBUTING.md](CONTRIBUTING.md#license-and-sign-off)).
If you contributed to the project before 2026-10-22 and object to your contribution
being offered under GPL-3.0-only, open an issue; that code will be replaced.

The Workshop browser and downloader were written for this client; no code from
[Unayung/wallpaper-engine-mac](https://github.com/Unayung/wallpaper-engine-mac) was
copied, translated or adapted.

## Priority Support: a paid service, not the software

The website (https://www.wallpapermachine.app) offers WallpaperMachine free and sells
one optional service beside it. Neither changes the license, and no copy of the
software is sold:

1. **Free.** The signed download built from a tagged release, or the source in this
   repository to build yourself.
2. **Priority Support.** A one-time purchase through Paddle.com, the website's reseller
   and Merchant of Record: compatibility questions and feature requests on the support
   forum are answered ahead of general requests.

GPLv3 allows charging for support (section 4). Priority Support is a service the
developer sells, not a donation and not a way to sponsor the project, and its money
does not pass through MMFoundation's Open Collective. Sponsoring MMFoundation there is
a gift that buys nothing in return ([SPONSORS.md](SPONSORS.md)).

A listing on the website's thank-you wall and in the
[README's list](README.md#thank-you-to-every-priority-support-member) is not part of
the purchase. People who bought Priority Support under its earlier name, Supporter,
were promised that listing and keep it. A new buyer may turn the same listing on as a
courtesy; it is off by default and not part of what they buy.

What follows from the license:

- **The software is never the product.** Nothing in the app checks for, unlocks or
  changes with a purchase: no license key, no special build, no feature gate.
- **Every recipient keeps every GPL right.** Anyone who has the download may run it,
  study and change its source, and redistribute or sell copies under GPLv3. Buyers get
  exactly the license everyone else does, and a refund takes none of it back.
- **No additional end-user agreement.** The download ships with the GPLv3 text and the
  third-party notices only. The website's terms (https://www.wallpapermachine.app/terms/)
  state that this repository's license, not those terms, governs the software; they
  and the refund policy (https://www.wallpapermachine.app/refunds/) cover the Priority
  Support purchase only.
- **Warranty.** The GPLv3 disclaimer (sections 15 and 16) applies to the software.
  Priority Support is the developer's own commitment to answer questions first, sold
  through Paddle; it is no warranty of the software and binds no upstream author.

## Corresponding source

Each release is built by this repository's workflow from a Git tag `vx.y.z`
([docs/release.md](docs/release.md)), and the repository at that tag is its
corresponding source, offered at no charge from the same place as the download (GPLv3
section 6(d)). It includes the build and packaging scripts and `project.yml`; the exact
versions of every Rust crate are pinned in `Renderer/Cargo.lock`, and every third-party
component, with its version, is listed in the bundled `THIRD-PARTY-NOTICES.txt`.

## Components and their licenses

"Compatible" means compatible with GPLv3 according to the FSF's license list
(https://www.gnu.org/licenses/license-list.html) or the license's own text.

| Component | Where | License | With GPL-3.0-only |
|---|---|---|---|
| Renderer, shader layer and scene engine | `Renderer/` | GPL-3.0-only (this project) | Same license |
| Application shell, extension, Workshop browser, control panel, scripts | `App/`, `Extension/`, `Shared/`, `scripts/` | GPL-3.0-only (this project) | Same license |
| Phosphene ABI reference | notice in `Extension/Phosphene-LICENSE.txt` | MIT | Compatible |
| ungive/mediaremote-adapter | `ThirdParty/mediaremote-adapter`, modified (see `provenance.json`) | BSD-3-Clause | Compatible; an embedded, unlinked framework |
| miniaudio | `ThirdParty/miniaudio` | Public domain or MIT-0 | Compatible |
| stb_image, stb_vorbis | `ThirdParty/stb_image`, `ThirdParty/stb_vorbis`, patched (`PATCHES.md` in each) | Public domain or MIT | Compatible |
| HarfBuzz | `ThirdParty/harfbuzz`, 15.0.0 (harfbuzz/harfbuzz tag `15.0.0`, commit `66946f52`), `src/` unchanged (build files and tests left out), linked statically (`harfbuzz`, from `src/harfbuzz.cc`) | Old MIT, SPDX MIT-Modern-Variant (`LICENSE` there, the release's `COPYING`) | Compatible |
| msdfgen | `ThirdParty/msdfgen`, 1.13 (Chlumsky/msdfgen tag `v1.13`, commit `1874bcf7`), `core/`, `ext/import-font.*` and `msdfgen.h` unchanged, linked statically (`msdfgen`) | MIT (`LICENSE` there, the release's `LICENSE.txt`) | Compatible |
| nlohmann-json, argparse | Homebrew, header-only | MIT | Compatible |
| quickjs-ng | Homebrew `quickjs-ng` | MIT | Compatible |
| lz4 | Homebrew `lz4` | BSD-2-Clause | Compatible |
| FreeType | `ThirdParty/freetype`, 2.15.0 (release tarball `freetype-2.15.0.tar.xz`), `src/`, `include/` and the CMake build unchanged (other build systems, tools, tests and docs left out), linked statically (`freetype`) without HVF or HarfBuzz | FTL or GPL-2.0-or-later (`LICENSE.TXT`, `docs/FTL.TXT`, `docs/GPLv2.TXT` there) | Compatible, used under GPL-2.0-or-later |
| libpng | Homebrew `libpng` (FreeType dependency) | libpng-2.0 | Compatible |
| Brotli | Homebrew `brotli` (FreeType dependency: `libbrotlidec`, `libbrotlicommon`) | MIT | Compatible |
| naga | Rust crate, patched copy in `ThirdParty/naga` (`PATCHES.md`) | MIT OR Apache-2.0, used under MIT | Compatible |
| uniffi, option-ext | Rust crates | MPL-2.0 | Compatible through MPL-2.0 section 3.3 |
| The other linked Rust crates | `Renderer/Cargo.lock` | MIT, alone or as a choice; a few Zlib or BSD-3-Clause | Compatible |

Not part of the app: **FFmpeg** and its libraries were removed on 2026-10-17; video and
sound decode with the project's own container readers, VideoToolbox, AudioToolbox and
the vendored `stb_vorbis`. The Vulkan, MoltenVK, SPIR-V and glslang libraries were
removed the same day with the Vulkan renderer. `ThirdParty/provenance.json` records both.

Each crate's license is the one its manifest declares. Build-dependencies and
proc-macros run inside the compiler and are not linked.

## Content and names outside the software licenses

- **SteamCMD** is downloaded by the user at run time into the app's support directory
  and is never bundled or redistributed; its use is subject to Valve's terms.
- **Wallpaper Engine assets.** Scene wallpapers need shared resources from a Wallpaper
  Engine installation the user owns. They are not bundled or distributed.
- **Workshop content** belongs to its creators and is downloaded by the user with the
  user's own Steam account. The app does not host or redistribute it.
- **Not affiliated.** WallpaperMachine is an independent project, not affiliated with or
  endorsed by Wallpaper Engine, its developers or Valve. Steam and Valve are trademarks
  of Valve Corporation.

## Signing and notarization

`scripts/package.py` signs every bundled library, the extension and the app ad hoc by
default; release builds are signed with the project's Developer ID and notarized by
Apple ([docs/build.md](docs/build.md#release-signing)), so the download opens without
**Open Anyway** and macOS privacy permissions survive in-app updates. Signing verifies
the bundle's integrity and notarization is Apple's malware check; neither is a license
grant. A build from source is signed ad hoc.

## Tooling

- `python3 scripts/check_licenses.py` lists the license of every Mach-O dependency of a
  built app (`otool -L`, walked from the executable, the extension and
  `Contents/Frameworks`), of the third-party code compiled into the renderer, and of
  every linked Rust crate (`cargo tree`). It fails GPL-2.0-only, GPLv3-incompatible and
  unknown licenses, and names any failing component this file does not mention.
  `--enforce` exits 1 on a finding. It needs a built app, Homebrew and Cargo, so the
  routine gate does not run it.
- `python3 scripts/notices.py` writes `THIRD-PARTY-NOTICES.txt` from the same closure:
  each component's name, version, SPDX license and license text taken from the component
  itself (for a dual `MIT OR Apache-2.0` crate, the MIT text). `--enforce` exits 1 when a
  text is missing.
- `scripts/package.py` refuses to package when a notice it must bundle is missing or a
  bundled Homebrew library ships no license file, and generates the notices file.

### Notice payload

`scripts/package.py` writes into the app bundle:

- `Contents/Resources/WallpaperMachine-LICENSE.txt`: the root `LICENSE`;
- `Contents/Resources/LICENSING.md`: this file;
- `Contents/Resources/Imported-Renderer-GPL-2.0-LICENSE.txt`: the GPLv2 text the
  imported renderer was received under, not the license of the code now;
- `Contents/Resources/provenance.json`: `ThirdParty/provenance.json`;
- `Contents/Resources/Licenses/<formula>-<version>/`: every `LICENSE*`, `COPYING*`,
  `COPYRIGHT*` and `NOTICE*` file of each bundled Homebrew library;
- `Contents/Resources/Licenses/renderer-third-party/{miniaudio,stb_vorbis}/LICENSE`;
- `Contents/Resources/THIRD-PARTY-NOTICES.txt`: one entry per third-party component,
  generated by `scripts/notices.py`.

Xcode also bundles `Contents/Resources/LICENSE` (mediaremote-adapter's BSD-3-Clause
notice) and the extension's `Phosphene-LICENSE.txt`. Rust crates that publish no
license file of their own get the text from their project's repository, kept unchanged
in `Packaging/notices/<crate>/`. `package.py --require-notices` makes a missing text an
error; the release workflow does not pass it yet.

## References

- GNU GPL version 3: https://www.gnu.org/licenses/gpl-3.0.html
- GPL FAQ, GPLv2/GPLv3 compatibility: https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility
- GPL FAQ, charging for distribution: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowMoney
- GPL FAQ, download fees and source access: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowDownloadFee
- FSF license list: https://www.gnu.org/licenses/license-list.html
- FSF, selling free software: https://www.gnu.org/philosophy/selling.html
- WallpaperMachine terms of service: https://www.wallpapermachine.app/terms/
- WallpaperMachine refund policy: https://www.wallpapermachine.app/refunds/
