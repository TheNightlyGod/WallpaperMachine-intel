import Observation
import XCTest

@testable import WallpaperMachine

/// The shell's actions: navigation and its first-visit loads, what a reopened panel restores, the
/// first-run flags, and the appearance and language choices.
@MainActor
final class PanelShellActionsTests: PanelTestCase {
  private final class Flag: @unchecked Sendable {
    private(set) var raised = false
    func raise() { raised = true }
  }

  // MARK: Navigation

  func testNavigatingSelectsThePageAndLeavesAnOlderBannerShowing() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    controller.errors.report(WallpaperActionError(message: "An older failure"))
    try await controller.navigate(.settings)
    XCTAssertEqual(panel.navigation.selection, .settings)
    try await controller.navigate(.wallpaper)
    XCTAssertEqual(panel.navigation.selection, .wallpaper)
    XCTAssertEqual(controller.errors.actionError, "An older failure", "browsing is not an action that clears")
    controller.dismissError()
    XCTAssertNil(controller.errors.message)
  }

  func testPixivLoadsOnItsFirstVisitOnlyWhileNothingIsLoadedOrLoading() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    XCTAssertFalse(panel.pixiv.hasLoaded)
    try await controller.navigate(.pixiv)
    XCTAssertTrue(panel.pixiv.isLoading, "the first visit asks for the default list")
    try await panel.waitUntil(timeout: 10) { panel.pixiv.hasLoaded }

    try await controller.navigate(.settings)
    try await controller.navigate(.pixiv)
    XCTAssertFalse(panel.pixiv.isLoading, "coming back loads nothing again")
    XCTAssertEqual(panel.navigation.selection, .pixiv)
  }

  func testDiscoverSearchesOnItsFirstVisitOnlyWhileNothingIsLoadedOrLoading() async throws {
    let transport = HoldingSteam()
    defer { transport.invalidate() }
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let workshop = WorkshopStore(
      service: WorkshopService(session: transport.session),
      downloader: WorkshopDownloadManager(sessionDirectory: panel.root.appendingPathComponent("holding")),
      supportDirectory: panel.root, defaults: panel.defaults)
    let controller = PanelController(
      store: panel.store, navigation: panel.navigation, workshop: workshop, pixiv: panel.pixiv,
      presentation: panel.presentation, theme: panel.theme, defaults: panel.defaults,
      dialogs: panel.dialogs, appLanguage: .english(),
      playback: PlaybackPreferences(defaults: panel.defaults), playlists: panel.playlists,
      hotKeys: HotKeyPreferences(defaults: panel.defaults), collections: panel.collections,
      presets: panel.presets, backup: panel.backup, imagePlacement: panel.imagePlacement,
      compatibility: panel.compatibility, automations: panel.automations, spaces: panel.spaces)
    defer { controller.stop() }

    try await controller.navigate(.workshop)
    XCTAssertTrue(workshop.isLoading)
    try await panel.waitUntil(timeout: 5) { transport.requests >= 1 }
    let first = transport.requests
    try await controller.navigate(.settings)
    try await controller.navigate(.workshop)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(transport.requests, first, "a visit while the first search runs starts no second one")
    XCTAssertEqual(panel.navigation.selection, .workshop)
  }

  // MARK: Reopening

  func testTheLastValidReportIsKeptAnInvalidOneIsDroppedSilentlyAndTheReopenedPanelTakesTheOldOne() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    XCTAssertNil(controller.restoredViewState, "a fresh launch starts clean")

    let filters = PanelViewState(
      installed: .init(text: "night", sort: "size", descending: true, tags: [], excludedTags: ["Mature"]),
      scroll: ["installed": 320])
    XCTAssertTrue(controller.storeViewState(filters))
    XCTAssertEqual(panel.navigation.viewState, filters)
    XCTAssertNil(controller.restoredViewState, "this window's own reports are not what it restores")

    var bogus = filters
    bogus.installed.sort = "random"
    var negative = filters
    negative.scroll = ["installed": -5]
    XCTAssertFalse(controller.storeViewState(bogus))
    XCTAssertFalse(controller.storeViewState(negative))
    XCTAssertEqual(panel.navigation.viewState, filters, "only the valid report was kept")
    XCTAssertNil(controller.errors.message, "an invalid report is dropped without a banner")

    // The window closes; the next one finds what the last one left, once.
    let reopened = panel.buildController()
    XCTAssertEqual(reopened.restoredViewState, filters)
    var newer = filters
    newer.installed.text = "newer search"
    reopened.storeViewState(newer)
    XCTAssertEqual(reopened.restoredViewState, filters, "a later report cannot undo what the person did since")
    XCTAssertEqual(panel.navigation.viewState, newer)

    // A window that writes before it reads still restores what it found, not what it wrote.
    let writer = panel.buildController()
    var written = newer
    written.installed.text = "written first"
    writer.storeViewState(written)
    XCTAssertEqual(writer.restoredViewState, newer)
  }

  // MARK: First-run flags

  func testTheFirstRunFlagsPersistInTheInjectedDefaultsAndSurviveAReopen() throws {
    let panel = try makeController(welcomeSeen: false)
    let other = try TemporaryDefaults.make(for: self).defaults
    let controller = panel.controller
    XCTAssertFalse(controller.welcomeSeen)
    XCTAssertFalse(controller.dragSelectLearned)

    controller.markWelcomeSeen()
    controller.markDragSelectLearned()
    XCTAssertTrue(controller.welcomeSeen && controller.dragSelectLearned)
    XCTAssertTrue(PanelPreferences.welcomeSeen(in: panel.defaults))
    XCTAssertTrue(PanelPreferences.dragSelectLearned(in: panel.defaults))
    XCTAssertFalse(PanelPreferences.welcomeSeen(in: other), "no other suite is written")
    let reopened = panel.buildController()
    XCTAssertTrue(reopened.welcomeSeen && reopened.dragSelectLearned)
  }

  // MARK: Appearance

  func testEachAppearanceChoicePersistsAndAnInvalidAccentIsRefused() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try controller.setThemeMode(.dark)
      try controller.setThemeAccent("#B43271")
      try controller.setThemeTone(.warm)
      try controller.setThemeIcon(.night)
      XCTAssertEqual(
        controller.themePreferences,
        AppThemePreferences(mode: .dark, accent: "#b43271", tone: .warm, icon: .night),
        "the accent is stored in lower case")
      XCTAssertEqual(AppThemeStore(defaults: panel.defaults).preferences, controller.themePreferences)

      for refused in ["b43271", "#b4327", "#b43271ff", "#gggggg", "red", ""] {
        do {
          try controller.setThemeAccent(refused)
          XCTFail("\(refused) is not an accent a control offers")
        } catch {
          XCTAssertTrue(error is InvalidControlValue, refused)
        }
      }
      XCTAssertEqual(controller.themePreferences.accent, "#b43271", "a refusal changes nothing")

      controller.resetTheme()
      XCTAssertEqual(controller.themePreferences, AppThemePreferences())
      XCTAssertEqual(controller.themePreferences.mode, .system)
      XCTAssertEqual(controller.themePreferences.accent, "#80bbff")
      XCTAssertEqual(controller.themePreferences.icon, .day)
      XCTAssertNil(panel.defaults.dictionary(forKey: AppThemeStore.defaultsKey), "the stored choice is removed")
    }
  }

  func testAViewThatShowsTheAppearanceIsToldWhenItChanges() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let fired = Flag()
      withObservationTracking(
        { MainActor.assumeIsolated { _ = controller.themePreferences } }, onChange: { fired.raise() })
      try controller.setThemeTone(.cool)
      XCTAssertTrue(fired.raised)
    }
  }

  // MARK: Language

  func testChoosingALanguageSwitchesAtOnceTellsTheBridgeAndSystemReturnsToMacOS() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      XCTAssertNil(controller.languagePreference, "the app follows macOS until a language is chosen")
      XCTAssertEqual(controller.effectiveLanguage.tag, "en")

      let chinese = try XCTUnwrap(AppLanguage.named("zh-Hans"))
      try await controller.setLanguage(chinese)
      XCTAssertEqual(controller.languagePreference, chinese)
      XCTAssertEqual(controller.effectiveLanguage, chinese)
      XCTAssertEqual(panel.bridge.labelLanguageCalls, [chinese.labelLocales])

      try await controller.setLanguage(nil)
      XCTAssertNil(controller.languagePreference)
      XCTAssertEqual(controller.effectiveLanguage.tag, "en", "System returns to the macOS language")
      XCTAssertEqual(panel.bridge.labelLanguageCalls.last, AppLanguage.english.labelLocales)
    }
  }

  func testALanguageTheAppDoesNotShipIsRefusedAndChangesNothing() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let unshipped = AppLanguage(tag: "zh-TW", name: "中文（台灣）", wallpaperEngineLocale: "zh-tw")
      do {
        try await controller.setLanguage(unshipped)
        XCTFail("a language the app does not ship was chosen")
      } catch {
        XCTAssertTrue(error is InvalidControlValue)
      }
      XCTAssertNil(controller.languagePreference)
      XCTAssertEqual(controller.effectiveLanguage.tag, "en")
      XCTAssertTrue(panel.bridge.labelLanguageCalls.isEmpty)
    }
  }

  /// The language chosen in the panel reaches the bridge as that language's Wallpaper Engine label
  /// tables, English after it, and the open inspector's rows are read again in it.
  func testTheOpenWallpapersOptionsAreReadAgainInTheNewLanguageAndAFailureNeverFailsTheSwitch() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      // The bridge relabels from the table the first locale names, as the engine would.
      func options(_ label: String) -> BridgeWallpaperOptionsSnapshot {
        BridgeSnapshotFixtures.options(
          wallpaperId: "w", properties: [BridgeSnapshotFixtures.textProperty(id: "size", labelHtml: label)])
      }
      let labels = ["zh-chs": "大小", "ja-jp": "サイズ", "ko-kr": "크기"]
      panel.bridge.options["w"] = options("Size")
      panel.store.wallpaperOptionsSnapshot = panel.bridge.options["w"]
      panel.bridge.onLabelLanguages = { locales in
        panel.bridge.options["w"] = options(locales.first.flatMap { labels[$0] } ?? "Size")
      }
      let rows = { controller.inspectorOptions(for: "w")?.properties.map(\.label.text) }
      XCTAssertEqual(rows(), ["Size"])

      try await controller.setLanguage(try XCTUnwrap(AppLanguage.named("zh-Hans")))
      XCTAssertEqual(panel.bridge.labelLanguageCalls.last, ["zh-chs", "en-us"])
      XCTAssertEqual(panel.bridge.optionRequests, ["w"], "the open wallpaper is read again")
      XCTAssertEqual(rows(), ["大小"])

      try await controller.setLanguage(try XCTUnwrap(AppLanguage.named("ko")))
      XCTAssertEqual(panel.bridge.labelLanguageCalls.last, ["ko-kr", "en-us"])
      XCTAssertEqual(rows(), ["크기"])

      try await controller.setLanguage(try XCTUnwrap(AppLanguage.named("ja")))
      XCTAssertEqual(panel.bridge.labelLanguageCalls.last, ["ja-jp", "en-us"])
      XCTAssertEqual(rows(), ["サイズ"])

      panel.bridge.failLabelLanguages = true
      try await controller.setLanguage(try XCTUnwrap(AppLanguage.named("zh-Hant")))
      XCTAssertEqual(controller.languagePreference?.tag, "zh-Hant", "the switch has happened whatever the labels did")
      XCTAssertNil(controller.errors.message, "a label failure is logged, not shown")
      XCTAssertEqual(rows(), ["サイズ"], "the rows keep the labels they had")
    }
  }
}

/// A Steam that never answers, so a search stays in flight and the test can count them.
private final class HoldingSteam: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let session: URLSession
  private let identifier = UUID().uuidString

  var requests: Int { lock.withLock { count } }

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HoldingProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Holding-Steam": identifier]
    configuration.urlCache = nil
    session = URLSession(configuration: configuration)
    HoldingProtocol.register(identifier, self)
  }

  func invalidate() {
    session.invalidateAndCancel()
    HoldingProtocol.remove(identifier)
  }

  fileprivate func record() { lock.withLock { count += 1 } }
}

private final class HoldingProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var holders: [String: HoldingSteam] = [:]

  static func register(_ identifier: String, _ holder: HoldingSteam) {
    lock.withLock { holders[identifier] = holder }
  }
  static func remove(_ identifier: String) { _ = lock.withLock { holders.removeValue(forKey: identifier) } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let holder = Self.lock.withLock { Self.holders[request.value(forHTTPHeaderField: "X-Holding-Steam") ?? ""] }
    holder?.record()
  }

  override func stopLoading() {}
}
