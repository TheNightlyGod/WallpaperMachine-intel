# Localization

How the app chooses a language, where each layer's strings live, and the exact
steps for shipping another language. English is the source language; Simplified
Chinese (`zh-Hans`), Traditional Chinese (`zh-Hant`), Japanese (`ja`), Korean
(`ko`) and Brazilian Portuguese (`pt-BR`) are translations. The user-facing behaviour is in
[Control panel → Language](features/control-panel.md#language).

## Which language the app shows

`AppLanguageStore` (`App/Services/Localization/AppLanguage.swift`) holds one
preference under `WallpaperMachine.appLanguage`: `system`, or the tag of a
shipped language. The effective language is

1. the saved tag, when the user chose one in **Settings → General → Language**;
2. otherwise the best match of the user's macOS language list against
   `AppLanguage.supported`, using `Bundle.preferredLocalizations(from:forPreferences:)`
   so the rules are the ones macOS applies to the bundle (`zh-CN`, `zh`,
   `zh-Hans-TW` → `zh-Hans`; `zh-TW`, `zh-HK`, `zh-Hant` → `zh-Hant`; `ja-JP` → `ja`;
   `ko-KR` → `ko`; `pt`, `pt-BR`, `pt-PT` → `pt-BR`; `en-GB`, `fr`, `es` → English).

The macOS list is read from the global defaults domain, not from
`Locale.preferredLanguages`, because the store also writes the user's choice into
the app-domain `AppleLanguages` override (and removes it on **System**). That
override is what makes `String(localized:)` — menus, alerts, notifications —
follow the choice on the next launch; the panel does not need it.

The **Import → Choose wallpapers** picker follows the effective language immediately,
including a choice made in the welcome guide. `WallpaperImportPicker` keeps its
attached sheet when the bundle's launch language already matches. Otherwise it
launches the same executable in `WallpaperImportPickerHelper` mode
(`--wallpaper-import-picker`) with a volatile `-AppleLanguages` argument, so the
title, instructions and system file-browser controls resolve in a fresh process.
The helper runs before `AppDelegate`, never starts the renderer or library
services, and returns the selected URLs to the parent as JSON. Other native
dialogs and menus change after quit/reopen.

The app's languages other than English are also the ones a Steam Workshop search is
read in, so it can be sent to Steam in English, translated on this Mac
(`WorkshopSearchLanguage.candidates(app:)`; Portuguese only while the app is in
Portuguese). That translation is the system's Translation framework, never a catalog,
and only text the person typed goes through it; how it works:
[Searching in another language](features/workshop-downloads.md#searching-in-another-language).

## Layers

| Layer | Strings | Mechanism |
| --- | --- | --- |
| Control panel (`App/Views/ControlPanel/`) | `App/Resources/Localizable.xcstrings` | Follows the effective language live, without a relaunch ([below](#the-panels-live-language)) |
| Native AppKit (menus, alerts, preview and sign-in windows); the update window is SwiftUI and follows the panel's live language | `App/Resources/Localizable.xcstrings` | `String(localized:)`; the bundle resolves at launch from the `AppleLanguages` override above |
| Info.plist usage text | `App/Resources/InfoPlist.xcstrings` | Compiled into each language's `InfoPlist.strings`; macOS reads the localized permission explanation in the app's launch language, with `Info.plist` providing the English fallback |
| Import file picker | `App/Resources/Localizable.xcstrings` plus macOS's native file-browser strings | Same-language sheet, or a short-lived helper whose launch language is the current effective app language |
| Lock-screen extension (`Extension/`) | `Extension/Localizable.xcstrings` | `String(localized:)` against the extension's own bundle, which follows the macOS language list; literals reach it through `WallpaperRuntime.failure(_:)`, and text that is already final (the renderer's own errors) goes through `failure(detail:)` |
| Language picker | `AppLanguage.supported` | Each language is listed under its own name, untranslated, so it can be found from any interface language |

Keys are the English source strings; a key without a translation renders as
English. Arguments are format specifiers (`%@` for text, `%lld` for an integer),
numbered (`%1$@`, `%2$lld`) in a translation that reorders them, and a literal
`%` is written `%%` wherever the string is read as a format.

Steam session warnings describe unavailable reusable authentication information or
failure to update retained authentication state; they do not turn a successful sign-in
into a failed download. The update warning interpolates one opaque error description
as text, including any percent signs it contains. Both warnings ship in every shipped language.

## The panel's live language

`Bundle.main` keeps the language the process launched in, so the panel resolves
its strings itself. `PanelLocale` (`App/Views/ControlPanel/Localization/`)
follows `AppLanguageStore`: `ControlPanelView` binds `PanelLocale.shared` to the
controller's store, and a change of the choice, or of the macOS list while the
choice is **System**, bumps an observable revision. From it `PanelLocale` gives

- `locale`: the effective language with the Mac's own region, so a Japanese
  interface still groups digits and orders dates the way the region setting does.
  The root's `.panelTheme(theme:locale:)` puts it in `\.locale`, and SwiftUI looks
  every `LocalizedStringKey` up in that language: `Text("…")`, `Button("…")`,
  `Toggle`, `Label`, `Section`, `Picker` and `Menu` literals re-render in place the
  moment the language changes, the first-run guide included. A sheet or popover opens
  in its own AppKit window, which carries the launch language instead of the root's
  `\.locale`, so its content takes `.panelPresentationLocale()` (the download and
  SteamCMD dialog, the support prompt, the Downloads, Import, Recently used, Now
  Playing and desktop-chooser popovers); a new sheet or popover with literals needs it too;
- `string(_:)`, which the global `L("…")` calls: the phrase from the language's own
  `<tag>.lproj` folder in the app bundle, for APIs that take a `String` (`.help`,
  `.navigationTitle`, `TextField` prompts, accessibility labels, alert text) and
  for strings the controller hands to views. It reads the revision, so a view that
  calls it re-renders too;
- `catalogString(_:)`: the translation of a phrase known only at run time (an
  author's combo label, the words of a Wallpaper Engine token, a Steam prompt, a
  release-note heading), never read as a format, so a `%` in it stays a `%`.

A literal that does not match its key exactly, arguments included, finds no
entry and renders English: `"\(count) wallpapers"` with an `Int` is the key
`%lld wallpapers`, with a `String` it is `%@ wallpapers`, and a ternary of two
literals is a `String`, not a key. Untrusted text (titles, names, errors) is
`Text(verbatim:)` and never looked up. The panel's confirmation sheets take their
title, message and action button from `L()`, but the **Cancel** button
`AppKitPanelDialogs` adds keeps `String(localized:)`, and the system's save and open
panels (all but the import picker) keep the launch language.

**Settings → General → Language** calls `PanelController.setLanguage`, which
refuses a tag the app does not ship.

The effective language also reaches the bridge, because a wallpaper can carry
its own label translations (`general.localization`) and the bridge resolves them
when it builds the property snapshot. `AppLanguage.wallpaperEngineLocale` names
the table's language code (`en-us`, `zh-chs`, `zh-cht`, `ja-jp`, `ko-kr`, `pt-br`) and
`labelLocales` lists it followed by `en-us`. `BridgeStore.setLabelLanguageAsync`
sends the list through `setLabelLanguages`, once before the library loads
(`AppDelegate`) and again from `PanelController.setLanguage`; it then re-reads
the open wallpaper's options so the inspector relabels in place. The list is
transient bridge state, never persisted, and these are the only two places that
change the effective language in production; a new path that did would have to
call `setLabelLanguageAsync` too. A failure to send it is logged and never fails
the language change.

What is never translated: identifiers, option values, paths, tags sent
to Steam, wallpaper titles, descriptions, creator names, custom property labels,
image filter names derived from LUT file names (`InspectorOptions.imageFilterLabel`)
and upstream diagnostic text. The exception to custom property labels is the
text a wallpaper translates itself: a label or choice that is exactly a token in
its own `general.localization` table follows the app language, falling back to
that table's English and then to the author's string. A built-in `ui_` token that no
table resolves is shown as English words derived from it (`ui_editor_effect_opacity_title`
becomes Opacity), translated only when the same phrase is a catalog key; the rest stay
English in the other languages. The curated phrases in
`PropertyLabels.curatedPhrases` reach the catalog through `catalogString(_:)`, so each
one needs an entry in every catalog, which `PanelPropertyRowsTests` checks. Two labels
are ours rather than the author's and
are translated: the Wallpaper Engine editor's own token for the scheme colour it
adds to every scene, and the **Unnamed option** stand-in for a control whose
label was pure decoration. The property labels the app itself writes into the
wallpapers it saves from pixiv (Image fit, its options and Background color) are
translated too, and only on wallpapers whose id starts with `pixiv-` or
`image-` (pictures imported from disk carry the same two properties); pixiv's
titles, tags and names never are.

## Keeping the catalogs in sync

Command-line builds never update either `Localizable.xcstrings`, and nothing fails when
a key the code uses is missing: a `String(localized:)`, `Text("…")` or `L("…")`
whose key is not in the catalog renders English, and a key no code uses stays in
the catalog forever. Pass user-facing text as a literal to `String(localized:)`,
to a view that takes a `LocalizedStringKey`, or through a
`String.LocalizationValue` parameter (as `L()` and `AppDelegate.menuItem` do), so
the compiler can see it; a runtime `NSLocalizedString(variable, …)` is invisible
to extraction.

`scripts/tests/test_localization_catalogs.py` runs in the Python stage of
`python3 scripts/test.py` and guards the catalogs themselves: `AppLanguage.supported`
starts with English and lists each language once; each of the two catalogs ships
exactly the registered languages; every key is translated, in the `translated`
state, into every one of them; no key is duplicated and no value blank; a
translation takes the same arguments as its key, never mixes numbered and plain
arguments, and escapes `%` exactly where the string is a format; no `{name}`
placeholder remains. It cannot see which keys the code uses.

`scripts/tests/test_panel_localization.py` runs in the same stage and covers the
control panel's side: it reads the first unlabelled string literal of every `L(…)`,
`Text(…)`, `Button(…)`, `Label(…)`, `Toggle(…)`, `Section(…)`, `Picker(…)`,
`Menu(…)`, `TextField(…)`, `SecureField(…)`, `Link(…)` and `LabeledContent(…)` call
under `App/Views/ControlPanel/`, turns each interpolation into a format argument
(`%lld`, `%@`, …), and fails when no catalog key matches the literal or a shipped
language lacks that key. Text that reaches a view through a variable or a `String`
parameter, and keys no code uses, are still for the extraction diff below.

To compare the catalogs with what the code actually uses, build once with
extraction on and diff the keys in the resulting `*.stringsdata` files
(`tables → Localizable → key`) against the catalog of the same target:
`WallpaperMachine.build` for `App/Resources/Localizable.xcstrings`,
`WallpaperMachineExtension.build` for `Extension/Localizable.xcstrings`.

```sh
xcodebuild -project WallpaperMachine.xcodeproj -scheme WallpaperMachine \
  -configuration Debug -derivedDataPath build SWIFT_EMIT_LOC_STRINGS=YES build
find build/Build/Intermediates.noindex/WallpaperMachine.build/Debug \
  -path '*WallpaperMachine*.build/Objects-normal/*' -name '*.stringsdata'
```

Hosted unit tests run in the app's preferences domain, so they see the
developer's own language choice. Panel tests pin the language (the panel test
fixtures use English, and render tests pass a store for the language they draw);
a test that checks a native localized message compares it with
`String(localized:)`, never with the English text.

`AppPermissionLocalizationTests` reads the built app's `InfoPlist.strings` for
every shipped language, without requesting permissions. It checks that location,
Apple Events and audio-capture explanations are present, that translations do not
fall back to English, and that the English resources agree with `Info.plist`.

Add a translated entry for every missing key and delete the keys nothing
extracts. The catalog mixes Xcode's expanded layout with one-line entries, so
edit it as text rather than re-serialising the JSON.

## Contributing translations

Community translations and corrections are welcome in the
[Wallpaper Machine project on Crowdin](https://translate.wallpapermachine.app/project/wallpaper-machine)
(`translate.wallpapermachine.app` is the project's own address on Crowdin). With a free
Crowdin account, pick a language and translate: the project is public and anyone can join
any of its languages without waiting for approval. The shipped languages' translations are
approved, so a suggestion there replaces the shipped wording once a proofreader approves it;
the daily [sync](#crowdin)'s pull request then carries it into the catalogs, and it ships in
the next release.

- **Correcting a shipped language** is a suggestion on the string in Crowdin; the comments
  there are the place to ask about context or discuss wording.
- **A new language** is translated on Crowdin first. When it is not in the project's list,
  ask for it in a [feature request](https://github.com/WallpaperMachine/WallpaperMachine/issues/new?template=feature_request.yml)
  or a Crowdin comment; a maintainer adds it. The app ships it once every string is
  translated: a maintainer then [adds the language](#adding-a-language) to the catalogs.
- **Proofreaders** approve other people's suggestions. A regular translator of a language can
  ask to become its proofreader in a GitHub issue or on Crowdin.

A pull request that edits an existing translation in the catalogs directly is
also fine, with one caveat: once it merges, `push` hands the new wording to Crowdin, where
an approved translation of that string outranks it, so a maintainer then runs
`python3 scripts/crowdin_sync.py push --overwrite` ([below](#crowdin)) or the next pull puts
the approved wording back. For a new string, the author's translations in the pull request
are what Crowdin starts from.

In a catalog, keep the English keys and format arguments intact and leave each completed
unit in the `translated` state. Include the English key and the screen or context when
reporting a wording problem in an issue. No local patch is needed once the change
ships in an official release; updating the app keeps the selected language.

Run `python3 scripts/tests/test_localization_catalogs.py` and
`python3 scripts/tests/test_panel_localization.py` for a quick, Xcode-free coverage
and format check. The full gate below also checks bundled resources and panel
layout. General contribution steps are in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Crowdin

The three catalogs (`App/Resources/Localizable.xcstrings`, `App/Resources/InfoPlist.xcstrings`,
`Extension/Localizable.xcstrings`) are Crowdin source files, configured in `crowdin.yml`
(project `941177`; its source language is English). Crowdin reads each catalog as one
multilingual file, so every shipped language is in it, with Apple's own tags: `zh-Hans`,
`zh-Hant`, `ja`, `ko`, `pt-BR`. The catalogs stay what the app builds from; Crowdin is where
translators work. `scripts/crowdin_sync.py` moves strings both ways and needs the Crowdin CLI
(`npm install -g @crowdin/cli`) signed in with `crowdin login`, or `CROWDIN_PERSONAL_TOKEN`.

The project is public, at `translate.wallpapermachine.app` (a CNAME to Crowdin), with open
language access: anyone signed in can join any of its languages and translate, without task
assignments (Crowdin cannot combine open access with task-based access control). Its target
languages are the shipped ones plus languages being translated for a later release (`ru`).

```sh
python3 scripts/crowdin_sync.py push              # keys, plus translations Crowdin lacks
python3 scripts/crowdin_sync.py push --overwrite  # a maintainer's correction: replace Crowdin's
python3 scripts/crowdin_sync.py pull [--dry-run]  # Crowdin's translations into the catalogs
python3 scripts/crowdin_sync.py add-language <tag> [--dry-run]  # a finished language, into the catalogs
```

- **`push`** sends the English keys and the catalogs' translations as ordinary, unapproved
  translations. A value Crowdin already has is not added again, so pushing an unchanged
  catalog changes nothing, and an approved translation is never replaced; a value Crowdin
  has not seen becomes its newest translation. `--overwrite` approves the catalogs'
  translations instead, so Crowdin takes the repository's wording wherever the two differ.
  That discards every Crowdin edit not pulled yet: run `pull --dry-run` first and overwrite
  only when it lists nothing but the correction being pushed.
- **What ships.** An export carries a string's approved translation when it has one, and
  its newest translation otherwise. While nothing in the project is approved, a
  translator's suggestion therefore reaches the next pull; once the translations are
  approved (the first `push --overwrite` does that for the catalogs' baseline, or
  proofreaders do it in Crowdin), only translations somebody approved reach it.
- **`pull`** rewrites the `value` of a translation that is already in a catalog, for the
  languages `AppLanguage.supported` registers, when Crowdin has it translated (an
  untranslated unit comes back in the `new` state with the English text and is skipped) and
  it passes the same format rules as the catalog test (same arguments, `%` escaped
  exactly where the string is a format; a refused translation is reported and the catalog's
  kept). The catalog is edited in place, so its mixed one-line layout and every other byte
  stay; a pull's diff is the real changes. Keys come from the repository: a key Crowdin has
  and a catalog lacks is not added, and a language the app does not ship is ignored until it
  is [added](#adding-a-language).
- **`add-language <tag>`** writes a language the app does not ship yet into every catalog, from
  Crowdin's export, as the first step of [adding a language](#adding-a-language). It writes all
  or nothing: while any string lacks a translation that passes the format rules, it lists
  them and changes no catalog, so `--dry-run` doubles as the "is it finished?" check. Each
  new unit goes first in its key's `localizations`, inline or on its own line to match the
  entry, so the diff is those lines and nothing else.
- **The loop.** `.github/workflows/crowdin.yml` runs `push` when a push to `main` changes a
  catalog, and `pull` every day (or from Actions → Crowdin → Run workflow): it checks the
  catalogs with `test_localization_catalogs.py` and opens a pull request on `l10n/crowdin`
  titled `chore(localization): update translations from Crowdin`. It needs the repository
  secret `CROWDIN_PERSONAL_TOKEN` (a Crowdin personal access token with read and write on
  the Projects scope). A pull request opened by that token starts no Checks run: close and
  reopen it. Without Settings → Actions → General → "Allow GitHub Actions to create and
  approve pull requests" the job pushes the branch and prints its compare link instead.

`scripts/tests/test_crowdin_sync.py` covers the in-place edit, the format guard and the
commands the script issues; nothing in it reaches Crowdin. A new string still ships in the
pull request that adds it, translated into every registered language, as
[above](#keeping-the-catalogs-in-sync); `push` then hands those translations to Crowdin
for proofreading.

## Adding a language

Use the BCP 47 tag Xcode uses for the locale (`zh-Hant`, `ja`, `de`, `pt-BR`…).
`scripts/tests/test_localization_catalogs.py` fails until the registry and the
catalogs agree.

1. **Catalogs.** A community language is translated on [Crowdin](#crowdin): add it to the
   project's target languages (Settings → Languages; use the one whose export tag is the
   catalog's tag, which Crowdin maps for `zh-Hans`, `zh-Hant`, `ja`, `ko`, `pt-BR` and `ru`),
   and once every string is translated and proofread run
   `python3 scripts/crowdin_sync.py add-language <tag>`, which writes it into all three
   catalogs. A language translated in the repository instead is added in Xcode to
   `App/Resources/Localizable.xcstrings`, `App/Resources/InfoPlist.xcstrings` and
   `Extension/Localizable.xcstrings`, every key translated, then handed to Crowdin with
   `python3 scripts/crowdin_sync.py push`. Either way each unit must end in the `translated`
   state. Xcode compiles each catalog into a `<tag>.lproj` folder, which is what `PanelLocale`
   reads. Run `xcodegen generate` to refresh the generated project's known regions from the
   catalogs; no `project.yml` edit is needed. `pull` only touches registered languages.
2. **Registry.** Append
   `AppLanguage(tag: "<tag>", name: "<own name>", wallpaperEngineLocale: "<code>")`
   to `AppLanguage.supported`. The locale is the Wallpaper Engine code that
   wallpapers use for the language in their own label tables (`zh-chs`, `ja-jp`,
   `ko-kr`…); it is required so a language cannot ship without it, and
   `AppLanguageTests` checks that the codes are distinct and well formed. The
   Settings picker and the first-run guide's picker derive from this list. Extend
   the system-language matching cases and locale-map expectations in
   `AppLanguageTests`, and add the language's two offscreen layout cases to
   `SettingsBRenderTests` and its coverage set; the other per-language checks
   derive from the registry.
3. **Verify.** `python3 scripts/test.py`. The Python check confirms the registry,
   the translations and their arguments; the hosted tests resolve phrases from the
   new language's own bundle (`PanelLocaleTests`), switch the panel live and offer
   every shipped language in the picker (`AppearanceSettingsTests`), check that the
   Settings rows and the controller's words are translated
   (`SettingsSectionsLocalizationTests`) and lay out every page in every language.
4. **Release notes.** The changelog has its own translation contract, separate
   from the catalogs: English, Simplified Chinese and, from 1.5.7, Korean. To add
   another notes language, update the model schema and validation in
   `scripts/release_notes.py`, `AppReleaseHistory` and the update window's language choice, and
   their tests together. Keep tagged historical sections unchanged and define an
   explicit English fallback for releases without that translation. See
   [release notes](release.md#release-notes-and-the-changelog).
5. **Document.** Add the language to
   [Control panel → Language](features/control-panel.md#language) and to the
   language list in every README, and record the run with
   `python3 scripts/log_verification.py`.

Adding or changing a string means adding it, in the same change, to the catalog of
each target that shows it, in every language that catalog ships: the app's catalogs for
the app and its panel, `Extension/Localizable.xcstrings` only for text the lock-screen
extension shows. A string only one target shows stays out of the other's catalog. The
Python check fails on a key that is missing a registered language. English needs no
translation: the source string is the fallback.

## Removing a language

Delete its `AppLanguage.supported` entry and the language from every `.xcstrings`
file. A saved preference naming a removed language falls back to **System** on the
next launch. `python3 scripts/crowdin_sync.py pull` ignores a language that is no longer
registered, so it can stay in the [Crowdin](#crowdin) project or be removed there.
