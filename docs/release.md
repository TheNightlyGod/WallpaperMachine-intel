# Versioning and releases

Version numbers, the pipeline that publishes a build, the notes it writes, and what
the in-app updater expects of a release. Build mechanics live in [build.md](build.md). To cut
a release, follow the [checklist](#checklist-for-a-release); when one fails, see
[Recovering a failed release](#recovering-a-failed-release).

## Source of truth

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
[`project.yml`](../project.yml) are the version of both the app and the
lock-screen extension; the two targets carry identical values. The embedded
`MediaRemoteAdapter` framework declares the same `CURRENT_PROJECT_VERSION`,
because XcodeGen would otherwise generate its own default of 1 there.
`scripts/bump_version.py` also rewrites the same two keys in the committed
`WallpaperMachine.xcodeproj/project.pbxproj`, so the generated project stays
in sync without anyone running `xcodegen`, and running it produces no diff.
Change the version through the script or the Version workflow, never by editing
one of the two files alone. The panel reads the bundle's version, so Settings →
About and every GitHub report show the released number with no other edit.

`MARKETING_VERSION` is a strict `x.y.z` semantic version.
`CURRENT_PROJECT_VERSION` is an integer build number, incremented by one on every
bump.

## Release specs in commit messages

Push to `main` with a line of exactly this form — as the subject, a body line, or
a squash-merge title — to trigger a bump:

| Spec | Effect on `0.1.0` |
|---|---|
| `release: patch` | `0.1.1` |
| `release: minor` | `0.2.0` |
| `release: major` | `1.0.0` |
| `release: 1.2.3` or `release: v1.2.3` | sets `1.2.3` exactly |

Matching is case-insensitive and anchored to a whole line. An explicit `x.y.z`
must not move the version backwards.

Every commit message in a push is scanned, and a squash merge's body lists the
messages of all its commits, so keep a `release:` line out of any message that
should not ship a version. If a single push contains several `release:` lines,
an explicit `x.y.z` wins; otherwise the highest of `major` > `minor` > `patch` is
used. A push with no `release:` line prints `No release: spec in commit
message; skipping.` and does nothing.

Bump the same way locally:

```sh
python3 scripts/bump_version.py --spec patch            # dry run, prints old -> new
python3 scripts/bump_version.py --spec patch --apply    # writes both files
```

`--message` / `--message-file` scan a commit message instead of taking a spec
directly; `--ci` reads `RELEASE_SPEC` or the GitHub event payload. With `--apply`
omitted nothing is written, which makes it safe to inspect a planned bump.
`scripts/tests/test_bump_version.py` covers the script and runs as part of
`python3 scripts/test.py`.

## Release notes and the changelog

A version's notes are written once, when it is cut, into its
[`CHANGELOG.md`](../CHANGELOG.md) section. The app bundles that file. The
release page uses only the English notes from the current section; the app keeps
both translations. [`scripts/release_notes.py`](../scripts/release_notes.py)
does both halves; GitHub's auto-generated notes are not used. Once a version's
tag exists, its section is not extended: the tag's build already bundled it, so
a change that lands later belongs in the next release's notes.

A bundled changelog section is both languages, in this order, and nothing else at `###`:

```markdown
### English

One or two sentences on what the release means, omitted when the lists say it.

#### New

- One change, one line

### 简体中文

同样的一两句。

#### 新增

- 同一变更的简体中文

**Full changelog**: https://github.com/owner/repo/compare/v0.1.0...v0.2.0
```

Category headings inside a language are `####`. The compare link follows both
blocks; the app ignores it. The headings are:

| Section | `####` English | `####` 简体中文 |
|---|---|---|
| breaking | Breaking changes | 不兼容变更 |
| new | New | 新增 |
| improved | Improved | 改进 |
| fixed | Fixed | 修复 |

### Written by the release-notes model

With `--ai` the commits between two version tags go to a language model that
writes them up for users — what they can do now, what works better, what no
longer goes wrong — in English and in Simplified Chinese, the same changes in
both, merging commits that describe one change and leaving internal work out.
The release pipeline always passes `--ai`.

| Environment | Default | Meaning |
|---|---|---|
| `RELEASE_NOTES_API_KEY` | none; required | Key for the gateway. A secret: it lives in the environment of one command or in the repository secret of the same name, never in a file. |
| `RELEASE_NOTES_API_BASE` | `https://sub2api.moraxcheng.me` | Anthropic Messages API gateway; a base that already ends in `/v1` is accepted |
| `RELEASE_NOTES_MODEL` | `claude-opus-5-5` | The model that writes the notes |

The model reads every non-merge commit in the range, newest first, except CI's own
`chore: bump version to x.y.z`. `docs`, `test`, `chore`, `ci`, `build`, `style` and `refactor`
commits bring only their subject; every other commit (`feat`, `fix`, `perf`,
breaking ones, and types or subjects the convention does not recognise) brings
its body, cut at 1,500 characters, until 120,000 characters of bodies are spent.
A squash merge's body is read per commit it lists (`* type(scope): subject`
lines), each under the same rules. `Co-authored-by`, `Signed-off-by`,
`Reviewed-by` and `Claude-Session` trailers, and GitHub's `---` rule before them,
are dropped first: they only spend the budget. Commit messages are therefore the
source of the notes: write them for the reader
[conventions.md](conventions.md#commits-and-pull-requests) describes.

The instructions also carry the project's rules on claims, because CI commits the
notes without review: no energy, battery or power-saving claims, nothing called
fully supported or fully compatible, and opt-in features (Native Metal, native
video, content pacing, on-demand scene idle, the animated lock screen) keep their
optional, experimental or off-by-default qualifier in both languages. Places in
the app are named the way the panel names them (`Settings` / `设置`, and the
same for General, Appearance, Performance, Playback, Library & Steam, Discover,
Installed, About and Lock screen).

The model answers with JSON. `summary` is `{"english", "chinese"}`. Each of
`breaking`, `new`, `improved` and `fixed` is a list of the same pair, one object
per change, so the two languages cannot drift in length. The script renders that
shape — `### English`, then `### 简体中文`, categories at `####`, then the compare
link — and stops the run on a reply that is not that JSON, omits a language,
carries other fields or an HTML comment (the boundary marker below), or was cut
off at the output-token limit. A Chinese string must contain Chinese characters
and must not copy the English; an English string must contain Latin text.
Whitespace is collapsed and list or heading markers are stripped, so no entry can
open a changelog section of its own. A range without commits is reported in both
languages as having no user-visible changes, without a request. The request
streams and names its own `User-Agent`, because Cloudflare in front of the
gateway refuses urllib's default one (error 1010). A connection that goes quiet
for 120 seconds, or a reply still running after 600, stops the run: the Version
job holds its branch lock while it waits. Nothing is retried; a failed run is
re-run.

### Listed from the commits

Without `--ai` the commits are listed in English, read through the
`type(scope): subject` convention in [conventions.md](conventions.md). It is
offline and free, and it is a developer preview for inspecting a range and for
tests. It is not published: `--release-body` and `--changelog --apply` refuse
notes that are not `### English` then `### 简体中文`.

Publication validates the whole bundled history, not just the current release.
Each `##` heading must be the `x.y.z` token `AppReleaseHistory` accepts
(optional `v`/`V`, three 64-bit integer components, no leading zeros), and each
section needs actual prose in both languages and matching bullet counts (headings
and compare links do not count as translated content). `## Unreleased`, duplicate
versions, an overflow, a prerelease suffix, a leading zero, or a non-version `##`
line inside notes fails `--release-body`, `--changelog --apply` and
`--rebuild-changelog --apply`: such headings are neither kept nor dropped,
because the app rejects the whole file when it sees one.
`--rebuild-changelog --apply` also refuses to replace the file if rebuilding
would introduce an English-only section; translate missing history before applying.

| Commit type | Section |
|---|---|
| `feat` | **New** |
| `fix` | **Fixed** |
| `perf` | **Performance** |
| `!` suffix or a `BREAKING CHANGE:` trailer | **Breaking changes** |
| `docs`, `test`, `chore`, `ci`, `build`, `style`, `refactor` | counted in one closing line |
| anything else, including non-conventional subjects | **Other changes** |

Nothing is dropped silently: a subject the convention does not recognise is
listed rather than hidden, and the only commit removed outright is CI's own
`chore: bump version to x.y.z`. A subject longer than 140 characters is cut at a
word boundary; the linked commit still carries every word.

### Commands

```sh
python3 scripts/release_notes.py                               # English listing, not for publish
python3 scripts/release_notes.py --ai --tag v0.6.0 --to HEAD   # bilingual notes, before the tag exists
python3 scripts/release_notes.py --tag v0.6.0 --release-body --ai --output notes.md
python3 scripts/release_notes.py --ai --changelog --apply      # write one bilingual section
python3 scripts/release_notes.py --rebuild-changelog --apply   # a section for every tag, recorded ones kept
```

A local `--ai` run needs `RELEASE_NOTES_API_KEY` exported for that command only.
`--previous` overrides the tag the range starts after; by default it is the
newest released version below the target that the range's end descends from, so a
gap in the numbering resolves correctly.

`--release-body` is the English-only GitHub release page. It reuses the version's
bilingual `CHANGELOG.md` section without calling the model again, keeps only the
English prose and the **Full changelog** link, then adds
`<!-- release-notes-end -->` and the install, checksum and requirement footer
(with a `Built from` line when `--built-from` is given). Raw commit messages are
not appended; the **Full changelog** link leads to the commit history. A
hand-pushed tag with no section is written once, by the model when `--ai` is
set, into the working-tree `CHANGELOG.md` before anything is built. English-only
or malformed source history fails the run instead of being published.

The marker is a contract: the updater shows everything above it and nothing
below. The What's New window reads the bundled changelog, not that footer; how the
app announces an update is in [After an update](features/updates.md#after-an-update).

Writing a section is idempotent — rerunning replaces the section for that
version instead of duplicating it. `--rebuild-changelog` writes a section for every
version tag but keeps each section `CHANGELOG.md` already holds word for word, so
the model's notes survive; only missing ones are listed from the commits, in
English, and that listing is not a publishable section. It never calls the model,
and refuses `--ai`. `CHANGELOG.md` is written with `--apply`, and also when
`--release-body` has to generate the current section. With `--changelog`, nothing
is generated unless `--apply` or `--output` is given, so that dry run never calls
the model; a plain `--ai` run prints the model's notes and does make the request.
`scripts/tests/test_release_notes.py` covers classification, rendering, the
changelog, range resolution against a throwaway repository, the model path
against a fake gateway and the publish path, and runs as part of
`python3 scripts/test.py`.

## Workflows

Version, Build, Release, Warm caches and Supporters are the release workflows in
`.github/workflows/`; Supporters shares only `main` with the others.
`claude.yml` and `claude-code-review.yml` are pull-request automation, described
in [CONTRIBUTING.md](../CONTRIBUTING.md#automated-review). `codeql.yml` is code
scanning, described [below](#codeql-codeqlyml).

Version, Build and Release grant `contents: write`; Build's publish job also needs
`id-token: write` and `attestations: write` for its provenance attestation, and
both callers pass those through, together with the repository's secrets (`secrets:
inherit`). Warm caches only reads. Supporters writes only `README.md` and
`README.zh-CN.md`, with `contents: write`, and reads Version's runs with
`actions: read`. The macOS setup Build and Warm caches share lives in one
composite action,
[`.github/actions/prepare-build`](../.github/actions/prepare-build/action.yml).

**Repository secrets.** Only a repository administrator can set or replace them:
`gh secret set <NAME>` in a checkout prompts for the value and writes it to the
repository `origin` points at.

| Secret | Read by |
|---|---|
| `RELEASE_NOTES_API_KEY` | Version for every bump; Build only for a tag without a `CHANGELOG.md` section |
| `SIGNING_CERTIFICATE_P12`, `SIGNING_CERTIFICATE_PASSWORD` | Build's `build` job, which fails when either is missing ([build.md](build.md#release-signing)) |
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude.yml` and `claude-code-review.yml` |

### Version (`version.yml`)

Runs on every push to `main`, and on demand from **Actions -> Version -> Run
workflow** with a `spec` input. On an `ubuntu-latest` runner it:

1. checks out with full history;
2. runs `python3 scripts/bump_version.py --ci --apply`;
3. has the release-notes model write the new version's bilingual section into
   `CHANGELOG.md` with `scripts/release_notes.py --to HEAD --ai --changelog
   --apply` — `### English` then `### 简体中文`. The tag does not exist yet, so
   the range ends at `HEAD`. Without the secret, or when the model fails or omits
   a language, the job stops here: nothing is committed or tagged, and re-running
   the failed job retries the same bump;
4. if anything changed, refuses to continue when the target tag already exists on
   `origin`, then commits `project.yml`,
   `WallpaperMachine.xcodeproj/project.pbxproj` and `CHANGELOG.md` as
   `chore: bump version to x.y.z`, tags `vx.y.z`, and pushes branch and tag
   atomically as `github-actions[bot]`;
5. calls the Build workflow directly for the tag it just pushed.

Step 5 is not redundant. **A tag pushed with `GITHUB_TOKEN` never starts another
workflow**, so the tag-triggered Release workflow would never fire for a
CI-produced tag; without the direct call, a bumped version would be tagged but
never published.

The bump job holds a `version-<ref>` concurrency group only while the bump commit
is produced. A workflow-wide group would keep the lock through the macOS build,
and because GitHub retains only the newest pending run, a queued `release:` push
could be replaced by a later ordinary push and silently lost.

The workflow needs permission to push to `main`: `contents: write`, and branch
protection must allow GitHub Actions.

### Build (`build.yml`)

`workflow_call` only, with a required `tag` input. It is the single place a
publishable artifact is produced, called by Version for CI-produced tags and by
Release for hand-pushed ones. It runs four jobs. `app-icon` compiles the app icon
on a `macos-26` runner. `build` then runs on `macos-15` (the oldest runner that
carries Xcode 26, whose Homebrew bottles set the published app's minimum macOS)
while `test` runs on `macos-26`, 150-minute timeout each, so the test gate adds no
time on top of the Release build. `publish` runs on `ubuntu-latest` only after
both succeed, so a published binary has passed the same gate a change has to pass.

The icon is compiled apart because Xcode 26's `actool` crashes on most `.icon`
compiles on macOS 15 ([build.md](build.md#stages-and-outputs)). `app-icon` runs
`python3 scripts/build.py --compile-app-icon DIR` and hands `Assets.car`,
`AppIcon.icns` and the partial Info.plist to `build` as the `app-icon-<tag>`
artifact.

**`build`**

1. checks out the tag with full history, which the notes need;
2. writes the release body with `scripts/release_notes.py --release-body --ai
   --built-from "$(git rev-parse HEAD)"` before anything is built. The current
   section must already be bilingual (`### English`, then `### 简体中文`) and is
   reused without calling the model; a hand-pushed tag with no section gets one
   written once into the working-tree `CHANGELOG.md`, so the app bundles both
   languages. English-only or malformed source history fails here, in seconds,
   rather than after the macOS build;
3. runs `prepare-build` (below) and downloads the `app-icon-<tag>` artifact;
4. runs `python3 scripts/build.py --configuration Release --app-icon DIR`, which
   leaves `AppIcon.icon` out of the Xcode build, puts the compiled icon and catalog
   into the bundle with their Info.plist keys and re-signs it;
5. imports the project signing certificate from the two signing secrets into a
   temporary keychain ([build.md](build.md#release-signing)), then runs
   `python3 scripts/package.py --configuration Release --require-deployment-target
   --sign-identity "WallpaperMachine Code Signing"`, which fails if a bundled
   library needs a newer macOS than the deployment target. Packaging proves the
   disk image, not the build tree: it mounts the image read-only and requires
   `app.wallpapermachine` at the bundle's version, a passing
   `codesign --verify --deep --strict`, the signed entitlements and Info.plist
   keys the lock screen extension and the permission prompts need ([bundle
   contract](build.md#bundle-contract)), the `Applications` link and the window
   layout, then writes the `.sha256` sidecar
   ([build.md](build.md#packaging-and-installing));
6. matches the image to the tag: it must be named
   `WallpaperMachine-<tag without v>-arm64.dmg`, and its checksum is echoed into the
   job summary;
7. hands the image, its sidecar and the notes to `publish` as the
   `release-<tag>` artifact.

Step 6 is the guard that the bump actually reached the build:
`scripts/package.py` names the image from the bundle's
`CFBundleShortVersionString`, so a mismatch means the published tag and the
built version disagree and the job fails instead of publishing the wrong binary.

**`test`** runs `prepare-build`, `python3 scripts/build.py --renderer-only` for the
renderer and the generated bridge, `python3 scripts/check_rust.py`,
`python3 scripts/check_renderer.py --allow-missing-gpu --allow-imprecise-timers`,
and `python3 scripts/test.py --serial`, which builds the Debug app, icon included,
and its tests itself. A failure in any of them prevents publication.
`--serial` runs one test class at a time: see
[Parallel execution](testing/README.md#parallel-execution) for why. The two
renderer flags are CI fallbacks for hosted VMs: only the exact exit 77 of a
compiled device or timer probe skips the named GPU or wall-clock cadence checks
([renderer testing](testing/renderer.md#scriptscheck_rendererpy)); each skip is a
CI warning, and all other probe and test failures remain failures. Excluded and
asset-dependent checks stay listed in the JSON reports and logs; they do not count
as verified asset or GPU coverage.

When either macOS job fails it uploads its full tool logs from `artifacts/` (for
`test`, also any WebKit, app or jetsam reports from the run) as `build-logs-<tag>`
or `test-logs-<tag>`, kept 14 days: the job output is only the scripts' filtered
summary.

**`publish`**

1. downloads the artifact and checks the image against its `.sha256` sidecar;
2. attests build provenance for the image with
   `actions/attest-build-provenance`;
3. writes the update manifest `WallpaperMachine-update.json` from the tag, the
   notes and the image with `scripts/update_manifest.py`
   ([below](#what-the-in-app-updater-expects));
4. publishes the image, its sidecar and the manifest with
   `scripts/publish_release.py`.

**`prepare-build` and the caches.** The composite action selects the newest
non-beta `/Applications/Xcode_26*.app`, `brew install --quiet`s the
XcodeGen/CMake/renderer package set with `dav1d` and `ccache`, and restores three
`actions/cache` entries. Every key carries the runner's macOS (`<os>` below is
`macos-15` or `macos-26`), because bottles, the FFmpeg keg and compiled objects
differ between releases; `build` and `test` therefore keep separate entries.

| Cache | Path | Key | What a hit saves |
|---|---|---|---|
| LGPL FFmpeg | `/opt/homebrew/Cellar/mwe-ffmpeg` | `mwe-ffmpeg-<os>-<dav1d version>-<hash of Formula/mwe-ffmpeg.rb>` | the FFmpeg source build; the action restores the keg's `opt` link and `scripts/install_ffmpeg.py` finds the keg current |
| C++ objects | `~/.ccache` | `ccache-<os>-<run>`, restored by the `ccache-<os>-` prefix | recompiling the scene engine. A checkout gives every file a new mtime, so CMake rebuilds the whole engine even from a restored build tree; ccache hashes content and returns the previous objects |
| Renderer | `~/.cargo/registry`, `~/.cargo/git`, `upstream/renderer/target` | `renderer-ccache-<os>-<hash of Cargo.lock, rust-toolchain.toml, provenance.json>`, restored by prefix | crate downloads, and Rust compilation while the nightly toolchain is unchanged |

The `CMAKE_<LANG>_COMPILER_LAUNCHER=ccache` variables only take effect on a build
tree's first CMake configure, so change the renderer key's prefix whenever the
launcher setup changes: no tree configured the old way may be restored. Each
macOS job prints `ccache --show-stats` at the end; hits against misses there is
the evidence the cache worked. The toolchain is an unpinned `nightly`
(`upstream/renderer/rust-toolchain.toml`), and a new nightly invalidates every
compiled crate, so the Rust half of the renderer build is only reused between
builds on the same nightly.

**What the attestation does and does not say.** Its SLSA predicate is built from
the run's OIDC claims: `resolvedDependencies[0]` is `git+<repo>@<claims.ref>` with
`digest.gitCommit = claims.sha`
([`actions/toolkit`](https://github.com/actions/toolkit/blob/main/packages/attest/src/provenance.ts)).
For a Version-produced tag those claims describe the push to `main` that carried
the `release:` line — the revision *before* the bump commit the tag points at,
because Build runs as a `workflow_call` inside that same run. So the attestation
binds the image's digest to this repository, this workflow, this builder and
this run; it does **not** identify the revision the image was built from. That
revision is recorded separately in the release body as
``Built from `vx.y.z` at `<sha>` ``, and anyone can check it with
`git rev-parse vx.y.z^{commit}`. A hand-pushed tag going through Release does not
have the discrepancy, because there the triggering ref is the tag itself.

**How `scripts/publish_release.py` publishes.** Drafts first, live releases
refused: it creates the release as a draft (or finishes a draft an earlier attempt
left), uploads the files, and clears the draft flag last, so a failure leaves a
draft that neither the API's `releases/latest` nor github.com's
`releases/latest/download/…` returns. A release already *published* is refused and
fails the job, because `gh release upload --clobber` deletes an existing asset
before writing its replacement and would take the download away. Latest cannot go
backwards between publishers: builds for different tags run concurrently, so
Build's final `publish` job holds a repository-wide
`release-promotion-<repository>` concurrency group with
[`queue: max`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
(waiting releases queue rather than replace the pending job), and the script
re-reads the public versions after the upload, immediately before clearing the
draft flag. It passes `--latest` only if no greater public, non-prerelease version
exists, and `--latest=false` otherwise; a failed lookup leaves the uploaded draft
unpublished. Manual invocations must be serialized with every other publisher too:
use the release workflow for the shared lock. The script's docstring and
`scripts/tests/test_publish_release.py` cover both rules.

### Warm caches (`warm-caches.yml`)

GitHub evicts a cache entry nobody has read for seven days. Twice a week (and on
demand from **Actions -> Warm caches -> Run workflow**) this runs `prepare-build`
and `python3 scripts/build.py --renderer-only` on `main`, once on `macos-15` and
once on `macos-26`, which reads every entry Build uses and saves a fresh C++ object
cache for each, so a release after a quiet week still starts warm. Caches saved on
`main` are readable from every ref, including the tags Release builds. It
publishes nothing.

### Supporters (`supporters.yml`)

Keeps the [README's Supporter list](../README.md#thank-you-to-every-supporter), and
the same list in its translation `README.zh-CN.md`, in step with the website's
[sponsor wall](https://www.wallpapermachine.app/#sponsors). Every hour (and on
demand from **Actions -> Supporters -> Run workflow**) it runs
`python3 scripts/update_sponsors.py` on `main`, which reads the wall's JSON from
`https://www.wallpapermachine.app/api/sponsors` and rewrites the block between the
`supporters:start` and `supporters:end` markers in both files; the script's
docstring describes the block, and edits between the markers are overwritten.
When the block changed it commits both READMEs as
`docs(readme): update the Supporter list` and pushes to `main`, starting again from
the new `main` if that moved. It skips the hour while a Version run is queued or
running, because Version's push of its bump commit does not retry. A wall that
can't be read, or a README without its block, fails the run and leaves both READMEs
as they were.

### CodeQL (`codeql.yml`)

Code scanning on every push to `main`, every pull request into it, weekly, and on
demand. It replaces GitHub's default setup, which can only autobuild Swift and
fails at the extension's link because the renderer library and the Homebrew
libraries do not exist yet. Actions, JavaScript/TypeScript, Python and Rust are
analyzed without a build on Linux. Swift runs on `macos-26`: `prepare-build` and
`python3 scripts/build.py --renderer-only` first, untraced, then CodeQL traces
`scripts/build.py --swift-only` with the `--xcode-setting` overrides CodeQL's own
Swift autobuild uses (no signing, no compilation cache, no integrated driver), so
the extractor sees every Swift compile. C/C++ (only vendored third-party code is
visible to it) and Ruby (only the FFmpeg formula) are deliberately not analyzed.
Default setup must stay off under **Settings -> Code security -> CodeQL
analysis**; while it is on, GitHub rejects this workflow's results.

### Release (`release.yml`)

Triggered by pushing a `v*.*.*` tag by hand. It only calls Build with
`github.ref_name`, sharing the `publish-<tag>` concurrency group with Version's
publish job so one tag is never built twice at once. A hand-pushed tag has no
`CHANGELOG.md` section unless one was committed before tagging; Build then asks
the model once and writes that bilingual section into the working tree before the
app is built. A section that is present but not bilingual fails the build; it is
not rewritten.

## What the in-app updater expects

**Settings → About** installs updates from the repository's latest GitHub Release.
What the app does with one (when it checks, how it avoids the API quota, download,
verification, replacing the running app, the What's New window) is in
[updates](features/updates.md). This section is the publish-side contract: what a
release has to carry for that to work.

The update manifest, `WallpaperMachine-update.json`, is an asset of every release.
`scripts/update_manifest.py` writes it in Build's `publish` job from the tag, the
notes file that becomes the release body and the image bytes, and
`scripts/publish_release.py` attaches it. It is the release object in the REST
API's shape: `tag_name`, `html_url`, `prerelease`, `body` and one asset with
`name`, `browser_download_url`, `size` and a `sha256:` `digest`. The app reads it
from `https://github.com/WallpaperMachine/WallpaperMachine/releases/latest/download/WallpaperMachine-update.json`,
which github.com redirects to the file on the release marked Latest. A draft never
resolves, and `publish_release.py` makes the release public only after the image,
sidecar and manifest are uploaded. The name is
`AppUpdateConfiguration.manifestName`; renaming it changes both sides at once. The
script refuses a tag that is not `vx.y.z`, a repository that is not `owner/name`
and an image not named as below.

What a release must satisfy:

- the repository is `WallpaperMachine/WallpaperMachine`
  (`AppUpdateConfiguration.repository`). Builds up to 1.0.0 still ask for
  `bobbyhuang-dev/WallpaperMachine` and reach it only through GitHub's rename
  redirect, so never create a repository at that old path;
- the release is not a draft or prerelease, and its tag is `vx.y.z` (no
  prerelease suffixes, no `nightly`);
- the disk image is named exactly `WallpaperMachine-<x.y.z>-arm64.dmg` — what
  `AppUpdateConfiguration.assetName(for:)` returns and what `scripts/package.py`
  produces (`image_name` in `scripts/lib/dmg.py`). The app can fall back to another
  product `.dmg`, but never downloads the `.sha256` sidecar, zips, feeds or
  blockmaps;
- the manifest's asset carries a `sha256:` digest of the image and a
  `browser_download_url` on github.com, both derived by `update_manifest.py`; the
  app refuses an image it cannot verify;
- releases are signed with the project certificate
  ([build.md](build.md#release-signing)), so the replacement keeps the designated
  requirement and macOS keeps the app's privacy permissions;
- the release body is the English notes above `<!-- release-notes-end -->`
  ([Release notes and the changelog](#release-notes-and-the-changelog)); the app
  shows what is above the marker as **What's new** in About and ignores the rest.

Renaming the image, publishing a prerelease, or attaching only a zip silently
breaks automatic updates; `Tests/Unit/GitHub/AppUpdateTests.swift` pins this
behavior, including the exact published image name and an install from a real disk
image.

## Recovering a failed release

A tag the Version workflow pushed stays when its Build run fails; only Build's
`publish` job makes a release public. If a tag was created but its release never
passed the publication gate, preserve that tag and fix the failed checks on
`main`: Version refuses a target tag that already exists on `origin`,
`publish_release.py` refuses a live release, and a `CHANGELOG.md` section is not
extended once its tag exists. Cut the next patch instead, with the optional
workflow-dispatch `notes_from` input set to the last *published* tag, so its
model-written bilingual notes include the still-unpublished changes:

```sh
gh workflow run version.yml --ref main -f spec=patch -f notes_from=v1.2.6
```

`notes_from` only sets `release_notes.py --previous`; it does not change the version
policy, skip tests or replace a live release. Ordinary releases leave it empty and
use the preceding tag.

## Checklist for a release

1. Land the change on `main` with a `release:` spec line, or run the Version
   workflow with a spec.
2. Confirm the Version run committed `chore: bump version to x.y.z` with the new
   `CHANGELOG.md` section and pushed `vx.y.z`. Read the section: it is `### English`
   then `### 简体中文`, and the model wrote both. The app bundles both translations;
   the GitHub release page shows only the English notes.
3. Confirm the called Build run passed the test gate, verified the mounted
   image, and published `WallpaperMachine-x.y.z-arm64.dmg` with its `.sha256`
   sidecar, `WallpaperMachine-update.json` and a provenance attestation. The
   manifest's `digest` must equal the sidecar's checksum:
   `curl -sL https://github.com/WallpaperMachine/WallpaperMachine/releases/latest/download/WallpaperMachine-update.json`.
4. Read the release body on the page: it should contain only the English notes
   from the current `CHANGELOG.md` section, followed by the install footer,
   without a Chinese section or raw commit list. The **Full changelog** link
   opens the commit history; the `Built from` line must match
   `git rev-parse vx.y.z^{commit}`.
5. Confirm Latest points at the highest published version. Re-running Build for a
   tag that is already published fails by design; if a published release is
   genuinely wrong, delete it deliberately rather than re-running.
6. Open the published image on a Mac: the window shows the app beside
   Applications over the background, the drag installs it, and the first launch
   goes through System Settings → Privacy & Security. Then run the manual smoke
   pass in [testing/manual-smoke.md](testing/manual-smoke.md) against that copy
   and record it with `python3 scripts/log_verification.py` (see
   [conventions](conventions.md#documentation)).

CI publishes the disk image although the questions in
[../LICENSING.md](../LICENSING.md) remain unresolved; the licensing gate that
once failed Build was removed for 1.0.0 by maintainer decision. That file also
records the intended Supporter model (a free Developer ID signed and notarized
download, and a one-time Supporter purchase for a sponsor place and priority
support, under the GPL with corresponding source alongside). Neither Developer
ID signing nor notarization is part of this pipeline: `scripts/package.py`
signs with a self-signed certificate that only keeps the designated requirement
stable ([build.md](build.md#release-signing)), a provenance attestation records
who built an artifact rather than who vouches for it, and neither is license
clearance.
