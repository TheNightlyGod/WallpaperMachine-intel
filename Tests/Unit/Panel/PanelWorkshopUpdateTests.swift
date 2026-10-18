import XCTest

@testable import WallpaperMachine

/// What the panel accepts for updates of installed Workshop wallpapers and for reinstalling one.
@MainActor
final class PanelWorkshopUpdateTests: MediaPanelTestCase {
  private func installed(_ ids: [String]) -> BridgeLibrarySnapshot {
    BridgeLibrarySnapshot(
      wallpapers: ids.map {
        BridgeWallpaperEntry(
          id: $0, title: $0, kind: .video, supported: true, active: false, selected: false, previewPath: nil)
      },
      scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 0,
      videoCount: UInt64(ids.count), webpageCount: 0, unknownCount: 0)
  }

  func testOnlyAnInstalledWallpaperThatItsAuthorChangedCanBeUpdated() async throws {
    // Installed two hours ago; its author changed it an hour ago.
    let changed = WorkshopItem(
      id: "123", title: "Changed", creator: "Creator", summary: "", previewURL: nil, tags: ["Video"],
      size: 1, subscriptions: 0, timeUpdated: Date().addingTimeInterval(-3600))
    let updates = WorkshopUpdateStore(
      defaults: try TemporaryDefaults.make(for: self).defaults, fetch: { _ in [changed] })
    let panel = try makeBrowsingPanel(
      service: WorkshopDetailsStub().service, updates: updates)
    let controller = panel.controller
    let folder = panel.root.appendingPathComponent("Library/123")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest = folder.appendingPathComponent("project.json")
    try Data("{}".utf8).write(to: manifest)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: manifest.path)
    panel.store.librarySnapshot = installed(["123", "456"])

    XCTAssertEqual(controller.workshopUpdates.count, 0)
    try await controller.checkWorkshopUpdates()
    XCTAssertTrue(controller.workshopUpdates.isChecking)
    try await waitFor { !updates.isChecking }
    XCTAssertEqual(controller.workshopUpdates.count, 1)
    XCTAssertNotNil(controller.workshopUpdates.lastChecked)
    XCTAssertTrue(controller.workshopUpdates.checksAutomatically)
    XCTAssertEqual(updates.available.keys.sorted(), ["123"])

    do {
      try await controller.updateWorkshopItem(id: "456")
      XCTFail("a wallpaper without an update has nothing to download")
    } catch is InvalidControlValue {}
    do {
      try await controller.updateWorkshopItem(id: "789")
      XCTFail("a wallpaper that is not installed cannot be updated")
    } catch let error as WallpaperActionError {
      XCTAssertEqual(error.message, "This wallpaper is no longer installed. Refresh your library.")
    }
    XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)

    try await controller.updateWorkshopItem(id: "123")
    XCTAssertEqual(controller.downloadRequestRows.map(\.id), ["123"], "an update goes through the same queue and prerequisites")
    XCTAssertEqual(controller.downloadRequestRows.first?.stage, .setup)
    try await controller.updateAllWorkshopItems()
    XCTAssertEqual(panel.workshop.downloadRequests.count, 1, "asking again keeps the one request")
  }

  /// Reinstalling downloads an installed wallpaper again, so it needs a wallpaper that is installed
  /// and the user's yes. Until both are there, Steam is not asked and nothing is queued.
  func testReinstallNeedsAnInstalledWallpaperAndAConfirmation() async throws {
    let stub = WorkshopDetailsStub()
    stub.rows["123"] = WorkshopDetailsStub.row("123", title: "Current", tags: ["Video"])
    addTeardownBlock { stub.invalidate() }
    let panel = try makeBrowsingPanel(service: stub.service)
    panel.store.librarySnapshot = installed(["123"])

    do {
      try await panel.controller.reinstallWorkshopItem(id: "456")
      XCTFail("a wallpaper that is not installed has nothing to reinstall")
    } catch is WallpaperActionError {}
    XCTAssertTrue(panel.dialogs.confirmations.isEmpty, "a stale id is refused before anything is asked")

    // No panel window means no sheet to answer it, which is a no.
    try await panel.controller.reinstallWorkshopItem(id: "123")
    XCTAssertEqual(panel.dialogs.confirmations.count, 1)
    XCTAssertEqual(panel.dialogs.confirmations.first?.title, "Reinstall this wallpaper?")
    XCTAssertEqual(panel.dialogs.confirmations.first?.button, "Reinstall")
    XCTAssertEqual(stub.requests, [])
    XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)
    XCTAssertTrue(panel.workshop.downloader.downloads.isEmpty)

    panel.dialogs.confirmAnswer = true
    try await panel.controller.reinstallWorkshopItem(id: "123")
    XCTAssertEqual(stub.requests, [["123"]], "Steam is asked for the item's current details")
    XCTAssertEqual(panel.controller.downloadRequestRows.map(\.id), ["123"])
    XCTAssertEqual(panel.controller.downloadRequestRows.first?.title, "Current")

    try await panel.controller.reinstallWorkshopItem(id: "123")
    XCTAssertEqual(stub.requests, [["123"]], "a retained request is where the user continues, not asked for again")
  }

  func testTheReinstallQuestionHoldsTheCommandQueueWhileItIsOpen() async throws {
    let stub = WorkshopDetailsStub()
    addTeardownBlock { stub.invalidate() }
    let panel = try makeBrowsingPanel(service: stub.service)
    panel.store.librarySnapshot = installed(["123"])
    let gate = SheetGate()
    let held = HoldingDialogs(gate: gate)
    let controller = PanelController(
      store: panel.store, navigation: ControlPanelNavigation(), workshop: panel.workshop,
      pixiv: panel.controller.pixiv, defaults: panel.controller.defaults, dialogs: held,
      appLanguage: .english())
    let asking = controller.launch("reinstall:123") { try await controller.reinstallWorkshopItem(id: "123") }
    try await waitFor { held.isAsking }
    XCTAssertTrue(controller.isStoreBusy, "the sheet is open inside the command, as it always was")
    gate.answer(false)
    await asking.value
    XCTAssertFalse(controller.isStoreBusy)
  }
}

/// Holds the confirmation sheet open until the test answers it.
@MainActor
private final class SheetGate {
  private var continuation: CheckedContinuation<Bool, Never>?
  func ask() async -> Bool { await withCheckedContinuation { continuation = $0 } }
  func answer(_ yes: Bool) { continuation?.resume(returning: yes); continuation = nil }
}

@MainActor
private final class HoldingDialogs: PanelDialogs {
  let gate: SheetGate
  private(set) var isAsking = false
  var presentingWindow: NSWindow? { nil }
  init(gate: SheetGate) { self.gate = gate }
  func confirm(_ title: String, detail: String, button: String) async -> Bool {
    isAsking = true
    defer { isAsking = false }
    return await gate.ask()
  }
  func choose(_ panel: NSSavePanel) async -> URL? { nil }
  func chooseMany(_ panel: NSOpenPanel) async -> [URL] { [] }
}
