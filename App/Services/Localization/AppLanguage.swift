import Foundation

/// A localization the app ships, as the Settings language picker offers it.
struct AppLanguage: Equatable, Sendable {
  /// BCP 47 tag; the same tag names the `.xcstrings` locale and the compiled `.lproj` folder.
  let tag: String
  /// The language's own name. It is deliberately not translated so a user can find
  /// their language whatever the interface currently shows.
  let name: String
  /// The Wallpaper Engine locale code a wallpaper's own label table uses for this language.
  /// Required, so a language cannot ship without naming the table it reads.
  let wallpaperEngineLocale: String

  static let english = AppLanguage(tag: "en", name: "English", wallpaperEngineLocale: "en-us")

  /// Every language the app ships, in picker order. Adding one means shipping its
  /// native catalogs first; the steps are in docs/localization.md.
  static let supported: [AppLanguage] = [
    english,
    AppLanguage(tag: "zh-Hans", name: "简体中文", wallpaperEngineLocale: "zh-chs"),
    AppLanguage(tag: "zh-Hant", name: "繁體中文", wallpaperEngineLocale: "zh-cht"),
    AppLanguage(tag: "ja", name: "日本語", wallpaperEngineLocale: "ja-jp"),
    AppLanguage(tag: "ko", name: "한국어", wallpaperEngineLocale: "ko-kr"),
  ]

  /// The locales a wallpaper's label table is read in, most preferred first: this language,
  /// then English, which almost every table carries.
  var labelLocales: [String] {
    let english = Self.english.wallpaperEngineLocale
    return wallpaperEngineLocale == english ? [english] : [wallpaperEngineLocale, english]
  }

  static func named(_ tag: String) -> AppLanguage? {
    supported.first { $0.tag == tag }
  }

  /// The shipped language that best serves a preference list, or English. Uses the
  /// bundle matching rules, so `zh-CN` reaches Simplified Chinese and `zh-TW` Traditional.
  static func match(_ preferences: [String]) -> AppLanguage {
    let tags = supported.map(\.tag)
    let best = Bundle.preferredLocalizations(from: tags, forPreferences: preferences).first
    return best.flatMap(named) ?? english
  }
}

/// The user's language choice for this app: a shipped tag, or `system` to follow macOS.
///
/// The choice reaches the panel at once through the snapshot and the injected user
/// script. Most native strings resolve through `Bundle.main` at launch, so the store
/// mirrors the choice into the app's `AppleLanguages` override for menus and other
/// dialogs on the next launch. Import uses a fresh picker helper when languages differ.
@MainActor
final class AppLanguageStore: ObservableObject {
  static let shared = AppLanguageStore()
  static let defaultsKey = "WallpaperMachine.appLanguage"
  static let appleLanguagesKey = "AppleLanguages"
  static let systemChoice = "system"

  /// `system` or the tag of a shipped language.
  @Published private(set) var preference: String
  private let defaults: UserDefaults
  private let systemLanguages: [String]

  init(
    defaults: UserDefaults = ClientPreferences.defaults,
    systemLanguages: [String] = AppLanguageStore.systemPreferredLanguages()
  ) {
    self.defaults = defaults
    self.systemLanguages = systemLanguages
    let saved = defaults.string(forKey: Self.defaultsKey)
    preference = saved.flatMap { AppLanguage.named($0)?.tag } ?? Self.systemChoice
  }

  /// The language the interface shows right now.
  var effective: AppLanguage {
    AppLanguage.named(preference) ?? AppLanguage.match(systemLanguages)
  }

  var choices: [AppLanguage] { AppLanguage.supported }

  var snapshot: [String: Any] {
    [
      "preference": preference, "effective": effective.tag,
      "options": choices.map { ["id": $0.tag, "name": $0.name] },
    ]
  }

  func set(_ value: String) throws {
    let next: String
    if value == Self.systemChoice {
      next = Self.systemChoice
    } else if let language = AppLanguage.named(value) {
      next = language.tag
    } else {
      throw InvalidControlValue()
    }
    guard next != preference else { return }
    if next == Self.systemChoice {
      defaults.removeObject(forKey: Self.defaultsKey)
      defaults.removeObject(forKey: Self.appleLanguagesKey)
    } else {
      defaults.set(next, forKey: Self.defaultsKey)
      // Foundation reads the app-domain list at launch; the chosen language leads and the
      // user's own order follows so untranslated tables still fall back the way macOS would.
      var languages = [next]
      for tag in systemLanguages where !languages.contains(tag) { languages.append(tag) }
      defaults.set(languages, forKey: Self.appleLanguagesKey)
    }
    preference = next
  }

  /// The user's macOS language list, read from the global domain so the app-domain
  /// override this store writes cannot masquerade as the system choice.
  nonisolated static func systemPreferredLanguages() -> [String] {
    let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
    if let languages = global?[appleLanguagesKey] as? [String], !languages.isEmpty {
      return languages
    }
    return Locale.preferredLanguages
  }
}
