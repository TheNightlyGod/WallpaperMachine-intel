import XCTest

@testable import WallpaperMachine

/// Saved playlists: saving a display's playlist under a name, listing, renaming, deleting and
/// applying them.
@MainActor
final class PanelPlanActionsTests: PanelTestCase {
  private func makePanel() throws -> PanelFixture {
    let panel = try makeController()
    panel.store.settingsSnapshot.displays = [
      OrganizationFixtures.display("primary"), OrganizationFixtures.display("secondary"),
      OrganizationFixtures.display("mirrored", mode: .mirror),
    ]
    panel.store.librarySnapshot.wallpapers = ["a", "b"].map { OrganizationFixtures.wallpaper($0) }
    return panel
  }

  func testASavedPlaylistIsANamedCopyOfADisplaysPlaylistThatIsReturned() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.editPlaylist(.mode(.rotate), display: "secondary")
    try await controller.editPlaylist(.order(.shuffle), display: "secondary")
    try await controller.editPlaylist(.interval(.custom(45)), display: "secondary")

    let plan = try await controller.savePlaylistPlan(name: "  Focus  ", display: "secondary")
    XCTAssertEqual(plan.name, "Focus")
    XCTAssertEqual(plan.playlist.mode, .rotate)
    XCTAssertEqual(plan.playlist.order, .shuffle)
    XCTAssertEqual(plan.playlist.interval, 45)
    XCTAssertNil(plan.playlist.planID, "the plan is not a copy of itself")
    XCTAssertEqual(panel.playlists.plan(id: plan.id), plan)
    XCTAssertEqual(controller.playlistPlanRows, [PlaylistPlanRow(id: plan.id, name: "Focus", playlist: plan.playlist, displayCount: 0)])

    let fromTarget = try await controller.savePlaylistPlan(name: "Target display")
    XCTAssertEqual(fromTarget.playlist, DisplayPlaylist(), "no display named: the target display, which is off")
    XCTAssertEqual(controller.playlistPlanRows.map(\.name), ["Focus", "Target display"], "in the order they were saved")

    for name in ["", "   ", String(repeating: "p", count: 129), "two\nlines"] {
      do {
        try await controller.renamePlaylistPlan(plan.id, to: name)
        XCTFail("renamed to \(name.debugDescription)")
      } catch {
        XCTAssertEqual(error.localizedDescription, String(localized: "Enter a name between 1 and 128 characters, on one line."))
      }
    }
    do {
      _ = try await controller.savePlaylistPlan(name: "Mirror", display: "mirrored")
      XCTFail("a mirror has no playlist to save")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
    XCTAssertEqual(controller.playlistPlanRows.count, 2)
  }

  func testRenamingKeepsThePlaylistAndAMissingPlanSaysSo() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let plan = try await controller.savePlaylistPlan(name: "Old")
    try await controller.renamePlaylistPlan(plan.id, to: "New")
    XCTAssertEqual(controller.playlistPlanRows.map(\.name), ["New"])
    XCTAssertEqual(controller.playlistPlanRows.first?.playlist, plan.playlist)
    try await controller.renamePlaylistPlan(plan.id, to: "New")
    for failing in [
      { try await controller.renamePlaylistPlan("gone", to: "x") },
      { try await controller.deletePlaylistPlan("gone") },
      { try await controller.applyPlaylistPlan("gone") },
    ] as [() async throws -> Void] {
      do {
        try await failing()
        XCTFail("a plan that no longer exists")
      } catch {
        XCTAssertEqual(
          error.localizedDescription, String(localized: "This playlist plan no longer exists. Refresh the library and retry."))
      }
    }
  }

  func testApplyingAPlanCopiesItToTheDisplayClearsTheHoldAndMakesATimedRotationDueNow() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.editPlaylist(.mode(.rotate), display: "primary")
    try await controller.editPlaylist(.interval(.preset(60)), display: "primary")
    try await controller.editPlaylist(.order(.shuffle), display: "primary")
    let plan = try await controller.savePlaylistPlan(name: "Hourly", display: "primary")
    try await controller.editPlaylist(.mode(.off), display: "secondary")
    panel.playlists.setHold(.removedWallpaper, on: "secondary")
    var manual: [String] = []
    panel.automations.manualChoice = { manual.append($0) }

    try await controller.applyPlaylistPlan(plan.id, display: "secondary")
    let applied = panel.playlists.playlist(for: "secondary")
    XCTAssertEqual(applied.mode, .rotate)
    XCTAssertEqual(applied.interval, 60)
    XCTAssertEqual(applied.order, .shuffle)
    XCTAssertEqual(applied.planID, plan.id, "the display keeps the link until a setting is edited")
    XCTAssertFalse(controller.playlistState(for: "secondary").isHeld, "choosing a playlist is asking for it to run")
    XCTAssertEqual(panel.playlists.nextChange["secondary"], .distantPast, "a timed rotation is due at once")
    XCTAssertEqual(manual, ["secondary"], "a manual choice for the automatic selection")
    XCTAssertEqual(controller.playlistPlanRows.first?.displayCount, 1)

    do {
      try await controller.applyPlaylistPlan(plan.id, display: "mirrored")
      XCTFail("a mirror has no playlist")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
  }

  func testDeletingACollectionThroughThePanelMakesSavedPlaylistsForgetIt() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let collection = try await controller.createCollection(name: "Night", wallpaperIDs: ["a"])
    try await controller.editPlaylist(.mode(.rotate), display: "primary")
    try await controller.editPlaylist(.collection(id: collection.id), display: "primary")
    let plan = try await controller.savePlaylistPlan(name: "From the collection", display: "primary")
    XCTAssertEqual(plan.playlist.source, .collection)
    try await controller.deleteCollection(collection.id)
    XCTAssertEqual(panel.playlists.plan(id: plan.id)?.playlist.source, .list, "an empty list, never the whole library")
    XCTAssertNil(panel.playlists.plan(id: plan.id)?.playlist.collectionID)
  }

  func testApplyingAPlanWhoseCollectionIsGoneIsRefused() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let collection = try await controller.createCollection(name: "Night", wallpaperIDs: ["a"])
    try await controller.editPlaylist(.mode(.rotate), display: "primary")
    try await controller.editPlaylist(.collection(id: collection.id), display: "primary")
    let plan = try await controller.savePlaylistPlan(name: "From the collection", display: "primary")
    // Removed behind the panel's back, so the plan still names it.
    try panel.collections.delete(collection.id)
    do {
      try await controller.applyPlaylistPlan(plan.id, display: "secondary")
      XCTFail("a rotation over a collection that is gone plays nothing")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, String(localized: "This collection no longer exists. Refresh the library and retry."))
    }
    XCTAssertEqual(panel.playlists.playlist(for: "secondary"), DisplayPlaylist())
  }

  func testEditingADisplaysCopyDetachesItAndDeletingThePlanLeavesTheCopiesRunning() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.editPlaylist(.mode(.rotate), display: "primary")
    let plan = try await controller.savePlaylistPlan(name: "Plan", display: "primary")
    try await controller.applyPlaylistPlan(plan.id, display: "primary")
    try await controller.applyPlaylistPlan(plan.id, display: "secondary")
    XCTAssertEqual(controller.playlistPlanRows.first?.displayCount, 2)

    try await controller.editPlaylist(.order(.shuffle), display: "secondary")
    XCTAssertNil(panel.playlists.playlist(for: "secondary").planID, "any real edit detaches the copy")
    XCTAssertEqual(controller.playlistPlanRows.first?.displayCount, 1)

    try await controller.deletePlaylistPlan(plan.id)
    XCTAssertTrue(controller.playlistPlanRows.isEmpty)
    XCTAssertEqual(panel.playlists.playlist(for: "primary").mode, .rotate, "the display keeps its playlist")
    XCTAssertNil(panel.playlists.playlist(for: "primary").planID)
  }

  func testARuleThatTargetedADeletedPlanStaysAndReadsAsUnavailable() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let plan = try await controller.savePlaylistPlan(name: "Plan", display: "primary")
    let target = WallpaperAutomationTarget(kind: .playlist, id: plan.id)
    try await controller.setAutomationMode(.schedule, display: "primary")
    try await controller.saveAutomationRule(AutomationRuleEdit(target: target), display: "primary")
    XCTAssertEqual(controller.automationTargets.title(of: target), "Plan")

    try await controller.deletePlaylistPlan(plan.id)
    XCTAssertEqual(controller.automationState(for: "primary").rules.map(\.target), [target], "the rule stays")
    XCTAssertNil(controller.automationTargets.title(of: target), "and reads as unavailable")
  }

  func testApplyingAPlanTakesTheDisplaysActivationTurnAndAMirrorOrAMissingPlanDoesNotQueue() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let plan = try await controller.savePlaylistPlan(name: "Plan", display: "primary")
    let gate = QueueGate()
    let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
    try await panel.waitUntil { panel.store.commands.isBusy }

    let apply = Task { try await controller.applyPlaylistPlan(plan.id, display: "secondary") }
    try await panel.waitUntil { panel.store.commands.hasWaiting(slot: BridgeStore.activationSlot(displayId: "secondary")) }
    XCTAssertNil(panel.playlists.playlist(for: "secondary").planID, "it waits for the command that is running")
    do {
      try await controller.applyPlaylistPlan(plan.id, display: "mirrored")
      XCTFail("a mirror has no playlist")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
    XCTAssertEqual(panel.store.commands.waiting.count, 1, "a refused apply never queued")
    gate.open()
    _ = await running.value
    try await apply.value
    XCTAssertEqual(panel.playlists.playlist(for: "secondary").planID, plan.id)
  }
}
