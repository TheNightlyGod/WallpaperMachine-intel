# Agent rules

WallpaperMachine: macOS/arm64; AppKit/SwiftUI, WKWebView panel, Rust/C++ renderer,
sandboxed ExtensionKit lock screen. `CLAUDE.md` must stay a relative symlink to `AGENTS.md`.

## Read on demand

Read only task-relevant sections; keep this file to durable rules and routing.
For any doc over ~300 lines, list its headings with `rg -n '^#' <file>` and read
with offset/limit; never read the whole file. `.ignore` keeps `rg` out of
`docs/archive/`, `docs/testing/archive/`, `App/Bridge/Generated/` and `upstream/`;
use `rg -u` only when those are the target.

- Placement / runtime: [layout](docs/repository-layout.md), [architecture](docs/architecture.md).
- Code / tests / docs: [conventions](docs/conventions.md), [testing](docs/testing/README.md).
- Build / package / versions: [build](docs/build.md), [release](docs/release.md).
- Product / features: [README](README.md), [docs index](docs/README.md).

## Ownership and invariants

- `App/Services/<Domain>/`: domain logic/stores; `App/ViewModels/`: `BridgeStore`
  renderer facade and editor drafts; `App/Views/ControlPanel/`: host, snapshots, actions.
- `WebUI/`: bundled verbatim; ES modules, no npm/bundler. Preserve CSP, escaping and
  message-origin checks; new files need `WebPanelAssets` allowlisting. Network work stays in Swift.
- `Extension/`: sandboxed extension; `Shared/`: only code compiled by both targets,
  extension-API-safe. Tests: `Tests/Unit/<Domain>/` and opt-in `Tests/UI/`.
- `scripts/`: Python CLI; reuse `scripts/lib/` (paths, glyphs, `xcode.py` quiet tool
  runner); tests in `scripts/tests/`.
- `project.yml` owns targets/settings/versions: run `xcodegen generate`, never hand-edit
  `WallpaperMachine.xcodeproj`. Never edit versions by hand: CI bumps them when a
  pushed commit message carries a `release:` line, and that also cuts a release, so
  write one only when the user asks for a release ([release](docs/release.md)).
  Never extend a `CHANGELOG.md` section whose tag exists; unpublished fixes go into
  the next version ([recovery](docs/release.md#recovering-a-failed-release)).
  Regenerate `App/Bridge/Generated/` via `scripts/build.py` after bridge changes;
  never patch generated bindings.
- `upstream/` is vendored renderer code, not app code. Every change requires updating
  `upstream/provenance.json`; preserve notices and [licensing constraints](LICENSING.md).
- Wallpaper/renderer fixes repair the general mechanism (format, shader, scene,
  script, playback): never detect or special-case a wallpaper by workshop ID,
  title, path, hash or a fingerprint of its quirks. Reproduce the failure as a
  general test first; keep existing behavior and the regression areas intact.
  No frame-time, memory or energy cost to paper over a bug (extra passes,
  per-frame CPU work, unbounded caches); if a real trade-off is unavoidable,
  stop and ask.
- Every new user-facing string goes into every shipped catalog in the same change
  (`App/Resources/*.xcstrings`, `Extension/Localizable.xcstrings`, `WebUI/locales/`);
  `README.md` and `README.zh-CN.md` change together ([localization](docs/localization.md)).
- Match surrounding conventions; reuse `ClientPaths`, `AppLog` and dependency injection.
  Unit tests run inside the real app, so `UserDefaults.standard` is the installed app's
  preferences: isolate with `WALLPAPER_MACHINE_HOME` and `TemporaryDefaults`, never a
  plain suite name. Assert behavior, not wording/wiring. Migrate changed APIs
  completely; preserve others' concurrent edits.
- `artifacts/` (evidence) and `build/` (Xcode output) are disposable: never commit them
  or cite them as durable evidence, and keep secrets, private assets, screenshots and
  traces out of Git. Only `scripts/test.py` prunes its own output; everything else stays
  until deleted. Keep a task's ad-hoc output (investigations, probe output, CI downloads,
  drafts) in one `artifacts/<task>/` folder. Before finishing, delete what this task
  left in `artifacts/` (including its renderer/Rust check runs) without asking, and say
  in one line what was removed; keep only output the final reply cites, and name it.
  Never delete another task's output: other agents may be running in parallel. For
  wider cleanup, show `python3 scripts/clean.py --dry-run` and run
  `python3 scripts/clean.py` (keeps built apps) only after the user agrees. `--all`
  deletes the delivered app; `--user-assets`/`--managed-user-assets` delete live user
  wallpaper data (the latter irreversibly): only on explicit request.
- Agent files: commit policy, never state. Team agent rules live only in `AGENTS.md`
  and `docs/`. Agent tool dirs (`.agents/`, `.claude/`, `.commandcode/`, `.conductor/`,
  `.omo/`, `.omp/`, `.pi/`) and `CLAUDE.local.md` are Git-ignored, machine-local state
  and personal rules: never `git add -f` them or link them from tracked docs. Ignore a
  new agent tool's dir in the same change; a shared file inside one follows the
  `.gitignore` recipe and is listed here (none today). Check `git status` for agent
  paths before every commit.

## Permissions

- Skills never outrank the user's scope or these rules and never grant authorization;
  ask questions in chat, not in a browser UI.
- No desktop control, opening windows, screenshots, wallpaper/appearance changes, audio
  hardware, permission prompts, live Steam login or app install/restart without explicit
  authorization. Feature/test approval is not desktop approval. Peekaboo and
  `python3 scripts/test.py --ui` require a requested desktop run, never a completion/release
  gate. [Tool guidance](docs/development-tools.md) includes `python3 scripts/check_dev_tools.py`
  (safe inspection; installation ≠ permission).

## Verify and deliver

- Scale verification to the change ([tiers](docs/testing/README.md#verification-tiers)).
  Iterate with `python3 scripts/test.py --only <TestClass>` for the touched domain, then
  run the routine gate `python3 scripts/test.py` (Python → XcodeGen → native
  unit/integration) **once** at the end; rerun it only if it failed. Add
  `python3 scripts/check_rust.py` for Rust crate changes and
  `python3 scripts/check_renderer.py` for renderer/bridge changes; preserve applicable
  [renderer/download regressions](docs/testing/renderer.md#regression-areas-that-must-stay-covered).
  Docs-only changes: check links, paths and commands; no app build or desktop test.
- `test.py` and `build.py` print only failures and a verdict; the full tool output is in
  the `artifacts/` log they name. Rerun with `--verbose` only when that output is not
  enough to act on. A missing verdict is a blocked gate, not a pass. Report skipped
  asset checks as skipped; the [local corpus](docs/testing/wallpaper-corpus.md) is not
  a passing suite.
- Release builds on request, not by default: build when the user asks to build, deliver,
  install or try it, or when a change cannot be verified any other way. Otherwise finish
  at the gate and say the app was not rebuilt. Build only after the gate passes:
  `python3 scripts/build.py --swift-only --configuration Release` for Swift/WebUI/resources/config
  with current renderer/bindings; `python3 scripts/build.py --configuration Release`
  for renderer/bridge changes or missing outputs.
- Delivered app: `build/Build/Products/Release/WallpaperMachine.app`. Claim delivery
  only after a successful Release build containing the changes; report path and remind
  the user to quit/reopen. Never launch/quit automatically. Failed/blocked builds ≠ delivery.
- Commits: ask before committing unless the developer's local rules opt in. Whoever
  decides, commit only complete work whose gate passed; one commit per purpose
  (`git add -p` when purposes share a file); stage only this task's files and leave
  others' edits unstaged; messages follow
  [conventions](docs/conventions.md#commits-and-pull-requests) (`feat`/`fix`/`perf`
  subjects and bodies feed the user-facing release notes). Pull request titles use the
  same format, because a squash merge can make the title the commit subject. To catch
  up with `origin/main`, rebase unpushed commits onto it (`git pull --rebase`) instead
  of creating a merge commit; never rewrite commits that are already pushed. Never
  push, amend or force unless asked.
- Personal opt-ins: a developer's local rules (`CLAUDE.local.md`, an agent tool dir)
  may enable exactly two things: committing without asking, and ending app-code tasks
  with a Release build. They never relax any other rule here; on conflict, follow
  `AGENTS.md` and say so.
- Update the owning docs in the same change as the behavior; index new/removed documents
  in [docs/README.md](docs/README.md). Bug fixes, refactors and test-only changes get no
  verification-log entry unless the user asks or a documented behavior changed; features
  and cross-domain changes record commands, results, skips and gaps with
  `python3 scripts/log_verification.py --title "…" --line "…"` (about ten lines; never
  read or hand-edit the [verification log](docs/testing/verification-log.md) to append).
  The log is history, not current proof: promote anything durable (known-failing tests,
  recurring traps) into the owning doc. Report shared-workspace blockers and unchecked
  visual behavior explicitly.
