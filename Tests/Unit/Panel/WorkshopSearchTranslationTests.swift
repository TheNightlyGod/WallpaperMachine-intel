import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// A Discover search typed in another language: Steam is searched in English while the field keeps
/// what was typed, the page says so (and that it is searching while the words are translated) and
/// can search the typed words instead, also after the panel is reopened, and Settings › General
/// turns it off, shows which languages are ready, reads them again when they change and downloads
/// only the one picked.
@MainActor
final class WorkshopSearchTranslationTests: MediaPanelTestCase {
  private var backend: FakeTranslation!

  private func makePanel() throws -> DiscoverPanel {
    let backend = FakeTranslation()
    backend.answers = ["猫": "cat", "风景": "landscape"]
    self.backend = backend
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let translator = WorkshopSearchTranslator(
      defaults: defaults, backend: backend, appLanguage: { .english })
    let panel = try makeDiscoverPanel(searchTranslation: translator)
    WorkshopBrowseProtocol.serve(rows())
    return panel
  }

  private func rows() -> [WorkshopBrowseProtocol.Row] {
    (0..<3).map { WorkshopBrowseProtocol.Row(id: String(2_000 + $0), title: "Wallpaper \($0)") }
  }

  private func searchTexts() -> [String] {
    WorkshopBrowseProtocol.requests.compactMap { WorkshopBrowseProtocol.values("searchtext", in: $0) }
  }

  /// Types `text`, lets the pause pass and waits for the tiles.
  private func type(_ text: String, into panel: DiscoverPanel, sleeper: ManualSleeper) async throws {
    WorkshopBrowseProtocol.serve(rows())
    panel.controller.workshopBrowser.edit(text: text)
    await sleeper.waitUntilPending(1)
    sleeper.fireNext()
    try await waitFor { panel.workshop.searchText == text }
    try await loaded(panel)
  }

  private func loaded(_ panel: DiscoverPanel) async throws {
    try await waitFor { panel.workshop.hasLoaded && !panel.workshop.isLoading }
  }

  func testATypedChineseSearchIsSentInEnglishAndCanBeSearchedAsTyped() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure

    try await type("猫", into: panel, sleeper: sleeper)
    XCTAssertEqual(searchTexts(), ["cat"], "Steam is searched in English")
    XCTAssertEqual(model.text, "猫", "the field keeps what was typed")
    XCTAssertEqual(panel.controller.workshopBrowse.lastSearch.text, "猫", "and so does a reopened panel")
    let shown = try XCTUnwrap(panel.controller.workshopBrowse.translation)
    XCTAssertEqual(shown, WorkshopSearchTranslation(original: "猫", english: "cat", language: "zh-Hans"))

    WorkshopBrowseProtocol.serve(rows())
    await model.searchAsTyped(shown).value
    try await loaded(panel)
    XCTAssertEqual(searchTexts(), ["猫"], "Search “猫” instead sends the typed words")
    XCTAssertNil(panel.controller.workshopBrowse.translation)

    WorkshopBrowseProtocol.serve(rows())
    model.choose(sort: .newest)
    try await waitFor { !self.searchTexts().isEmpty }
    try await loaded(panel)
    XCTAssertEqual(searchTexts(), ["猫"], "a sort keeps searching what was typed")

    try await type("风景", into: panel, sleeper: sleeper)
    XCTAssertEqual(searchTexts(), ["landscape"], "another text is translated again")
    XCTAssertEqual(panel.controller.workshopBrowse.translation?.original, "风景")

    // A click on the line of a search that a newer one replaced changes nothing.
    WorkshopBrowseProtocol.serve(rows())
    await model.searchAsTyped(shown).value
    XCTAssertEqual(searchTexts(), [])
    XCTAssertEqual(panel.controller.workshopBrowse.translation?.english, "landscape")

    try await type("猫", into: panel, sleeper: sleeper)
    XCTAssertEqual(searchTexts(), ["cat"], "the text turned down is translated again once another was searched")
    XCTAssertEqual(panel.controller.workshopBrowse.translation, shown, "with its line")
  }

  func testSearchingAsTypedOutlivesTheWindow() async throws {
    let panel = try makePanel()
    let model = panel.controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure
    try await type("猫", into: panel, sleeper: sleeper)
    let shown = try XCTUnwrap(panel.controller.workshopBrowse.translation)
    WorkshopBrowseProtocol.serve(rows())
    await model.searchAsTyped(shown).value
    try await loaded(panel)
    XCTAssertEqual(searchTexts(), ["猫"])
    panel.controller.stop()

    // The window closes and the panel opens again: another controller and translator, with no
    // answers kept, over the app's own Workshop store.
    let reopened = PanelController(
      store: panel.store, navigation: ControlPanelNavigation(selection: .workshop), workshop: panel.workshop,
      pixiv: panel.controller.pixiv, presentation: PanelPresentation(), theme: panel.theme,
      defaults: panel.defaults, dialogs: panel.dialogs, appLanguage: .english(),
      searchTranslation: WorkshopSearchTranslator(
        defaults: panel.defaults, backend: backend, appLanguage: { .english }))
    addTeardownBlock { @MainActor in reopened.stop() }
    let translated = backend.translations.count
    WorkshopBrowseProtocol.serve(rows())
    reopened.workshopBrowser.choose(sort: .newest)
    try await waitFor { !self.searchTexts().isEmpty }
    try await loaded(panel)
    XCTAssertEqual(reopened.workshopBrowser.text, "猫")
    XCTAssertEqual(searchTexts(), ["猫"], "a sort in the reopened panel keeps searching what was typed")
    XCTAssertNil(reopened.workshopBrowse.translation)
    XCTAssertEqual(backend.translations.count, translated, "nothing is translated again")
  }

  func testASearchShowsAsSearchingWhileItIsTranslated() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    let model = controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure
    try await type("猫", into: panel, sleeper: sleeper)
    let counted = controller.workshopTitleSubtitle

    backend.holdsTranslations = true
    WorkshopBrowseProtocol.serve(rows())
    model.edit(text: "风景")
    await sleeper.waitUntilPending(1)
    sleeper.fireNext()
    try await waitFor { self.backend.heldCount == 1 }
    XCTAssertFalse(panel.workshop.isLoading, "Steam is not asked before the English is known")
    let browse = controller.workshopBrowse
    XCTAssertTrue(browse.isLoading)
    XCTAssertEqual(WorkshopSummary.make(browse: browse), .searching)
    XCTAssertEqual(
      WorkshopEmptyState.make(browse: browse, draftText: model.text, filterCount: model.filterCount), .loading)
    XCTAssertEqual(
      controller.workshopTitleSubtitle, browse.source.titleSubtitle(summary: .searching),
      "the window's subtitle is searching too")
    XCTAssertNotEqual(controller.workshopTitleSubtitle, counted, "and drops the previous search's count")

    backend.releaseTranslations()
    try await waitFor { panel.workshop.searchText == "风景" }
    try await loaded(panel)
    XCTAssertEqual(searchTexts(), ["landscape"])
    XCTAssertFalse(controller.workshopBrowse.isLoading)
  }

  func testTheTranslatedSearchLineFitsTheSmallestWindowInEveryLanguage() async throws {
    for language in AppLanguage.supported.map(\.tag) {
      let backend = FakeTranslation()
      backend.answers = ["猫耳の女の子と夜の街並み": "A girl with cat ears and the cityscape at night"]
      let translator = WorkshopSearchTranslator(
        defaults: try TemporaryDefaults.make(for: self).defaults, backend: backend, appLanguage: { .english })
      let panel = try makeDiscoverPanel(language: language, searchTranslation: translator)
      WorkshopBrowseProtocol.serve(rows())
      panel.controller.start()
      panel.presentation.show()
      try await panel.controller.searchWorkshop(
        text: "猫耳の女の子と夜の街並み", sort: .trendingYear, tags: [], excludedTags: [])
      try await loaded(panel)
      for inspector in [false, true] {
        panel.controller.shell.isInspectorShown = inspector
        let size = NSSize(width: 760, height: 560)
        let host = PanelHost(controller: panel.controller)
        host.layout(at: size)
        try await host.settle(0.35)
        host.layout(at: size)
        let drawn = identifiers(in: host.hosting.view)
        XCTAssertTrue(drawn.contains("workshop-search-translation"), "\(language): the line is drawn")
        XCTAssertTrue(drawn.contains("workshop-search-as-typed"), "\(language): with its button")
        let measured = host.hosting.sizeThatFits(in: size)
        XCTAssertEqual(measured.width, size.width, accuracy: 1, "\(language) inspector \(inspector): no wider")
        XCTAssertLessThanOrEqual(measured.height, size.height + 1, "\(language) inspector \(inspector): no taller")
        XCTAssertLessThanOrEqual(host.widestSplitView, size.width + 1, "\(language) inspector \(inspector)")
        host.close()
      }
      panel.controller.stop()
    }
  }

  /// Every accessibility identifier under `view`.
  private func identifiers(in view: NSView) -> Set<String> {
    var found = Set<String>()
    func walk(_ element: Any?, depth: Int) {
      guard depth < 40, let object = element as? NSObject else { return }
      if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
        let identifier = object.value(forKey: "accessibilityIdentifier") as? String, !identifier.isEmpty
      {
        found.insert(identifier)
      }
      if object.responds(to: NSSelectorFromString("accessibilityChildren")),
        let children = object.value(forKey: "accessibilityChildren") as? [Any]
      {
        for child in children { walk(child, depth: depth + 1) }
      }
    }
    walk(view, depth: 0)
    return found
  }

  func testEnglishIsSearchedAsTypedWithNothingToShowBesideIt() async throws {
    let panel = try makePanel()
    let sleeper = ManualSleeper()
    panel.controller.workshopBrowser.sleep = sleeper.closure
    try await type("aurora", into: panel, sleeper: sleeper)
    XCTAssertEqual(searchTexts(), ["aurora"])
    XCTAssertNil(panel.controller.workshopBrowse.translation)
    XCTAssertEqual(backend.questionCount, 0, "English never reaches the translator")
  }

  func testTurnedOffASearchGoesAsTyped() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    let sleeper = ManualSleeper()
    controller.workshopBrowser.sleep = sleeper.closure
    panel.store.snapshotRevision = 1
    await controller.settings.set(.translateWorkshopSearches, to: false)?.value
    XCTAssertFalse(controller.isSwitchOn(.translateWorkshopSearches))

    try await type("猫", into: panel, sleeper: sleeper)
    XCTAssertEqual(searchTexts(), ["猫"])
    XCTAssertNil(controller.workshopBrowse.translation)
    XCTAssertEqual(backend.questionCount, 0, "nothing runs while it is off")
    XCTAssertTrue(controller.searchTranslationSettings.downloadable.isEmpty, "nothing to download while off")
  }

  func testTurnedOffASearchTheWorkshopRunsAgainByItselfGoesAsTyped() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    let sleeper = ManualSleeper()
    controller.workshopBrowser.sleep = sleeper.closure
    try await type("猫", into: panel, sleeper: sleeper)
    XCTAssertEqual(searchTexts(), ["cat"])

    try await controller.setTranslatesWorkshopSearches(false)
    XCTAssertEqual(controller.workshopBrowse.translation?.english, "cat", "the search on show stays as it was")

    WorkshopBrowseProtocol.serve(rows())
    try await controller.openWorkshop(.browse)
    try await waitFor { !self.searchTexts().isEmpty }
    try await loaded(panel)
    XCTAssertEqual(searchTexts(), ["猫"], "the list opened again is searched as typed")
    XCTAssertNil(controller.workshopBrowse.translation, "with no line beside it")
  }

  func testTurnedOffTheLineOnShowStillSearchesTheTypedWords() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    let model = controller.workshopBrowser
    let sleeper = ManualSleeper()
    model.sleep = sleeper.closure
    try await type("猫", into: panel, sleeper: sleeper)
    try await controller.setTranslatesWorkshopSearches(false)
    let shown = try XCTUnwrap(controller.workshopBrowse.translation, "the line on show stays")

    WorkshopBrowseProtocol.serve(rows())
    await model.searchAsTyped(shown).value
    try await loaded(panel)
    XCTAssertEqual(searchTexts(), ["猫"], "Search “猫” instead still sends the typed words")
    XCTAssertNil(controller.workshopBrowse.translation)
  }

  func testResetAllSettingsTurnsTranslationBackOn() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      try await controller.setTranslatesWorkshopSearches(false)
      XCTAssertFalse(controller.isSwitchOn(.translateWorkshopSearches))
      panel.dialogs.confirmAnswer = true
      try await controller.resetAllSettings()
      XCTAssertTrue(controller.isSwitchOn(.translateWorkshopSearches), "on by default")
    }
  }

  func testSettingsShowsTheReadyLanguagesAndDownloadsOnlyThePickedOne() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    backend.installed = ["ja"]
    backend.downloadable = ["zh-Hans", "ko"]
    XCTAssertNil(controller.searchTranslationSettings.downloaded, "unread until Settings shows the row")

    controller.searchTranslation.refreshLanguages()
    try await waitFor { controller.searchTranslationSettings.downloaded != nil }
    var state = controller.searchTranslationSettings
    XCTAssertEqual(state.downloaded?.map(\.tag), ["ja"])
    XCTAssertEqual(state.downloadable.map(\.tag), ["zh-Hans", "ko"], "Traditional Chinese cannot be downloaded here")
    XCTAssertEqual(backend.downloads, [], "reading downloads nothing")

    try await controller.downloadSearchTranslationLanguage("ko")
    XCTAssertEqual(backend.downloads, ["ko"])
    try await waitFor { controller.searchTranslationSettings.downloaded?.count == 2 }
    state = controller.searchTranslationSettings
    XCTAssertEqual(state.downloaded?.map(\.tag), ["ja", "ko"])
    XCTAssertEqual(state.downloadable.map(\.tag), ["zh-Hans"])

    for tag in ["en", "xx", "pt-BR"] {
      do {
        try await controller.downloadSearchTranslationLanguage(tag)
        XCTFail("\(tag) is not a language searches are read in")
      } catch is InvalidControlValue {}
    }
    XCTAssertEqual(backend.downloads, ["ko"])
  }

  /// The row reads the languages when the page shows it, again when Reset all settings turns the
  /// switch back on, and again when the app's language changes which languages it lists.
  func testTheRowReadsTheLanguagesAgainAfterAResetOrAnotherAppLanguage() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      panel.store.snapshotRevision = 1
      panel.translation.installed = ["ja"]
      panel.translation.downloadable = ["zh-Hans", "ko", "pt-BR"]
      try await controller.setTranslatesWorkshopSearches(false)
      controller.settings.select(.general)
      let hosting = NSHostingController(
        rootView: AnyView(
          SettingsPages().environment(controller)
            .panelTheme(theme: controller.theme, locale: PanelLocale.shared)))
      hosting.sizingOptions = []
      let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
      defer {
        window.contentViewController = nil
        window.close()
      }
      /// Lays the page out turn by turn until `condition` holds, or for `turns` turns.
      func draw(turns: Int = 250, until condition: () -> Bool = { false }) async throws {
        for _ in 0..<turns where !condition() {
          window.setContentSize(NSSize(width: 760, height: 560))
          window.layoutIfNeeded()
          hosting.view.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(20))
        }
      }
      try await draw(turns: 10)
      XCTAssertEqual(panel.translation.availabilityQuestions, [], "nothing is read while the switch is off")

      panel.dialogs.confirmAnswer = true
      try await controller.resetAllSettings()
      try await draw { controller.searchTranslationSettings.downloaded != nil }
      var state = controller.searchTranslationSettings
      XCTAssertEqual(state.downloaded?.map(\.tag), ["ja"], "Reset all settings turned it on and read them")
      XCTAssertEqual(state.downloadable.map(\.tag), ["zh-Hans", "ko"])

      try await controller.setLanguage(AppLanguage.named("pt-BR"))
      try await draw { controller.searchTranslationSettings.downloadable.contains { $0.tag == "pt-BR" } }
      state = controller.searchTranslationSettings
      XCTAssertEqual(state.downloadable.map(\.tag), ["zh-Hans", "ko", "pt-BR"], "Portuguese is offered once the app is in it")
      XCTAssertFalse(window.isVisible, "Layout stays offscreen")
    }
  }
}
