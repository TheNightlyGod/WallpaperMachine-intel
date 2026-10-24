# Contributing

WallpaperMachine is a native macOS app (an AppKit shell with a SwiftUI control
panel), a sandboxed lock-screen ExtensionKit extension, and a vendored Rust/C++
renderer. This page gets you running and points at the document that owns each
topic; it does not repeat them.

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md). Found a
vulnerability? Report it privately, as [SECURITY.md](SECURITY.md) describes, not in
an issue. Bugs and ideas go through the issue forms; questions go to the
Discussions Q&A.

## Setup

Apple Silicon, macOS 15.6 or later, and a full Xcode 26 selected with
`xcode-select`. Install the Homebrew packages that
[docs/build.md](docs/build.md#prerequisites) lists, then:

```sh
python3 scripts/build.py
python3 scripts/test.py
python3 scripts/check_dev_tools.py   # optional diagnostics only
```

The first build compiles the renderer, generates the Swift bridge bindings,
generates the Xcode project and builds the app. Flags and failure modes:
[docs/build.md](docs/build.md).

## Day-to-day loop

1. Edit sources. Swift and resource changes rebuild with
   `python3 scripts/build.py --swift-only`; renderer changes need a full
   `python3 scripts/build.py`.
2. While iterating, run `python3 scripts/test.py --only <TestClass>` for the
   domain you touched; run the full `python3 scripts/test.py` (Python script
   tests, project generation, then `WallpaperMachineTests`) once before you open
   the PR. Neither touches the desktop. Only failures and a verdict reach the
   terminal; the full log is in `artifacts/tests/` (`--verbose` streams it). The
   [verification tiers](docs/testing/README.md#verification-tiers) scale this to
   the size of the change.
3. Run the targeted check your change needs: `python3 scripts/check_rust.py` for
   Rust crates, `python3 scripts/check_renderer.py` for renderer, bridge or scene
   work, `python3 scripts/test.py --ui` only when a desktop run is explicitly
   wanted.
4. Update the document that owns the behavior you changed. For a feature or
   cross-domain change, record the run with
   `python3 scripts/log_verification.py --title "…" --line "…"`. Before you
   commit, `git status` should show only your change. `python3 scripts/clean.py`
   clears `artifacts/` and stray byproducts but keeps Xcode's derived data and the
   built app (`--dry-run` previews).

## Where to read next

| I want to | Read |
|---|---|
| Understand how the pieces fit together | [docs/architecture.md](docs/architecture.md) |
| Find out where a file or new code belongs | [docs/repository-layout.md](docs/repository-layout.md) |
| Build, package, or install locally | [docs/build.md](docs/build.md) |
| Know the code, test and doc rules | [docs/conventions.md](docs/conventions.md) |
| Translate the app or improve existing wording | [docs/localization.md](docs/localization.md#contributing-translations) |
| Write or run tests, or record evidence | [docs/testing/README.md](docs/testing/README.md) |
| Debug the renderer or GPU output | [docs/testing/renderer.md](docs/testing/renderer.md) |
| Ship a version | [docs/release.md](docs/release.md) |
| Profile, inspect, or diagnose the desktop | [docs/development-tools.md](docs/development-tools.md) |
| Work on panel UX, downloads, audio, lock screen, theming | [docs/README.md](docs/README.md) product feature section |
| Check licensing constraints | [LICENSING.md](LICENSING.md) |

## Hard rules

The rules contributors trip over; [AGENTS.md](AGENTS.md) and
[docs/conventions.md](docs/conventions.md) hold the full set.

- **Never hand-edit generated files.** `WallpaperMachine.xcodeproj` comes from
  `project.yml`; `App/Bridge/Generated` comes from `uniffi-bindgen`. Change the
  source, regenerate, commit both.
- **Never change `ThirdParty/` without updating `ThirdParty/provenance.json`.** That
  file is the record of which third-party revision is vendored.
- **Never commit `artifacts/` or `build/`.** Both are Git-ignored and disposable.
  Screenshots, traces, wallpaper payloads, Steam session data and personal paths
  stay out of Git too. Preview a cleanup with `python3 scripts/clean.py
  --dry-run`: its `--all` flag also deletes the locally delivered app, and
  `--user-assets` and `--managed-user-assets` delete live wallpaper data.
- **Commit agent policy, never agent state.** Shared rules for AI agents live in
  tracked files only: `AGENTS.md` (plus its `CLAUDE.md` symlink) and `docs/`.
  Agent tool directories and `CLAUDE.local.md` are Git-ignored per-machine state:
  never `git add -f` them or link to them from tracked docs. Using a new agent
  tool? Ignore its directory in the same change; the directory list and the
  exception recipe are in `AGENTS.md` and `.gitignore`.
- **Routine verification never takes over the desktop.** No screen capture, no
  synthetic input, no opening app windows, no changing the user's wallpapers
  unless a desktop run was explicitly requested. `scripts/test.py --ui` is that
  explicit case and is not a merge gate.
- **Report what you did not verify.** Headless-only coverage is a fine result;
  claiming visual correctness you never observed is not.

## Commits and pull requests

- Commit subjects and PR titles are Conventional Commits (`fix(scene): …`,
  `feat(downloads): …`); [docs/conventions.md](docs/conventions.md#commits-and-pull-requests)
  has the rules. The type is not decoration: `scripts/release_notes.py` hands the
  commits of a release to the release-notes model, and the subjects and bodies of
  `feat`, `fix` and `perf` commits become the notes users read.
- Pull requests are normally squash-merged. The PR title becomes the commit
  subject when the PR has several commits (the commit's own subject when it has
  one), and the commit messages become the body, so title a PR as you would the
  commit.
- A `release:` line in a PR title or in any commit message cuts a version when the
  change lands on `main` ([docs/release.md](docs/release.md#release-specs-in-commit-messages)).
  Leave it out unless a maintainer asked for that release.
- CI commits to `main` on its own (version bumps and the Supporter list), so a
  long-lived branch falls behind quickly; update it from `origin/main` before you
  ask for review, rebasing commits you have not pushed yet rather than merging
  `origin/main` into them.
- The [PR template](.github/pull_request_template.md) carries the checklist, and
  the definition of done is in [docs/conventions.md](docs/conventions.md#definition-of-done).

## License and sign-off

WallpaperMachine is licensed under the GNU GPL version 3 only ([LICENSE](LICENSE));
[LICENSING.md](LICENSING.md) records where its code came from and the licenses of the
components it uses. By contributing you agree that your contribution is licensed under
the same terms, GPL-3.0-only, and that it does not carry code you may not license that
way: code available only under GPL-2.0-only, for example, cannot be accepted.

Sign off the commits of a pull request with `git commit -s`, and tick the sign-off box in
the pull request; a squash merge drops per-commit trailers, so the box is what remains.
The sign-off certifies the Developer Certificate of Origin below, as published at
https://developercertificate.org/:

```text
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

## Automated review

Claude Code runs on the Claude account of `fzlzjerry`, so only that account wakes
it; events from anyone else, including re-runs, are skipped. A same-repository PR
is reviewed (`.github/workflows/claude-code-review.yml`, inline comments) when
`fzlzjerry` opens it or pushes to it. Any other PR, a fork PR included, gets that
review when `fzlzjerry` adds the `claude-review` label; the review never checks
out or runs the PR's code, and the label is removed afterwards so it can be added
again for new commits. A `@claude` mention by `fzlzjerry` in an issue or a comment
runs `.github/workflows/claude.yml`.

## Automated contributors

Agents working in this repository must follow [AGENTS.md](AGENTS.md) in addition
to everything above; it is the authoritative rule file for ownership, permissions,
verification, build delivery and commits.

By default an agent asks before it commits and builds Release only when you ask.
It never pushes, amends, rebases or rewrites history unless you ask. To give your own
agent more autonomy, add a personal rule in your untracked `CLAUDE.local.md` or
your agent tool's directory; `AGENTS.md` allows exactly two opt-ins, committing
without asking and ending app-code tasks with a Release build. Commits an agent
made are yours: review them before you push.
