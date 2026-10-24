# Conventions

The rules this repository actually follows. Most of them are descriptions of
existing code: when a rule and the surrounding file disagree, match the file and
raise the conflict rather than reformatting someone else's code in passing.

## Repository structure

- Application code goes in `App/`, grouped by role (`Services/<Domain>/`,
  `ViewModels/`, `Views/ControlPanel/`, `Bridge/`, `Logging/`). Lock-screen
  extension code goes in `Extension/`, and only types both targets compile go in
  `Shared/`.
- The control panel is SwiftUI in `App/Views/ControlPanel/`: one folder per area
  (`Shell/`, `Library/`, `Inspector/`, `Discover/`, `Downloads/`, `Pixiv/`,
  `Settings/`, `Welcome/`) beside the shared `Model/`, `Components/`, `Theme/`,
  `Localization/` and `Images/`.
- Third-party sources stay under `ThirdParty/` (the patched `naga` crate, the
  MediaRemote adapter, the scene engine's C libraries). Do not add first-party code
  there, and do not change vendored sources without recording the revision in
  `ThirdParty/provenance.json`.
- Renderer code goes in `Renderer/`: the Rust crates (`Shader/`, `Core/`, `Bridge/`),
  the scene engine (`Engine/`) and the other C++ areas (`Renderer/<Area>/`, never
  under `ThirdParty/`): pure C++17 until a layer needs a platform API, written from
  public specifications rather than copied from another implementation, with its
  tests in `Renderer/<Area>/tests/` registered in `scripts/check_renderer.py`
  (today `Renderer/Media/`, `Renderer/Sound/` and `Renderer/Surface/`, see
  [container-readers.md](container-readers.md), [sound-decoding.md](sound-decoding.md) and
  [scene rendering](features/scene-rendering.md#when-native-metal-cannot-draw-a-scene)).
- Tests go in `Tests/Unit/<Domain>/` (non-interactive) or `Tests/UI/`
  (XCUITest, takes over the desktop).
- Developer commands go in `scripts/`; their shared helpers in `scripts/lib/`;
  their own tests in `scripts/tests/`.
- Everything a run produces is disposable: `artifacts/` for evidence, `build/`
  for Xcode output. Both are Git-ignored.

Adding a new target, source directory, resource or build setting means editing
`project.yml` and regenerating the project. See
[repository-layout.md](repository-layout.md) for the full map.

## Swift

- **One primary type per file, named after it.** `AppLog.swift` declares
  `enum AppLog`, `WorkshopStore.swift` declares `WorkshopStore`. Small supporting
  types (`Report`, `ImportError`, a private helper class) stay nested in or
  beside the type that owns them.
- **Imports first, alphabetically**, one per line: `import AppKit` / `import
  Darwin` / `import Foundation`. Test files open with `import XCTest` followed by
  `@testable import WallpaperMachine`.
- **Indentation follows the file.** Both two and four spaces occur: four dominate
  `App/Services/`, two `Extension/` and `Shared/`, and `Tests/` and the
  control-panel views mix both. Braces are K&R (opening brace on the declaration
  line). Never reindent a file you are only partly changing.
- **Dependency injection through default initializer arguments**, so production
  call sites stay argument-free and tests substitute fakes:
  `init(session: URLSession = .shared)`,
  `init(defaults: UserDefaults = .standard)`,
  `init(processRunner: any SteamCMDProcessRunning = SteamCMDProcessRunner())`,
  `init(currentAppURL: URL = Bundle.main.bundleURL, fileManager: FileManager = .default)`.
  Where the seam needs more than one implementation, declare a `Sendable`
  protocol (`AppUpdateClient`, `SteamCMDProcessRunning`) and inject `any` of it.
  Reaching for a singleton or `Bundle.main` in the middle of a method is what
  makes a type untestable; put it in the initializer default instead.
- **Filesystem and process work belongs in an `actor`** (`WallpaperImportService`,
  `WorkshopDownloader`); observable UI state belongs in a `@MainActor` store
  (`BridgeStore`, `WorkshopStore`, `AppUpdateStore`). Long operations honour
  cancellation with `try Task.checkCancellation()` and clean up staging in
  `defer`.
- **Stateless namespaces are `enum` with `static` members**, not empty structs or
  classes (`AppLog`, `ClientPaths`).
- **Errors are typed values, not strings**: a small struct conforming to
  `LocalizedError`, or a coded issue such as `AppUpdateIssue(code:detail:)`.
  Report failures; never swallow them into a silent no-op.
- **User-facing text is localized** through `App/Resources/Localizable.xcstrings`
  (keys are the English source). AppKit menus, alerts and windows use
  `String(localized:)`, which follows the language fixed at launch. Control-panel
  strings follow the panel's live language instead: views write literals that
  localize themselves (`Text("…")`, `Button("…")`, `Toggle("…")`,
  `Label("…", systemImage:)`, `Section("…")`, `Picker("…")`, `Menu("…")`); APIs
  that take a `String` (`.help`, `.navigationTitle`, `TextField` prompts,
  `.accessibilityLabel`, alert text) and strings a model hands to a view use
  `L("…")`; a phrase known only at run time (an author's combo label, a Steam
  prompt) uses `PanelLocale.shared.catalogString(_:)`. A literal must equal its
  catalog key exactly, interpolations included (`"\(count) wallpapers"` with an
  `Int` is the key `%lld wallpapers`), or it renders English; a ternary of two
  literals is a `String`, not a key. A new string goes into every shipped catalog
  in the same change; a new language follows [localization.md](localization.md)
  and is declared in `AppLanguage.supported`. Translate labels, never identifiers,
  option values, paths or third-party content; write whole phrases with
  placeholders instead of assembling sentences from English fragments. Missing
  keys fall back to their English source. No hardcoded English in new UI strings.
- **Log through `AppLog`** (`trace`/`debug`/`info`/`warn`/`error`), which routes
  into the in-app log view. Do not add `print` to app code.
- **Paths come from `ClientPaths`.** Never hardcode `~/Library/Application
  Support/...`; the `WALLPAPER_MACHINE_HOME` override is what keeps tests off
  the real library.
- **`App/Bridge/Generated/` is build output.** It is written by `uniffi-bindgen`
  during [the build](build.md); hand edits are lost on the next build. Change the
  bridge crate in `Renderer/Bridge/` and regenerate.
- Comments explain a decision that is not visible from the code (why a staging
  directory is a sibling of the library, why an rpath is deleted). `///` doc
  comments state a type's responsibility in one line. No commentary that restates
  the next statement.

## SwiftUI control panel

How the panel runs (controller, actions, observation, window hosting) is in
[architecture.md](architecture.md#control-panel-swiftui). The rules for code in
`App/Views/ControlPanel/`:

- **Typed actions only.** A view never writes to a store and never names an action
  by string. It starts the controller's typed method through
  `controller.launch(key, policy:) { try await controller.action(...) }`, which
  reports a thrown error to the banner and lets the control disable itself while
  `controller.isBusy(key)`; build keys with `PanelActionCoordinator.key(...)`. Use
  `.latestWins` where a newer value must replace one still running (a search, a
  property, a navigation), `.dropDuplicates` otherwise. A new action is an
  `async throws` method in `Model/PanelController+<Group>.swift` that picks its
  disposition with `run(_:slot:...)`; confirmations and file panels go through
  `controller.dialogs`, never a direct `NSAlert` or `NSOpenPanel`.
- **Typed state only.** What a view shows is a typed computed property or a small
  value type with a `make(...)` factory on the controller or an area model, never a
  dictionary. A getter that reads a store which is not `@Observable` reads its
  `controller.revisions` counter first, or its view stops updating.
- **Area views take no arguments.** A page, an inspector or a toolbar item reads
  `@Environment(PanelController.self)`; its state lives in the controller or its area
  model, which outlive a view that SwiftUI rebuilds.
- **One `ForEach` per lazy list.** A `LazyVStack`, `LazyHStack`, `LazyVGrid`,
  `LazyHGrid` or `List` draws its rows through a single `ForEach` over one ordered
  list of stable ids (`DownloadQueue.entries`), never one `ForEach` per state or
  section: an item that moves from one sibling `ForEach` to another under the same id
  keeps the row drawn before, until the view is rebuilt. Build the order and the
  sections in the model; a `ForEach` nested in another one's rows is fine.
  `scripts/tests/test_panel_lazy_lists.py` enforces this.
- **A choice says when something overrides it.** Where another setting or condition
  can change what a choice does (a Reduced quality rule holding frames to 30 under a
  **No limit** slider or a **Keep running** battery mode), every place that shows the
  choice (its Quick Settings module, its full row, the Displays and inspector notes)
  says so while it happens, names the setting that does it and opens that setting's
  page. Never put an effect down to a setting that did not cause it. Work the reading
  out once in the model from what the engine reports (`QualityReport`,
  `FrameRateCeiling`), and test each surface with the overriding setting on.
- **Untrusted text stays text.** Titles, descriptions, author and creator names,
  Steam and pixiv data and error details are `Text(verbatim:)`. An author's property
  label passes through the allowlist parser (`PropertyLabelDocument`) and never
  becomes markup the panel does not draw itself. Every link goes through
  `ExternalLink` and every image through a `PanelImageSource`.
- **Strings** follow the panel's live language ([Swift](#swift), above, and
  [localization.md](localization.md#the-panels-live-language)).
- **Symbols are SF Symbols** (`Image(systemName:)`, `Label(_:systemImage:)`). The
  Settings sections and the Quick Settings tiles draw a white filled symbol on a
  coloured rounded square (`SymbolTile`), as System Settings does. Never copy
  Apple's symbol artwork, or another icon set, into the repository.
- **Colours** come from `\.panelTheme` (`AccentPalette`, `SurfacePalette`) or the
  system's semantic colours; a view never hardcodes a colour value.
- **Accessibility.** Every icon-only control has an accessibility label
  (`L("…")`); an error or a status change is announced; the keyboard paths stay
  (grid arrows, Home and End, Return and Space, the Escape chain, Command-F for the
  page's search); controls the UI tests find carry a stable
  `accessibilityIdentifier`. A composite control in a Settings row is
  `.accessibilityElement(children: .contain)`, or the row's label lands on every
  child.
- **Selectable text** where people copy from it: the error banner, the inspectors,
  the download dialog and the first-run guide. Put `.textSelection(.enabled)` on the
  static text, not on a container, where it can swallow button clicks. The tabs,
  the toolbar, tiles and Settings are not selectable.
- **No per-frame or idle work.** Anything that animates on its own reads
  `\.panelIsVisible` and Reduce Motion and stops when either says so; no timer runs
  while the window is hidden; grids are lazy; nothing walks the library on a
  download tick. A grid tile builds only what it shows: a control hidden with
  `.opacity(0)` still costs its whole view tree in every tile, and scrolling builds
  a row of tiles at every step, so it drops frames (keep it only while an assistive
  technology needs to reach it, as the Installed tile's check and heart do). Model work that only a visible window needs is gated on
  `controller.presentation.isVisible`.
- **Layout in the detail column.** A page or an inspector takes the width it is
  offered: wrap a page's root in a `GeometryReader` that hands its size back, end
  padded flexible content with `.frame(minWidth: 0)`, use `PanelEmptyState` (not
  `ContentUnavailableView`, which asks for about 260 points), and never put
  `.fixedSize(horizontal: false, vertical: true)` on wrapping text there. Any
  minimum width beside the open inspector makes AppKit throw "needing another
  Update Constraints in Window pass" when the window shrinks to its floor; the
  render tests that shrink the window catch it.

## Python scripts

- File names are `snake_case.py`; each starts with `#!/usr/bin/env python3` and a
  one-line module docstring describing what it does.
- Standard library only. No third-party packages, no virtualenv.
- Arguments via `argparse`, usually with `description=__doc__`. Flags are
  `--kebab-case`.
- Define `main()` and end with `raise SystemExit(main())`; `main()` returns an
  exit code (`0`/`1`) rather than calling `sys.exit` from nested helpers. Scripts
  that only orchestrate subprocesses may instead translate
  `subprocess.CalledProcessError` into that process's return code.
- Shared logic goes in `scripts/lib/` — repository paths in `scripts/lib/paths.py`,
  status markers in `scripts/lib/glyphs.py`. Do not recompute the repository root
  or re-derive shared paths in a new script.
- Status output uses `markers()` from `scripts/lib/glyphs.py`
  (`OK`/`WARN`/`MISSING`/`+`, upgraded to Nerd Font glyphs only where they
  render). Do not invent per-script symbols or emoji. See
  [development-tools.md](development-tools.md).
- Every script gets a test in `scripts/tests/` when it contains real logic
  (parsing, version arithmetic, detection rules) rather than only shelling out.
  `python3 scripts/test.py` runs them.

## Tests

Full strategy, commands and evidence policy: [testing/README.md](testing/README.md).
The rules that bind every change:

- Pick the cheapest layer that can observe the behavior: a Swift unit test in
  `Tests/Unit/<Domain>/`, a Python test in `scripts/tests/`, a headless renderer
  check ([testing/renderer.md](testing/renderer.md)), and only then `Tests/UI/`.
- Assert what a consumer observes — returned values, resulting filesystem state,
  emitted errors, ordering and precedence. Never assert wiring, defaults,
  forwarding, mock echoes, or the text of a source file.
- Deterministic and isolated: unique temporary directories, a redirected
  `WALLPAPER_MACHINE_HOME`, a `TemporaryDefaults` suite instead of
  `UserDefaults.standard` (which is the installed app's preferences inside the
  test host), injected fakes instead of the network or the real SteamCMD,
  cleanup in `defer`. A test must pass in the full suite and on its own, in any
  order.
- Routine verification never controls the desktop, captures the screen, opens app
  windows, or changes the user's wallpapers. Desktop runs
  (`python3 scripts/test.py --ui`) happen only when explicitly requested.
- Unit tests run inside the Debug app, which macOS treats as a new app after every
  rebuild: a test never reads or writes under `~/Documents` (this repository, its
  worktrees, `artifacts/`), because each access asks the user for Documents access.
  Fixtures come from the test bundle or a temporary directory; probe output and
  snapshots go to `FileManager.default.temporaryDirectory`. Nothing a test does may
  reach the desktop either: opening an address, revealing in Finder, opening System
  Settings and hiding the app go through `DesktopActions.current`, which the test
  bundle's principal class (`Tests/Unit/Support/TestBundle.swift`) replaces with a
  recorder before any test runs. New code that opens, reveals or hides uses it, never
  `NSWorkspace.shared` or `NSApp.hide` directly.
- Panel tests build the controller with `PanelTestCase.makeController(...)` or
  `withPanel(...)` (temporary home, `TemporaryDefaults`, English, the welcome guide
  already seen) and call the typed actions. Render tests host a view in an unordered
  window from `ControlPanelWindow.make` or an `NSHostingView`, never order it front,
  never set `NSApp.appearance`, and assert model state, sizes or the accessibility
  tree rather than pixels.
- A test that only pins wording, an implementation detail or an incidental
  default must be deleted, not re-pinned to the new text — regardless of who
  wrote it.

## Documentation

- One topic per file. If a second document needs the topic, link to the owner in
  one sentence instead of restating it.
- Files under `docs/` are `lowercase-hyphenated.md`, with exactly one `#` H1.
  Product feature docs go in `docs/features/`, test documents in `docs/testing/`.
- Adding or removing a document means updating [README.md](README.md), the index.
- Ground every statement in the repository: real paths, real flags, real test
  names. Delete a claim you cannot confirm instead of softening it.
- [testing/verification-log.md](testing/verification-log.md) is newest-entry
  first and keeps the ten newest entries. An entry is a heading, optional short
  context and a bullet per command with exit status, counts and skips — about
  ten lines. Never edit a recorded result. `python3 scripts/log_verification.py`
  prepends an entry and moves whatever falls past ten verbatim into
  `testing/archive/`; before it runs, promote anything still true about the
  current tree into the doc that owns it. A durable fact left only in the log
  is a fact nobody will find.
- Never cite a path under `artifacts/` or `build/` as durable evidence: both are
  Git-ignored and are deleted by `python3 scripts/clean.py`. Describe what was
  exercised and what the run showed.
- State what was **not** verified. "Visual behavior unverified; headless checks
  only" is a complete and acceptable result.

## Commits and pull requests

- Conventional-Commit style subjects, as in the existing history:
  `feat(appearance): add light theme, system adaptation and customization`,
  `fix(scene): drive the global camera from the general.zoom animation`,
  `test(probe): add property overrides and synthetic clicks to the probe`,
  `docs(agents): record the new regression coverage and probe controls`,
  `chore(xcodeproj): match xcodegen target order`. Imperative mood, lower case
  after the colon, no trailing period.
- The type is not decoration. `scripts/release_notes.py` hands every commit in a
  release to the release-notes model, which writes the user-facing notes: `feat`,
  `fix`, `perf` and breaking commits arrive with their body, `docs`, `test`,
  `chore`, `ci`, `build`, `style` and `refactor` with their subject only, as internal work to
  leave out. The subject and body are therefore what users end up reading on the
  release page and in the app's What's new card, so write them for users. Without
  `--ai` the same script lists the commits by type instead. See
  [release.md](release.md#release-notes-and-the-changelog).
- Pull request titles follow the same format. Squash-merging a PR with several
  commits makes its title the commit subject, so an untyped title such as
  `Discover fixes and new tabs` reaches the release notes without a type. When a squash body lists several
  changes, write each as `* type(scope): subject` so they are read one by one.
- A version bump is requested with a standalone `release: patch|minor|major|x.y.z`
  line and performed by CI; `chore: bump version to x.y.z` commits are produced
  by the Version workflow, not by hand. A pushed `release:` line also cuts a
  release, so add one only when a release is intended. See [release.md](release.md).
- Things that must change together in one commit:
  - `project.yml` and the regenerated `WallpaperMachine.xcodeproj` (run
    `xcodegen generate`, which any `scripts/build.py` or `scripts/test.py` run
    does for you);
  - a bridge-crate interface change and the regenerated `App/Bridge/Generated`;
  - a behavior change and the documentation that describes that behavior;
  - a new user-facing string and every shipped catalog;
  - `README.md` and `README.zh-CN.md`;
  - a vendored `ThirdParty/` update and `ThirdParty/provenance.json`.
- History stays linear: catch up with `origin/main` by rebasing unpushed commits
  (`git pull --rebase`), not with a `Merge remote-tracking branch` commit. CI commits
  to `main` on its own (version bumps, the Supporter list), so a local `main`
  falls behind often. Commits that are already pushed are never rewritten.
- Never commit `artifacts/`, `build/`, screenshots, traces, wallpaper payloads,
  Steam session data, credentials, or absolute personal paths.

## Definition of done

- [ ] Behavior implemented end to end — no stubs, placeholders or dead flags.
- [ ] Every call site of a changed API migrated; no compatibility shim or unused
      old path left behind.
- [ ] `python3 scripts/test.py` passes, plus any targeted check the change needs
      (`scripts/check_rust.py` for Rust crates, `scripts/check_renderer.py` for
      renderer work).
- [ ] New or changed behavior is covered by a test that would fail without the
      change; tests that no longer defend a contract are deleted.
- [ ] `project.yml` and the generated project agree; generated bindings
      regenerated if the bridge changed.
- [ ] Documentation updated in the file that owns the topic, and
      [README.md](README.md) updated if a document was added.
- [ ] Verification recorded honestly, including what was not verified.
- [ ] No byproducts outside the Git-ignored `artifacts/` and `build/`: `git status`
      shows only the change itself. Whatever the work left in `artifacts/` has been
      listed for the user, who decides whether it is deleted.
