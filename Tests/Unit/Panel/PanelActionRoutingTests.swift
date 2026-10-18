import XCTest

@testable import WallpaperMachine

/// How an action relates to the error banner and the command queue: the contract the web panel's
/// single switch enforced by position, now spelled by `ActionDisposition`.
@MainActor
final class PanelActionRoutingTests: PanelTestCase {
  private struct Refused: LocalizedError {
    var errorDescription: String? { "Refused" }
  }

  @MainActor private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
      isOpen = true
      let waiting = waiters
      waiters = []
      for waiter in waiting { waiter.resume() }
    }
  }

  private func wallpaper(_ id: String) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry(
      id: id, title: id, kind: .video, supported: true, active: false, selected: false, previewPath: nil)
  }

  func testDirectAndQueuedActionsClearTheBannerFirstAndBrowsingActionsLeaveIt() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    for disposition in [ActionDisposition.direct, .queued] {
      controller.errors.report(Refused())
      var bannerInside: String?
      try await controller.run(disposition) { bannerInside = controller.errors.actionError }
      XCTAssertNil(bannerInside, "\(disposition) clears the banner before its work starts")
    }
    for disposition in [ActionDisposition.immediate, .immediateQueued] {
      controller.errors.report(Refused())
      var bannerInside: String?
      try await controller.run(disposition) { bannerInside = controller.errors.actionError }
      XCTAssertEqual(bannerInside, "Refused", "\(disposition) leaves an older banner showing")
    }
    XCTAssertTrue(ActionDisposition.direct.clearsBanner && !ActionDisposition.direct.waitsInQueue)
    XCTAssertTrue(ActionDisposition.queued.clearsBanner && ActionDisposition.queued.waitsInQueue)
    XCTAssertTrue(!ActionDisposition.immediate.clearsBanner && !ActionDisposition.immediate.waitsInQueue)
    XCTAssertTrue(!ActionDisposition.immediateQueued.clearsBanner && ActionDisposition.immediateQueued.waitsInQueue)
  }

  func testQueuedWorkWaitsBehindARunningCommandAndDirectWorkDoesNot() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let gate = Gate()
    var log: [String] = []
    let running = Task { @MainActor in
      await panel.store.commands.run { await gate.wait() }
    }
    try await panel.waitUntil { panel.store.commands.isBusy }

    let queued = Task { @MainActor in
      try await controller.run(.queued) { log.append("queued") }
    }
    let queuedWithoutClearing = Task { @MainActor in
      try await controller.run(.immediateQueued) { log.append("immediateQueued") }
    }
    try await controller.run(.direct) { log.append("direct") }
    try await controller.run(.immediate) { log.append("immediate") }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(log, ["direct", "immediate"], "only the queued dispositions wait for the running command")

    gate.open()
    _ = await running.value
    _ = try await queued.value
    _ = try await queuedWithoutClearing.value
    XCTAssertEqual(log, ["direct", "immediate", "queued", "immediateQueued"], "and they run in arrival order")
  }

  func testANewerCommandInTheSameSlotReplacesOneStillWaiting() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let gate = Gate()
    var log: [String] = []
    let running = Task { @MainActor in
      await panel.store.commands.run { await gate.wait() }
    }
    try await panel.waitUntil { panel.store.commands.isBusy }
    let slot = BridgeStore.selectionSlot
    let first = Task { @MainActor in
      try await controller.run(.queued, slot: slot, subject: "a") { log.append("a") }
    }
    try await panel.waitUntil { panel.store.commands.hasWaiting(slot: slot) }
    let second = Task { @MainActor in
      try await controller.run(.queued, slot: slot, subject: "b") { log.append("b") }
    }
    gate.open()
    _ = await running.value
    let ranFirst = try await first.value
    let ranSecond = try await second.value
    XCTAssertFalse(ranFirst, "a replaced command reports that it did not run")
    XCTAssertTrue(ranSecond)
    XCTAssertEqual(log, ["b"])
  }

  func testALaunchedActionsFailureReachesTheBannerAndTheKeyIsFreeAgain() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let key = PanelActionCoordinator.key("delete", id: "a")
    let task = controller.launch(key) { try await controller.run(.queued) { throw Refused() } }
    XCTAssertTrue(controller.isBusy(key))
    await task.value
    XCTAssertEqual(controller.errors.message, "Refused")
    XCTAssertFalse(controller.isBusy(key))

    await controller.launch(key) { try await controller.run(.direct) {} }.value
    XCTAssertNil(controller.errors.message, "the next direct action cleared it")
  }

  func testAnActionThatSucceedsReconcilesTheDismissals() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let errors = panel.controller.errors
    try? await panel.store.refreshAllAsync()
    errors.dismiss()
    XCTAssertNotNil(errors.dismissedLibraryError)
    panel.bridge.snapshot = BridgeSnapshotBundle(
      app: panel.store.appSnapshot, library: panel.store.librarySnapshot,
      wallpaperOptions: nil, monitorInformation: panel.store.monitorInformationSnapshot,
      settings: panel.store.settingsSnapshot)
    try await panel.store.refreshAllAsync()
    await panel.controller.launch("x:") {}.value
    XCTAssertNil(errors.dismissedLibraryError, "the source cleared, so a success re-arms it")
  }

  func testStoreBusyCoversTheQueueAndAnyActivationOrApply() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    XCTAssertFalse(panel.controller.isStoreBusy)
    let gate = Gate()
    let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
    try await panel.waitUntil { panel.controller.isStoreBusy }
    gate.open()
    _ = await running.value
    try await panel.waitUntil { !panel.controller.isStoreBusy }
  }

  func testIdResolversRefuseWhatIsNoLongerThereAndKeepRequestOrder() throws {
    let panel = try makeController()
    let controller = panel.controller
    panel.store.librarySnapshot.wallpapers = ["a", "b", "c"].map(wallpaper)

    XCTAssertEqual(try controller.installedWallpaperID("b"), "b")
    XCTAssertThrowsError(try controller.installedWallpaperID("gone")) { error in
      XCTAssertEqual(
        error.localizedDescription, "This wallpaper is no longer installed. Refresh your library.")
    }

    XCTAssertEqual(try controller.installedWallpaperIDs(["c", "a", "c", "a"]), ["c", "a"], "distinct, first occurrence first")
    XCTAssertThrowsError(try controller.installedWallpaperIDs(["a", "gone"])) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Some selected wallpapers are no longer installed. Refresh your library.",
        "one stale id refuses the whole batch")
    }
    XCTAssertThrowsError(try controller.installedWallpaperIDs([])) { XCTAssertTrue($0 is InvalidControlValue) }
    XCTAssertThrowsError(try controller.installedWallpaperIDs(Array(repeating: "a", count: 4097))) {
      XCTAssertTrue($0 is InvalidControlValue)
    }
  }

  func testOnlyAnEnabledDisplayWithItsOwnWallpaperIsAPerDisplayTarget() throws {
    let panel = try makeController()
    let controller = panel.controller
    func display(_ id: String, mode: BridgeDisplayMode, enabled: Bool = true) -> BridgeDisplaySettingsRow {
      BridgeDisplaySettingsRow(
        displayId: id, title: id, enabled: enabled, mode: mode, mirrorTargets: [],
        selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
        muted: false, volume: 1)
    }
    panel.store.settingsSnapshot.displays = [
      display("primary", mode: .standalone), display("mirror", mode: .mirror),
      display("off", mode: .standalone, enabled: false),
    ]
    XCTAssertEqual(try controller.standaloneDisplayID(), "primary", "no display named: the target display")
    XCTAssertEqual(try controller.standaloneDisplayID("primary"), "primary")
    for refused in ["mirror", "off", "unknown"] {
      XCTAssertThrowsError(try controller.standaloneDisplayID(refused), refused) {
        XCTAssertTrue($0 is InvalidControlValue)
      }
    }
    panel.navigation.targetDisplayID = "mirror"
    XCTAssertThrowsError(try controller.standaloneDisplayID(), "a target that cannot show its own wallpaper")
  }
}
