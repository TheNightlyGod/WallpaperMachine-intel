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

The **Import → Choose files** picker follows the effective language immediately,
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
| Native (menus, dialogs, errors) | `App/Resources/Localizable.xcstrings` | `String(localized:)`; the bundle resolves at launch from the `AppleLanguages` override above |
| Info.plist usage text | `App/Resources/InfoPlist.xcstrings` | Excluded from the app target in `project.yml`, because `Info.plist` supplies `NSAudioCaptureUsageDescription` itself; kept complete in every shipped language, which the Python check requires |
| Import file picker | `App/Resources/Localizable.xcstrings` plus macOS's native file-browser strings | Same-language sheet, or a short-lived helper whose launch language is the current effective app language |
| Lock-screen extension (`Extension/`) | `Extension/Localizable.xcstrings` | `String(localized:)` against the extension's own bundle, which follows the macOS language list; literals reach it through `WallpaperRuntime.failure(_:)`, and text that is already final (the renderer's own errors) goes through `failure(detail:)` |
| Web panel (`WebUI/`) | `WebUI/locales/<tag>.js`, one ES module per language, registered in `WebUI/i18n.js` | `t(source, params)` for JavaScript, `data-i18n` / `data-i18n-label` for static markup; `applyStaticText()` refreshes the latter |
| Language picker | `AppLanguage.supported` | Each language is listed under its own name, untranslated, so it can be found from any interface language |

Keys are the English source strings on both sides; a key without a translation
renders as English. `i18n.js` resolves a tag by exact match first, then by
maximized language + script (`Intl.Locale.maximize()`), never across scripts, so
the panel and `AppLanguageStore` agree.

Swift injects `window.__appLanguage` at document start so the first paint is
already localized, and repeats the effective tag in every snapshot as
`state.language.effective`. `panel.js` calls `setLanguage()` from the snapshot;
because every string is translated where it is drawn, a change re-renders the
page in place without a reload. The `languageSetting` action validates the
value against the registry and refreshes the user script so a later reload or
WebContent recovery starts in the same language.

The effective language also reaches the bridge, because a wallpaper can carry
its own label translations (`general.localization`) and the bridge resolves them
when it builds the property snapshot. `AppLanguage.wallpaperEngineLocale` names
the table's language code (`en-us`, `zh-chs`, `zh-cht`, `ja-jp`) and
`labelLocales` lists it followed by `en-us`. `BridgeStore.setLabelLanguageAsync`
sends the list through `setLabelLanguages`, once before the library loads
(`AppDelegate`) and again from the `languageSetting` action, which also re-reads
the open wallpaper's options so the inspector relabels in place. The list is
transient bridge state, never persisted, and these are the only two places that
change the effective language in production; a new path that did would have to
call `setLabelLanguageAsync` too. A failure to send it is logged and never fails
the language change.

What is never translated: action identifiers, option values, paths, tags sent
to Steam, wallpaper titles, descriptions, creator names, custom property labels
and upstream diagnostic text. The exception to custom property labels is the
text a wallpaper translates itself: a label or choice that is exactly a token in
its own `general.localization` table follows the app language, falling back to
that table's English and then to the author's string. A built-in `ui_` token that no
table resolves is shown as English words derived from it (`ui_editor_effect_opacity_title`
becomes Opacity), translated only when the same phrase is a catalog key; the rest stay
English in the other languages. The curated phrases in `enginePropertyLabels`
(`WebUI/panel.js`) reach `t()` through a table lookup, so each one needs an entry in
every catalog, which `test_panel_localization.py` checks. Two labels are ours rather than the author's and
are translated: the Wallpaper Engine editor's own token for the scheme colour it
adds to every scene, and the **Unnamed option** stand-in for a control whose
label was pure decoration. The property labels the app itself writes into the
wallpapers it saves from pixiv (Image fit, its options and Background color) are
translated too, and only on wallpapers whose id starts with `pixiv-` or
`image-` (pictures imported from disk carry the same two properties); pixiv's
titles, tags and names never are.

## Keeping the native catalogs in sync

Command-line builds never update either `Localizable.xcstrings`, and nothing fails when
they drift: a `String(localized:)` whose key is missing renders English, and a
key no code uses stays in the catalog forever. Pass user-facing text as a
literal to `String(localized:)`, or through a `String.LocalizationValue`
parameter (as `AppDelegate.menuItem` does), so the compiler can see it; a
runtime `NSLocalizedString(variable, …)` is invisible to extraction.

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
developer's own language choice. A test that checks a localized message
compares it with `String(localized:)`, never with the English text.

Add a translated entry for every missing key and delete the keys nothing
extracts. The catalog mixes Xcode's expanded layout with one-line entries, so
edit it as text rather than re-serialising the JSON.

## Adding a language

Use the BCP 47 tag Xcode uses for the locale (`zh-Hant`, `ja`, `de`, `pt-BR`…).
Every step is checked by `scripts/tests/test_panel_localization.py`, which runs
in the Python stage of `python3 scripts/test.py` and fails until the three
registries agree and the catalogs are complete.

1. **Native catalogs.** In Xcode, open `App/Resources/Localizable.xcstrings`,
   `App/Resources/InfoPlist.xcstrings` and `Extension/Localizable.xcstrings`,
   add the language and translate every
   key; each unit must end in the `translated` state. The catalogs need no
   project change.
2. **Panel catalog.** Copy `WebUI/locales/zh-Hans.js` to
   `WebUI/locales/<tag>.js` and translate every value. Keep the keys and every
   `{placeholder}` exactly; single-quoted strings, two-space indentation, one
   entry per line. A catalog must contain the same keys as every other catalog.
3. **Panel registry.** In `WebUI/i18n.js`, add
   `import <binding> from './locales/<tag>.js';` and `'<tag>': <binding>,` to
   `catalogs`.
4. **Native registry.** Append
   `AppLanguage(tag: "<tag>", name: "<own name>", wallpaperEngineLocale: "<code>")`
   to `AppLanguage.supported`. The locale is the Wallpaper Engine code that
   wallpapers use for the language in their own label tables (`zh-chs`, `ja-jp`,
   `ko-kr`…); it is required so a language cannot ship without it, and
   `AppLanguageTests` checks that the codes are distinct and well formed. The
   served-file allowlist in `WebPanelAssets` and the Settings picker derive from
   this list; nothing else needs a change.
5. **Verify.** `python3 scripts/test.py`. The Python check confirms the
   registries, key parity and placeholders; the hosted tests load the panel in
   each language offscreen, switch it live through `languageSetting`, and
   confirm the picker offers every shipped language.
6. **Document.** Add the language to
   [Control panel → Language](features/control-panel.md#language) and record the
   run with `python3 scripts/log_verification.py`.

Adding or changing a string in the app means adding it to every catalog in the
same change; the Python check fails on a key present in one catalog and missing
from another. English needs no catalog: the source string is the fallback.

## Removing a language

Delete its `WebUI/locales/<tag>.js`, its `i18n.js` import and registry entry,
its `AppLanguage.supported` entry and the locale from every `.xcstrings` file. A
saved preference naming a removed language falls back to **System** on the next
launch.
