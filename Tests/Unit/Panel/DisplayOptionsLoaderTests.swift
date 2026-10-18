import XCTest

@testable import WallpaperMachine

/// Settings › Displays shows each display's own wallpaper's configuration, which the bridge reports
/// only for the one wallpaper the inspector has open. The loader fetches the others while Settings
/// is on screen, once per snapshot, without ever letting an outdated answer be seen.
@MainActor
final class DisplayOptionsLoaderTests: PanelTestCase {
  private func fps(_ options: BridgeWallpaperOptionsSnapshot?) -> UInt32? {
    options?.displayConfigurations.first?.targetFps
  }

  func testOptionsAreOnlyFetchedForVisibleSettings() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.configureDisplays()
    try await panel.start()
    panel.show()
    XCTAssertTrue(panel.bridge.optionRequests.isEmpty, "Installed is on show, not Settings")

    panel.navigation.selection = .settings
    panel.presentation.hide()
    panel.controller.refreshVisibilityGatedWork()
    XCTAssertTrue(panel.bridge.optionRequests.isEmpty, "a hidden panel fetches nothing")

    panel.show()
    await panel.controller.displayOptions.settled()
    XCTAssertEqual(panel.bridge.optionRequests, ["second"], "the open wallpaper's own options are not asked for again")
    XCTAssertEqual(fps(panel.controller.displayOptions.options(for: "second")), 48)
    XCTAssertNil(panel.controller.displayOptions.options(for: "first"))

    panel.hide()
    XCTAssertNil(panel.controller.displayOptions.options(for: "second"), "leaving drops what was read")
    XCTAssertEqual(panel.bridge.optionRequests, ["second"])
  }

  func testAFailureFallsBackWithoutLoopingAndAsksAgainOnReentry() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.configureDisplays()
    try await panel.start()
    panel.bridge.failedOptionIDs = ["second"]
    panel.navigation.selection = .settings
    panel.show()
    await panel.controller.displayOptions.settled()
    try await panel.quiet()
    XCTAssertEqual(panel.bridge.optionRequests, ["second"], "a failure is not retried on its own")
    XCTAssertNil(panel.controller.displayOptions.options(for: "second"), "the row falls back to its saved values")
    panel.controller.refreshVisibilityGatedWork()
    XCTAssertEqual(panel.bridge.optionRequests, ["second"], "the same snapshot is never read twice")

    panel.navigation.selection = .wallpaper
    panel.controller.refreshVisibilityGatedWork()
    panel.bridge.failedOptionIDs = []
    panel.navigation.selection = .settings
    panel.controller.refreshVisibilityGatedWork()
    await panel.controller.displayOptions.settled()
    XCTAssertEqual(panel.bridge.optionRequests, ["second", "second"])
    XCTAssertEqual(fps(panel.controller.displayOptions.options(for: "second")), 48)
  }

  func testACancelledReadCannotOverwriteANewRevisionOrAResurrectedDisplay() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.configureDisplays()
    try await panel.start()
    let stale = try XCTUnwrap(panel.bridge.options["second"])
    panel.bridge.holdOptions = true
    panel.navigation.selection = .settings
    panel.show()
    try await panel.waitUntil { panel.bridge.pendingOptions.count == 1 }

    // Leave and come back while the first read is parked: a second read starts.
    panel.hide()
    panel.navigation.selection = .wallpaper
    panel.controller.refreshVisibilityGatedWork()
    panel.navigation.selection = .settings
    panel.show()
    try await panel.waitUntil { panel.bridge.pendingOptions.count == 2 }
    panel.bridge.finishOption(stale)
    try await panel.quiet()
    XCTAssertEqual(panel.bridge.optionRequests, ["second", "second"])
    XCTAssertNil(panel.controller.displayOptions.options(for: "second"), "the cancelled read's answer is dropped")

    // A new snapshot moves the second display to another wallpaper: the parked read is outdated.
    panel.store.monitorInformationSnapshot.rows[1].wallpaperId = "replacement"
    panel.store.snapshotRevision &+= 1
    panel.controller.refreshVisibilityGatedWork()
    try await panel.waitUntil { panel.bridge.optionRequests.last == "replacement" }
    panel.bridge.finishOption(stale)
    try await panel.quiet()
    XCTAssertNil(panel.controller.displayOptions.options(for: "second"))
    XCTAssertNil(panel.controller.displayOptions.options(for: "replacement"), "the older reply does not stand in for the new read")

    // The display is gone: nothing is asked for and the last parked reply is dropped.
    panel.store.monitorInformationSnapshot.rows.removeLast()
    panel.store.settingsSnapshot.displays.removeLast()
    panel.store.snapshotRevision &+= 1
    panel.controller.refreshVisibilityGatedWork()
    panel.bridge.finishOption(stale)
    try await panel.quiet()
    XCTAssertTrue(panel.controller.displayOptions.options.isEmpty)
    XCTAssertEqual(panel.bridge.optionRequests, ["second", "second", "replacement"])
  }

  func testOptionsReadForAnOlderSnapshotAreNeverShown() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.configureDisplays()
    try await panel.start()
    panel.navigation.selection = .settings
    panel.show()
    await panel.controller.displayOptions.settled()
    XCTAssertNotNil(panel.controller.displayOptions.options(for: "second"))
    panel.store.snapshotRevision &+= 1
    XCTAssertNil(
      panel.controller.displayOptions.options(for: "second"),
      "a row falls back to its saved values until the read for the new snapshot lands")
  }

  func testTheLifecycleObservationStartsTheFetchWhenSettingsOpensAndTheWindowShows() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.configureDisplays()
    try await panel.start()
    panel.navigation.selection = .settings
    panel.presentation.show()
    try await panel.waitUntil { panel.bridge.optionRequests == ["second"] }
    try await panel.waitUntil { panel.controller.displayOptions.options(for: "second") != nil }
  }
}
