import XCTest

@testable import WallpaperMachine

/// **Download and apply**: the wallpaper is applied once it has arrived, but only if the person
/// has not chosen anything else for that display since they asked, within an hour, and never
/// from a relaunch. `finishInstall` stands in for the download arriving; the bridge is the
/// two-display test bridge, so nothing touches a desktop or Steam.
@MainActor
final class WorkshopApplyOnArrivalTests: XCTestCase {
  private var home: URL!
  private var defaults: UserDefaults!
  private var previousHome: String?
  private var workshops: [WorkshopStore] = []
  private let clock = TestClock()

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("mwe-apply-on-arrival-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    defaults = try TemporaryDefaults.make(for: self).defaults
  }

  /// Jobs own PTYs inside `home`; every one of them is reaped before the directory goes.
  override func tearDown() async throws {
    for workshop in workshops {
      await workshop.downloader.shutdown()
      await workshop.steamCMDSetup.shutdown()
    }
    workshops.removeAll()
    if let previousHome {
      setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
    } else {
      unsetenv("WALLPAPER_MACHINE_HOME")
    }
    try? FileManager.default.removeItem(at: home)
  }

  // MARK: Applying

  func testTheWallpaperIsAppliedOnceItHasArrivedAndOnlyOnThatDisplay() async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    XCTAssertTrue(fixture.bridge.applications.isEmpty, "Asking for it changes nothing until it has arrived")

    try await arrive(wanted, fixture)

    XCTAssertEqual(fixture.bridge.assignments["primary"], "c")
    XCTAssertEqual(fixture.bridge.assignments["secondary"], "b", "The other display keeps what it showed")
    XCTAssertEqual(fixture.bridge.applications.filter { $0 == ("primary", "c") }.count, 1)
    XCTAssertNil(fixture.workshop.applyNotes["c"])

    try await arrive(wanted, fixture)
    XCTAssertEqual(
      fixture.bridge.applications.filter { $0 == ("primary", "c") }.count, 1,
      "The choice is used up by the arrival it was made for")
  }

  func testAPlainDownloadAppliesNothing() async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store)

    try await arrive(wanted, fixture)

    XCTAssertEqual(fixture.bridge.assignments["primary"], "a")
    XCTAssertTrue(fixture.bridge.applications.isEmpty)
  }

  /// The person's own choice for that display wins, whenever in the download it was made.
  func testChoosingAnotherWallpaperMeanwhileWithdrawsTheChoiceAndSaysSo() async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")

    try await fixture.store.commands.run(slot: BridgeStore.activationSlot(displayId: "primary"), subject: "b") {
      try await fixture.store.activateWallpaperAsync(id: "b", displayId: "primary", origin: .user)
    }
    try await arrive(wanted, fixture)

    XCTAssertEqual(fixture.bridge.assignments["primary"], "b", "What they chose stands")
    XCTAssertFalse(fixture.bridge.applications.contains { $0.1 == "c" })
    XCTAssertNotNil(fixture.workshop.applyNotes["c"], "They are told it arrived and was left alone")
    XCTAssertFalse(fixture.workshop.appliesOnArrival("c"))
  }

  /// Copying, swapping and applying a saved layout are the person's choices for the displays they
  /// name, though no single display's command slot runs them.
  func testCopyingToTheDisplayMeanwhileWithdrawsTheChoice() async throws {
    try await assertTransferWithdrawsTheChoice(
      .copy(from: "secondary", to: "primary"), leaving: ["primary": "b", "secondary": "b"])
  }

  func testSwappingTheDisplayMeanwhileWithdrawsTheChoice() async throws {
    try await assertTransferWithdrawsTheChoice(
      .swap("primary", "secondary"), leaving: ["primary": "b", "secondary": "a"])
  }

  func testApplyingALayoutNamingTheDisplayMeanwhileWithdrawsTheChoice() async throws {
    try await assertTransferWithdrawsTheChoice(
      .layout([WallpaperDisplayAssignment(displayID: "primary", displayTitle: "primary", wallpaperID: "b")]),
      leaving: ["primary": "b", "secondary": "b"])
  }

  private func assertTransferWithdrawsTheChoice(
    _ request: WallpaperDisplayTransfer.Request, leaving expected: [String: String],
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")

    try await fixture.store.applyDisplayTransferAsync(request)
    try await arrive(wanted, fixture)

    XCTAssertEqual(fixture.bridge.assignments, expected, "What they chose stands", file: file, line: line)
    XCTAssertFalse(fixture.bridge.applications.contains { $0.1 == "c" }, file: file, line: line)
    XCTAssertNotNil(
      fixture.workshop.applyNotes["c"], "They are told it arrived and was left alone", file: file, line: line)
    XCTAssertFalse(fixture.workshop.appliesOnArrival("c"), file: file, line: line)
  }

  func testATransferThatLeavesTheDisplayAloneDoesNotWithdrawTheChoice() async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")

    // Copying from the display changes the other one; a layout for the other display is about it.
    try await fixture.store.applyDisplayTransferAsync(.copy(from: "primary", to: "secondary"))
    try await fixture.store.applyDisplayTransferAsync(
      .layout([WallpaperDisplayAssignment(displayID: "secondary", displayTitle: "secondary", wallpaperID: "b")]))
    try await arrive(wanted, fixture)

    XCTAssertEqual(fixture.bridge.assignments["primary"], "c")
    XCTAssertNil(fixture.workshop.applyNotes["c"])
  }

  func testAChoiceMadeWhileTheApplyWaitsForItsTurnStillWins() async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    let gate = Gate()
    let busy = Task { try await fixture.store.commands.run(slot: "other") { await gate.wait() } }
    await until { fixture.store.commands.isBusy }

    try await fixture.workshop.finishInstall(item: wanted, replacing: false, bridge: fixture.store)
    let waiting = try XCTUnwrap(fixture.workshop.applyInFlight("c"))
    await until { fixture.store.commands.waiting.map(\.subject) == ["c"] }
    let chosen = Task {
      try await fixture.store.commands.run(slot: BridgeStore.activationSlot(displayId: "primary"), subject: "b") {
        try await fixture.store.activateWallpaperAsync(id: "b", displayId: "primary", origin: .user)
      }
    }
    await until { fixture.store.commands.waiting.map(\.subject) == ["b"] }
    gate.open()
    _ = try await [busy.value, chosen.value]
    await waiting.value

    XCTAssertEqual(fixture.bridge.assignments["primary"], "b")
    XCTAssertFalse(fixture.bridge.applications.contains { $0.1 == "c" })
    XCTAssertNotNil(fixture.workshop.applyNotes["c"])
  }

  func testAutomaticChangesAndOtherDisplaysDoNotWithdrawTheChoice() async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")

    // A playlist moving on is the app, not the person, and a choice for the other display is
    // about another display.
    try await fixture.store.commands.run(slot: BridgeStore.activationSlot(displayId: "primary"), subject: "b", origin: .playlist) {
      try await fixture.store.activateWallpaperAsync(id: "b", displayId: "primary", origin: .playlist)
    }
    try await fixture.store.commands.run(slot: BridgeStore.activationSlot(displayId: "secondary"), subject: "a") {
      try await fixture.store.activateWallpaperAsync(id: "a", displayId: "secondary", origin: .user)
    }
    try await arrive(wanted, fixture)

    XCTAssertEqual(fixture.bridge.assignments["primary"], "c")
    XCTAssertEqual(fixture.bridge.assignments["secondary"], "a")
    XCTAssertNil(fixture.workshop.applyNotes["c"])
  }

  /// Two asks for one display are two choices, and the person's last one stands. The first
  /// wallpaper to arrive must not count as a choice that takes the display from the other.
  func testTheLatestAskForADisplayWinsWhenItArrivesFirst() async throws {
    try await assertTheLatestAskWins(arrivingFirst: "c")
  }

  func testTheLatestAskForADisplayWinsWhenTheEarlierOneArrivesFirst() async throws {
    try await assertTheLatestAskWins(arrivingFirst: "b")
  }

  private func assertTheLatestAskWins(arrivingFirst: String) async throws {
    let fixture = try await makeFixture()
    let earlier = item("b"), later = item("c")
    fixture.workshop.requestDownload(item: earlier, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    fixture.workshop.requestDownload(item: later, rememberSession: false, bridge: fixture.store, applyTo: "primary")

    for wanted in arrivingFirst == "c" ? [later, earlier] : [earlier, later] {
      try await arrive(wanted, fixture)
    }

    XCTAssertEqual(fixture.bridge.assignments["primary"], "c", "The wallpaper asked for last is the one shown")
    XCTAssertEqual(fixture.bridge.assignments["secondary"], "b", "The other display keeps what it showed")
    XCTAssertEqual(fixture.bridge.applications.map { "\($0.0)=\($0.1)" }, ["primary=c"])
    XCTAssertNil(fixture.workshop.applyNotes["c"])
    XCTAssertNotNil(fixture.workshop.applyNotes["b"], "The earlier one arrived and is told why it was left alone")
    XCTAssertFalse(fixture.workshop.appliesOnArrival("b"))
    XCTAssertFalse(fixture.workshop.appliesOnArrival("c"))
  }

  func testAsksForDifferentDisplaysDoNotWithdrawEachOther() async throws {
    let fixture = try await makeFixture()
    let first = item("b"), second = item("c")
    fixture.workshop.requestDownload(item: first, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    fixture.workshop.requestDownload(item: second, rememberSession: false, bridge: fixture.store, applyTo: "secondary")

    try await arrive(first, fixture)
    try await arrive(second, fixture)

    XCTAssertEqual(fixture.bridge.assignments["primary"], "b")
    XCTAssertEqual(fixture.bridge.assignments["secondary"], "c")
    XCTAssertTrue(fixture.workshop.applyNotes.isEmpty)
  }

  func testAChoiceIsGoodForAnHourAndNotLonger() async throws {
    let fixture = try await makeFixture()
    let inTime = item("c")
    fixture.workshop.requestDownload(item: inTime, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    clock.date.addTimeInterval(WorkshopStore.applyIntentLifetime - 1)
    try await arrive(inTime, fixture)
    XCTAssertEqual(fixture.bridge.assignments["primary"], "c", "A slow download is still what they asked for")

    let tooLate = item("b")
    fixture.workshop.requestDownload(item: tooLate, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    clock.date.addTimeInterval(WorkshopStore.applyIntentLifetime + 1)
    try await arrive(tooLate, fixture)

    XCTAssertEqual(fixture.bridge.assignments["primary"], "c", "A download that outlived the hour changes nothing")
    XCTAssertNotNil(fixture.workshop.applyNotes["b"])
  }

  func testAnApplyThatFailsLeavesTheDisplayAloneAndSaysWhy() async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.bridge.failOnce = "primary=c"
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")

    try await arrive(wanted, fixture)

    XCTAssertEqual(fixture.bridge.assignments["primary"], "a")
    let note = try XCTUnwrap(fixture.workshop.applyNotes["c"])
    XCTAssertTrue(note.contains(CocoaError(.fileWriteUnknown).localizedDescription), "The reason is in the note: \(note)")
  }

  func testADisplayThatCannotShowItAnymoreIsNotAppliedTo() async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    fixture.bridge.eligible.remove("primary")
    try await fixture.store.refreshAllAsync()

    try await arrive(wanted, fixture)

    XCTAssertTrue(fixture.bridge.applications.isEmpty)
    XCTAssertNotNil(fixture.workshop.applyNotes["c"])
  }

  func testWhatNeverReachedTheLibraryIsNotApplied() async throws {
    let fixture = try await makeFixture()
    let wanted = item("c")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    fixture.bridge.libraryRefreshFailure = CocoaError(.fileReadUnknown)

    do {
      try await fixture.workshop.finishInstall(item: wanted, replacing: false, bridge: fixture.store)
      XCTFail("a library that could not be rescanned reports it")
    } catch {}

    XCTAssertNil(fixture.workshop.applyInFlight("c"))
    XCTAssertFalse(fixture.workshop.appliesOnArrival("c"))
    XCTAssertTrue(fixture.bridge.applications.isEmpty)
  }

  // MARK: What is excluded

  func testAnApplicationACollectionAndAnUnusableDisplayAreOnlyDownloaded() async throws {
    let fixture = try await makeFixture()
    fixture.bridge.eligible.remove("secondary")
    try await fixture.store.refreshAllAsync()
    let cases: [(WorkshopItem, String)] = [
      (item("a", tags: ["Application"]), "primary"),
      (item("b", collectionSize: 4), "primary"),
      (item("c"), "secondary"),
    ]

    for (wanted, display) in cases {
      fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: display)
      try await arrive(wanted, fixture)
    }

    XCTAssertTrue(fixture.bridge.applications.isEmpty)
    XCTAssertEqual(fixture.bridge.assignments, ["primary": "a", "secondary": "b"])
    XCTAssertTrue(fixture.workshop.applyNotes.isEmpty, "Nothing was promised, so nothing is explained")
  }

  // MARK: Shared scene assets

  func testASceneWaitsForItsSharedAssetsAndThenApplies() async throws {
    let assets = AssetsProbe()
    let fixture = try await makeFixture(assets: assets)
    let scene = item("c", tags: ["Scene"])
    fixture.workshop.requestDownload(item: scene, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    startSharedAssetsJob(fixture)

    try await arrive(scene, fixture)
    XCTAssertTrue(fixture.bridge.applications.isEmpty, "A scene cannot play before its shared assets are there")
    XCTAssertTrue(fixture.workshop.appliesOnArrival("c"), "It still waits for them")

    fixture.workshop.settleApplyIntentsAwaitingAssets(bridge: fixture.store)
    XCTAssertNil(fixture.workshop.applyInFlight("c"), "Nothing happens while they are still downloading")

    assets.ready = true
    fixture.workshop.refreshSceneAssetsReadiness()
    fixture.workshop.settleApplyIntentsAwaitingAssets(bridge: fixture.store)
    await fixture.workshop.applyInFlight("c")?.value
    fixture.workshop.settleApplyIntentsAwaitingAssets(bridge: fixture.store)
    await fixture.workshop.applyInFlight("c")?.value

    XCTAssertEqual(fixture.bridge.assignments["primary"], "c")
    XCTAssertEqual(fixture.bridge.applications.filter { $0 == ("primary", "c") }.count, 1)
  }

  func testASceneWhoseSharedAssetsNeverArriveIsNotAppliedAndSaysWhy() async throws {
    let fixture = try await makeFixture()
    let scene = item("c", tags: ["Scene"])
    fixture.workshop.requestDownload(item: scene, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    let job = startSharedAssetsJob(fixture)
    try await arrive(scene, fixture)

    fixture.workshop.downloader.cancel(job)
    try await waitUntil { !job.isPending }
    fixture.workshop.settleApplyIntentsAwaitingAssets(bridge: fixture.store)

    XCTAssertFalse(fixture.workshop.appliesOnArrival("c"), "It does not wait for assets that are not coming")
    XCTAssertNotNil(fixture.workshop.applyNotes["c"])
    XCTAssertTrue(fixture.bridge.applications.isEmpty)
  }

  // MARK: Not applying what was never downloaded

  func testCancellingOrDismissingTheDownloadWithdrawsTheChoice() async throws {
    let fixture = try await makeFixture()
    for id in ["a", "c"] {
      fixture.workshop.requestDownload(item: item(id), rememberSession: false, bridge: fixture.store, applyTo: "primary")
      XCTAssertTrue(fixture.workshop.appliesOnArrival(id))
    }

    fixture.workshop.cancelDownload(id: "a")
    fixture.workshop.removeDownloadRequest(id: "c")

    XCTAssertFalse(fixture.workshop.appliesOnArrival("a"))
    XCTAssertFalse(fixture.workshop.appliesOnArrival("c"))
    try await arrive(item("c"), fixture)
    XCTAssertTrue(fixture.bridge.applications.isEmpty)
  }

  func testAFailedDownloadAppliesNothingAndAPlainRetryAsksForNothing() async throws {
    let fixture = try await makeFixture(runtime: "exit 1")
    try await makeSetupReady(fixture)
    fixture.workshop.username = "localtest"
    let wanted = item("222")

    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    let job = try XCTUnwrap(fixture.workshop.downloader.download(for: "222"))
    try await waitUntil { !job.isPending }

    XCTAssertNotNil(job.errorMessage, "The fixture runtime fails every download")
    XCTAssertTrue(fixture.bridge.applications.isEmpty)
    XCTAssertNil(fixture.workshop.applyInFlight("222"))

    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store)
    XCTAssertFalse(fixture.workshop.appliesOnArrival("222"), "Downloading again without asking to apply does not apply")
  }

  func testTheChoiceSurvivesWaitingForSetupAndIsStillThereWhenTheDownloadRuns() async throws {
    let fixture = try await makeFixture()
    let wanted = item("222")
    fixture.workshop.requestDownload(item: wanted, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    XCTAssertEqual(fixture.workshop.downloadRequests.map(\.id), ["222"], "SteamCMD is not set up yet, so it waits")

    try await makeSetupReady(fixture)
    XCTAssertTrue(
      fixture.workshop.continueDownload(
        id: "222", account: "localtest", rememberSession: false, includeResources: false, bridge: fixture.store))

    let job = try XCTUnwrap(fixture.workshop.downloader.download(for: "222"))
    XCTAssertTrue(job.isPending)
    XCTAssertTrue(fixture.workshop.appliesOnArrival("222"), "Answering a question on the way keeps what was asked")
  }

  /// A relaunch restores jobs paused and unapplied: the person did not see this one arrive.
  func testARelaunchRestoresTheDownloadsButNotTheChoiceToApplyThem() async throws {
    let fixture = try await makeFixture()
    let waiting = item("111")
    fixture.workshop.requestDownload(item: waiting, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    let requestFile = home.appendingPathComponent("Downloads/workshop-requests.json")
    try assertRecordsNoChoice(requestFile)

    try await makeSetupReady(fixture)
    fixture.workshop.username = "localtest"
    let running = item("222")
    fixture.workshop.requestDownload(item: running, rememberSession: false, bridge: fixture.store, applyTo: "primary")
    XCTAssertTrue(fixture.workshop.appliesOnArrival("222"))
    let queueFile = home.appendingPathComponent("Downloads/Workshop/queue.json")
    try await waitUntil { FileManager.default.fileExists(atPath: queueFile.path) }
    try assertRecordsNoChoice(queueFile)

    let relaunched = try await makeFixture()
    XCTAssertFalse(
      relaunched.workshop.downloadRequests.isEmpty && relaunched.workshop.downloader.downloads.isEmpty,
      "The downloads themselves are restored")
    for restored in [waiting, running] {
      XCTAssertFalse(relaunched.workshop.appliesOnArrival(restored.id))
      try await arrive(restored, relaunched)
    }
    XCTAssertTrue(relaunched.bridge.applications.isEmpty, "Nothing arrives and applies by itself after a relaunch")
  }

  // MARK: Fixture

  private struct Fixture {
    let workshop: WorkshopStore
    let store: BridgeStore
    let bridge: DisplayTransferTestBridge
    let executable: URL
  }

  private func item(_ id: String, tags: [String] = ["Video"], collectionSize: Int? = nil) -> WorkshopItem {
    WorkshopItem(
      id: id, title: "Fixture \(id)", creator: "Test", summary: "", previewURL: nil, tags: tags,
      size: 0, subscriptions: 0, collectionSize: collectionSize)
  }

  /// The runtime blocks on its PTY by default so a job keeps its real pending state; `runtime`
  /// replaces its script. Scene readiness is injected so this Mac's Steam install cannot change it.
  private func makeFixture(assets: AssetsProbe? = nil, runtime script: String = "IFS= read -r hold") async throws -> Fixture {
    let assets = assets ?? AssetsProbe()
    let runtime = home.appendingPathComponent("runtime", isDirectory: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    let executable = runtime.appendingPathComponent("steamcmd")
    try Data("#!/bin/sh\n\(script)\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let bridge = DisplayTransferTestBridge(noPointer: .init())
    try bridge.installProjects(in: ClientPaths.libraryURL)
    let store = BridgeStore(bridge: bridge)
    try await store.refreshAllAsync()
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(
        sessionDirectory: home.appendingPathComponent("SteamSession", isDirectory: true),
        runtimeProvider: ArrivalRuntimeProvider()),
      supportDirectory: home, defaults: defaults, runtimeProvider: ArrivalRuntimeProvider(),
      sceneAssetsAvailable: { _ in assets.ready }, now: { [clock] in clock.date })
    workshops.append(workshop)
    return Fixture(workshop: workshop, store: store, bridge: bridge, executable: executable)
  }

  private func makeSetupReady(_ fixture: Fixture) async throws {
    fixture.workshop.steamCMDSetup.selectExisting(at: fixture.executable)
    try await waitUntil { fixture.workshop.steamCMDSetup.selectedRuntime != nil }
  }

  /// A running download of Wallpaper Engine's shared assets, which a scene waits for.
  @discardableResult
  private func startSharedAssetsJob(_ fixture: Fixture) -> WorkshopDownload {
    fixture.workshop.downloader.installAssets(
      username: "localtest", executable: fixture.executable,
      destination: home.appendingPathComponent("SceneAssets", isDirectory: true), rememberSession: false
    ) {}
    return fixture.workshop.downloader.download(for: nil)!
  }

  /// The download finishing: the library is rescanned and any apply that was asked for runs.
  private func arrive(_ wanted: WorkshopItem, _ fixture: Fixture) async throws {
    try await fixture.workshop.finishInstall(item: wanted, replacing: false, bridge: fixture.store)
    await fixture.workshop.applyInFlight(wanted.id)?.value
  }

  /// The files a relaunch reads back say nothing about wanting a wallpaper applied.
  private func assertRecordsNoChoice(_ file: URL, line: UInt = #line) throws {
    let text = try String(contentsOf: file, encoding: .utf8).lowercased()
    for word in ["apply", "primary", "revision"] {
      XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) records the choice: \(word)", line: line)
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else {
        throw WorkshopFailure(message: "The download queue did not reach the expected state")
      }
      try await Task.sleep(for: .milliseconds(2))
    }
  }
}

/// The panel's side of the same flow: which requests may ask for an apply at all.
@MainActor
final class WorkshopDownloadAndApplyPanelTests: XCTestCase {
  private var root: URL!
  private var defaults: UserDefaults!
  private var store: BridgeStore!
  private var workshop: WorkshopStore!
  private var controller: WebPanelController!
  private let navigation = ControlPanelNavigation()

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-apply-\(UUID().uuidString)")
    defaults = try TemporaryDefaults.make(for: self).defaults
    store = BridgeStore(bridge: WallpaperBridge(noPointer: .init()))
    store.settingsSnapshot = BridgeSnapshotFixtures.settings(displays: [display("primary", mode: .standalone)])
    workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    workshop.selectedItem = WorkshopItem(
      id: "222", title: "Fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"],
      size: 0, subscriptions: 0)
    controller = WebPanelController(
      store: store, navigation: navigation, workshop: workshop, defaults: defaults,
      appLanguage: .english())
  }

  override func tearDown() async throws {
    controller.stop()
    await workshop.steamCMDSetup.shutdown()
    try? FileManager.default.removeItem(at: root)
  }

  private func display(_ id: String, mode: BridgeDisplayMode, enabled: Bool = true) -> BridgeDisplaySettingsRow {
    BridgeDisplaySettingsRow(
      displayId: id, title: id, enabled: enabled, mode: mode, mirrorTargets: [],
      selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
      muted: false, volume: 1)
  }

  func testDownloadAndApplyAsksForTheTargetDisplayAndTheSnapshotSaysSo() async throws {
    try await controller.perform("requestDownload", body: ["id": "222", "apply": true])

    XCTAssertTrue(workshop.appliesOnArrival("222"))
    let requests = try XCTUnwrap(controller.snapshot()["downloadRequests"] as? [[String: Any]])
    XCTAssertEqual(requests.first { $0["id"] as? String == "222" }?["applyOnArrival"] as? Bool, true)
  }

  func testAPlainRequestAsksForNoApply() async throws {
    try await controller.perform("requestDownload", body: ["id": "222"])
    XCTAssertFalse(workshop.appliesOnArrival("222"))
    try await controller.perform("requestDownload", body: ["id": "222", "apply": false])
    XCTAssertFalse(workshop.appliesOnArrival("222"))
    let requests = try XCTUnwrap(controller.snapshot()["downloadRequests"] as? [[String: Any]])
    XCTAssertEqual(requests.first?["applyOnArrival"] as? Bool, false)
  }

  func testATargetThatCannotShowAWallpaperOfItsOwnRefusesBeforeAnythingIsQueued() async throws {
    for target in [display("primary", mode: .mirror), display("primary", mode: .standalone, enabled: false)] {
      store.settingsSnapshot = BridgeSnapshotFixtures.settings(displays: [target])
      do {
        try await controller.perform("requestDownload", body: ["id": "222", "apply": true])
        XCTFail("a display that shows no wallpaper of its own has nothing to apply to")
      } catch {}
      XCTAssertTrue(workshop.downloadRequests.isEmpty)
      XCTAssertFalse(workshop.appliesOnArrival("222"))
    }
  }

  func testOnlyAWorkshopWallpaperCanAskToBeApplied() async throws {
    for body: [String: Any] in [
      ["id": NSNull(), "apply": true],
      ["id": "222", "apply": "yes"],
      ["id": "222", "apply": 1],
    ] {
      do {
        try await controller.perform("requestDownload", body: body)
        XCTFail("\(body) is not a request the panel sends")
      } catch {}
    }
    XCTAssertTrue(workshop.downloadRequests.isEmpty)
  }
}

/// A clock a test moves by hand.
private final class TestClock {
  var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class AssetsProbe {
  var ready = false
}

@MainActor
private final class Gate {
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

/// Lets other main-actor tasks run until `condition` holds; fails the test if it never does.
@MainActor
private func until(
  _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
) async {
  for _ in 0..<1_000 {
    if condition() { return }
    await Task.yield()
  }
  XCTFail("Condition never became true", file: file, line: line)
}

/// Replaces only Valve runtime verification; the session, PTY and queue stay real.
private struct ArrivalRuntimeProvider: SteamCMDRuntimeProviding {
  func resolve(executable: URL) throws -> SteamCMDRuntime {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw SteamCMDSetupIssue(kind: .invalidSelection, detail: "Missing fixture runtime")
    }
    return SteamCMDRuntime(rootURL: executable.deletingLastPathComponent(), executableURL: executable)
  }
  func prepare(executable: URL, staging: URL) async throws -> URL { executable }
  func validate(at root: URL) async throws {}
}
