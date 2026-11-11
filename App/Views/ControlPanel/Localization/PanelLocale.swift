import Combine
import Foundation
import Observation
import SwiftUI

/// The language the SwiftUI panel renders in, switchable while the app runs.
///
/// `Bundle.main` is fixed at launch, so strings that must follow a language chosen in the
/// panel resolve against that language's own `<tag>.lproj` sub-bundle instead, with the
/// matching `Locale` for number and date formatting. Everything here reads observable state,
/// so a SwiftUI `body` that calls `L()` or `string(_:)` re-renders when the language changes.
/// The root modifier `.panelTheme(theme:locale:)` publishes `locale` for `Text`, `Button` and
/// the other views that localize their own literals.
@MainActor
@Observable
final class PanelLocale {
  /// The panel's language, following `AppLanguageStore.shared`.
  static let shared: PanelLocale = {
    let locale = PanelLocale()
    locale.bind(to: AppLanguageStore.shared)
    return locale
  }()

  /// Bumped whenever the bound store announces a change. The language itself is read from the
  /// store on demand, because `objectWillChange` fires before the new value is stored.
  private var revision = 0
  @ObservationIgnored private var fixed: AppLanguage
  @ObservationIgnored private var store: AppLanguageStore?
  @ObservationIgnored private var subscription: AnyCancellable?
  @ObservationIgnored private let resources: Bundle
  @ObservationIgnored private let region: String?
  @ObservationIgnored private var bundles: [String: Bundle] = [:]
  @ObservationIgnored private var locales: [String: Locale] = [:]

  /// - Parameters:
  ///   - language: The language until `bind(to:)` is called.
  ///   - region: The macOS region whose number and date conventions the panel keeps, whatever
  ///     language the user picks here; the system's by default.
  ///   - resources: The bundle that holds the `<tag>.lproj` folders.
  init(
    language: AppLanguage = .english, region: String? = Locale.current.region?.identifier,
    resources: Bundle = .main
  ) {
    fixed = language
    self.region = region
    self.resources = resources
  }

  /// Follows `store`: the language changes the moment the store's choice does, and the system
  /// language counts while the choice is System. Binding again replaces the earlier store.
  func bind(to store: AppLanguageStore) {
    self.store = store
    subscription = store.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated { self?.revision += 1 }
    }
    revision += 1
  }

  /// The BCP 47 tag of the language in effect, one of `AppLanguage.supported`.
  var tag: String {
    _ = revision
    return (store?.effective ?? fixed).tag
  }

  /// The language with the system region, so a Japanese interface still groups digits and
  /// orders dates the way the Mac's region setting does.
  var locale: Locale {
    let tag = tag
    if let cached = locales[tag] { return cached }
    let made = Locale(identifier: region.map { "\(tag)_\($0)" } ?? tag)
    locales[tag] = made
    return made
  }

  /// The language's own `<tag>.lproj` folder. A language without one, which a shipped build never
  /// has, reads the main bundle's launch language.
  var bundle: Bundle {
    let tag = tag
    if let cached = bundles[tag] { return cached }
    let found = resources.path(forResource: tag, ofType: "lproj").flatMap(Bundle.init(path:))
    bundles[tag] = found ?? resources
    return found ?? resources
  }

  /// A phrase in the panel's language, for the APIs that take a `String`. A key the catalog
  /// does not have comes back as English with its arguments filled in.
  func string(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: bundle, locale: locale)
  }

  /// The translation of an English phrase that is only known at run time (an author's combo label,
  /// a word Wallpaper Engine's token was reduced to, a Steam prompt, a release-note heading).
  /// Returns the phrase itself when the catalog has no entry. The phrase is never read as a
  /// format string, so a `%` in it stays a `%`.
  func catalogString(_ key: String) -> String {
    bundle.localizedString(forKey: key, value: key, table: nil)
  }
}

/// A phrase in the panel's language for the APIs that take a `String`: `.help`, `.navigationTitle`,
/// alert text, `TextField` prompts, accessibility labels and strings a model hands to a view.
/// `Text`, `Button`, `Toggle`, `Label`, `Section`, `Picker` and `Menu` literals localize themselves.
@MainActor
func L(_ value: String.LocalizationValue) -> String {
  PanelLocale.shared.string(value)
}

extension View {
  /// Hands a sheet's or popover's content the panel's language again. Each opens in its own AppKit
  /// window, whose `Text`, `Button` and `Toggle` literals otherwise resolve in the language the app
  /// was launched in rather than the one chosen in the panel since.
  func panelPresentationLocale() -> some View {
    modifier(PanelPresentationLocale())
  }
}

private struct PanelPresentationLocale: ViewModifier {
  func body(content: Content) -> some View {
    content.environment(\.locale, PanelLocale.shared.locale)
  }
}
