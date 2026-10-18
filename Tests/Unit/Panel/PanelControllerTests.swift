import AppKit
import XCTest

@testable import WallpaperMachine

/// What the controller does around its window: what it restores, what it starts and stops, and
/// what it re-reads when the user comes back.
@MainActor
final class PanelControllerTests: PanelTestCase {
  func testItRestoresWhatEarlierWindowsPersistedAndClearsTheLegacyKey() throws {
    let panel = try makeController(welcomeSeen: false)
    XCTAssertFalse(panel.controller.welcomeSeen)
    XCTAssertFalse(panel.controller.dragSelectLearned)
    XCTAssertTrue(panel.controller.favoriteIDs.isEmpty)
    XCTAssertTrue(panel.controller.remembersSession)

    PanelPreferences.markWelcomeSeen(in: panel.defaults)
    PanelPreferences.markDragSelectLearned(in: panel.defaults)
    try PanelPreferences.saveFavorites(["b", "a"], in: panel.defaults)
    panel.defaults.set(480, forKey: PanelPreferences.legacyInspectorWidthKey)

    let reopened = panel.buildController()
    XCTAssertTrue(reopened.welcomeSeen)
    XCTAssertTrue(reopened.dragSelectLearned)
    XCTAssertEqual(reopened.favoriteIDs, ["a", "b"])
    XCTAssertNil(panel.defaults.object(forKey: PanelPreferences.legacyInspectorWidthKey))
    XCTAssertEqual(reopened.hidesAfterActivating, false)
    panel.defaults.set(true, forKey: PanelPreferences.hideAfterActivatingKey)
    XCTAssertTrue(reopened.hidesAfterActivating, "read on demand, never cached")
  }

  func testEveryAreaModelIsCreatedOnceAndOwnedByTheController() throws {
    let panel = try makeController()
    let controller = panel.controller
    XCTAssertTrue(controller.shell === controller.shell)
    XCTAssertTrue(controller.shell.controller === controller)
    XCTAssertTrue(controller.library.controller === controller)
    XCTAssertTrue(controller.inspector.controller === controller)
    XCTAssertTrue(controller.workshopBrowser.controller === controller)
    XCTAssertTrue(controller.downloads.controller === controller)
    XCTAssertTrue(controller.pixivBrowser.controller === controller)
    XCTAssertTrue(controller.settings.controller === controller)
    XCTAssertTrue(controller.displaysSettings.controller === controller)
    XCTAssertTrue(controller.welcome.controller === controller)
    XCTAssertTrue(controller.supportPrompt.controller === controller)
  }

  func testStartWiresTheStoresAndStopUndoesIt() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    XCTAssertFalse(controller.isStarted)
    XCTAssertFalse(panel.workshop.prefetchesNextPage, "nothing is wired before the panel starts")
    XCTAssertFalse(panel.pixiv.prefetchesNextPage)

    try await panel.start()
    XCTAssertTrue(controller.isStarted)
    XCTAssertFalse(controller.isStopped)
    XCTAssertTrue(panel.workshop.prefetchesNextPage)
    XCTAssertNotNil(panel.workshop.onPreviewsAvailable)
    XCTAssertTrue(panel.pixiv.prefetchesNextPage)
    XCTAssertNotNil(panel.pixiv.onThumbnailsAvailable)
    XCTAssertTrue(controller.revisions.isStarted)

    controller.stop()
    XCTAssertFalse(controller.isStarted)
    XCTAssertTrue(controller.isStopped)
    XCTAssertFalse(controller.revisions.isStarted)
    controller.stop()
    XCTAssertTrue(controller.isStopped, "stopping twice is harmless")
  }

  func testTheWindowClosingStopsThePanel() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await panel.start()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    panel.presentation.attach(to: window)
    XCTAssertTrue(panel.controller.isStarted)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    XCTAssertTrue(panel.controller.isStopped)
  }

  func testEnergySamplingRunsOnlyWhileSettingsIsVisible() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let monitor = panel.controller.energyUsage
    try await panel.start()
    panel.show()
    XCTAssertFalse(monitor.isActive, "Installed is on show, not Settings")

    panel.navigation.selection = .settings
    panel.controller.refreshVisibilityGatedWork()
    XCTAssertTrue(monitor.isActive)

    panel.hide()
    XCTAssertFalse(monitor.isActive, "a hidden, minimized or covered panel stops sampling")
    panel.show()
    XCTAssertTrue(monitor.isActive)

    panel.navigation.selection = .wallpaper
    panel.controller.refreshVisibilityGatedWork()
    XCTAssertFalse(monitor.isActive, "leaving Settings stops sampling")

    panel.navigation.selection = .settings
    panel.controller.refreshVisibilityGatedWork()
    XCTAssertTrue(monitor.isActive)
    panel.controller.stop()
    XCTAssertFalse(monitor.isActive, "a closed panel samples nothing")
  }

  func testTheLifecycleObservationFollowsNavigationAndVisibilityByItself() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let monitor = panel.controller.energyUsage
    try await panel.start()
    panel.presentation.show()
    panel.navigation.selection = .settings
    try await panel.waitUntil { monitor.isActive }
    panel.presentation.hide()
    try await panel.waitUntil { !monitor.isActive }
  }

  /// Returning to the panel costs a bridge round trip only while a Login Items note is waiting to
  /// be cleared; a panel with nothing pending does not re-read the bridge on every focus.
  func testReturningToThePanelReadsTheBridgeOnlyWhileAnApprovalIsPending() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await panel.start()
    panel.store.settingsSnapshot.launchAtLoginAvailable = true
    panel.reportFromBridge(panel.store.settingsSnapshot)

    panel.presentation.becomeKey()
    try await panel.quiet()
    XCTAssertEqual(panel.bridge.snapshotReads, 0, "Nothing is waiting for approval")

    var waiting = panel.store.settingsSnapshot
    waiting.launchAtLoginNeedsApproval = true
    panel.store.settingsSnapshot = waiting
    panel.reportFromBridge(waiting)
    panel.presentation.show()
    panel.presentation.resignKey()
    try await panel.quiet()
    XCTAssertEqual(panel.bridge.snapshotReads, 0, "Only becoming key counts as returning to the panel")

    panel.presentation.becomeKey()
    panel.presentation.becomeKey()
    try await panel.waitUntil { panel.bridge.snapshotReads >= 1 }
    try await panel.quiet()
    XCTAssertEqual(panel.bridge.snapshotReads, 1, "Focus changes in a row share the read that is in flight")
  }

  func testReturningToThePanelLooksForSceneAssetsInstalledMeanwhile() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await panel.start()
    XCTAssertFalse(panel.workshop.sceneAssetsReady)
    panel.sceneAssets.available = true
    XCTAssertFalse(panel.workshop.sceneAssetsReady, "nothing re-reads on its own")
    panel.presentation.becomeKey()
    XCTAssertTrue(panel.workshop.sceneAssetsReady)
  }

  func testAClosedPanelNoLongerReactsToTheWindow() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await panel.start()
    panel.controller.stop()
    panel.sceneAssets.available = true
    panel.presentation.becomeKey()
    XCTAssertFalse(panel.workshop.sceneAssetsReady)
  }
}
