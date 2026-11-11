import Foundation

/// Settings › General › **Translate Workshop searches into English** as its row shows it: the
/// switch, which languages are downloaded for translation, and which the Download menu offers.
struct SearchTranslationSettings: Equatable {
  var isEnabled: Bool
  /// The languages downloaded for translation, in the app's order; nil until they were read.
  var downloaded: [AppLanguage]?
  /// The languages the Download menu offers: supported, not yet downloaded. Empty while off.
  var downloadable: [AppLanguage]

  /// - Parameter candidates: The languages searches are read in now; a language read before the
  ///   app's language changed is left out.
  static func make(
    isEnabled: Bool, languages: [WorkshopSearchTranslator.LanguageState]?, candidates: [AppLanguage]
  ) -> SearchTranslationSettings {
    let known = languages?.filter { candidates.contains($0.language) }
    return SearchTranslationSettings(
      isEnabled: isEnabled,
      downloaded: known?.filter { $0.availability == .installed }.map(\.language),
      downloadable: isEnabled
        ? (known ?? []).filter { $0.availability == .downloadable }.map(\.language) : [])
  }

  /// The row's note: which languages are ready, on its own line above `explanation`, the row's
  /// own note. Nil while off or before the languages were read, when the row's note stands alone.
  @MainActor func note(explanation: String, locale: Locale) -> String? {
    guard isEnabled, let downloaded else { return nil }
    let status: String
    if downloaded.isEmpty {
      status = L("No language is downloaded for translation yet, so searches are sent as typed.")
    } else {
      let names = downloaded.map(\.name).formatted(.list(type: .and).locale(locale))
      status = L("Ready for searches typed in \(names).")
    }
    return status + "\n" + explanation
  }
}
