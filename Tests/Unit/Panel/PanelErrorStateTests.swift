import XCTest

@testable import WallpaperMachine

/// The error line: what it shows first, what a dismissal hides, and when the same failure may
/// speak again.
@MainActor
final class PanelErrorStateTests: PanelTestCase {
  private struct Failure: LocalizedError {
    let errorDescription: String?
  }

  func testAnActionErrorShowsFirstAndDismissClearsIt() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let errors = panel.controller.errors
    XCTAssertNil(errors.message)

    errors.report(Failure(errorDescription: "Apply failed"))
    XCTAssertEqual(errors.message, "Apply failed")

    panel.store.latestBridgeErrorMessage = "Bridge says no"
    panel.store.latestBridgeErrorRevision = 1
    XCTAssertEqual(errors.message, "Apply failed", "an action's own error outranks the bridge's")

    errors.dismiss()
    XCTAssertNil(errors.message, "Dismiss hides the action error and the bridge error shown behind it")
  }

  func testACancellationIsNotAFailureToShow() throws {
    let panel = try makeController()
    panel.controller.errors.report(CancellationError())
    XCTAssertNil(panel.controller.errors.message)
  }

  func testClearingTheActionErrorLeavesAnUndismissedBridgeErrorShowing() throws {
    let panel = try makeController()
    let errors = panel.controller.errors
    panel.store.latestBridgeErrorMessage = "Renderer unavailable"
    panel.store.latestBridgeErrorRevision = 4
    errors.report(Failure(errorDescription: "Apply failed"))
    errors.clearAction()
    XCTAssertEqual(errors.message, "Renderer unavailable")
  }

  func testABridgeErrorIsDismissedByRevisionSoTheSameWordsReturnWhenTheyHappenAgain() throws {
    let panel = try makeController()
    let errors = panel.controller.errors
    panel.store.latestBridgeErrorMessage = "Renderer unavailable"
    panel.store.latestBridgeErrorRevision = 1
    XCTAssertEqual(errors.message, "Renderer unavailable")

    errors.dismiss()
    XCTAssertNil(errors.message)
    errors.reconcile()
    XCTAssertNil(errors.message, "a dismissal outlives a reconcile while the revision has not moved")

    panel.store.latestBridgeErrorRevision = 2
    XCTAssertEqual(errors.message, "Renderer unavailable", "the same failure again is a newer revision")
  }

  func testDismissingSuppressesLibraryAndDownloadFailuresUntilTheyRecur() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let errors = panel.controller.errors
    // The bridge answers nothing, so reading the library fails.
    try? await panel.store.refreshAllAsync()
    panel.workshop.downloader.installAssets(
      username: "anonymous", executable: panel.root.appendingPathComponent("missing"),
      destination: panel.root.appendingPathComponent("assets"), rememberSession: false,
      onInstalled: {})
    let downloadFailure = try XCTUnwrap(panel.workshop.downloader.errorMessage)
    XCTAssertNotNil(errors.message, "The library failure must surface")
    XCTAssertEqual(errors.downloadMessage, downloadFailure)

    errors.dismiss()
    errors.reconcile()
    XCTAssertNil(errors.message, "A dismissed library failure must stay dismissed")
    XCTAssertNil(errors.downloadMessage)

    // The library recovers: nothing is dismissed any more.
    panel.bridge.snapshot = BridgeSnapshotBundle(
      app: panel.store.appSnapshot, library: panel.store.librarySnapshot,
      wallpaperOptions: nil, monitorInformation: panel.store.monitorInformationSnapshot,
      settings: panel.store.settingsSnapshot)
    try await panel.store.refreshAllAsync()
    errors.reconcile()
    XCTAssertNil(errors.libraryFailureMessage)
    XCTAssertNil(errors.dismissedLibraryError, "the recovery re-arms the dismissal")

    panel.bridge.snapshot = nil
    try? await panel.store.refreshAllAsync()
    errors.reconcile()
    XCTAssertNotNil(errors.message, "A failure that happens again after recovery must surface")
  }

  func testTheControllerRearmsADismissalWhenItsSourceClearsWithoutAnyoneAsking() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await panel.start()
    try? await panel.store.refreshAllAsync()
    XCTAssertNotNil(panel.controller.errors.message)
    panel.controller.errors.dismiss()
    XCTAssertNotNil(panel.controller.errors.dismissedLibraryError)

    panel.bridge.snapshot = BridgeSnapshotBundle(
      app: panel.store.appSnapshot, library: panel.store.librarySnapshot,
      wallpaperOptions: nil, monitorInformation: panel.store.monitorInformationSnapshot,
      settings: panel.store.settingsSnapshot)
    try await panel.store.refreshAllAsync()
    try await panel.waitUntil { panel.controller.errors.dismissedLibraryError == nil }
  }
}
