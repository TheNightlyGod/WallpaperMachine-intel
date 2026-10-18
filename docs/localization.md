# Localization

How the app chooses a language, where each layer's strings live, and the exact
steps for shipping another language. English is the source language; Simplified
Chinese (`zh-Hans`), Traditional Chinese (`zh-Hant`) and Japanese (`ja`) are
translations. The user-facing behaviour is in
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
   `en-GB`, `fr` → English).

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

## Layers

| Layer | Strings | Mechanism |
| --- | --- | --- |
| Control panel (`App/Views/ControlPanel/`) | `App/Resources/Localizable.xcstrings` | Follows the effective language live, without a relaunch ([below](#the-panels-live-language)) |
| Native AppKit (menus, alerts, What's New, preview and sign-in windows) | `App/Resources/Localizable.xcstrings` | `String(localized:)`; the bundle resolves at launch from the `AppleLanguages` override above |
| Info.plist usage text | `App/Resources/InfoPlist.xcstrings` | Compiled into each language's `InfoPlist.strings`; macOS reads the localized permission explanation in the app's launch language, with `Info.plist` providing the English fallback |
| Import file picker | `App/Resources/Localizable.xcstrings` plus macOS's native file-browser strings | Same-language sheet, or a short-lived helper whose launch language is the current effective app language |
| Lock-screen extension (`Extension/`) | `Extension/Localizable.xcstrings` | `String(localized:)` against the extension's own bundle, which follows the macOS language list; literals reach it through `WallpaperRuntime.failure(_:)`, and text that is already final (the renderer's own errors) goes through `failure(detail:)` |
| Language picker | `AppLanguage.supported` | Each language is listed under its own name, untranslated, so it can be found from any interface language |

Keys are the English source strings; a key without a translation renders as
English. Arguments are format specifiers (`%@` for text, `%lld` for an integer),
numbered (`%1$@`, `%2$lld`) in a translation that reorders them, and a literal
`%` is written `%%` wherever the string is read as a format.

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
  moment the language changes, the first-run guide included;
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
the table's language code (`en-us`, `zh-chs`, `zh-cht`, `ja-jp`) and
`labelLocales` lists it followed by `en-us`. `BridgeStore.setLabelLanguageAsync`
sends the list through `setLabelLanguages`, once before the library loads
(`AppDelegate`) and again from `PanelController.setLanguage`; it then re-reads
the open wallpaper's options so the inspector relabels in place. The list is
transient bridge state, never persisted, and these are the only two places that
change the effective language in production; a new path that did would have to
call `setLabelLanguageAsync` too. A failure to send it is logged and never fails
the language change.

What is never translated: identifiers, option values, paths, tags sent
to Steam, wallpaper titles, descriptions, creator names, custom property labels
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
starts with English and lists each language once; each of the three catalogs ships
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

## Adding a language

Use the BCP 47 tag Xcode uses for the locale (`zh-Hant`, `ja`, `de`, `pt-BR`…).
`scripts/tests/test_localization_catalogs.py` fails until the registry and the
catalogs agree.

1. **Catalogs.** In Xcode, open `App/Resources/Localizable.xcstrings`,
   `App/Resources/InfoPlist.xcstrings` and `Extension/Localizable.xcstrings`, add
   the language and translate every key, panel strings included; each unit must
   end in the `translated` state. The catalogs need no project change; Xcode
   compiles each into a `<tag>.lproj` folder, which is what `PanelLocale` reads.
2. **Registry.** Append
   `AppLanguage(tag: "<tag>", name: "<own name>", wallpaperEngineLocale: "<code>")`
   to `AppLanguage.supported`. The locale is the Wallpaper Engine code that
   wallpapers use for the language in their own label tables (`zh-chs`, `ja-jp`,
   `ko-kr`…); it is required so a language cannot ship without it, and
   `AppLanguageTests` checks that the codes are distinct and well formed. The
   Settings picker, the first-run guide's picker and the panel's render tests
   derive from this list; nothing else needs a change.
3. **Verify.** `python3 scripts/test.py`. The Python check confirms the registry,
   the translations and their arguments; the hosted tests resolve phrases from the
   new language's own bundle (`PanelLocaleTests`), switch the panel live and offer
   every shipped language in the picker (`AppearanceSettingsTests`), check that the
   Settings rows and the controller's words are translated
   (`SettingsSectionsLocalizationTests`) and lay out every page in every language.
4. **Document.** Add the language to
   [Control panel → Language](features/control-panel.md#language) and to the
   language list in both READMEs, and record the run with
   `python3 scripts/log_verification.py`.

Adding or changing a string in the app means adding it to every catalog in the
same change; the Python check fails on a key that is missing a registered
language. English needs no translation: the source string is the fallback.

## Removing a language

Delete its `AppLanguage.supported` entry and the language from every `.xcstrings`
file. A saved preference naming a removed language falls back to **System** on the
next launch.
