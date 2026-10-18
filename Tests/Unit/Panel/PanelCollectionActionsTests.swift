import os
import XCTest

@testable import WallpaperMachine

/// The collection actions of the library sidebar, the selection bar and the inspector, and the
/// rows the sidebar reads, checked against the stores.
@MainActor
final class PanelCollectionActionsTests: PanelTestCase {
  private func makePanel(installed: [String] = ["a", "b", "c"]) throws -> (PanelFixture, PanelController) {
    let panel = try makeController()
    panel.store.librarySnapshot.wallpapers = installed.map { OrganizationFixtures.wallpaper($0) }
    return (panel, panel.controller)
  }

  func testACollectionHoldsTheInstalledWallpapersOnceEachInRequestOrderAndIsReturned() async throws {
    let (panel, controller) = try makePanel()
    defer { Task { await panel.shutdown() } }
    let created = try await controller.createCollection(name: "  Night  ", wallpaperIDs: ["c", "a", "c"])
    XCTAssertEqual(created.name, "Night", "names are trimmed")
    XCTAssertEqual(created.wallpaperIDs, ["c", "a"], "once each, in the order given")
    XCTAssertEqual(panel.collections.collection(id: created.id), created)
    XCTAssertEqual(controller.collectionRows, [CollectionRow(id: created.id, name: "Night", wallpaperIDs: ["c", "a"])])

    let empty = try await controller.createCollection(name: "Empty")
    XCTAssertEqual(empty.wallpaperIDs, [], "no ids makes an empty collection")
    XCTAssertEqual(controller.collectionRows.map(\.name), ["Night", "Empty"], "in the order they were made")
  }

  func testAStaleWallpaperRefusesTheWholeBatchAndNothingIsCreatedOrAdded() async throws {
    let (panel, controller) = try makePanel()
    defer { Task { await panel.shutdown() } }
    let stale = L("Some selected wallpapers are no longer installed. Refresh your library.")
    do {
      _ = try await controller.createCollection(name: "Gone", wallpaperIDs: ["a", "missing"])
      XCTFail("a collection cannot start from a wallpaper that is not installed")
    } catch { XCTAssertEqual(error.localizedDescription, stale) }
    XCTAssertTrue(controller.collectionRows.isEmpty)

    let kept = try await controller.createCollection(name: "Kept", wallpaperIDs: ["a"])
    do {
      try await controller.addToCollection(kept.id, wallpaperIDs: ["b", "missing"])
      XCTFail("a batch with a stale id adds nothing")
    } catch { XCTAssertEqual(error.localizedDescription, stale) }
    XCTAssertEqual(panel.collections.collection(id: kept.id)?.wallpaperIDs, ["a"])

    for refused in [[""], Array(repeating: "a", count: 4097)] {
      do {
        _ = try await controller.createCollection(name: "Invalid", wallpaperIDs: refused)
        XCTFail("an empty id or more than 4,096 ids is not a selection a control makes")
      } catch { XCTAssertTrue(error is InvalidControlValue) }
    }
  }

  func testNamesThatAreBlankLongOrOnSeveralLinesAreRefusedWithoutChangingAnything() async throws {
    let (panel, controller) = try makePanel()
    defer { Task { await panel.shutdown() } }
    let collection = try await controller.createCollection(name: "Work")
    for name in ["", "   ", String(repeating: "x", count: 129), "two\nlines"] {
      do {
        _ = try await controller.createCollection(name: name)
        XCTFail("created \(name.debugDescription)")
      } catch { XCTAssertEqual(error.localizedDescription, String(localized: "Enter a name between 1 and 128 characters, on one line.")) }
      do {
        try await controller.renameCollection(collection.id, to: name)
        XCTFail("renamed to \(name.debugDescription)")
      } catch {}
    }
    XCTAssertEqual(controller.collectionRows.map(\.name), ["Work"])
    _ = try await controller.createCollection(name: String(repeating: "长", count: 128))
    try await controller.renameCollection(collection.id, to: "Evening")
    XCTAssertEqual(controller.collectionRows.map(\.name), ["Evening", String(repeating: "长", count: 128)])
  }

  func testMembershipKeepsItsOrderNeverDuplicatesAndRemovingToleratesAWallpaperThatLeft() async throws {
    let (panel, controller) = try makePanel()
    defer { Task { await panel.shutdown() } }
    let collection = try await controller.createCollection(name: "Mix", wallpaperIDs: ["b"])
    try await controller.addToCollection(collection.id, wallpaperIDs: ["c", "b", "a"])
    XCTAssertEqual(panel.collections.collection(id: collection.id)?.wallpaperIDs, ["b", "c", "a"])

    panel.store.librarySnapshot.wallpapers.removeAll { $0.id == "c" }
    try await controller.removeFromCollection(collection.id, wallpaperIDs: ["c", "never-there"])
    XCTAssertEqual(
      panel.collections.collection(id: collection.id)?.wallpaperIDs, ["b", "a"],
      "a wallpaper that left the library can still be taken out")

    do {
      try await controller.addToCollection("gone", wallpaperIDs: ["a"])
      XCTFail("a collection that no longer exists")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, String(localized: "This collection no longer exists. Refresh the library and retry."))
    }
  }

  func testTheSidebarCountsEveryMemberEvenOneTheLibraryNoLongerHolds() async throws {
    let (panel, controller) = try makePanel()
    defer { Task { await panel.shutdown() } }
    let collection = try await controller.createCollection(name: "Mix", wallpaperIDs: ["a", "b"])
    panel.store.librarySnapshot.wallpapers.removeAll { $0.id == "b" }
    XCTAssertEqual(controller.collectionRows.first?.count, 2, "stale ids still count until they are removed")
    XCTAssertEqual(controller.collectionRows.first?.id, collection.id)
  }

  func testDeletingACollectionLeavesItsPlaylistsAnEmptyListOfTheirOwn() async throws {
    let (panel, controller) = try makePanel()
    defer { Task { await panel.shutdown() } }
    let collection = try await controller.createCollection(name: "Night", wallpaperIDs: ["a", "b"])
    try await controller.editPlaylist(.mode(.rotate))
    try await controller.editPlaylist(.collection(id: collection.id))
    XCTAssertEqual(panel.playlists.playlist(for: "primary").source, .collection)

    try await controller.deleteCollection(collection.id)
    XCTAssertTrue(controller.collectionRows.isEmpty)
    let playlist = panel.playlists.playlist(for: "primary")
    XCTAssertEqual(playlist.source, .list, "never an all-library rotation")
    XCTAssertEqual(playlist.wallpaperIDs, [])
    XCTAssertNil(playlist.collectionID)
    XCTAssertEqual(controller.playlistState(for: "primary").source, .list)

    do {
      try await controller.deleteCollection(collection.id)
      XCTFail("deleting twice")
    } catch {}
  }

  func testACollectionEditLeavesAnOlderBannerAloneAndNeverWaitsForTheQueue() async throws {
    let (panel, controller) = try makePanel()
    defer { Task { await panel.shutdown() } }
    struct Refused: LocalizedError { var errorDescription: String? { "Refused" } }
    controller.errors.report(Refused())
    let gate = QueueGate()
    let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
    try await panel.waitUntil { panel.store.commands.isBusy }
    _ = try await controller.createCollection(name: "While busy", wallpaperIDs: ["a"])
    XCTAssertEqual(controller.collectionRows.map(\.name), ["While busy"], "metadata does not wait for the renderer")
    XCTAssertEqual(controller.errors.message, "Refused", "browsing and organizing leave the banner showing")
    gate.open()
    _ = await running.value
  }

  func testTheRowsFollowTheStoreWithoutAnyOtherChange() async throws {
    let (panel, controller) = try makePanel()
    defer { Task { await panel.shutdown() } }
    try await panel.start()
    let changes = OSAllocatedUnfairLock(initialState: 0)
    withObservationTracking {
      _ = controller.collectionRows
    } onChange: {
      changes.withLock { $0 += 1 }
    }
    _ = try panel.collections.create(name: "Made behind the panel's back", wallpaperIDs: ["a"])
    try await panel.waitUntil { changes.withLock { $0 } == 1 }
    XCTAssertEqual(controller.collectionRows.map(\.name), ["Made behind the panel's back"])
  }
}
