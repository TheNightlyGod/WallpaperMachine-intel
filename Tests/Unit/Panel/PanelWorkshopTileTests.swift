import XCTest

@testable import WallpaperMachine

/// What a Discover tile wears and what a double-click on it means, from the library, the favorites
/// and the download state together.
@MainActor
final class PanelWorkshopTileTests: MediaPanelTestCase {
  private func item(
    _ id: String = "222", tags: [String] = ["Video"], preview: String? = nil, collection: Int? = nil,
    creatorID: String? = nil
  ) -> WorkshopItem {
    WorkshopItem(
      id: id, title: "Local video", creator: "Fixture", summary: "", previewURL: preview.flatMap(URL.init(string:)),
      tags: tags, size: 0, subscriptions: 0, creatorID: creatorID, collectionSize: collection)
  }

  private func library(_ id: String, kind: BridgeWallpaperKind = .video) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry(
      id: id, title: id, kind: kind, supported: true, active: false, selected: false, previewPath: nil)
  }

  func testAnItemKnowsItsStillItsMarksAndItsKindLabel() {
    XCTAssertEqual(
      item(preview: "https://images.steamusercontent.com/ugc/a/preview/").thumbnail,
      .steamThumbnail(URL(string: "https://images.steamusercontent.com/ugc/a/preview/")!))
    XCTAssertNil(item(preview: "http://images.steamusercontent.com/ugc/a/").thumbnail, "only https is read")
    XCTAssertNil(item().thumbnail)
    XCTAssertTrue(item(tags: ["Scene", "approved"]).isApproved, "the tag is read in any case")
    XCTAssertFalse(item(tags: ["Scene"]).isApproved)
    XCTAssertTrue(item(collection: 4).isCollection)
    XCTAssertTrue(item(collection: 0).isCollection, "a collection of unknown size is still one")
    XCTAssertFalse(item().isCollection)
    XCTAssertEqual(item(collection: 4).kindLabel, "Collection")
    XCTAssertEqual(item(tags: ["Scene"]).kindLabel, "Scene")
    XCTAssertEqual(item(tags: ["Mature"]).kindLabel, "All types", "no type tag reads All types")
    XCTAssertEqual(item(creatorID: "76561198000000001").authorProfileID, "76561198000000001")
    XCTAssertNil(item(creatorID: "not an id").authorProfileID)
    XCTAssertNil(item().authorProfileID)
    XCTAssertFalse(item(tags: ["Application"]).canRunOnMac)
    XCTAssertTrue(item(tags: ["Web"]).canRunOnMac)
  }

  func testATileWearsTheCheckTheHeartAndTheRingOfItsDownload() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let wanted = item()
      panel.workshop.selectedItem = wanted
      var tile = controller.workshopTile(for: wanted)
      XCTAssertFalse(tile.isInstalled)
      XCTAssertFalse(tile.isFavorite)
      XCTAssertNil(tile.download)

      panel.store.librarySnapshot.wallpapers = [library("222")]
      controller.favoriteIDs = ["222"]
      tile = controller.workshopTile(for: wanted)
      XCTAssertTrue(tile.isInstalled)
      XCTAssertTrue(tile.isFavorite)
      XCTAssertEqual(tile.id, "222")

      try await controller.requestDownload(item: wanted)
      tile = controller.workshopTile(for: wanted)
      XCTAssertEqual(tile.download?.kind, .attention, "a request waiting for setup marks the tile")
      XCTAssertEqual(tile.download?.action, .continueSetup)

      let collection = item("900", collection: 3)
      XCTAssertNil(controller.workshopTile(for: collection).download)
    }
  }

  /// Double-clicking downloads a tile, applies it once it is in the library, and opens a collection.
  func testADoubleClickMeansWhatTheStateOfTheItemCallsFor() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let wanted = item()
      panel.workshop.selectedItem = wanted
      XCTAssertEqual(controller.workshopDoubleClick(for: item("900", collection: 3)), .openCollection)
      XCTAssertEqual(controller.workshopDoubleClick(for: wanted), .requestDownload)

      try await controller.requestDownload(item: wanted)
      XCTAssertEqual(controller.workshopDoubleClick(for: wanted), .continueSetup, "a retained request reopens its dialog")

      panel.workshop.selectedItem = wanted
      panel.store.librarySnapshot.wallpapers = [library("222")]
      XCTAssertEqual(controller.workshopDoubleClick(for: wanted), .apply, "in the library, the target can show it")
      panel.store.librarySnapshot.wallpapers = [library("222", kind: .unknown)]
      XCTAssertEqual(controller.workshopDoubleClick(for: wanted), .select, "a type this version cannot run is only selected")
      panel.store.librarySnapshot.wallpapers = [library("222")]
      panel.store.settingsSnapshot.displays[0].mode = .mirror
      XCTAssertEqual(controller.workshopDoubleClick(for: wanted), .select, "a mirror cannot take it")
    }
  }

  func testADoubleClickOnADownloadUnderWayOnlySelectsIt() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
      try await panel.waitUntil { panel.workshop.steamCMDSetup.selectedRuntime != nil }
      let wanted = item()
      panel.workshop.selectedItem = wanted
      panel.workshop.username = "localtest"
      controller.remembersSession = false
      try await controller.requestDownload(item: wanted)
      try await panel.waitUntil { panel.workshop.downloader.download(for: "222")?.isPending == true }
      XCTAssertEqual(controller.workshopDoubleClick(for: wanted), .select)
      XCTAssertEqual(controller.workshopTile(for: wanted).download?.action, .cancel)
    }
  }

  /// A wallpaper that arrived through Download and apply and was left alone says why, until the
  /// target display shows it or the finished downloads are cleared.
  func testAWallpaperThatArrivedAndWasLeftAloneSaysWhyUntilTheTargetShowsIt() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let wanted = item()
      panel.workshop.selectedItem = wanted
      XCTAssertNil(controller.workshopApplyNote(for: "222"))
      try await controller.requestDownload(item: wanted, apply: true)
      // The person chooses another wallpaper for the display before this one arrives.
      panel.reportFromBridge(panel.store.settingsSnapshot)
      panel.store.commands.noteUserChoice(in: [BridgeStore.activationSlot(displayId: "primary")])
      try await panel.workshop.finishInstall(item: wanted, replacing: false, bridge: panel.store)
      await panel.workshop.applyInFlight("222")?.value

      let note = "Downloaded, but not applied because you chose another wallpaper."
      XCTAssertEqual(controller.workshopApplyNote(for: "222"), note)
      XCTAssertEqual(controller.workshopItemDownload(for: wanted).applyNote, note)

      panel.store.monitorInformationSnapshot.rows = [
        BridgeMonitorInfoRow(
          displayId: "primary", title: "Primary", wallpaperId: "222", wallpaperTitle: "W",
          mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill", targetFps: "30",
          audioResponse: false)
      ]
      XCTAssertNil(controller.workshopApplyNote(for: "222"), "the reason is moot once the display shows it")
      XCTAssertNil(controller.workshopItemDownload(for: wanted).applyNote)

      panel.store.monitorInformationSnapshot.rows = []
      XCTAssertEqual(controller.workshopApplyNote(for: "222"), note)
      try await controller.clearDownloads()
      XCTAssertNil(controller.workshopApplyNote(for: "222"), "clearing the finished downloads forgets the note")
    }
  }
}
