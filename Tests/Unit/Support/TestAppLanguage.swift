import Foundation

@testable import WallpaperMachine

extension AppLanguageStore {
  /// A store pinned to English for tests that read rendered labels.
  ///
  /// `PanelController` falls back to `AppLanguageStore.shared`, which reads the
  /// developer's own app-domain defaults and macOS language list, so a panel test
  /// that leaves the language implicit renders whatever the developer last chose in
  /// the app. Tests that inspect wording pass this store instead; tests that want a
  /// specific language build their own with `systemLanguages`.
  @MainActor
  static func english() -> AppLanguageStore {
    AppLanguageStore(defaults: TemporaryDefaults.makeForCurrentTest().defaults, systemLanguages: ["en"])
  }

  /// The store the shared panel language follows in the test host: English, bound before any test
  /// runs (`TestBundle`) and bound again by every test that changed it. `L()` resolves through
  /// the shared panel language, so following `AppLanguageStore.shared` instead made every wording
  /// assertion fail on a Mac whose copy of the app was last set to another language.
  @MainActor
  static let testHost = english()
}
