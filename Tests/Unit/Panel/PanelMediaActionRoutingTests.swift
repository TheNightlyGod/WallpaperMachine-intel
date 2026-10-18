import XCTest

@testable import WallpaperMachine

/// How the Workshop, download and pixiv actions relate to the error banner and the command queue.
/// Browsing, cancelling, pausing and answering a prompt never wait behind a renderer command and
/// leave an older banner showing, so they stay usable while a wallpaper applies; requests that
/// change what is installed or retained clear the banner and wait their turn.
@MainActor
final class PanelMediaActionRoutingTests: MediaPanelTestCase {
  private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
      isOpen = true
      for waiter in waiters { waiter.resume() }
      waiters = []
    }
  }

  func testBrowsingAndControllingLeaveAnOlderBannerAndRequestsClearIt() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      @MainActor func report() { controller.errors.actionError = "An earlier failure" }

      let leaving: [(String, @MainActor () async throws -> Void)] = [
        ("cancelDownload", { try await controller.cancelDownload(id: "none") }),
        ("setupCancel", { try await controller.cancelSteamCMDSetup() }),
        ("openWorkshop", { try await controller.openWorkshop(.browse) }),
        ("pixivCancel", { try await controller.pixivCancel(id: "none") }),
        ("pixivClear", { try await controller.pixivClearDownloads() }),
        ("steamWebSignOut", { try await controller.steamWebSignOut() }),
      ]
      for (name, action) in leaving {
        report()
        try await action()
        XCTAssertEqual(controller.errors.actionError, "An earlier failure", "\(name) leaves the banner showing")
      }
      panel.workshop.cancelSearch()

      let clearing: [(String, @MainActor () async throws -> Void)] = [
        ("requestSceneAssets", { try await controller.requestSceneAssets() }),
        ("removeDownloadRequest", { try await controller.removeDownloadRequest(id: WorkshopStore.sceneAssetsRequestID) }),
        ("clearDownloads", { try await controller.clearDownloads() }),
        ("logOutSteam", { try await controller.logOutSteam() }),
        ("locateSteamCMD", { try await controller.locateSteamCMD() }),
        ("downloadSubscribed", { try? await controller.downloadSubscribedWorkshopItems() }),
      ]
      for (name, action) in clearing {
        report()
        try await action()
        XCTAssertNil(controller.errors.actionError, "\(name) clears the banner before it starts")
      }
    }
  }

  func testBrowsingNeverWaitsBehindARunningCommandAndRequestsDo() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let gate = Gate()
      let running = Task { @MainActor in
        await panel.store.commands.run { await gate.wait() }
      }
      try await panel.waitUntil { panel.store.commands.isBusy }

      // None of these may wait for the running command: they would hang the test if they did.
      try await controller.cancelDownload(id: "none")
      try await controller.cancelSteamCMDSetup()
      try await controller.openWorkshop(.browse)
      try await controller.pixivSearch(PixivQuery())
      try await controller.pixivPause(id: "none")
      try await controller.pixivCancel(id: "none")
      try await controller.workshopGoBack()
      panel.workshop.cancelSearch()

      var requested = false
      let request = Task { @MainActor in
        try await controller.requestSceneAssets()
        requested = true
      }
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertFalse(requested, "a request waits for the running command")
      XCTAssertTrue(controller.downloadRequestRows.isEmpty)

      await gate.open()
      _ = await running.value
      try await request.value
      XCTAssertTrue(requested)
      XCTAssertEqual(controller.downloadRequestRows.map(\.id), [WorkshopStore.sceneAssetsRequestID])
    }
  }
}
