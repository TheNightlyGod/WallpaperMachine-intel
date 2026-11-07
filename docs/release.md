# Versioning and releases

Version numbers, the pipeline that publishes a build, the notes it writes, and what
the in-app updater and the [Homebrew cask](#homebrew) expect of a release. Build mechanics
live in [build.md](build.md). To cut
a release, follow the [checklist](#checklist-for-a-release); when one fails, see
[Recovering a failed release](#recovering-a-failed-release); for an urgent fix that
must not wait for what `main` holds, see [Hotfix releases](#hotfix-releases).

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
[`CHANGELOG.md`](../CHANGELOG.md) section. The update manifest carries the newest
sections, in every language, to the app's update window
([below](#what-the-in-app-updater-expects)); the release page uses only the English
notes from the current section. [`scripts/release_notes.py`](../scripts/release_notes.py)
does both halves; GitHub's auto-generated notes are not used. Once a version's tag
exists, its section is not extended: the tag's release already published it, so a
change that lands later belongs in the next release's notes.

The layout is conventional-changelog's, the one standard-version writes: a heading
that links the version to its comparison with the previous one and gives the release
date, then category headings, and bullets that end with their issue and commit
links. From 1.5.7 a section has three languages, in this order, and nothing else at
`###`; each language may open with its banner line. Earlier sections keep their
original English and Simplified Chinese notes:

```markdown
## [1.6.2](https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.6.1...v1.6.2) (2026-10-24)

### English

![WallpaperMachine 1.6.2](Resources/ReleaseBanners/1.6.2.jpg)

One or two sentences on what the release means, omitted when the lists say it.

#### Bug Fixes

- Long names on narrow tiles now shrink to fit (closes [#76](https://github.com/WallpaperMachine/WallpaperMachine/issues/76)) ([bb75725](https://github.com/WallpaperMachine/WallpaperMachine/commit/bb75725338d4ab37a649973457c0357900b93355))

### 简体中文

![WallpaperMachine 1.6.2](Resources/ReleaseBanners/1.6.2.zh-Hans.jpg)

同样的一两句。

#### 问题修复

- 较窄磁贴上的长名称现在会缩小以完整显示 (closes [#76](https://github.com/WallpaperMachine/WallpaperMachine/issues/76)) ([bb75725](https://github.com/WallpaperMachine/WallpaperMachine/commit/bb75725338d4ab37a649973457c0357900b93355))

### 한국어

![WallpaperMachine 1.6.2](Resources/ReleaseBanners/1.6.2.ko.jpg)

같은 내용을 한두 문장으로 요약합니다.

#### 버그 수정

- 좁은 타일의 긴 이름이 이제 줄어들어 전체가 표시됩니다 (closes [#76](https://github.com/WallpaperMachine/WallpaperMachine/issues/76)) ([bb75725](https://github.com/WallpaperMachine/WallpaperMachine/commit/bb75725338d4ab37a649973457c0357900b93355))
```

The heading is `## [x.y.z](<compare link>) (YYYY-MM-DD)`; a first release, with no
earlier tag, links `https://github.com/<repository>/commits/vx.y.z`. Sections no
longer end in a `**Full changelog**` line: the heading carries that link. The
sections written before this layout were converted with their own compare links,
older `bobbyhuang-dev` addresses included. The script still reads the older
`## x.y.z — YYYY-MM-DD` heading, but always writes the linked one.

Category headings inside a language are `####`, in this order:

| Section | `####` English | `####` 简体中文 | `####` 한국어 |
|---|---|---|---|
| highlights | Highlights | 亮点 | 주요 변경 사항 |
| breaking | Breaking Changes | 不兼容变更 | 호환되지 않는 변경 사항 |
| new | Features | 新功能 | 새로운 기능 |
| improved | Improvements | 改进 | 개선 사항 |
| fixed | Bug Fixes | 问题修复 | 버그 수정 |
| performance (listings and older sections only) | Performance Improvements | 性能改进 | 성능 개선 |
| other (listings and older sections only) | Other Changes | 其他变更 | 기타 변경 사항 |

Highlights appear only in feature releases: the three to five changes that define the
release, which the other sections still list. A feature release is `x.y.0`, or a patch
whose notes start below `x.y` because it replaces an `x.y.0` that was never published.

Every bullet ends with the same links in all three languages, written by the script
from the commits the bullet describes, never by the model:
` (closes [#N](https://github.com/<repository>/issues/N), closes [#M](…))` when those
commits close issues, then ` ([abc1234](https://github.com/<repository>/commit/<full sha>))`,
several commits comma-separated inside one pair of parentheses. The link text is the
7-character short hash, and the word `closes` stays English in every language: it is
GitHub's keyword. Closing references come from the full messages of the bullet's
commits: GitHub's keywords, case-insensitive (`close`, `closes`, `closed`, `fix`,
`fixes`, `fixed`, `resolve`, `resolves`, `resolved`), followed by `#N`. References to
other repositories are ignored, and numbers are deduplicated and sorted ascending.
That is why a commit names the issue it resolves with `Closes #N`
([conventions](conventions.md#commits-and-pull-requests)). Model-written bullets from
before this layout have no recorded commits and carry no links.

### Release banners

A release can carry a banner in each language: a 3:1 picture (2400 × 800
pixels, JPEG or PNG) committed as `Resources/ReleaseBanners/x.y.z.jpg` (English),
`x.y.z.zh-Hans.jpg` (Simplified Chinese) and `x.y.z.ko.jpg` (Korean), or `.png`,
before the commit with the `release:` line. Each banner carries its own language's
words; a missing localized file falls back to the English banner. When the section
is written, the script opens each language block with its image line:

- `CHANGELOG.md` on GitHub shows the images from their repository paths.
- The release page shows the English one from the version's tag on
  `raw.githubusercontent.com`, at the top of the English notes.
- The app bundles neither the folder nor `CHANGELOG.md`; what its update window shows
  of a section is in [The update window](features/updates.md#the-update-window).

Publishing refuses a banner line that names another version's file, and a banner
line is not translated prose: a language block holding only a picture is missing its
translation.
Banners are drawn for the product, not taken from Workshop wallpapers: their art
belongs to their authors. Sections whose tag exists keep the banner they shipped
with, so a banner never goes back into an older release.

### Developer's notes

A release can also carry a note from the developer, printed word for word: commit
`Resources/ReleaseNotes/x.y.z.md` (English), `x.y.z.zh-Hans.md` (Simplified Chinese)
and `x.y.z.ko.md` (Korean) before the commit with the `release:` line. Each language
block then puts it under its own heading (**A note from the developer**, **开发者的话**,
**개발자의 말**) after the summary and before the categories, so it reaches
`CHANGELOG.md`, the release page (English) and the app's update window. The model never
sees it and cannot rewrite it. The note is all three files or none, each in its own
script, and only plain paragraphs separated by blank lines: a heading, list, picture or
the boundary marker stops the run before the model is asked, because each would change
how the section is read. Like a banner, it belongs to the version it names and is never
added to a section whose tag exists.

### Written by the release-notes model

With `--ai` the commits between two version tags go to a language model that
writes them up for users — what they can do now, what works better, what no
longer goes wrong — in English, Simplified Chinese and Korean, the same changes in
all three, merging commits that describe one change and leaving internal work out.
The release pipeline always passes `--ai`.

| Environment | Default | Meaning |
|---|---|---|
| `RELEASE_NOTES_API_KEY` | none; required | Key for the gateway. A secret: it lives in the environment of one command or in the repository secret of the same name, never in a file. |
| `RELEASE_NOTES_API_BASE` | `https://sub2api.moraxcheng.me` | Anthropic Messages API gateway; a base that already ends in `/v1` is accepted |
| `RELEASE_NOTES_MODEL` | `claude-opus-5-5` | The model that writes the notes |
| `RELEASE_NOTES_GITHUB_TOKEN` | none | Lets the script ask GitHub which account wrote a commit, for the [thanks line](#thanking-contributors); CI passes the job's `github.token` |

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
fully supported or fully compatible, and opt-in features (direct video plane sampling,
on-demand scene idle, drawing only the visible part of cropped scenes, the animated lock
screen) keep their optional, experimental
or off-by-default qualifier in every language; Native Metal is the default
renderer and native video is the default video player, and neither is ever called
optional. The model groups many commits about
one area (text layers, particles, lighting) into one bullet that names what users
see, keeping each section to about 15 bullets, and is told whether the version is a
feature release, which decides whether it writes highlights. Places in
the app are named the way the panel labels them, in English and in the zh-Hans
and ko catalogs' words (`Settings` / `设置` / `설정`); the prompt lists those names,
so renaming a tab or a Settings section changes the list in
`scripts/release_notes.py` in the same commit.

The prompt lists each commit as `* <short hash> <subject>`, so the model can cite it.
The model answers with JSON. `summary` is `{"english", "chinese", "korean"}`. Each of
`highlights`, `breaking`, `new`, `improved` and `fixed` is a list of
`{"english", "chinese", "korean", "commits"}` objects, one per change, so
translations cannot drift in length; `commits` is a required, non-empty list of the
short hashes of the commits the bullet describes. The summary names no commits. The
script resolves every hash to a commit of the range and stops the run on one that is
not a list, is empty, holds something other than a hash, or names a commit outside
the range (the bump commit included) or more than one commit. It renders that shape —
`### English`, then `### 简体中文`, then `### 한국어`, categories at `####`, each
bullet followed by its [issue and commit links](#release-notes-and-the-changelog) —
and stops the run on a reply that is not that JSON, omits a language, carries other
fields or an HTML comment (the boundary marker below), or was cut off at the
output-token limit. The compare link belongs to the section heading.
A Chinese string must contain Chinese characters; a Korean string must contain
Hangul; neither may copy the English or another translation. An English string
must contain Latin text. Whitespace is collapsed and list or heading markers are
stripped, so no entry can open a changelog section of its own. A range without
commits is reported in all three languages as having no user-visible changes,
without a request. The request
streams and names its own `User-Agent`, because Cloudflare in front of the
gateway refuses urllib's default one (error 1010). A connection that goes quiet
for 120 seconds, or a reply still running after 600, stops the run: the Version
job holds its branch lock while it waits. Nothing is retried; a failed run is
re-run.

#### Thanking contributors

Each language block of a new section ends with one line, written by the script and
not the model, thanking the outside contributors whose commits are in the range:
`Thanks to [@login](https://github.com/login) for contributing to this release.`,
`感谢 [@login](…) 为本版本做出的贡献。` and `이번 릴리스에 기여해 주신 [@login](…) 님께
감사드립니다.`, the same logins in the same order (oldest first contribution first)
in all three. Every commit of the range counts, internal ones included, except CI's
bump commit.

A contributor is a GitHub login. A commit's author has one when the address is
GitHub's noreply form (`<id>+login@users.noreply.github.com`); for any other address,
with `RELEASE_NOTES_GITHUB_TOKEN` set, the script asks GitHub's commit API once per
address (`GET /repos/<repo>/commits/<sha>`) and takes the author account GitHub links
it to. A `Co-authored-by` trailer counts only with a noreply address. Nobody is
credited by name or address alone: an address GitHub links to no account, a commit
it does not know yet (404/422) and every address in a run without the token are
left out, so a maintainer's new address is never thanked. Any other API failure
stops the run. `MAINTAINERS` in `scripts/release_notes.py` (`bobbyhuang-dev`,
`fzlzjerry` and the `t3code` agent account) and every bot (`[bot]` logins, GitHub's
`Bot` type) are never thanked; add a new maintainer there. AI co-authors such as
`noreply@anthropic.com` have no login and drop out on their own. The commit listing
(no `--ai`) ends with the English line too; `--rebuild-changelog` adds none to the
sections it lists, and a recorded section is never changed, so a version whose tag
exists keeps the notes it was published with.

### Listed from the commits

Without `--ai` the commits are listed in English, read through the
`type(scope): subject` convention in [conventions.md](conventions.md), as one
`### English` block with the same heading, `####` category names and link suffix
as the model's notes: `- **scope** — Subject (closes [#N](…)) ([abc1234](…))`. A
subject that repeats an earlier one collapses into one bullet that links every
commit behind it. It is offline and free, and it is a developer preview for
inspecting a range and for tests. It is not published: `--release-body` and
`--changelog --apply` refuse notes without the required ordered language blocks:
`### English`, then `### 简体中文`, then `### 한국어` for versions 1.5.7 and later.
Older bilingual sections remain valid.

Publication validates the whole changelog history, not just the current release.
Each `##` heading must be `## [x.y.z](<link>) (YYYY-MM-DD)` (or the older
`## x.y.z — YYYY-MM-DD`) with the version token `AppReleaseHistory` accepts
(optional `v`/`V`, three 64-bit integer components, no leading zeros), and each
section needs actual prose in every required language and matching bullet counts
(headings and compare links do not count as translated content). An explicitly
present Korean block must be complete even in older sections. Unknown, repeated
or misordered language headings also fail validation. `## Unreleased`, duplicate
versions, an overflow, a prerelease suffix, a leading zero, or a non-version `##`
line inside notes fails `--release-body`, `--changelog --apply` and
`--rebuild-changelog --apply`: such headings are neither kept nor dropped,
because the app rejects the whole file when it sees one.
`--rebuild-changelog --apply` also refuses to replace the file if rebuilding
would introduce an English-only section; translate missing history before applying.

| Commit type | Section |
|---|---|
| `feat` | **Features** |
| `fix` | **Bug Fixes** |
| `perf` | **Performance Improvements** |
| `!` suffix or a `BREAKING CHANGE:` trailer | **Breaking Changes** |
| `docs`, `test`, `chore`, `ci`, `build`, `style`, `refactor` | counted in one closing line |
| anything else, including non-conventional subjects | **Other Changes** |

Nothing is dropped silently: a subject the convention does not recognise is
listed rather than hidden, and the only commit removed outright is CI's own
`chore: bump version to x.y.z`. A subject longer than 140 characters is cut at a
word boundary; the linked commit still carries every word.

### Commands

```sh
python3 scripts/release_notes.py                               # English listing with its heading, not for publish
python3 scripts/release_notes.py --ai --tag v1.5.7 --to HEAD   # three languages, before the tag exists
python3 scripts/release_notes.py --tag v1.5.7 --release-body --ai --output notes.md
python3 scripts/release_notes.py --ai --changelog --apply      # write one translated section
python3 scripts/release_notes.py --rebuild-changelog --apply   # a section for every tag, recorded ones kept
```

A local `--ai` run needs `RELEASE_NOTES_API_KEY` exported for that command only.
To see the thanks line for contributors without a noreply address, pass
`RELEASE_NOTES_GITHUB_TOKEN="$(gh auth token)"` the same way.
`--previous` overrides the tag the range starts after; by default it is the
newest released version below the target that the range's end descends from, so a
gap in the numbering resolves correctly.

`--release-body` is the English-only GitHub release page. It reuses the version's
translated `CHANGELOG.md` section without calling the model again and keeps only the
English block, in the same category names and with each bullet's issue and commit
links. It then adds `**Full changelog**: <compare link>`, the link the section heading
carries (for an older heading, the comparison with the previous tag), then
`<!-- release-notes-end -->` and the install, checksum and requirement footer
(with a `Built from` line when `--built-from` is given). Raw commit messages are
not appended; the **Full changelog** link leads to the commits of the comparison. A
hand-pushed tag with no section is written once, by the model when `--ai` is
set, into the working-tree `CHANGELOG.md` before anything is built. English-only
or malformed source history fails the run instead of being published.

The marker is a contract: the updater shows everything above it and nothing
below, and About skips the **Full changelog** line. The update window reads the
manifest's `changelog` field, not that body, and falls back to the body only when the
field is missing; see [The update window](features/updates.md#the-update-window).

Writing a section is idempotent — rerunning replaces the section for that
version instead of duplicating it. `--rebuild-changelog` writes a section for every
version tag but keeps each section `CHANGELOG.md` already holds word for word, so
the model's notes survive; only missing ones are listed from the commits, in
English, and that listing is not a publishable section. It never calls the model,
and refuses `--ai`. `CHANGELOG.md` is written with `--apply`, and also when
`--release-body` has to generate the current section. With `--changelog`, nothing
is generated unless `--apply` or `--output` is given, so that dry run never calls
the model; a plain `--ai` run prints the model's section, heading included, and does
make the request. `scripts/tests/test_release_notes.py` covers classification,
closing references, rendering and links, the changelog headings, range resolution
against a throwaway repository, the model path and its commit citations against a
fake gateway, who is thanked (noreply logins, GitHub's commit record against a fake
API, maintainers and bots left out) and the thanks line in every language, the publish path and the committed `CHANGELOG.md` itself;
`scripts/tests/test_update_manifest.py` covers the manifest. Both run as part of
`python3 scripts/test.py`.

## Hotfix releases

An urgent fix (a broken sign-in, a crash on launch) ships on its own, not together
with the features `main` has gathered since the last release. A release that carries
both waits for both to be checked, and if it breaks something nobody can tell, or
pull back, one without the other: 1.6.4 shipped the SteamCMD sign-in fix with the
whole of #100. A hotfix release holds the fix and nothing else, so it can be checked
in minutes, its notes say only what it fixes, and `main` goes on as before.

A hotfix branched from 1.8.2 or older builds with that tag's `build.yml` and
`scripts/package.py`: it is signed with the project certificate from the
`SIGNING_CERTIFICATE_P12` and `SIGNING_CERTIFICATE_PASSWORD` secrets and is not
notarized ([build.md](build.md#release-signing)). Keep those two secrets until a
Developer ID release has shipped.

1. Branch from the newest release tag, named after it:

   ```sh
   git fetch --tags
   git switch -c hotfix/1.6.5 v1.6.5
   ```

   GitHub runs the workflow files of the branch that is pushed, so a tag older than this
   process (1.6.5 and earlier) needs them on the branch first. Take them from `main` now,
   and commit them on their own, without a `release:` line, once the gate in step 2 has
   passed with the fix, before the fix's commit:

   ```sh
   git checkout origin/main -- .github/workflows/version.yml .github/workflows/checks.yml \
     scripts/bump_version.py scripts/tests/test_bump_version.py
   # after the gate:
   git commit -m "ci(release): bring the hotfix release workflow to this branch" -- \
     .github/workflows/version.yml .github/workflows/checks.yml \
     scripts/bump_version.py scripts/tests/test_bump_version.py
   ```

   The merge back into `main` meets the same files there and changes nothing.

2. Make the fix there, with its test, not on `main`; run the gate
   (`python3 scripts/test.py`) as for any change. Pull requests into `hotfix/**` get the
   same Checks as those into `main`.
3. Push the branch with `release: patch` in the fix's commit message, or merge a pull
   request into the branch with that line, or run
   `gh workflow run version.yml --ref hotfix/1.6.5 -f spec=patch`. Version bumps the
   patch number, writes the CHANGELOG.md section from the commits since the tag the
   branch was cut from (only the fix), commits, tags and pushes to the hotfix branch,
   and calls Build exactly as for `main`. Build and `publish_release.py` do not care
   which branch a tag is on.
4. Version's bump job then merges the tag into `main` with a merge commit
   (`chore: merge hotfix x.y.z into main`), which brings the fix, the version and the
   CHANGELOG.md section there. Main's next release continues from the hotfix's number,
   and its notes start at the hotfix's tag, which is now an ancestor, so the fix is not
   listed twice. When the merge conflicts, or `main` moved while it pushed, the job
   opens an issue "Merge hotfix x.y.z into main" with the commands, and fails; do that
   merge before `main` releases again.

`scripts/bump_version.py` holds a hotfix branch to this: only a patch of the version
the branch carries, which must be the newest `vx.y.z` tag. It also refuses a release
from `main` while the newest tag is not merged into it. A minor or major spec, a branch
cut from an older release, or a version another release already took fails the bump
before anything is written, so a hotfix always becomes Latest and never takes a
number `main` will want. To fix an older line instead, release from `main`.

Merge a hotfix branch into `main` only with a merge commit, never a squash or a
rebase: those copy the fix's `release:` line into a new commit on `main`, and its push
would release again. A plain merge is safe: Version skips the `release:` lines of
pushed commits that a version tag already contains. This is the one merge commit the
[commit rules](conventions.md#commits-and-pull-requests) allow on `main`. Delete the
hotfix branch once the merge is on `main`.

Make the fix on the hotfix branch. A fix that already landed on `main` can be
cherry-picked without committing (`git cherry-pick --no-commit <commit>`, then commit it
after the gate, ending the message with `(cherry picked from commit <commit>)`): the
merge back then meets the same change
on both sides and goes through, but the commit on `main` is not part of the hotfix tag,
so `main`'s next notes may describe the fix again. Read that section before its release.

Nothing in the repository blocks this today: as of 2026-10-29 it has no rulesets and no
branch protection (`gh api repos/WallpaperMachine/WallpaperMachine/rules/branches/main`
and `.../rules/branches/hotfix%2Fx.y.z` both return `[]`), and every workflow declares
the write permissions it needs. Protection added later must let GitHub Actions push to
`main` (bumps and the hotfix merge) and to `hotfix/**` (the hotfix's bump commit and tag),
or the release stops after its notes are written.

### Emergency patch release for someone else (agents)

When the developer asks for an emergency, urgent or hotfix patch release, that request
is the release the [agent rules](../AGENTS.md) require before a `release:` line is
written. Do this, in order:

1. **Find the base.** `git fetch --tags origin` and take the newest tag,
   `git tag --list 'v*' --sort=-v:refname | head -1`. Check that `main` has unreleased
   commits since it (`git log --oneline <tag>..origin/main`); if it has none, a hotfix
   branch gains nothing, so release from `main` the usual way instead and say so.
2. **Find the fix.** Cut `hotfix/<base version>` from that tag
   (`git switch -c hotfix/1.6.5 v1.6.5`); when the tag predates the hotfix workflow, take
   its files from `main` as [step 1 above](#hotfix-releases) shows and commit them after
   the gate. Then make the fix with its test, or apply the commit the developer names with
   `git cherry-pick --no-commit <commit>`, never on `main`. Keep only what the
   emergency needs: anything else waits for `main`'s next release.
3. **Verify** as for any change: the routine gate `python3 scripts/test.py`, plus
   `scripts/check_rust.py` or `scripts/check_renderer.py` when the fix touches them.
   No push on a failed or missing verdict.
4. **Commit** with a user-facing `fix(scope): …` subject and body (they become the notes),
   `Closes #n` for the issue, and a standalone `release: patch` line. A developer's
   note, if asked for, is committed first ([Developer's notes](#developers-notes)).
   `python3 scripts/bump_version.py --spec patch --branch hotfix/<base>` is a dry run
   of the version the push will cut.
5. **Confirm, then push.** Pushing publishes a release to every user. Show the
   developer the commits on the branch (`git log --oneline <tag>..HEAD`), the version
   it becomes and the verification result, and push only after they agree:
   `git push -u origin hotfix/<base>`.
6. **Follow it through.** Watch the Version run for the branch
   (`gh run list --workflow version.yml --branch hotfix/<base>`), its merge step and its
   Build. Then check the release as the [checklist](#checklist-for-a-release)
   says (Latest, image, manifest, notes), and that
   `chore: merge hotfix x.y.z into main` is on `origin/main`; when the merge step
   opened an issue instead, resolve that merge before anything else is released.
   Offer to delete the remote hotfix branch once the merge is on `main`.

A failure along the way follows [Recovering a failed release](#recovering-a-failed-release),
on the hotfix branch rather than `main`.

## Workflows

Version, Build, Release, Rehearsal, Warm caches and Supporters are the release workflows
in `.github/workflows/`; Supporters shares only `main` with the others.
`claude.yml` and `claude-code-review.yml` are pull-request automation, described
in [CONTRIBUTING.md](../CONTRIBUTING.md#automated-review). `checks.yml` runs
`python3 scripts/test.py --python-only` on Linux for every pull request into `main` or a
`hotfix/**` branch and every push to them, the fast check a pull request waits for. `codeql.yml` is code scanning,
described [below](#codeql-codeqlyml).

Version, Build and Release grant `contents: write`; Build's publish job also needs
`id-token: write` and `attestations: write` for its provenance attestation, and its
build job `actions: read` to find the app icon among the run's jobs and artifacts. All
three callers (Version, Release, Rehearsal) pass those through, together with the
repository's secrets (`secrets: inherit`); Rehearsal must grant what the skipped publish
job declares. Warm caches only reads. Supporters writes only `README.md`,
`README.zh-CN.md`, `README.pt-BR.md` and `README.ko.md`, with `contents: write`, and reads Version's runs with
`actions: read`. The macOS setup Build and Warm caches share lives in one
composite action,
[`.github/actions/prepare-build`](../.github/actions/prepare-build/action.yml).

**Repository secrets.** Only a repository administrator can set or replace them:
`gh secret set <NAME>` in a checkout prompts for the value and writes it to the
repository `origin` points at.

| Secret | Read by |
|---|---|
| `RELEASE_NOTES_API_KEY` | Version for every bump; Build only for a tag without a `CHANGELOG.md` section |
| `DEVELOPER_ID_CERTIFICATE_P12`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `NOTARY_API_KEY`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER` | Build's `build` job, which fails when any is missing ([build.md](build.md#release-signing)) |
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude.yml` and `claude-code-review.yml` |

### Version (`version.yml`)

Runs on every push to `main` or to a `hotfix/**` branch
([Hotfix releases](#hotfix-releases)), and on demand from **Actions -> Version -> Run
workflow** with a `spec` input. On an `ubuntu-latest` runner it:

1. checks out with full history;
2. runs `python3 scripts/bump_version.py --ci --apply`;
3. has the release-notes model write the new version's three-language section into
   `CHANGELOG.md` with `scripts/release_notes.py --to HEAD --ai --changelog
   --apply` — `### English`, then `### 简体中文`, then `### 한국어`. The tag does
   not exist yet, so
   the range ends at `HEAD`. Without the secret, or when the model fails or omits
   a language, the job stops here: nothing is committed or tagged, and re-running
   the failed job retries the same bump;
4. if anything changed, refuses to continue when the target tag already exists on
   `origin`, then commits `project.yml`,
   `WallpaperMachine.xcodeproj/project.pbxproj` and `CHANGELOG.md` as
   `chore: bump version to x.y.z`, tags `vx.y.z`, and pushes branch and tag
   atomically as `github-actions[bot]`;
5. for a `hotfix/**` branch, merges that tag into `main` in the same job, or opens an
   issue when it cannot, without holding the release back
   ([Hotfix releases](#hotfix-releases));
6. calls the Build workflow directly for the tag it just pushed.

Step 6 is not redundant. **A tag pushed with `GITHUB_TOKEN` never starts another
workflow**, so the tag-triggered Release workflow would never fire for a
CI-produced tag; without the direct call, a bumped version would be tagged but
never published.

The bump job holds one `version-release` concurrency group, shared by `main` and every
hotfix branch, only while the version is chosen, committed and tagged and a hotfix is
merged into `main`. A workflow-wide group would keep the lock through the macOS build.
Runs queue (`queue: max`) instead of replacing the pending one, so a queued `release:`
push is never lost behind a later ordinary push, and `main` cannot release between a
hotfix's tag and its merge. When that merge needs a person (a conflict), the lock ends
with the job, but `bump_version.py` refuses a release from any branch that does not
contain the newest tag, so `main` releases again only once the hotfix is merged. A merge
whose push lost a race with another push to `main` (the Supporter list) is retried. A queued run checks out the branch as it is when the lock is
free, not the commit that was pushed, so its push is never rejected as out of date; the
release spec still comes from its own push.

The workflow needs permission to push to `main`: `contents: write`, and branch
protection must allow GitHub Actions.

### Build (`build.yml`)

`workflow_call` only, with a required `tag` input. It is the single place a
publishable artifact is produced, called by Version for CI-produced tags and by
Release for hand-pushed ones; [Rehearsal](#rehearsal-rehearsalyml) calls it with
`rehearsal: true` and a `ref`. It runs three jobs. `app-icon` ("App icon (macOS 26)")
compiles the app icon on a `macos-26` runner. `build` ("Build, sign and notarize
(macOS 15)") starts at the same time on `macos-15` (the oldest runner that carries
Xcode 26, whose Homebrew bottles set the published app's minimum macOS), with a
150-minute timeout, and takes the icon only once the app is compiled, so the icon job,
about a minute, is never what a release waits for. `publish` ("Publish the release")
runs on `ubuntu-latest` once `build` succeeds.

The test gate is not part of a release. Every change passes `python3 scripts/test.py`
before it is committed, and on hosted VMs the gate failed 1.5.0 through 1.5.4 only on
timing and layout the VM got wrong, each failure leaving a tag that could not be
published and a fix that had to ship under the next number. The
[Test workflow](#test-testyml) runs the same gate by hand.

The icon is compiled apart because Xcode 26's `actool` crashes on most `.icon`
compiles on macOS 15 ([build.md](build.md#stages-and-outputs)). `app-icon` runs
`python3 scripts/build.py --compile-app-icon DIR` and hands `Assets.car`,
`AppIcon.icns` and the partial Info.plist to `build` as the `app-icon-<tag>`
artifact.

**`build`**

1. checks out the tag with full history, which the notes need (a rehearsal checks out
   its `ref` and applies the rehearsed version with `scripts/bump_version.py --spec
   <version> --apply`, as the bump commit would);
2. writes the release body with `scripts/release_notes.py --release-body --ai
   --built-from "$(git rev-parse HEAD)"` before anything is built. The current
   section must already have every required language and is reused without
   calling the model; a hand-pushed tag with no section gets one written once into
   the working-tree `CHANGELOG.md`. A copy of that `CHANGELOG.md` goes to `publish`
   with the notes, so the update manifest carries every translation of the new
   section. Missing translations or malformed source history fail here, in seconds,
   rather than after the macOS build. A rehearsal writes no notes;
3. imports the Developer ID certificate and the notary API key from the signing
   secrets into a temporary keychain ([build.md](build.md#release-signing)), also
   before anything is built: a missing secret, a certificate that does not import
   (1.9.0's failure, which then came after the whole build) or a key Apple refuses
   fails in about a minute. Xcode signs ad hoc, so the identity changes nothing there;
4. runs `prepare-build` (below), restoring both caches and reusing the renderer build
   for every source unchanged since it (`reuse-renderer-build`);
5. runs `python3 scripts/build.py --configuration Release --no-app-icon`, which
   leaves `AppIcon.icon` out of the Xcode build;
6. waits until `app-icon` has uploaded `app-icon-<tag>`, which it normally has, looking
   the artifact up by name so a re-run of only this job finds an earlier attempt's,
   and fails if that job ended without one; downloads it and runs
   `python3 scripts/build.py --configuration Release --install-app-icon DIR`, which
   puts the compiled icon and catalog into the bundle with their Info.plist keys and
   re-signs it;
7. runs
   `python3 scripts/package.py --configuration Release --require-deployment-target
   --sign-identity "Developer ID Application" --notarize "WallpaperMachine Notary"
   --notary-keychain <that keychain>`, which fails if a bundled library needs a newer
   macOS than the deployment target, and signs with the hardened runtime, notarizes
   and staples the app and then the disk image; a submission Apple refuses fails the
   job with Apple's log. Each submission waits up to 50 minutes, and one Apple has not
   finished by then fails the job with its id (a new team's first submissions take
   hours: [build.md](build.md#release-signing)). It also generates
   `THIRD-PARTY-NOTICES.txt` into the bundle; a component whose license text
   cannot be found is named in the log and marked in the file, and
   `--require-notices` (not yet passed here: see
   [../LICENSING.md](../LICENSING.md#notice-payload)) would fail on it.
   Packaging proves the
   disk image, not the build tree: it mounts the image read-only and requires
   `app.wallpapermachine` at the bundle's version, its stapled ticket, a passing
   `codesign --verify --deep --strict`, the signed entitlements and Info.plist
   keys the lock screen extension and the permission prompts need ([bundle
   contract](build.md#bundle-contract)), the `Applications` link and the window
   layout, then writes the `.sha256` sidecar
   ([build.md](build.md#packaging-and-installing));
8. matches the image to the tag: it must be named
   `WallpaperMachine-<tag without v>-arm64.dmg`, and its checksum is echoed into the
   job summary;
9. hands the image, its sidecar, the notes and that `CHANGELOG.md` to `publish` as
   the `release-<tag>` artifact (a rehearsal keeps its image three days as
   `rehearsal-<tag>`, and skips `publish`).

Step 8 is the guard that the bump actually reached the build:
`scripts/package.py` names the image from the bundle's
`CFBundleShortVersionString`, so a mismatch means the published tag and the
built version disagree and the job fails instead of publishing the wrong binary.

When `build` fails it uploads its full tool logs from `artifacts/` as
`build-logs-<tag>`, kept 14 days: the job output is only the scripts' filtered
summary.

**`publish`**

1. downloads the artifact and checks the image against its `.sha256` sidecar;
2. attests build provenance for the image with
   `actions/attest-build-provenance`;
3. writes the update manifest `WallpaperMachine-update.json` from the tag, the
   notes, the image and the build job's `CHANGELOG.md` with
   `scripts/update_manifest.py --changelog` ([below](#what-the-in-app-updater-expects));
   `publish`'s own checkout of the tag lacks a section generated for a hand-pushed tag;
4. publishes the image, its sidecar and the manifest with
   `scripts/publish_release.py`.

**`prepare-build` and the caches.** The composite action selects the newest
non-beta `/Applications/Xcode_26*.app`, downloads that Xcode's Metal Toolchain when
`xcrun metal` cannot run (the runner images do not always carry it, and the extension
compiles a Core Image kernel), `brew install --quiet`s the
XcodeGen/CMake/renderer package set with `ccache`, and restores two
`actions/cache` entries. Every key carries the runner's macOS (`<os>` below is
`macos-15` or `macos-26`), because bottles and compiled objects
differ between releases; `build` and the Test workflow therefore keep separate entries.

| Cache | Path | Key | Saved by | What a hit saves |
|---|---|---|---|---|
| C++ objects | `~/.ccache` | `ccache-<os>-<run>`, restored by the `ccache-<os>-` prefix | `save-object-cache` (default on): Warm caches and Test's `renderer` job. Test's three jobs share a run's key, so `rust` and `native` pass `"false"`; so do CodeQL, which runs on every push and saved 147 MB each time, and Build, whose release would wait for the upload | compiling a C++ file the build tree has to rebuild: ccache hashes content and returns the previous object |
| Renderer | `~/.cargo/registry`, `~/.cargo/git`, `Renderer/target` | `renderer-ccache-<os>-<hash of rust-toolchain.toml>-<hash of Cargo.lock, provenance.json>-<run>`, restored by the prefix without the run, then by the toolchain prefix alone | `save-renderer-cache` (default off): Warm caches, daily | crate downloads, and, with `reuse-renderer-build`, every Rust crate and C++ file unchanged since the restored build |

The `CMAKE_<LANG>_COMPILER_LAUNCHER=ccache` variables only take effect on a build
tree's first CMake configure, so change the renderer key's prefix whenever the
launcher setup changes: no tree configured the old way may be restored. Each
macOS job prints `ccache --show-stats` at the end; hits against misses there is
the evidence the cache worked. The toolchain is a pinned stable release
(`Renderer/rust-toolchain.toml`); raising the pin changes the renderer key's
toolchain hash, so the next build compiles every crate once and starts a new entry.

Only runs on `main` save either cache, and only the callers that opt in; every other
ref (pull requests, branches, hand-pushed tags) restores and never saves. An entry saved
under another ref is readable by that ref alone, and those entries pushed the repository
past GitHub's 10 GB cache limit, which evicts the `main` entries releases need; on
2026-11-04 CodeQL's per-push C++ object caches did the same (10.5 GB in 108 entries,
most of them CodeQL's). A release only restores: [Warm caches](#warm-caches-warm-cachesyml)
writes the entries it reads, once a day, so they are at most a day behind `main`.

**Reusing the renderer build.** A checkout gives every file the current time, and cargo
and CMake decide what to rebuild by comparing times, so a restored `Renderer/target`
looked older than all its sources: every release recompiled the four workspace crates
(vendored naga, `wm-shader`, `wallpaper-core`, `wallpaper-bridge`), reran the core
crate's build script and recompiled the C++ engine through ccache (214 compiler calls,
54 misses, for 1.9.1), 3m30s of the macOS 15 runner although the cache held them
built. With `reuse-renderer-build: "true"`, `prepare-build` runs
`python3 scripts/source_times.py restore` and then `record` after the cache restore.
`record` writes `Renderer/target/source-times.json`, which travels with the build in
the cache: the blob id of every tracked file under `Renderer/` and `ThirdParty/`, the
entries of every directory there, and the toolchain (the `rustc`, Apple clang, SDK,
CMake and Homebrew library versions, the cargo manifests and the compiler flags in the
environment). `restore` gives every file whose blob id is unchanged, and every directory
whose entries are unchanged, a time older than any build output, but only when the
toolchain is the recorded one; changed, added and removed files keep the checkout's time.
Cargo and CMake then rebuild exactly what changed: a release whose renderer sources are
unchanged rebuilds only `wallpaper-bridge`, which `GIT_SHORT_COMMIT` stamps with the new
revision (about half the old time), and one C++ file changed compiles that one file.
Removing or adding a file changes its directory's entries, so a build script watching the
directory (and CMake's `file(GLOB)`) runs again. The record vouches for the whole target
directory only while every job that keeps it builds the same thing, `scripts/build.py`'s
renderer stage (`cargo build --workspace --release`): Build, Warm caches and CodeQL pass
the input. Every other job (Test's, which also build test profiles) runs
`source_times.py forget`, so a cache it saved would never be trusted. The first run
after a change of toolchain, or without a record, rebuilds everything once, as before.

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

### Test (`test.yml`)

The test gate on hosted runners, run by hand from **Actions -> Test -> Run
workflow** on the branch or tag chosen under "Use workflow from" (`--ref` below). It
does not tag, build the Release app or publish, and no release waits for it
([why](#build-buildyml)). It has no input naming another ref to test: only a run started from `main` saves
caches (other refs restore without saving), and a run started from `main` that built
another ref's code would let that code write the caches every release restores. Its
three jobs run in parallel on `macos-26` runners, each after `prepare-build` and
`python3 scripts/build.py --renderer-only` for the renderer and the generated bridge,
so a run takes about as long as the native tests (about 25 minutes for 1.5) rather
than the sum (over 40):

- `rust` runs `python3 scripts/check_rust.py`;
- `renderer` runs `python3 scripts/check_renderer.py --allow-missing-gpu
  --allow-imprecise-timers`. The two flags are fallbacks for hosted VMs: only the exact
  exit 77 of a compiled device or timer probe skips the named GPU or wall-clock cadence
  checks ([renderer testing](testing/renderer.md#scriptscheck_rendererpy)); each skip
  is a CI warning, and all other probe and test failures remain failures. Excluded and
  asset-dependent checks stay listed in the JSON reports and logs; they do not count as
  verified asset or GPU coverage;
- `native` runs `python3 scripts/test.py --serial`, which builds the Debug app, icon
  included, and its tests itself. `--serial` runs one test class at a time: see
  [Parallel execution](testing/README.md#parallel-execution) for why.

```sh
gh workflow run test.yml --ref main
gh workflow run test.yml --ref <branch> -f skip_renderer=true -f only="SettingsWindowRenderTests WorkshopBrowserRenderTests"
```

`only` passes each space-separated name to `scripts/test.py --only`, and
`skip_renderer` skips the `rust` and `renderer` jobs; both are for diagnosis, so only
a run without them says the gate passes. A failed job keeps its logs, result bundles
and any WebKit, app or jetsam reports included, as `test-logs-<run id>-<job>` for 14
days.

### Warm caches (`warm-caches.yml`)

Every day at 03:17 UTC (and on demand from **Actions -> Warm caches -> Run workflow**)
this runs `prepare-build` with `save-renderer-cache` and `reuse-renderer-build` and
then `python3 scripts/build.py --renderer-only` on `main`, once on `macos-15` and once
on `macos-26`, and saves a new renderer build and C++ object cache for each. They are
the entries a release restores (Build saves none, so a release never waits for an
upload), so its renderer build is at most a day behind `main` and it rebuilds only
what changed since. Reading every entry also keeps GitHub from evicting one nobody
read for seven days. Caches saved on `main` are readable from every ref, including
the tags Release builds. It publishes nothing. After a change to the caches or to
`scripts/source_times.py` reaches `main`, run it once by hand, so the next release
does not rebuild the renderer from an entry without a record.

### Supporters (`supporters.yml`)

Keeps the [README's Supporter list](../README.md#thank-you-to-every-priority-support-member)
of Priority Support members, and the same list in its translations `README.zh-CN.md`,
`README.pt-BR.md` and `README.ko.md`, in step with the website's
[thank-you wall](https://www.wallpapermachine.app/#sponsors). Every hour (and on
demand from **Actions -> Supporters -> Run workflow**) it runs
`python3 scripts/update_sponsors.py` on `main`, which reads the wall's JSON from
`https://www.wallpapermachine.app/api/sponsors` and rewrites the block between the
`supporters:start` and `supporters:end` markers in all four files; the script's
docstring describes the block, and edits between the markers are overwritten.
When the block changed it commits the four READMEs as
`docs(readme): update the Supporter list` and pushes to `main`, starting again from
the new `main` if that moved. It skips the hour while a Version run is queued or
running, because Version's push of its bump commit does not retry. A wall that
can't be read, or a README without its block, fails the run and leaves the READMEs
as they were.

### CodeQL (`codeql.yml`)

Code scanning on every push to `main`, weekly, and on demand. Pull requests do not
run it: the Swift job's full traced app build takes about half an hour, and its
findings were mostly false positives, so new alerts surface after the merge instead.
It replaces GitHub's default setup, which can only autobuild Swift and
fails at the extension's link because the renderer library and the Homebrew
libraries do not exist yet. Actions, Python and Rust are analyzed without a build
on Linux. Swift runs on `macos-26`: `prepare-build` (restoring the caches without
saving the C++ object cache, and reusing the renderer build) and
`python3 scripts/build.py --renderer-only` first, untraced, then CodeQL traces
`scripts/build.py --swift-only` with the `--xcode-setting` overrides CodeQL's own
Swift autobuild uses (no signing, no compilation cache, no integrated driver), so
the extractor sees every Swift compile. The traced build also leaves out the `.metal`
sources (`EXCLUDED_SOURCE_FILE_NAMES=*.metal`): under CodeQL's tracer Xcode 26 cannot
find the Metal Toolchain that `prepare-build` installed
([github/codeql-action#3978](https://github.com/github/codeql-action/issues/3978)), and
they hold no Swift. C/C++ (only vendored third-party code is
visible to it), Ruby (the repository has none) and JavaScript/TypeScript (none since
the SwiftUI control panel; CodeQL fails a language with no code) are deliberately not
analyzed.
The renderer's Rust test sources (`tests/` directories, `tests.rs` and `*_tests`
modules under `Renderer/`) are excluded through `paths-ignore`: their fixture values
in panic messages read as cleartext logging, and those alerts kept returning after
being dismissed whenever a test file moved. Keep new Rust tests under those names.
Removing a language from the matrix does not remove its configuration: **Security ->
Code scanning -> Tool status** keeps showing that language's last scan, failed or
not, because nothing uploads to its category again. In the same change, delete it
there (the configuration's **⋯ -> Delete configuration**) once no alert in it needs
keeping.
Default setup must stay off under **Settings -> Code security -> CodeQL
analysis**; while it is on, GitHub rejects this workflow's results.

### Rehearsal (`rehearsal.yml`)

A release is tagged before it is built, and a tag is never taken back
([Recovering a failed release](#recovering-a-failed-release)), so a build or packaging
failure burns the version: 1.7.0 (a bundled library packaging could not relocate) and
1.9.0 (the Developer ID certificate's import) were each replaced by the next patch,
with the changelog and banners moved by hand. Rehearsal runs the release path without
a version to lose. Dispatched on any branch (**Actions -> Rehearsal -> Run workflow**,
or `gh workflow run rehearsal.yml --ref <branch> -f spec=patch`), its `plan` job turns
the `spec` input into the version a release of that branch would get, with
`scripts/bump_version.py --spec` and nothing written, and calls Build with
`rehearsal: true`, the branch's commit as `ref` and that version as `tag`. Build then
runs its usual jobs, runners, caches and signing secrets: it applies the version to the
checkout as the bump commit would, imports the certificate and the notary key, builds,
adds the icon, signs, notarizes and staples the app and the image, and verifies the
mounted image. It writes no notes and skips `publish`, and keeps the disk image for three
days as the run's `rehearsal-<tag>` artifact, to try before releasing. A newer rehearsal
of the same branch cancels a running one.

Rehearse before landing a change to the release path (the workflows, `prepare-build`,
`scripts/build.py`, `scripts/package.py` and `scripts/lib/`, `project.yml`'s bundle or
signing settings, the Homebrew libraries), and before a release that must not slip.

### Release (`release.yml`)

Triggered by pushing a `v*.*.*` tag by hand. It only calls Build with
`github.ref_name`, sharing the `publish-<tag>` concurrency group with Version's
publish job so one tag is never built twice at once. A hand-pushed tag has no
`CHANGELOG.md` section unless one was committed before tagging; Build then asks
the model once and writes that translated section into the working tree before the
app is built. A section that is present but missing a required translation fails
the build; it is not rewritten.

## What the in-app updater expects

**Settings → About** installs updates from the repository's latest GitHub Release.
What the app does with one (when it checks, how it avoids the API quota, download,
verification, replacing the running app, the update window) is in
[updates](features/updates.md). This section is the publish-side contract: what a
release has to carry for that to work.

The update manifest, `WallpaperMachine-update.json`, is an asset of every release.
`scripts/update_manifest.py` writes it in Build's `publish` job from the tag, the
notes file that becomes the release body, `CHANGELOG.md` and the image bytes, and
`scripts/publish_release.py` attaches it. It is the release object in the REST
API's shape: `tag_name`, `html_url`, `prerelease`, `body` and one asset with
`name`, `browser_download_url`, `size` and a `sha256:` `digest`, plus one field the
API does not have. `changelog` (written with `--changelog CHANGELOG.md`) is a string
holding the newest 20 `## ` version sections of `CHANGELOG.md` verbatim, every
language included, from the first `## ` heading on, without the file's preamble.
The script refuses a changelog with no section for the tag. When an update is
available, the app's update window shows from it each version newer than the
installed one, in the app's language, and falls back to the release body when the
field is missing, as in manifests from before it existed
([The update window](features/updates.md#the-update-window)). The app no longer
bundles `CHANGELOG.md` or `Resources/ReleaseBanners`. Updates and their results are
passive entries in the control panel and menu bar; no window opens automatically. The app reads the manifest
from `https://github.com/WallpaperMachine/WallpaperMachine/releases/latest/download/WallpaperMachine-update.json`,
which github.com redirects to the file on the release marked Latest. A draft never
resolves, and `publish_release.py` makes the release public only after the image,
sidecar and manifest are uploaded. The name is
`AppUpdateConfiguration.manifestName`; renaming it changes both sides at once. The
script refuses a tag that is not `vx.y.z`, a repository that is not `owner/name`
and an image not named as below.

New manifests additionally carry `bundle_identifier`, `minimum_system_version` and
`architectures`. Packaging reads these from the verified signed app inside the DMG
and writes `WallpaperMachine-<version>-arm64.dmg.metadata.json`, binding them to the
image name, version, size and SHA-256. Build transfers this internal file to the
publish job; `update_manifest.py --metadata <file>` verifies the binding before
writing the manifest. The metadata sidecar is not a public release asset. CI requires
it; the optional CLI flag remains available for testing legacy manifests. Older
clients ignore these additive fields. New clients reject known incompatibility before
downloading and also verify the actual signed application's target version, macOS
minimum and architecture before installing, including when reading a legacy manifest.

Before any GitHub mutation, `publish_release.py` verifies exactly the DMG, SHA-256
sidecar and manifest, including the notes body and compatibility fields. After uploading,
it checks the draft's asset names, lengths and any GitHub-supplied digests before
promoting it. Missing or mismatched assets leave the release a draft. The existing
publish lock, immutable live releases and final Latest comparison are unchanged.

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
- releases are signed with the project's Developer ID and notarized
  ([build.md](build.md#release-signing)): the updater installs only a copy that meets
  `AppUpdateConfiguration.signingRequirement` (the Developer ID, or the project
  certificate that signed 1.0.2 through 1.8.2; copies older than 1.8.0 accept only the
  latter), and keeping the designated requirement is what lets macOS keep the app's
  privacy permissions;
- the release body is the English notes above `<!-- release-notes-end -->`
  ([Release notes and the changelog](#release-notes-and-the-changelog)); the app
  uses it as a fallback when localized changelog sections are unavailable and
  ignores the footer after the marker;
- the manifest's `changelog` starts with the new version's section in the
  [layout above](#release-notes-and-the-changelog), so an install several versions
  behind sees every change it is about to receive.

Renaming the image, publishing a prerelease, or attaching only a zip silently
breaks automatic updates; `Tests/Unit/GitHub/AppUpdateTests.swift` pins this
behavior, including the exact published image name and an install from a real disk
image.

## Homebrew

The `wallpapermachine` cask lives in Homebrew's repository, not here
([`Casks/w/wallpapermachine.rb`](https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/w/wallpapermachine.rb)).
It installs the release's own disk image, the `v<x.y.z>` release's
`WallpaperMachine-<x.y.z>-arm64.dmg`, and pins it by SHA-256: renaming the image or
changing the tag format breaks Homebrew installs as well as updates, and replacing a
published image, even with a rebuild of the same version, makes `brew install` of that
version fail its checksum. Homebrew finds a new version through the release marked
Latest (`livecheck` with `github_latest`) and its autobump opens the version bump
itself, so a release needs no step for it; until that bump merges, `brew install` gets
the previous version, which then updates itself. The cask declares `auto_updates`, so
`brew upgrade` leaves an installed copy to the in-app updater
([updates](features/updates.md#installing)). Changing what the cask states takes a pull
request to that repository: the minimum macOS (`depends_on macos: :sequoia`), the
bundle identifier `app.wallpapermachine` it quits before uninstalling, or the app-data
folders its `zap` stanza moves to the Trash, which include
`~/Library/Application Support/WallpaperMachine` and so the wallpaper library unless it
was [moved](features/library-location.md).

## Recovering a failed release

A failure the tag's code did not cause (Apple's notary or ticket service, a runner, a
secret replaced since) is retried with **Re-run failed jobs** in the same run: only
`build` and `publish` run again, and they publish the same version. A failure that needs
a change to the code costs the version, as below; a
[rehearsal](#rehearsal-rehearsalyml) of the branch before releasing it finds that kind
without taking one.

A tag the Version workflow pushed stays when its Build run fails; only Build's
`publish` job makes a release public. If a tag was created but its release never
passed the publication gate, preserve that tag and fix the failed checks on
`main`: Version refuses a target tag that already exists on `origin`,
`publish_release.py` refuses a live release, and a `CHANGELOG.md` section is not
extended once its tag exists. Cut the next patch instead, with the optional
workflow-dispatch `notes_from` input set to the last *published* tag, so its
model-written translated notes include the still-unpublished changes:

```sh
gh workflow run version.yml --ref main -f spec=patch -f notes_from=v1.2.6
```

`notes_from` only sets `release_notes.py --previous`; it does not change the version
policy, skip tests or replace a live release. Ordinary releases leave it empty and
use the preceding tag. When the unpublished tag was a feature release, its notes start
below that minor version, so the patch gets highlights too; commit copies of its
banners under the patch's number (`x.y.1.jpg`, `x.y.1.zh-Hans.jpg`,
`x.y.1.ko.jpg`) before running the
workflow, since a section names only its own version's banner. Remove the sections
of the unpublished versions the patch replaces, and their banners, from
`CHANGELOG.md`: its notes already cover them, and a section left there is shown again
in the update window of every install that updates across it. Remove them before the
patch is cut, in or before the push with the `release:` line: the patch's manifest
carries `CHANGELOG.md` as it is at the patch's tag, and that copy is not rewritten.

## Checklist for a release

1. When the release includes a change to the release path (the workflows,
   `prepare-build`, `scripts/build.py`, `scripts/package.py`, `scripts/lib/`, signing,
   bundled libraries), [rehearse](#rehearsal-rehearsalyml) it first and wait for a
   green run. Then land the change on `main` with a `release:` spec line, or run the
   Version workflow with a spec. An urgent fix goes on a `hotfix/<x.y.z>` branch from the
   newest tag instead ([Hotfix releases](#hotfix-releases)); afterwards also confirm
   `chore: merge hotfix x.y.z into main` reached `main`, or that its issue is handled.
2. Confirm the Version run committed `chore: bump version to x.y.z` with the new
   `CHANGELOG.md` section and pushed `vx.y.z`. Read the section: its heading is
   `## [x.y.z](<compare link>) (YYYY-MM-DD)`, then `### English`, `### 简体中文` and
   `### 한국어`, the model wrote all three, and each bullet links the commits it
   describes and any issue they close. The update window shows all translations;
   the GitHub release page shows only the English notes.
3. Confirm the called Build run verified the mounted
   image, and published `WallpaperMachine-x.y.z-arm64.dmg` with its `.sha256`
   sidecar, `WallpaperMachine-update.json` and a provenance attestation. The
   manifest's `digest` must equal the sidecar's checksum, and its `changelog` must
   start with the new version's heading:
   `curl -sL https://github.com/WallpaperMachine/WallpaperMachine/releases/latest/download/WallpaperMachine-update.json`.
4. Read the release body on the page: it should contain only the English notes
   from the current `CHANGELOG.md` section, followed by the install footer,
   with its issue and commit links, without Chinese or Korean sections or a raw
   commit list. The **Full changelog** link opens the comparison with the previous
   version; the `Built from` line must match
   `git rev-parse vx.y.z^{commit}`.
5. Confirm Latest points at the highest published version. Re-running Build for a
   tag that is already published fails by design; if a published release is
   genuinely wrong, delete it deliberately rather than re-running.
6. Open the published image on a Mac: the window shows the app beside
   Applications over the background, the drag installs it, and the first launch
   opens without **Open Anyway** (`spctl --assess -vv` on the installed app says
   `source=Notarized Developer ID`). Then run the manual smoke
   pass in [testing/manual-smoke.md](testing/manual-smoke.md) against that copy
   and record it with `python3 scripts/log_verification.py` (see
   [conventions](conventions.md#documentation)).

CI publishes the disk image although the questions in
[../LICENSING.md](../LICENSING.md) remain unresolved; the licensing gate that
once failed Build was removed for 1.0.0 by maintainer decision. That file also
describes the distribution (a free signed download beside the paid Priority
Support service, under the GPL with corresponding source alongside). The image is
signed with the project's Developer ID and notarized
([build.md](build.md#release-signing)); notarization is Apple's malware check and a
provenance attestation records who built an artifact rather than who vouches for it,
and neither is license clearance.
