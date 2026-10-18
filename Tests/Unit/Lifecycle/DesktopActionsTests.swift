import XCTest

@testable import WallpaperMachine

/// The tests run inside the app, so nothing they do may reach the developer's desktop: the test
/// bundle's principal class replaces every desktop action before the first test.
@MainActor
final class DesktopActionsTests: XCTestCase {
  func testTheTestBundleTakesTheDesktopAwayBeforeAnyTestRuns() {
    let log = DesktopActionLog.shared
    let opened = log.opened.count
    let revealed = log.revealed.count
    let address = URL(string: "https://github.com/WallpaperMachine/WallpaperMachine/releases")!

    XCTAssertTrue(DesktopActions.current.open(address))
    DesktopActions.current.reveal([FileManager.default.temporaryDirectory])

    XCTAssertEqual(log.opened.count, opened + 1, "An address a test opens is recorded, never shown in the browser")
    XCTAssertEqual(log.opened.last, address)
    XCTAssertEqual(log.revealed.count, revealed + 1, "A reveal is recorded, never shown in Finder")
  }

  /// The update store opens the releases page and reveals downloads through its live workspace
  /// unless a test injects one; even then it must not reach the browser.
  func testTheUpdaterWithItsLiveWorkspaceOpensNothingFromATest() {
    let log = DesktopActionLog.shared
    let opened = log.opened.count
    let store = AppUpdateStore(currentVersion: "1.0.0", client: DisabledAppUpdateClient())
    store.openReleases()
    XCTAssertEqual(log.opened.count, opened + 1)
    XCTAssertEqual(log.opened.last, AppUpdateConfiguration.releasesURL)
  }

  /// The panel's own seams default to the same desktop actions.
  func testThePanelSeamsDefaultToTheReplacedDesktop() throws {
    let log = DesktopActionLog.shared
    let hidden = log.hidden
    let loginItems = log.loginItemsOpened
    let opened = log.opened.count
    let bridge = WallpaperBridge(noPointer: .init())
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = PanelController(
      store: BridgeStore(bridge: bridge), navigation: ControlPanelNavigation(),
      workshop: WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root, defaults: defaults),
      defaults: defaults, appLanguage: .english())
    controller.hideApplication()
    controller.openLoginItemsSettings()
    _ = controller.openSystemURL(root)
    _ = controller.openSupportURL(AppUpdateConfiguration.releasesURL)
    XCTAssertEqual(log.hidden, hidden + 1)
    XCTAssertEqual(log.loginItemsOpened, loginItems + 1)
    XCTAssertEqual(log.opened.count, opened + 2)
  }
}
