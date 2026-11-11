import Foundation

/// Workshop searches typed in another language: searching the words as typed instead of their
/// English, the switch in Settings › General, and downloading a language for translation. The
/// translating itself is `WorkshopSearchTranslator`'s, which `searchWorkshop` asks.
extension PanelController {
  /// **Search “…” instead**: searches `original` as it was typed rather than its English
  /// translation, and keeps it so while the search text stays the same (a sort, a filter, another
  /// list, a reopened panel). Does nothing unless the search text is still `original` and the
  /// search on show, or the one under way, is its translation: a click on a line that a newer
  /// search has replaced changes nothing. The line on show still works once the switch is off,
  /// which drops the translation the store would search with next.
  func searchWorkshopAsTyped(_ original: String) async throws {
    let translations = [workshop.committedQuery?.translation, workshop.searchTranslation]
    guard workshop.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == original,
      translations.contains(where: { $0?.original == original })
    else { return }
    try await run(.immediate) {
      workshop.declinedTranslationText = original
      workshop.searchTranslation = nil
      workshop.search()
    }
  }

  /// `translateWorkshopSearches`: whether a search typed in another language is sent in English.
  /// Applies from the next search; the one on show stays, with its line, while a search the
  /// Workshop runs again by itself (another list, Back, a sign-in) goes as typed once it is off.
  func setTranslatesWorkshopSearches(_ on: Bool) async throws {
    try await run(.immediate) {
      searchTranslation.setEnabled(on)
      if !on { workshop.searchTranslation = nil }
    }
  }

  /// **Download…**: the system's prompt to download the language `tag` names for translating
  /// searches into English. The person can decline it there.
  func downloadSearchTranslationLanguage(_ tag: String) async throws {
    guard let language = AppLanguage.named(tag) else { throw InvalidControlValue() }
    try await run(.immediate) { try await searchTranslation.download(language) }
  }

  /// What Settings › General shows of translating searches.
  var searchTranslationSettings: SearchTranslationSettings {
    _ = revisions.language
    return SearchTranslationSettings.make(
      isEnabled: searchTranslation.isEnabled, languages: searchTranslation.languages,
      candidates: WorkshopSearchLanguage.candidates(app: appLanguage.effective))
  }
}
