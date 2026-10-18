import XCTest

@testable import WallpaperMachine

/// The base of the Workshop, downloads and pixiv model tests. It pins the panel's language to
/// English, so the phrases the model words with `L()` can be asserted whatever language the Mac that
/// runs the tests is set to, and puts the shared language back afterwards.
@MainActor
class MediaPanelTestCase: PanelTestCase {
  /// For the number formatting a model type takes as an argument.
  let english = Locale(identifier: "en_US")

  override func setUp() async throws {
    try await super.setUp()
    PanelLocale.shared.bind(to: .english())
  }

  override func tearDown() async throws {
    PanelLocale.shared.bind(to: .testHost)
    try await super.tearDown()
  }

  /// `withPanel` over a pixiv of the test's own, for a test whose answers depend on the request
  /// (a page number) more than the fixture's one ranking does.
  func withPanel(
    pixivTransport: any PixivTransport, _ body: (PanelFixture) async throws -> Void
  ) async throws {
    let made = makeStore()
    let panel = try PanelFixture(
      store: made.store, bridge: made.bridge, displayTitles: .renderer, pixivTransport: pixivTransport)
    do {
      try await panel.start()
      try await body(panel)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  /// A controller over its own temporary folder (which is `WALLPAPER_MACHINE_HOME` until the test
  /// ends), defaults and stores, never started and with no window. For the tests that must supply
  /// the Workshop store's Steam themselves (an offline one, a stubbed details endpoint), which
  /// `PanelFixture` does not let them do. pixiv answers nothing.
  struct BrowsingPanel {
    let controller: PanelController
    let workshop: WorkshopStore
    let store: BridgeStore
    let dialogs: RecordingDialogs
    let root: URL
  }

  func makeBrowsingPanel(
    service: WorkshopService, updates: WorkshopUpdateStore? = nil, supportPrompt: SupportPromptStore? = nil
  ) throws -> BrowsingPanel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-browsing-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let workshop = WorkshopStore(
      service: service, downloader: WorkshopDownloadManager(sessionDirectory: root),
      supportDirectory: root, defaults: defaults, updates: updates)
    let pixiv = PixivStore(
      service: PixivService(
        transport: PixivFixtureTransport { _ in throw URLError(.notConnectedToInternet) },
        minimumInterval: .zero),
      packager: PixivWallpaperPackager(library: root.appendingPathComponent("Library")),
      sessions: PixivMemorySessionStore())
    let store = makeStore(supportPrompt: supportPrompt).store
    let dialogs = RecordingDialogs()
    let previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
    let controller = PanelController(
      store: store, navigation: ControlPanelNavigation(), workshop: workshop, pixiv: pixiv,
      defaults: defaults, dialogs: dialogs, appLanguage: .english())
    addTeardownBlock { @MainActor in
      controller.stop()
      workshop.cancelSearch()
      await workshop.downloader.shutdown()
      await workshop.steamCMDSetup.shutdown()
      await pixiv.downloads.shutdown()
      if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) }
      else { unsetenv("WALLPAPER_MACHINE_HOME") }
      try? FileManager.default.removeItem(at: root)
    }
    return BrowsingPanel(
      controller: controller, workshop: workshop, store: store, dialogs: dialogs, root: root)
  }

  /// Waits, in short turns, until `condition` holds or `timeout` seconds pass.
  func waitFor(
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else {
        return XCTFail("Timed out waiting for the condition", file: file, line: line)
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
