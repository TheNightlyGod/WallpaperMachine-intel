import CoreGraphics
import Darwin
import Foundation
import XCTest

@testable import WallpaperMachine

final class LockScreenWallpaperServiceTests: XCTestCase {
  private var root: URL!
  private var defaults: UserDefaults!
  private var defaultsSuite: String!
  private var timers: [Timer] = []
  private let preference = "WallpaperMachineAnimateLockScreen"
  private var store: URL { root.appendingPathComponent("Index.plist") }
  private var journal: URL { root.appendingPathComponent("journal.plist") }
  private var exchange: URL { root.appendingPathComponent("Exchange") }
  private var project: URL { root.appendingPathComponent("Project") }
  private var home: URL { root.appendingPathComponent("Home") }
  private var previousHome: String?

  override func setUpWithError() throws {
    (defaults, defaultsSuite) = try TemporaryDefaults.make(for: self)
    // Keep the system-temp alias in play so asset publication cannot regress
    // to subtracting differently resolved absolute path spellings.
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lock-screen-service-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
    // The managed user-asset store lives under the support root; every test that
    // publishes one has to land in a throwaway home, not the user's own.
    previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    try Data(#"{"type":"video","title":"t","file":"a.mp4"}"#.utf8).write(
      to: project.appendingPathComponent("project.json"))
    try Data([0x00]).write(to: project.appendingPathComponent("a.mp4"))
    try write(fixture())
  }
  override func tearDownWithError() throws {
    timers.forEach { $0.invalidate() }
    timers.removeAll()
    try FileManager.default.removeItem(at: root)
    if let previousHome {
      setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
    } else {
      unsetenv("WALLPAPER_MACHINE_HOME")
    }
  }

  @MainActor
  private func scheduleMonitor(_ callback: @escaping @MainActor () -> Void) -> Timer {
    // A real Timer, deliberately never registered with a run loop.
    let timer = Timer(timeInterval: 2, repeats: true) { _ in
      MainActor.assumeIsolated { callback() }
    }
    timers.append(timer)
    return timer
  }

  private func choice(_ name: String) -> [String: Any] {
    [
      "Content": [
        "Choices": [["Provider": name, "Configuration": Data(name.utf8), "Files": [String]()]],
        "Shuffle": "$null",
      ], "LastSet": Date(timeIntervalSince1970: 1),
    ]
  }
  private func node(_ name: String) -> [String: Any] {
    [
      "Desktop": choice(name + "-desktop"), "Idle": choice(name + "-idle"), "Type": "individual",
      "Unrelated": name,
    ]
  }
  private func fixture() -> [String: Any] {
    [
      "AllSpacesAndDisplays": node("global"), "SystemDefault": node("system"),
      "Displays": ["one": node("display-one"), "two": node("display-two")],
      "Spaces": [
        "space-a": [
          "Default": node("default-a"),
          "Displays": ["one": node("space-one"), "two": node("space-two")],
        ]
      ],
      "Unrelated": "keep",
    ]
  }
  private func write(_ value: [String: Any]) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(
      to: store, options: .atomic)
  }

  private func scene(propertiesJSON: String? = nil) -> BridgeLockScreenScene {
    BridgeLockScreenScene(
      displayId: CGMainDisplayID(), wallpaperId: "2001", title: "t",
      projectPath: project.appendingPathComponent("project.json").path,
      assetsPath: project.path, fps: 30, scalingMode: .fill, scalingFactor: 1,
      framing: .centered, propertiesJson: propertiesJSON, paused: false)
  }

  /// The managed store as the app writes it, isolated per test through
  /// `WALLPAPER_MACHINE_HOME`.
  @discardableResult
  private func writeManagedAsset(
    propertyId: String, fileName: String, bytes: String, kind: String = "file"
  ) throws -> URL {
    let store = ClientPaths.userAssetsURL.appendingPathComponent("2001", isDirectory: true)
    let digest = "d" + String(bytes.hashValue, radix: 16, uppercase: false)
    let directory = store.appendingPathComponent("\(propertyId)/\(digest)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(fileName)
    try Data(bytes.utf8).write(to: file)
    let manifest = """
      {"version":1,"wallpaperId":"2001","properties":{"\(propertyId)":{"kind":"\(kind)",\
      "sourcePath":"/Users/someone/\(fileName)","truncated":false,"migratedLegacyPaths":[],\
      "assets":[{"assetId":"\(digest)","fileName":"\(fileName)",\
      "sourcePath":"/Users/someone/\(fileName)","size":\(bytes.utf8.count),\
      "modified":"2024-01-01T00:00:00Z","digest":"\(digest)"}]}}}
      """
    try Data(manifest.utf8).write(to: store.appendingPathComponent("manifest.json"))
    return file
  }

  @MainActor
  private func waitFor(
    _ description: String, timeout: TimeInterval = 10,
    condition: @MainActor () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for \(description)")
  }

  /// Answers the extension's readiness files like the real lock-screen renderer, as process
  /// `processID` when given.
  private func readinessResponder(held: String? = nil, processID: Int32? = nil) -> Task<Void, Never> {
    let exchange = self.exchange
    return Task.detached {
      while !Task.isCancelled {
        let file = exchange.appendingPathComponent(LockScreenConfiguration.fileName)
        if let data = try? Data(contentsOf: file),
          let configuration = try? JSONDecoder().decode(LockScreenConfiguration.self, from: data)
        {
          for scene in configuration.scenes {
            let readiness = LockScreenReadiness(
              revision: configuration.revision, displayID: scene.displayID, error: nil, held: held,
              processID: processID)
            try? JSONEncoder().encode(readiness).write(
              to: exchange.appendingPathComponent("ready-\(scene.displayID).json"),
              options: .atomic)
          }
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  /// A scene the extension holds because Native Metal is the only renderer and could not draw it is not an
  /// activation failure: the surface exists and shows its picture, so the lock screen stays on it, and the
  /// extension's own words about why ride on the status instead of an error that would restore the original.
  @MainActor
  func testAHeldSceneKeepsTheLockScreenOnAndShowsTheExtensionsNote() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    let service = LockScreenWallpaperService(
      prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [self.scene()] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    let note = "Native Metal can't draw this wallpaper: it uses something Native Metal can't draw."
    let responder = readinessResponder(held: note)
    defer { responder.cancel() }
    service.setEnabled(true)
    await waitFor("the lock screen to enable on the held scene") { service.isEnabled }
    XCTAssertNil(service.errorMessage, "a held scene is not an activation failure")
    XCTAssertTrue(service.status.hasPrefix("Enabled for 1 display"), service.status)
    XCTAssertTrue(service.status.hasSuffix(note), service.status)
    XCTAssertTrue(service.ownsDesktopProvider, "the lock screen stays on the held surface")
  }

  @MainActor
  func testActivationFailureAlwaysHandsDesktopBackToPosterProvider() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [self.scene()] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal,
      reload: { throw LockScreenWallpaperFailure(message: "agent missing") }),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    var before = 0
    var after = 0
    service.beforeActivation = { before += 1 }
    service.afterDeactivation = { after += 1 }
    service.setEnabled(true)
    await waitFor("the failed activation to settle") { !service.isBusy }
    XCTAssertEqual(before, 1)
    XCTAssertEqual(after, 1)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertFalse(service.isEnabled)
    XCTAssertNotNil(service.errorMessage)
  }

  @MainActor
  func testDisableWithFailedRestorationStillHandsDesktopBack() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    var failReload = false
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [self.scene()] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal,
      reload: {
        if failReload { throw LockScreenWallpaperFailure(message: "agent missing") }
      }),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    var before = 0
    var after = 0
    service.beforeActivation = { before += 1 }
    service.afterDeactivation = { after += 1 }
    let responder = readinessResponder()
    defer { responder.cancel() }
    service.setEnabled(true)
    await waitFor("the lock screen provider to enable") { service.isEnabled }
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.ownsDesktopProvider)
    XCTAssertTrue(service.claimsDesktopPicture)
    XCTAssertTrue(service.locksDesktopPictureChoice)
    XCTAssertEqual(before, 1)
    failReload = true
    service.setEnabled(false)
    await waitFor("deactivation to finish") { !service.isBusy }
    XCTAssertEqual(after, 1)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertFalse(service.claimsDesktopPicture, "handed back, so the posters may start again")
    XCTAssertFalse(service.locksDesktopPictureChoice)
  }

  /// Any snapshot refreshes the service, so refreshes arrive while the first frame is awaited.
  /// They must not report the lock screen enabled before the extension renders, nor publish
  /// the activation again; once a frame arrives it is enabled and the choice is saved.
  @MainActor
  func testRefreshWhileAwaitingTheFirstFrameNeitherClaimsEnabledNorRepublishes() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [self.scene()] },
    selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    service.beforeActivation = {}
    service.afterDeactivation = {}
    let file = exchange.appendingPathComponent(LockScreenConfiguration.fileName)
    func publishedRevision() throws -> String {
      try JSONDecoder().decode(LockScreenConfiguration.self, from: Data(contentsOf: file)).revision
    }
    service.setEnabled(true)
    await waitFor("the activation to be published") { FileManager.default.fileExists(atPath: file.path) }
    let revision = try publishedRevision()
    service.refresh()
    try await Task.sleep(for: .milliseconds(200))
    service.refresh()
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertFalse(service.isEnabled, "nothing has rendered yet")
    XCTAssertTrue(service.isBusy)
    XCTAssertEqual(try publishedRevision(), revision, "the activation a refresh interrupted is not published again")
    XCTAssertFalse(defaults.bool(forKey: preference))
    let responder = readinessResponder()
    defer { responder.cancel() }
    await waitFor("the lock screen to enable") { service.isEnabled && !service.isBusy }
    XCTAssertTrue(defaults.bool(forKey: preference))
  }

  @MainActor
  func testNoAppliedWallpaperReleasesDesktopProvider() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    var scenes = [scene()]
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { scenes },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    var after = 0
    service.beforeActivation = {}
    service.afterDeactivation = { after += 1 }
    let responder = readinessResponder()
    defer { responder.cancel() }
    service.setEnabled(true)
    await waitFor("the lock screen provider to enable") { service.isEnabled }
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.ownsDesktopProvider)
    scenes = []
    service.refresh()
    await waitFor("the provider release to settle") { !service.isBusy }
    XCTAssertEqual(after, 1)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertNil(service.errorMessage)
  }

  @MainActor
  func testDisplayTopologyChangesDoNotClearSurvivingLockScreens() async throws {
    var builtIn = scene()
    builtIn.displayId = 1
    var external = builtIn
    external.displayId = 2
    // The external display is first (primary); display identity is not array order.
    var records = [external, builtIn]
    var publications: [LockScreenConfiguration] = []
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { records },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { [1: "one", 2: "two"][$0] },
    persistConfiguration: { url, bytes in
      try bytes.write(to: url, options: .atomic)
      publications.append(try JSONDecoder().decode(
        LockScreenConfiguration.self, from: Data(contentsOf: url)))
    })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("both lock screens ready") { service.isEnabled && !service.isBusy }

    for next in [[builtIn], [external, builtIn], [external]] {
      publications.removeAll()
      records = next
      service.refresh()
      await waitFor("display topology publication") { service.isEnabled && !service.isBusy }
      let expected = Set(next.map(\.displayId))
      XCTAssertEqual(Set(try XCTUnwrap(publications.last).scenes.map(\.displayID)), expected)
      for publication in publications {
        XCTAssertTrue(expected.isSubset(of: Set(publication.scenes.map(\.displayID))),
          "A surviving display must never receive an empty manifest while another display changes")
      }
    }

    publications.removeAll()
    records = [builtIn, external]
    service.refresh()
    await waitFor("both displays return") { service.isEnabled && !service.isBusy }
    let stable = try XCTUnwrap(publications.last)
    publications.removeAll()
    records = [external, builtIn]
    service.refresh()
    await waitFor("primary ordering change") { !service.isBusy }
    XCTAssertTrue(publications.isEmpty, "Reordering displays must not republish their wallpapers")
    let onDisk = try JSONDecoder().decode(LockScreenConfiguration.self,
      from: Data(contentsOf: exchange.appendingPathComponent(LockScreenConfiguration.fileName)))
    XCTAssertEqual(onDisk, stable)

    service.setEnabled(false)
    await waitFor("explicit disable clears every display") { !service.isBusy }
    XCTAssertEqual(try XCTUnwrap(publications.last).scenes, [])
    XCTAssertFalse(service.ownsDesktopProvider)
  }

  @MainActor
  func testWakeDisplayLookupGapPreservesCommittedWallpapersAndRecovers() async throws {
    var builtIn = scene()
    builtIn.displayId = 1
    var external = builtIn
    external.displayId = 2
    var records = [external, builtIn]
    var online: Set<UInt32> = [1, 2]
    var reloads = 0
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { records },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 }),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { online.contains($0) ? [1: "one", 2: "two"][$0] : nil })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("external-primary lock screens ready") { service.isEnabled && !service.isBusy }
    let manifest = exchange.appendingPathComponent(LockScreenConfiguration.fileName)
    let committed = try Data(contentsOf: manifest)
    let selected = try Data(contentsOf: store)
    let initialReloads = reloads

    // Core Graphics can temporarily report either or both screens offline
    // before the bridge publishes the settled topology.
    for visible: Set<UInt32> in [[2], [], [1, 2]] {
      online = visible
      service.refresh()
      await waitFor("wake lookup settles") { !service.isBusy }
      XCTAssertTrue(service.isEnabled)
      XCTAssertTrue(service.ownsDesktopProvider)
      XCTAssertNil(service.errorMessage)
      XCTAssertEqual(try Data(contentsOf: manifest), committed)
      XCTAssertEqual(try Data(contentsOf: store), selected)
      XCTAssertEqual(reloads, initialReloads, "A lookup gap must not restart WallpaperAgent")
      XCTAssertTrue(timers.last?.isValid == true, "The existing monitor must keep checking topology")
    }

    online = [2]
    records = [external]
    service.refresh()
    await waitFor("settled external-only topology") { service.isEnabled && !service.isBusy }
    let configuration = try JSONDecoder().decode(LockScreenConfiguration.self,
      from: Data(contentsOf: manifest))
    XCTAssertEqual(configuration.scenes.map(\.displayID), [2])

    // A real removal, unlike an offline lookup, must still release ownership.
    records = []
    service.refresh()
    await waitFor("last wallpaper removed") { !service.isBusy }
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertEqual(try JSONDecoder().decode(LockScreenConfiguration.self,
      from: Data(contentsOf: manifest)).scenes, [])
  }

  @MainActor
  func testMonitorTimerLetsTheSystemCoalesceItsWakeups() {
    let timer = LockScreenWallpaperService.scheduleMonitorTimer {}
    defer { timer.invalidate() }
    XCTAssertEqual(timer.timeInterval, 2, "the cadence stays two seconds")
    XCTAssertTrue(timer.isValid)
    XCTAssertGreaterThanOrEqual(timer.tolerance, timer.timeInterval / 2)
  }

  @MainActor
  func testMonitorExistsOnlyWhileRequestedAndDoesNotRescheduleWhileBusy() async throws {
    var calls = 0
    var pending: CheckedContinuation<[BridgeLockScreenScene], Never>?
    var suspend = false
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: {
      calls += 1
      if suspend { return await withCheckedContinuation { pending = $0 } }
      return []
    },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    XCTAssertTrue(timers.isEmpty)
    service.refresh()
    await waitFor("off refresh") { !service.isBusy }
    XCTAssertEqual(calls, 0)
    XCTAssertTrue(timers.isEmpty)
    service.setEnabled(true)
    await waitFor("requested empty scene refresh") { !service.isBusy }
    XCTAssertTrue(service.isRequested)
    XCTAssertFalse(service.isEnabled)
    XCTAssertEqual(timers.count, 1, "Empty scenes still need monitoring for a future wallpaper")
    let timer = try XCTUnwrap(timers.first)
    XCTAssertTrue(timer.isValid)
    suspend = true
    timer.fire()
    await waitFor("suspended scene request") { pending != nil }
    let busyCalls = calls
    timer.fire()
    XCTAssertEqual(calls, busyCalls)
    XCTAssertEqual(timers.count, 1)
    suspend = false
    pending?.resume(returning: [])
    pending = nil
    await waitFor("busy refresh") { !service.isBusy }
    service.refresh()
    await waitFor("explicit refresh") { !service.isBusy }
    XCTAssertEqual(timers.count, 1)
    service.setEnabled(false)
    XCTAssertFalse(timer.isValid, "Disable must stop monitoring before asynchronous restoration")
    await waitFor("disable") { !service.isBusy }
    XCTAssertFalse(defaults.bool(forKey: preference))
    service.setEnabled(true)
    await waitFor("reenable empty scenes") { !service.isBusy }
    XCTAssertEqual(timers.count, 2)
    try await service.shutdown()
    XCTAssertTrue(timers.allSatisfy { !$0.isValid })
    service.setEnabled(true)
    XCTAssertEqual(timers.count, 2)
  }

  @MainActor
  func testPersistedRequestStartsOneMonitorAndErrorsRequireExplicitRetry() async throws {
    defaults.set(true, forKey: preference)
    var fail = true
    var calls = 0
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: {
      calls += 1
      if fail { throw LockScreenWallpaperFailure(message: "scene lookup failed") }
      return []
    },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    XCTAssertTrue(service.isRequested)
    XCTAssertEqual(timers.count, 1)
    let first = try XCTUnwrap(timers.first)
    first.fire()
    await waitFor("failed polling refresh") { !service.isBusy }
    XCTAssertNotNil(service.errorMessage)
    XCTAssertFalse(first.isValid)
    XCTAssertEqual(calls, 1)
    fail = false
    service.refresh()
    await waitFor("explicit retry") { !service.isBusy }
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(timers.count, 2)
    XCTAssertTrue(try XCTUnwrap(timers.last).isValid)
    try await service.shutdown()
    XCTAssertTrue(timers.allSatisfy { !$0.isValid })
  }

  /// The poster sync stays away from the desktop picture exactly while the lock screen is asked
  /// for and able to take it; the Settings switch stays locked from the ask until the handback.
  @MainActor
  func testTheLockScreenClaimsTheDesktopPictureOnlyWhileItCanTakeIt() throws {
    func makeService() -> LockScreenWallpaperService {
      LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [] },
        selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
        exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    }
    let off = makeService()
    XCTAssertFalse(off.claimsDesktopPicture, "Off, the posters keep the desktop")
    XCTAssertFalse(off.locksDesktopPictureChoice)
    try off.start()
    XCTAssertFalse(off.claimsDesktopPicture)
    XCTAssertFalse(off.locksDesktopPictureChoice)

    defaults.set(true, forKey: preference)
    let requested = makeService()
    try requested.start()
    XCTAssertTrue(requested.isRequested)
    XCTAssertTrue(requested.claimsDesktopPicture, "Asked for and able to start: posters wait for it")
    XCTAssertTrue(requested.locksDesktopPictureChoice)

    try Data("invalid journal".utf8).write(to: journal)
    let failed = makeService()
    XCTAssertThrowsError(try failed.start())
    XCTAssertNotNil(failed.errorMessage)
    XCTAssertFalse(failed.claimsDesktopPicture, "A lock screen that could not start leaves the desktop to the posters")
    XCTAssertTrue(failed.locksDesktopPictureChoice, "but the choice stays locked until it is turned off")
  }

  @MainActor
  func testRecoveryFailureDoesNotStartMonitorAndRefreshCanRecover() async throws {
    defaults.set(true, forKey: preference)
    try Data("invalid journal".utf8).write(to: journal)
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    XCTAssertThrowsError(try service.start())
    XCTAssertTrue(timers.isEmpty)
    XCTAssertNotNil(service.errorMessage)
    try FileManager.default.removeItem(at: journal)
    service.refresh()
    await waitFor("successful recovery retry") { !service.isBusy }
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(timers.count, 1)
    try await service.shutdown()
  }

  @MainActor
  func testDisableCancelsReadinessBeforeEnabledPreferenceCanCommit() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [self.scene()] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    service.setEnabled(true)
    await waitFor("published scene awaiting readiness") {
      service.ownsDesktopProvider && FileManager.default.fileExists(atPath: self.journal.path)
    }
    XCTAssertTrue(service.isBusy)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(defaults.bool(forKey: preference))
    let timer = try XCTUnwrap(timers.last)
    service.setEnabled(false)
    XCTAssertFalse(timer.isValid)
    try answerPublishedReadiness()
    await waitFor("cancelled readiness and restoration") { !service.isBusy }
    XCTAssertFalse(service.isRequested)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertFalse(defaults.bool(forKey: preference))
    XCTAssertNil(service.errorMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testNewGenerationCannotCommitPreviousReadiness() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    var records = [scene()]
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { records },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    service.setEnabled(true)
    await waitFor("first generation awaiting readiness") {
      service.ownsDesktopProvider && FileManager.default.fileExists(atPath: self.journal.path)
    }
    records = []
    service.refresh()
    try answerPublishedReadiness()
    await waitFor("replacement generation") { !service.isBusy }
    XCTAssertTrue(service.isRequested)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertFalse(defaults.bool(forKey: preference))
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(timers.count, 1)
    try await service.shutdown()
  }

  @MainActor
  func testShutdownStopsMonitorBeforeWaitingAndKeepsItStoppedOnFailure() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    var failReload = false
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [self.scene()] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal,
      reload: {
        if failReload { throw LockScreenWallpaperFailure(message: "restoration failed") }
      }),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    service.setEnabled(true)
    await waitFor("activation waiting for readiness") {
      service.ownsDesktopProvider && FileManager.default.fileExists(atPath: self.journal.path)
    }
    let timer = try XCTUnwrap(timers.last)
    failReload = true
    let shutdown = Task { try await service.shutdown() }
    await waitFor("shutdown monitor cancellation") { !timer.isValid }
    do {
      try await shutdown.value
      XCTFail("Expected failed restoration")
    } catch {
      XCTAssertNotNil(service.errorMessage)
    }
    XCTAssertFalse(timer.isValid)
    XCTAssertFalse(service.isBusy)
    XCTAssertEqual(timers.count, 1)
    XCTAssertFalse(defaults.bool(forKey: preference))
    failReload = false
    service.setEnabled(false)
    await waitFor("explicit restoration retry") { !service.isBusy }
    XCTAssertNil(service.errorMessage)
    XCTAssertTrue(timers.allSatisfy { !$0.isValid })
  }

  @MainActor
  func testShutdownRestoresNativeChoicesBeforeWaitingForDesktopRestoration() async throws {
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    service.setScreenSaverEnabled(true)
    await waitFor("both native modes enabled") { service.isEnabled && service.screenSaverEnabled }
    var pending: CheckedContinuation<Void, Never>?
    var finished = false
    let shutdown = Task {
      try await service.shutdown {
        XCTAssertEqual(try self.selectedProvider("Desktop"), "display-one-desktop")
        XCTAssertEqual(try self.selectedProvider("Idle"), "display-one-idle")
        XCTAssertFalse(service.ownsDesktopProvider)
        await withCheckedContinuation { pending = $0 }
      }
      finished = true
    }
    await waitFor("desktop restoration pending") { pending != nil }
    XCTAssertFalse(finished, "Do not exit between native and PNG-original restoration")
    XCTAssertTrue(timers.allSatisfy { !$0.isValid })
    pending?.resume()
    try await shutdown.value
    XCTAssertTrue(finished)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.screenSaverEnabled)
  }

  @MainActor
  func testFailedDesktopRestorationLeavesQuitCancelledAndAllowsExplicitRetry() async throws {
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    do {
      try await service.shutdown {
        throw CocoaError(.fileWriteNoPermission)
      }
      XCTFail("A failed desktop restoration must cancel quit")
    } catch {
      XCTAssertNotNil(service.errorMessage)
    }
    // A cancelled quit must not leave the native service permanently stopping.
    service.setEnabled(true)
    await waitFor("retry after cancelled quit") { !service.isBusy }
    XCTAssertTrue(service.isRequested)
    XCTAssertNil(service.errorMessage)
    var restored = false
    try await service.shutdown { restored = true }
    XCTAssertTrue(restored)
  }

  /// An unchanged monitor tick must not disable or republish. After a lookup gap,
  /// that same timer — not another scene or preference change — retries the
  /// committed mapping once the display UUID resolves.
  private func publishedRevision() throws -> String {
    let data = try Data(contentsOf: exchange.appendingPathComponent(LockScreenConfiguration.fileName))
    return try JSONDecoder().decode(LockScreenConfiguration.self, from: data).revision
  }

  private func storeOwnsDisplayOne() throws -> Bool {
    let root = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: store), format: nil)
        as? [String: Any])
    let node = (root["Displays"] as? [String: Any])?["one"] as? [String: Any]
    let choices = ((node?["Desktop"] as? [String: Any])?["Content"] as? [String: Any])?["Choices"]
      as? [[String: Any]]
    return choices?.first?["Provider"] as? String == LockScreenConfiguration.extensionIdentifier
  }

  /// macOS keeps a lock-screen renderer whose process died as its wallpaper and never loads it
  /// again, so the lock screen stays black. The app publishes again, which makes it reload.
  @MainActor
  func testRendererExitRepublishesSoMacOSLoadsItAgain() async throws {
    var record = scene()
    record.displayId = 1
    var reloads = 0
    var watches: [Int32: @MainActor () -> Void] = [:]
    var cancelled: [Int32] = []
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: { reloads += 1 }),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { [1: "one"][$0] },
      watchProcessExit: { pid, exited in
        watches[pid] = exited
        return { cancelled.append(pid) }
      })
    var responder = readinessResponder(processID: 999_901)
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("lock screen ready") { service.isEnabled && !service.isBusy }
    let first = try publishedRevision()
    let firstReloads = reloads
    let exited = try XCTUnwrap(watches[999_901], "The process that drew the frame is watched")

    responder.cancel()
    responder = readinessResponder(processID: 999_902)
    exited()
    await waitFor("a new publication") {
      !service.isBusy && (try? self.publishedRevision()) != first && watches[999_902] != nil
    }
    XCTAssertTrue(service.isEnabled)
    XCTAssertNil(service.errorMessage)
    XCTAssertGreaterThan(reloads, firstReloads, "WallpaperAgent is made to load the renderer again")
    XCTAssertTrue(try storeOwnsDisplayOne())
    XCTAssertEqual(cancelled, [999_901])
    try await service.shutdown()
    XCTAssertEqual(cancelled, [999_901, 999_902])
  }

  /// A renderer that keeps dying is not restarted for ever: past the limit the lock screen is
  /// handed back to macOS with an error and a Retry, as for any other failure.
  @MainActor
  func testRendererThatKeepsExitingRestoresTheSystemWallpaperWithAnError() async throws {
    var record = scene()
    record.displayId = 1
    var watches: [Int32: @MainActor () -> Void] = [:]
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { [1: "one"][$0] },
      watchProcessExit: { pid, exited in
        watches[pid] = exited
        return {}
      })
    var pid: Int32 = 999_910
    var responder = readinessResponder(processID: pid)
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("lock screen ready") { service.isEnabled && !service.isBusy }
    for recovery in 1...LockScreenWallpaperService.rendererRecoveryLimit {
      let exited = try XCTUnwrap(watches[pid])
      pid += 1
      responder.cancel()
      responder = readinessResponder(processID: pid)
      exited()
      await waitFor("recovery \(recovery)") { !service.isBusy && watches[pid] != nil }
      XCTAssertTrue(service.isEnabled)
      XCTAssertNil(service.errorMessage)
    }
    try XCTUnwrap(watches[pid])()
    await waitFor("the failure") { !service.isBusy && service.errorMessage != nil }
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(try storeOwnsDisplayOne())
  }

  /// Core Graphics lists no sleeping display, and an external one can drop off while it sleeps.
  /// While the Mac is locked or dark that keeps the committed lock screen; awake, it applies.
  @MainActor
  func testDisplaysThatLeaveWhileAwayKeepTheirLockScreen() async throws {
    var record = scene()
    record.displayId = 1
    var records = [record]
    var away = true
    var sceneReads = 0
    var publications = 0
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: {
      sceneReads += 1
      return records
    },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { [1: "one"][$0] },
      persistConfiguration: { url, bytes in
        try bytes.write(to: url, options: .atomic)
        publications += 1
      },
      displaysAreAway: { away })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("lock screen ready") { service.isEnabled && !service.isBusy }
    let selected = try Data(contentsOf: store)
    let published = publications
    let timer = try XCTUnwrap(timers.last)

    records = []
    let reads = sceneReads
    timer.fire()
    await waitFor("a tick with no displays") { sceneReads > reads && !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.ownsDesktopProvider)
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(publications, published)
    XCTAssertEqual(try Data(contentsOf: store), selected)

    away = false
    timer.fire()
    await waitFor("the departure to apply") { !service.isBusy && !service.isEnabled }
    XCTAssertFalse(try storeOwnsDisplayOne())
    XCTAssertNil(service.errorMessage)
  }

  /// WallpaperAgent between its restart and relaunch fails one attempt; the committed selection
  /// stays on the lock screen and the next monitor tick publishes again.
  @MainActor
  func testTransientFailureKeepsTheCommittedSelectionAndRetries() async throws {
    var record = scene()
    record.displayId = 1
    var failReload = false
    var reloads = 0
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal,
        reload: {
          reloads += 1
          if failReload {
            throw LockScreenWallpaperFailure(message: "agent relaunching", reason: .transient)
          }
        }),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { [1: "one"][$0] })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("lock screen ready") { service.isEnabled && !service.isBusy }
    let timer = try XCTUnwrap(timers.last)

    failReload = true
    record.propertiesJson = #"{"speed":2}"#
    let failedReloads = reloads
    timer.fire()
    await waitFor("the failed publication") { !service.isBusy && reloads > failedReloads }
    XCTAssertNil(service.errorMessage)
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.ownsDesktopProvider)
    XCTAssertTrue(try storeOwnsDisplayOne(), "The lock screen is not handed back to macOS")
    XCTAssertTrue(timer.isValid)

    failReload = false
    let failed = try publishedRevision()
    timer.fire()
    await waitFor("the retry") { !service.isBusy && (try? self.publishedRevision()) != failed }
    XCTAssertNil(service.errorMessage)
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(try storeOwnsDisplayOne())
  }

  /// Retries back off and end: after the last one the failure is reported and the system
  /// wallpaper restored, as before.
  @MainActor
  func testTransientFailuresBackOffAndThenRestoreWithAnError() async throws {
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { [1: "one"][$0] }, runningExtensionBundles: { [] }, readinessTimeout: 1)
    let responder = readinessResponder()
    try service.start()
    service.setEnabled(true)
    await waitFor("lock screen ready") { service.isEnabled && !service.isBusy }
    let timer = try XCTUnwrap(timers.last)

    // No renderer answers from here on, so every publication times out.
    responder.cancel()
    try await Task.sleep(for: .milliseconds(100))
    record.propertiesJson = #"{"speed":2}"#
    var attempts = 0
    var revision = try publishedRevision()
    func tick() async {
      timer.fire()
      await waitFor("a tick") { !service.isBusy }
      if let next = try? publishedRevision(), next != revision {
        attempts += 1
        revision = next
      }
    }
    // The first attempt and its retries after 1, 2, 4, 8 and 16 ticks.
    let retries = LockScreenWallpaperService.transientRetrySkips
    for _ in 0..<(1 + retries.dropLast().reduce(0) { $0 + $1 + 1 }) {
      await tick()
      XCTAssertNil(service.errorMessage)
      XCTAssertTrue(try storeOwnsDisplayOne())
    }
    XCTAssertEqual(attempts, retries.count)
    for _ in 0..<(retries.last ?? 0) { await tick() }
    XCTAssertNil(service.errorMessage, "The last retry waits out its back-off")
    await tick()
    XCTAssertNotNil(service.errorMessage)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(try storeOwnsDisplayOne())
  }

  @MainActor
  func testUnchangedMonitorTickDoesNotRepublishAndResolvedUUIDRecovers() async throws {
    var builtIn = scene()
    builtIn.displayId = 1
    var online: Set<UInt32> = [1]
    var publications = 0
    var reloads = 0
    var sceneReads = 0
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: {
      sceneReads += 1
      return [builtIn]
    },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 }),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { online.contains($0) ? [1: "one"][$0] : nil },
    persistConfiguration: { url, bytes in
      try bytes.write(to: url, options: .atomic)
      publications += 1
    })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("lock screen ready") { service.isEnabled && !service.isBusy }
    let manifest = exchange.appendingPathComponent(LockScreenConfiguration.fileName)
    let committed = try Data(contentsOf: manifest)
    let publishedCount = publications
    let reloadCount = reloads
    let timer = try XCTUnwrap(timers.last)
    XCTAssertTrue(timer.isValid)

    let unchangedReads = sceneReads
    timer.fire()
    await waitFor("unchanged monitor tick") { sceneReads > unchangedReads && !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.ownsDesktopProvider)
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(publications, publishedCount)
    XCTAssertEqual(reloads, reloadCount)
    XCTAssertEqual(try Data(contentsOf: manifest), committed)
    let enabledStatus = service.status
    let selected = try Data(contentsOf: store)

    online = []
    timer.fire()
    await waitFor("pending topology") { !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(publications, publishedCount)
    XCTAssertEqual(try Data(contentsOf: manifest), committed)
    XCTAssertEqual(try Data(contentsOf: store), selected)
    XCTAssertTrue(timer.isValid)

    online = [1]
    timer.fire()
    await waitFor("monitor recovery") { !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.ownsDesktopProvider)
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(publications, publishedCount, "Resolving the same mapping must not republish")
    XCTAssertEqual(reloads, reloadCount, "Recovery must not restart WallpaperAgent")
    XCTAssertEqual(try Data(contentsOf: manifest), committed)
    XCTAssertEqual(try Data(contentsOf: store), selected)
    XCTAssertEqual(service.status, enabledStatus)
    XCTAssertEqual(timers.count, 1)
  }

  @MainActor
  func testContentRefreshAtTheSamePathRebuildsPublishedWebBytesOnlyWhenChanged() async throws {
    try Data(#"{"type":"web","title":"t","file":"index.html"}"#.utf8).write(
      to: project.appendingPathComponent("project.json"))
    try Data("<html>first</html>".utf8).write(to: project.appendingPathComponent("index.html"))
    var record = scene()
    record.displayId = 1
    var contentRevision: UInt64 = 0
    var publications = 0
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" }, persistConfiguration: { url, bytes in
        try bytes.write(to: url, options: .atomic)
        publications += 1
      }, contentRevision: { contentRevision })
    try service.start()
    service.setScreenSaverEnabled(true)
    await waitFor("initial web publication") { !service.isBusy }
    let initial = try publishedConfiguration()
    let count = publications
    contentRevision += 1
    service.refresh()
    await waitFor("unchanged source check") { !service.isBusy }
    XCTAssertEqual(publications, count)
    XCTAssertEqual(try publishedConfiguration(), initial)
    try Data("<html>replacement content</html>".utf8).write(
      to: project.appendingPathComponent("index.html"), options: .atomic)
    contentRevision += 1
    service.refresh()
    await waitFor("changed source publication") { !service.isBusy }
    let changed = try publishedConfiguration()
    XCTAssertNotEqual(changed.scenes.first?.projectPath, initial.scenes.first?.projectPath)
    let published = exchange.appendingPathComponent(try XCTUnwrap(changed.scenes.first?.projectPath))
      .deletingLastPathComponent().appendingPathComponent("index.html")
    XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "<html>replacement content</html>")
    service.setScreenSaverEnabled(false)
    await waitFor("web publication stopped") { !service.isBusy }
  }

  /// A compatibility failure still rolls back to disabled. A later lookup gap must
  /// not erase that error or restart the monitor, and must not touch the selection.
  @MainActor
  func testPendingTopologyKeepsEarlierCompatibilityError() async throws {
    var builtIn = scene()
    builtIn.displayId = 1
    var online: Set<UInt32> = [1]
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [builtIn] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { online.contains($0) ? [1: "one"][$0] : nil })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("lock screen ready") { service.isEnabled && !service.isBusy }
    try setGlobalWallpaperLinked()
    builtIn.fps = 24
    service.refresh()
    await waitFor("compatibility rollback") { !service.isBusy }
    let manifest = exchange.appendingPathComponent(LockScreenConfiguration.fileName)
    let error = try XCTUnwrap(service.errorMessage)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    let errorStatus = service.status
    XCTAssertEqual(
      try JSONDecoder().decode(LockScreenConfiguration.self, from: Data(contentsOf: manifest)).scenes,
      [])
    let timer = try XCTUnwrap(timers.last)
    XCTAssertFalse(timer.isValid)
    let failedStore = try Data(contentsOf: store)
    let failedManifest = try Data(contentsOf: manifest)
    let timerCount = timers.count

    online = []
    service.refresh()
    await waitFor("pending retry") { !service.isBusy }
    XCTAssertEqual(service.errorMessage, error)
    XCTAssertEqual(service.status, errorStatus)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertEqual(try Data(contentsOf: store), failedStore)
    XCTAssertEqual(try Data(contentsOf: manifest), failedManifest)
    XCTAssertEqual(timers.count, timerCount)
    XCTAssertFalse(timer.isValid, "A preserved error must not restart the monitor")
  }

  /// Replacing a committed mapping keeps isEnabled until the new frame is
  /// acknowledged. A readiness failure still rolls back to disabled.
  @MainActor
  func testReplacementStagingKeepsEnabledUntilReadinessFailureRollsBack() async throws {
    var builtIn = scene()
    builtIn.displayId = 1
    var external = builtIn
    external.displayId = 2
    var records = [builtIn]
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { records },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { [1: "one", 2: "two"][$0] })
    try service.start()
    service.setEnabled(true)
    await waitFor("first publication") {
      service.ownsDesktopProvider && FileManager.default.fileExists(atPath: self.journal.path)
    }
    try answerPublishedReadiness()
    await waitFor("first mapping enabled") { service.isEnabled && !service.isBusy }
    let manifest = exchange.appendingPathComponent(LockScreenConfiguration.fileName)

    records = [builtIn, external]
    service.refresh()
    await waitFor("replacement published") {
      guard service.isBusy else { return false }
      guard let data = try? Data(contentsOf: manifest),
        let configuration = try? JSONDecoder().decode(LockScreenConfiguration.self, from: data)
      else { return false }
      return configuration.scenes.count == 2
    }
    XCTAssertTrue(service.isEnabled, "Staging must not clear the committed enabled state")
    XCTAssertTrue(service.ownsDesktopProvider)
    try failPublishedReadiness("renderer failed")
    await waitFor("readiness rollback") { !service.isBusy }
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertEqual(
      try JSONDecoder().decode(LockScreenConfiguration.self, from: Data(contentsOf: manifest)).scenes,
      [])
    XCTAssertTrue(service.errorMessage?.contains("renderer failed") == true)
  }

  // MARK: - Managed user assets

  /// The extension can only read the exchange directory, so a property pointing at the
  /// app's managed store has to be republished there and the value
  /// rewritten. Only the assets this wallpaper references may travel.
  @MainActor
  func testReferencedUserAssetsArePublishedIntoTheExchangeAndNothingElseIs() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    try writeManagedAsset(propertyId: "cover", fileName: "a b+c.png", bytes: "cover-bytes")
    // A second wallpaper's import, which this one must not carry into the exchange.
    let other = ClientPaths.userAssetsURL.appendingPathComponent(
      "9999/cover/abc", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("other-wallpaper".utf8).write(to: other.appendingPathComponent("other.png"))

    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [self.scene(propertiesJSON: #"{"cover":"/Users/someone/a b+c.png"}"#)] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("enabled with published assets") { service.isEnabled }

    let configuration = try JSONDecoder().decode(
      LockScreenConfiguration.self,
      from: Data(contentsOf: exchange.appendingPathComponent(LockScreenConfiguration.fileName)))
    let json = try XCTUnwrap(XCTUnwrap(configuration.scenes.first).propertiesJSON)
    let root = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
    let value = try XCTUnwrap(root["cover"] as? String)

    XCTAssertTrue(
      value.hasPrefix(exchange.path + "/revisions/"),
      "the extension cannot read the app's own store, so the value must name the exchange copy")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: value)), Data("cover-bytes".utf8))
    let published = try FileManager.default.subpathsOfDirectory(atPath: exchange.path)
    XCTAssertFalse(
      published.contains { $0.hasSuffix("other.png") },
      "another wallpaper's imports are not this wallpaper's to publish")

    try await service.shutdown()
  }

  /// Republishing the same selection must not copy it again, and must not leave the
  /// revision it replaced behind for good — there was no collection at all before.
  @MainActor
  func testRepublishingReusesTheRevisionAndCollectsOnlyUnreferencedOnes() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    try writeManagedAsset(propertyId: "cover", fileName: "first.png", bytes: "first-bytes")
    var properties = #"{"cover":"/Users/someone/first.png"}"#
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [self.scene(propertiesJSON: properties)] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor)
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("first publication") { service.isEnabled }

    let revisions = exchange.appendingPathComponent("revisions", isDirectory: true)
    let firstNames = try Set(FileManager.default.contentsOfDirectory(atPath: revisions.path))
    let assetRevision = try XCTUnwrap(
      publishedAssetRevision(), "the first publication must name an asset revision")
    let inode = try XCTUnwrap(try? FileManager.default.attributesOfItem(
      atPath: assetRevision.path)[.systemFileNumber] as? NSNumber)

    // A stale revision of exactly the shape earlier activations left behind.
    let orphan = revisions.appendingPathComponent(String(repeating: "a", count: 64), isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: orphan.appendingPathComponent("stale.png"))

    // Off and on again republishes the same selection from scratch, which is the
    // path that would copy the assets a second time if the fingerprint were unstable.
    service.setEnabled(false)
    await waitFor("deactivated") { !service.isBusy && !service.isEnabled }
    service.setEnabled(true)
    await waitFor("second publication") { service.isEnabled && !service.isBusy }

    XCTAssertEqual(
      try XCTUnwrap(try? FileManager.default.attributesOfItem(
        atPath: assetRevision.path)[.systemFileNumber] as? NSNumber), inode,
      "an unchanged selection must reuse its revision rather than copy it again")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: orphan.path),
      "an unreferenced revision is a leak; there was no collection before this")
    let afterNames = try Set(FileManager.default.contentsOfDirectory(atPath: revisions.path))
    XCTAssertTrue(
      firstNames.isSubset(of: afterNames),
      "a revision the published configuration still names must never be collected")

    // Now change the selection: the old asset revision becomes unreferenced.
    try writeManagedAsset(propertyId: "cover", fileName: "second.png", bytes: "second-bytes")
    properties = #"{"cover":"/Users/someone/second.png"}"#
    service.refresh()
    await waitFor("third publication") { service.isEnabled && !service.isBusy }

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: assetRevision.path),
      "the replaced asset revision is unreferenced and must be collected")
    let replacement = try XCTUnwrap(publishedAssetRevision())
    XCTAssertEqual(
      try Data(contentsOf: replacement.appendingPathComponent("cover/second.png")),
      Data("second-bytes".utf8))

    try await service.shutdown()
  }


  @MainActor
  func testScreenSaverOnlySelectsIdleWithoutWaitingForAnActiveSurface() async throws {
    var record = scene()
    record.displayId = 1
    var native = fixture()
    native["AllSpacesAndDisplays"] = ["Type": "idle", "Idle": choice("default")]
    try write(native)
    let original = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: store), format: nil) as! NSDictionary
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" })
    service.beforeActivation = { XCTFail("Saver-only selection must not take the desktop") }
    try service.start()
    service.setScreenSaverEnabled(true)
    await waitFor("idle selection without a readiness responder") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    let configuration = try publishedConfiguration()
    XCTAssertFalse(configuration.lockScreenEnabled)
    XCTAssertTrue(configuration.screenSaverEnabled)
    XCTAssertEqual(configuration.scenes.map(\.displayID), [1])
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertEqual(try selectedProvider("Idle"), LockScreenConfiguration.extensionIdentifier)
    let selected = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: store), format: nil) as! [String: Any]
    XCTAssertNil(selected["AllSpacesAndDisplays"],
      "Selected must mean the default global screen saver no longer overrides the display")

    service.setScreenSaverEnabled(false)
    await waitFor("idle restoration") { !service.isBusy }
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertEqual(try PropertyListSerialization.propertyList(
      from: Data(contentsOf: store), format: nil) as? NSDictionary, original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testSystemDefaultLinkedWallpaperActivatesBothModesAndRestoresOnShutdown() async throws {
    for saverOnly in [false, true] {
      var record = scene()
      record.displayId = 1
      let linked: [String: Any] = ["Type": "linked", "Linked": choice("default")]
      let original: [String: Any] = [
        "AllSpacesAndDisplays": linked, "SystemDefault": linked,
        "Displays": [String: Any](), "Spaces": [String: Any](),
      ]
      try write(original)
      defaults.removePersistentDomain(forName: defaultsSuite)
      let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
        selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
        exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
        displayUUID: { _ in "one" })
      let responder = readinessResponder()
      try service.start()
      service.setScreenSaverEnabled(true)
      if !saverOnly { service.setEnabled(true) }
      await waitFor("native default wallpaper activation") { !service.isBusy }
      XCTAssertNil(service.errorMessage)
      XCTAssertNil(service.screenSaverError)
      XCTAssertEqual(service.isEnabled, !saverOnly)
      XCTAssertTrue(service.screenSaverEnabled)
      XCTAssertEqual(try selectedProvider("Idle"), LockScreenConfiguration.extensionIdentifier)
      XCTAssertEqual(try selectedProvider("Desktop"),
        saverOnly ? "default" : LockScreenConfiguration.extensionIdentifier)
      try await service.shutdown()
      responder.cancel()
      await responder.value
      XCTAssertEqual(try PropertyListSerialization.propertyList(
        from: Data(contentsOf: store), format: nil) as? NSDictionary, original as NSDictionary)
      XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
  }

  @MainActor
  func testDisablingEitherPresentationPreservesTheOtherInBothOrders() async throws {
    for (disableLockFirst, displayOnline) in [(true, true), (false, true), (true, false), (false, false)] {
      var online = true
      var record = scene()
      record.displayId = 1
      let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in online ? "one" : nil })
      let responder = readinessResponder()
      try service.start()
      service.setScreenSaverEnabled(true)
      await waitFor("saver selected") { !service.isBusy }
      service.setEnabled(true)
      await waitFor("both presentations selected") { !service.isBusy }
      XCTAssertTrue(service.isEnabled)
      XCTAssertTrue(service.screenSaverEnabled)
      online = displayOnline
      if disableLockFirst { service.setEnabled(false) }
      else { service.setScreenSaverEnabled(false) }
      await waitFor("one presentation restored") { !service.isBusy }
      let configuration = try publishedConfiguration()
      XCTAssertEqual(configuration.lockScreenEnabled, !disableLockFirst)
      XCTAssertEqual(configuration.screenSaverEnabled, disableLockFirst)
      XCTAssertEqual(service.isEnabled, !disableLockFirst)
      XCTAssertEqual(service.screenSaverEnabled, disableLockFirst)
      XCTAssertEqual(service.ownsDesktopProvider, !disableLockFirst)
      XCTAssertEqual(try selectedProvider(disableLockFirst ? "Idle" : "Desktop"),
        LockScreenConfiguration.extensionIdentifier)
      XCTAssertEqual(try selectedProvider(disableLockFirst ? "Desktop" : "Idle"),
        disableLockFirst ? "display-one-desktop" : "display-one-idle")
      if !displayOnline {
        if disableLockFirst { service.setEnabled(true) }
        else { service.setScreenSaverEnabled(true) }
        await waitFor("re-enable deferred by topology") { !service.isBusy }
      }
      if disableLockFirst { service.setScreenSaverEnabled(false) }
      else { service.setEnabled(false) }
      await waitFor("both restored") { !service.isBusy }
      responder.cancel()
      try await service.shutdown()
      XCTAssertTrue(try publishedConfiguration().scenes.isEmpty)
      XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
      XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    }
  }

  @MainActor
  func testWebSaverPublishesEntryAndManagedPropertiesWithoutTakingLockScreen() async throws {
    try Data(#"{"type":"web","title":"still","file":"pages/index.html"}"#.utf8).write(
      to: project.appendingPathComponent("project.json"))
    try FileManager.default.createDirectory(at: project.appendingPathComponent("pages"),
      withIntermediateDirectories: true)
    try Data("<html><body>local</body></html>".utf8).write(
      to: project.appendingPathComponent("pages/index.html"))
    try writeManagedAsset(propertyId: "cover", fileName: "a b.png", bytes: "cover-content")
    let manifestURL = ClientPaths.userAssetsURL.appendingPathComponent("2001/manifest.json")
    var manifest = try XCTUnwrap(try JSONSerialization.jsonObject(
      with: Data(contentsOf: manifestURL)) as? [String: Any])
    var entries = try XCTUnwrap(manifest["properties"] as? [String: Any])
    entries["empty"] = ["kind": "directory", "sourcePath": "/old/empty",
      "truncated": false, "migratedLegacyPaths": [], "assets": []] as [String: Any]
    manifest["properties"] = entries
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    var record = scene(propertiesJSON:
      #"{"cover":{"type":"file","value":"/old/a b.png"},"empty":{"type":"directory","value":"/old/empty"},"color":{"type":"color","value":"1 0 0"}}"#)
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" })
    try service.start()
    service.setEnabled(true)
    await waitFor("web excluded from lock screen") { !service.isBusy }
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    service.setScreenSaverEnabled(true)
    await waitFor("web saver selected") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertFalse(service.isEnabled)
    let configuration = try publishedConfiguration()
    let published = try XCTUnwrap(configuration.scenes.first)
    XCTAssertEqual(published.webEntryFile, "pages/index.html")
    let rootURL = exchange.appendingPathComponent(published.projectPath).deletingLastPathComponent()
    XCTAssertEqual(try String(contentsOf: rootURL.appendingPathComponent("pages/index.html"),
      encoding: .utf8), "<html><body>local</body></html>")
    let properties = try XCTUnwrap(try JSONSerialization.jsonObject(
      with: Data(try XCTUnwrap(published.propertiesJSON).utf8)) as? [String: [String: Any]])
    let value = try XCTUnwrap(properties["cover"]?["value"] as? String)
    let url = try XCTUnwrap(URL(string: value))
    XCTAssertTrue(url.isFileURL)
    XCTAssertTrue(url.path.hasPrefix(rootURL.path + "/"),
      "The web read grant must not expose other projects or their imports")
    XCTAssertEqual(try Data(contentsOf: url), Data("cover-content".utf8))
    XCTAssertEqual(properties["cover"]?["type"] as? String, "file")
    XCTAssertEqual(properties["color"]?["value"] as? String, "1 0 0")
    let emptyURL = try XCTUnwrap(URL(string: try XCTUnwrap(properties["empty"]?["value"] as? String)))
    XCTAssertTrue(emptyURL.path.hasPrefix(rootURL.path + "/"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: emptyURL.path), [])
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    try await service.shutdown()
  }

  @MainActor
  func testEscapingWebEntryLeavesNativeSelectionsUntouched() async throws {
    try Data(#"{"type":"web","file":"../outside.html"}"#.utf8).write(
      to: project.appendingPathComponent("project.json"))
    try Data("outside".utf8).write(to: root.appendingPathComponent("outside.html"))
    let original = try Data(contentsOf: store)
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" })
    try service.start()
    service.setScreenSaverEnabled(true)
    await waitFor("rejected web entry") { !service.isBusy }
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertNotNil(service.screenSaverError)
    XCTAssertEqual(try Data(contentsOf: store), original)
  }

  @MainActor
  func testIdleRendererFailureRestoresSelectionAndStopsAutomaticRetries() async throws {
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" })
    try service.start()
    service.setScreenSaverEnabled(true)
    await waitFor("saver selected") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    let timer = try XCTUnwrap(timers.last)
    try failPublishedReadiness("native renderer could not load")
    timer.fire()
    await waitFor("failed idle renderer restored") { !service.isBusy }
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertNotNil(service.screenSaverError)
    XCTAssertFalse(timer.isValid)
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertTrue(try publishedConfiguration().scenes.isEmpty)
  }

  @MainActor
  func testCancellingLockActivationDoesNotCancelAnAlreadySelectedSaver() async throws {
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
    selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" })
    try service.start()
    service.setScreenSaverEnabled(true)
    await waitFor("saver selected") { !service.isBusy }
    service.setEnabled(true)
    await waitFor("lock waiting for its first frame") {
      service.ownsDesktopProvider && (try? self.selectedProvider("Desktop"))
        == LockScreenConfiguration.extensionIdentifier
    }
    service.setEnabled(false)
    await waitFor("lock cancelled while saver remains selected") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertNil(service.screenSaverError)
    let configuration = try publishedConfiguration()
    XCTAssertTrue(configuration.screenSaverEnabled)
    XCTAssertFalse(configuration.lockScreenEnabled)
    XCTAssertEqual(try selectedProvider("Idle"), LockScreenConfiguration.extensionIdentifier)
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    try await service.shutdown()
  }

  @MainActor
  func testRestoredLockTimeoutKeepsSaverSelectedUntilExplicitLockRetry() async throws {
    defaults.set(true, forKey: preference)
    defaults.set(true, forKey: "WallpaperMachineUseWallpaperAsScreenSaver")
    var record = scene()
    record.displayId = 1
    var answerLock = false
    var desktopReturned = false
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {
      if answerLock { try? self.answerPublishedReadiness() }
    }, scenes: { [record] }, selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" }, runningExtensionBundles: { [] }, readinessTimeout: 0.2)
    service.afterDeactivation = { desktopReturned = true }
    try service.start()
    service.refresh()
    await waitFor("restored lock activation timeout") { !service.isBusy }
    XCTAssertTrue(service.isRequested)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertTrue(desktopReturned)
    let lockError = try XCTUnwrap(service.errorMessage)
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertNil(service.screenSaverError)
    XCTAssertTrue(defaults.bool(forKey: preference))
    XCTAssertTrue(defaults.bool(forKey: "WallpaperMachineUseWallpaperAsScreenSaver"))
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertEqual(try selectedProvider("Idle"), LockScreenConfiguration.extensionIdentifier)
    let fallback = try publishedConfiguration()
    XCTAssertFalse(fallback.lockScreenEnabled)
    XCTAssertTrue(fallback.screenSaverEnabled)
    XCTAssertEqual(fallback.scenes.map(\.displayID), [1])

    let monitor = try XCTUnwrap(timers.last)
    XCTAssertTrue(monitor.isValid)
    monitor.fire()
    await waitFor("saver monitoring after lock timeout") { !service.isBusy }
    XCTAssertEqual(try publishedConfiguration(), fallback)
    XCTAssertEqual(service.errorMessage, lockError)
    XCTAssertTrue(service.screenSaverEnabled)

    record.paused = true
    service.refresh()
    await waitFor("saver pause update without retrying lock") { !service.isBusy }
    let paused = try publishedConfiguration()
    XCTAssertFalse(paused.lockScreenEnabled)
    XCTAssertTrue(paused.screenSaverEnabled)
    XCTAssertEqual(paused.scenes.first?.paused, true)
    XCTAssertEqual(service.errorMessage, lockError)
    XCTAssertNil(service.screenSaverError)

    answerLock = true
    service.refresh(retryingLockScreen: true)
    await waitFor("explicit lock retry") { !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertNil(service.errorMessage)
    XCTAssertNil(service.screenSaverError)
    XCTAssertEqual(try selectedProvider("Desktop"), LockScreenConfiguration.extensionIdentifier)
    XCTAssertEqual(try selectedProvider("Idle"), LockScreenConfiguration.extensionIdentifier)
    try await service.shutdown()
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testSaverDisableDuringLockRetryWithMissingDisplayUUIDRestoresIdleImmediately() async throws {
    var record = scene()
    record.displayId = 1
    var online = true
    var answerLock = false
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {
      if answerLock { try? self.answerPublishedReadiness() }
    }, scenes: { [record] }, selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in online ? "one" : nil }, runningExtensionBundles: { [] },
    readinessTimeout: 0.2)
    try service.start()
    service.setEnabled(true)
    service.setScreenSaverEnabled(true)
    await waitFor("lock timeout retaining saver") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertNotNil(service.errorMessage)
    let retained = try publishedConfiguration()

    online = false
    service.refresh(retryingLockScreen: true)
    await waitFor("lock retry waiting for display identity") { !service.isBusy }
    XCTAssertEqual(try publishedConfiguration(), retained)
    XCTAssertFalse(service.isEnabled)
    XCTAssertTrue(service.screenSaverEnabled)

    service.setScreenSaverEnabled(false)
    await waitFor("saver restored before display identity returns") { !service.isBusy }
    XCTAssertTrue(service.isRequested)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.screenSaverRequested)
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertNil(service.screenSaverError)
    XCTAssertFalse(defaults.bool(forKey: "WallpaperMachineUseWallpaperAsScreenSaver"))
    XCTAssertFalse(try publishedConfiguration().screenSaverEnabled)
    XCTAssertTrue(try publishedConfiguration().scenes.isEmpty)
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))

    online = true
    answerLock = true
    try XCTUnwrap(timers.last).fire()
    await waitFor("pending lock retry after display identity returns") { !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(try selectedProvider("Desktop"), LockScreenConfiguration.extensionIdentifier)
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    try await service.shutdown()
  }

  @MainActor
  func testSharedExtensionFailureStillRollsBackBothModes() async throws {
    let bundle = root.appendingPathComponent("extension.appex")
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {
      _ = try? LockScreenExtensionStatus.loadConfiguration(
        exchange: self.exchange, bundleURL: bundle, supportedVersion: 1,
        reportWriteFailure: { XCTFail("\($0)") })
    }, scenes: { [record] }, selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" }, expectedExtensionBundle: bundle,
    runningExtensionBundles: { [] }, readinessTimeout: 0.2)
    try service.start()
    service.setEnabled(true)
    service.setScreenSaverEnabled(true)
    await waitFor("shared extension rejection") { !service.isBusy }
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertNotNil(service.screenSaverError)
    XCTAssertFalse(try XCTUnwrap(timers.last).isValid)
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    XCTAssertTrue(try publishedConfiguration().scenes.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    try await service.shutdown()
  }

  @MainActor
  func testSaverCanStopAndRestartAfterLockTimeoutAndRejectsItsOwnRendererFailure() async throws {
    var record = scene()
    record.displayId = 1
    var lockRevision: String?
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {
      if let configuration = try? self.publishedConfiguration(), configuration.lockScreenEnabled,
        !configuration.scenes.isEmpty {
        lockRevision = configuration.revision
      }
    }, scenes: { [record] }, selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" }, runningExtensionBundles: { [] }, readinessTimeout: 0)
    try service.start()
    service.setScreenSaverEnabled(true)
    await waitFor("initial saver selection") { !service.isBusy }
    service.setEnabled(true)
    await waitFor("lock timeout while saver was selected") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    let lockError = try XCTUnwrap(service.errorMessage)
    let stale = LockScreenReadiness(
      revision: try XCTUnwrap(lockRevision), displayID: 1, error: "old desktop failure")
    try JSONEncoder().encode(stale).write(
      to: exchange.appendingPathComponent("ready-1.json"), options: .atomic)
    try XCTUnwrap(timers.last).fire()
    await waitFor("ignoring departed desktop readiness") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertNil(service.screenSaverError)

    service.setScreenSaverEnabled(false)
    await waitFor("saver disabled with failed lock still requested") { !service.isBusy }
    XCTAssertTrue(service.isRequested)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertEqual(service.errorMessage, lockError)
    XCTAssertFalse(try XCTUnwrap(timers.last).isValid)
    XCTAssertTrue(try publishedConfiguration().scenes.isEmpty)
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")

    service.setScreenSaverEnabled(true)
    await waitFor("saver restarted independently") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertFalse(try publishedConfiguration().lockScreenEnabled)
    XCTAssertEqual(service.errorMessage, lockError)
    XCTAssertEqual(try selectedProvider("Idle"), LockScreenConfiguration.extensionIdentifier)
    try failPublishedReadiness("current saver renderer failed")
    try XCTUnwrap(timers.last).fire()
    await waitFor("current saver failure rollback") { !service.isBusy }
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertNotNil(service.screenSaverError)
    XCTAssertFalse(try XCTUnwrap(timers.last).isValid)
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    XCTAssertTrue(try publishedConfiguration().scenes.isEmpty)
    try await service.shutdown()
  }

  @MainActor
  func testFailedSaverOnlyPublicationRestoresBothSelections() async throws {
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
    selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" }, persistConfiguration: { url, data in
      let configuration = try JSONDecoder().decode(LockScreenConfiguration.self, from: data)
      if configuration.screenSaverEnabled && !configuration.lockScreenEnabled {
        throw CocoaError(.fileWriteOutOfSpace)
      }
      try data.write(to: url, options: .atomic)
    }, runningExtensionBundles: { [] }, readinessTimeout: 0)
    try service.start()
    service.setEnabled(true)
    service.setScreenSaverEnabled(true)
    await waitFor("failed saver-only fallback") { !service.isBusy }
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertNotNil(service.screenSaverError)
    XCTAssertFalse(try XCTUnwrap(timers.last).isValid)
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    XCTAssertTrue(try publishedConfiguration().scenes.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    try await service.shutdown()
  }

  /// The scene the app publishes for one display showing a project of `type` at `framing`.
  @MainActor
  private func publishedScene(type: String, framing: BridgeFraming) async throws -> LockScreenScene {
    try Data(#"{"type":"\#(type)","title":"t","file":"index.html"}"#.utf8).write(
      to: project.appendingPathComponent("project.json"))
    try Data("<html></html>".utf8).write(to: project.appendingPathComponent("index.html"))
    var record = scene()
    record.displayId = 1
    record.framing = framing
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    // A web page can only be a screen saver; the others take the lock screen.
    if type == "web" { service.setScreenSaverEnabled(true) } else { service.setEnabled(true) }
    await waitFor("\(type) published") {
      (service.isEnabled || service.screenSaverEnabled) && !service.isBusy
    }
    let published = try XCTUnwrap(publishedConfiguration().scenes.first)
    try await service.shutdown()
    return published
  }

  @MainActor
  func testASceneAndAVideoPublishTheirPositionButAWebPageDoesNot() async throws {
    let position = BridgeFraming(panX: 0.2, panY: 0.8)
    for type in ["video", "scene"] {
      let published = try await publishedScene(type: type, framing: position)
      XCTAssertEqual(
        published.framing, LockScreenFraming(panX: 0.2, panY: 0.8), "a \(type) is positioned")
      XCTAssertNil(published.webEntryFile)
    }
    let web = try await publishedScene(type: "web", framing: position)
    XCTAssertEqual(web.webEntryFile, "index.html")
    XCTAssertNil(web.framing, "a web page fills its window, so it carries no position")
  }

  /// Moving a wallpaper on its display has to reach the extension. It publishes a new
  /// revision, which the extension answers by replacing its renderer, and a position
  /// that did not change publishes nothing.
  @MainActor
  func testMovingAWallpaperRepublishesOnlyWhenItsPositionChanges() async throws {
    var record = scene()
    record.displayId = 1
    record.framing = BridgeFraming(panX: 0.2, panY: 0.8)
    var publications = 0
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" },
      persistConfiguration: { url, bytes in
        try bytes.write(to: url, options: .atomic)
        publications += 1
      })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("first publication") { service.isEnabled && !service.isBusy }
    let first = try publishedConfiguration()
    XCTAssertEqual(first.scenes.first?.framing, LockScreenFraming(panX: 0.2, panY: 0.8))
    let count = publications

    service.refresh()
    await waitFor("unchanged refresh") { !service.isBusy }
    XCTAssertEqual(publications, count, "the same position publishes nothing")
    XCTAssertEqual(try publishedConfiguration().revision, first.revision)

    record.framing = BridgeFraming(panX: 0.7, panY: 0.8)
    service.refresh()
    await waitFor("moved publication") {
      publications > count && service.isEnabled && !service.isBusy
    }
    let moved = try publishedConfiguration()
    XCTAssertNotEqual(moved.revision, first.revision, "the extension reloads on a new revision")
    XCTAssertEqual(moved.scenes.first?.framing, LockScreenFraming(panX: 0.7, panY: 0.8))
    XCTAssertEqual(moved.scenes.first?.projectPath, first.scenes.first?.projectPath,
      "only the position moved, so the published project is reused")
    let extensionView = try XCTUnwrap(first.scenes.first)
    XCTAssertFalse(
      extensionView.sharesRenderer(with: try XCTUnwrap(moved.scenes.first)),
      "the extension replaces its renderer to move the picture")
    try await service.shutdown()
  }

  private func publishedConfiguration() throws -> LockScreenConfiguration {
    try JSONDecoder().decode(LockScreenConfiguration.self,
      from: Data(contentsOf: exchange.appendingPathComponent(LockScreenConfiguration.fileName)))
  }

  @MainActor
  func testRegistrationRunsForActivationButNotSteadyRefreshOrDisable() async throws {
    var record = scene()
    record.displayId = 1
    var registrations = 0
    let service = LockScreenWallpaperService(prepareExtension: { registrations += 1 },
      notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" })
    let responder = readinessResponder()
    defer { responder.cancel() }
    service.setEnabled(true)
    await waitFor("activation") { !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertEqual(registrations, 1)
    service.refresh()
    await waitFor("unchanged refresh") { !service.isBusy }
    service.setEnabled(false)
    await waitFor("disable") { !service.isBusy }
    XCTAssertEqual(registrations, 1)
    service.setScreenSaverEnabled(true)
    await waitFor("saver activation") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertEqual(registrations, 2, "The screen saver also uses the registered extension")
    service.setEnabled(true)
    await waitFor("lock screen alongside saver") { !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertEqual(registrations, 3)
    try await service.shutdown()
    XCTAssertEqual(registrations, 3)
  }

  @MainActor
  func testRegistrationFailureDoesNotSelectOrPersistNativePresentation() async throws {
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {
      throw LockScreenWallpaperFailure(message: "registration unavailable")
    }, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" })
    service.beforeActivation = { XCTFail("Registration must finish before native selection") }
    service.setEnabled(true)
    service.setScreenSaverEnabled(true)
    await waitFor("registration failure") { !service.isBusy }
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertNotNil(service.screenSaverError)
    XCTAssertFalse(defaults.bool(forKey: preference))
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    try await service.shutdown()
  }

  @MainActor
  func testDisableDuringRegistrationCannotPublishOrSelectTheCancelledActivation() async throws {
    var record = scene()
    record.displayId = 1
    var finishRegistration: CheckedContinuation<Void, Never>?
    let service = LockScreenWallpaperService(prepareExtension: {
      await withCheckedContinuation { finishRegistration = $0 }
    }, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" })
    service.beforeActivation = { XCTFail("A cancelled activation must not own the desktop") }
    service.setEnabled(true)
    await waitFor("registration started") { finishRegistration != nil }
    XCTAssertFalse(service.isEnabled)
    service.setEnabled(false)
    finishRegistration?.resume()
    await waitFor("cancelled activation") { !service.isBusy }
    XCTAssertFalse(service.isEnabled)
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertFalse(FileManager.default.fileExists(atPath: exchange.appendingPathComponent(LockScreenConfiguration.fileName).path))
    try await service.shutdown()
  }

  @MainActor
  func testRefreshDuringRegistrationSharesTheWorkAndStillWaitsForPixels() async throws {
    var record = scene()
    record.displayId = 1
    var preparations = 0
    var finishRegistration: CheckedContinuation<Void, Never>?
    let service = LockScreenWallpaperService(prepareExtension: {
      preparations += 1
      await withCheckedContinuation { finishRegistration = $0 }
    }, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" })
    service.setEnabled(true)
    await waitFor("registration started") { finishRegistration != nil }
    service.refresh()
    service.refresh()
    finishRegistration?.resume()
    await waitFor("publication after registration") {
      FileManager.default.fileExists(atPath: self.exchange.appendingPathComponent(LockScreenConfiguration.fileName).path)
    }
    XCTAssertEqual(preparations, 1)
    XCTAssertTrue(service.isBusy)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(defaults.bool(forKey: preference))
    let responder = readinessResponder()
    defer { responder.cancel() }
    await waitFor("first frame") { !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertEqual(preparations, 1)
    try await service.shutdown()
  }

  @MainActor
  func testWrongCopyIsAutomaticallyRepairedAndRetriedWithANewRevision() async throws {
    let bundle = root.appendingPathComponent("intended.appex")
    var record = scene()
    record.displayId = 1
    var registrations = 0
    var revisions: [String] = []
    let service = LockScreenWallpaperService(prepareExtension: { registrations += 1 },
      notifyConfigurationChanged: {
        guard let configuration = try? self.publishedConfiguration(), !configuration.scenes.isEmpty else { return }
        revisions.append(configuration.revision)
        let first = revisions.count == 1
        let report = LockScreenExtensionStatus(revision: configuration.revision,
          bundlePath: first ? self.root.appendingPathComponent("old.appex").path : bundle.path,
          supportedVersion: first ? 1 : LockScreenConfiguration.supportedVersion, error: nil)
        try? JSONEncoder().encode(report).write(to: self.exchange.appendingPathComponent(LockScreenExtensionStatus.fileName))
      }, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" }, expectedExtensionBundle: bundle)
    let responder = readinessResponder()
    defer { responder.cancel() }
    service.setEnabled(true)
    service.setScreenSaverEnabled(true)
    await waitFor("copy conflict recovery") { !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertNil(service.errorMessage)
    XCTAssertNil(service.screenSaverError)
    XCTAssertEqual(registrations, 2)
    XCTAssertEqual(Set(revisions).count, 2)
    XCTAssertTrue(defaults.bool(forKey: preference))
    XCTAssertEqual(try selectedProvider("Desktop"), LockScreenConfiguration.extensionIdentifier)
    XCTAssertEqual(try selectedProvider("Idle"), LockScreenConfiguration.extensionIdentifier)
    try await service.shutdown()
  }

  @MainActor
  func testPersistentWrongCopyStopsAfterOneAutomaticRetryAndRestoresSelection() async throws {
    var record = scene()
    record.displayId = 1
    var registrations = 0
    var activations = 0
    let service = LockScreenWallpaperService(prepareExtension: { registrations += 1 },
      notifyConfigurationChanged: {
        guard let configuration = try? self.publishedConfiguration(), !configuration.scenes.isEmpty else { return }
        activations += 1
        let report = LockScreenExtensionStatus(revision: configuration.revision,
          bundlePath: self.root.appendingPathComponent("old.appex").path,
          supportedVersion: LockScreenConfiguration.supportedVersion, error: nil)
        try? JSONEncoder().encode(report).write(to: self.exchange.appendingPathComponent(LockScreenExtensionStatus.fileName))
      }, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" }, expectedExtensionBundle: root.appendingPathComponent("intended.appex"))
    service.setEnabled(true)
    await waitFor("bounded copy recovery") { !service.isBusy }
    XCTAssertEqual(registrations, 2)
    XCTAssertEqual(activations, 2)
    XCTAssertFalse(service.isEnabled)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertFalse(service.canRefreshAutomatically)
    XCTAssertFalse(defaults.bool(forKey: preference))
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertTrue(try publishedConfiguration().scenes.isEmpty)
    try await service.shutdown()
  }

  @MainActor
  func testRefreshDuringCopyRecoveryCannotResetTheAutomaticRetryLimit() async throws {
    var record = scene()
    record.displayId = 1
    var preparations = 0
    var finishRepair: CheckedContinuation<Void, Never>?
    let service = LockScreenWallpaperService(prepareExtension: {
      preparations += 1
      if preparations == 2 { await withCheckedContinuation { finishRepair = $0 } }
    }, notifyConfigurationChanged: {
      guard let configuration = try? self.publishedConfiguration(), !configuration.scenes.isEmpty else { return }
      let report = LockScreenExtensionStatus(revision: configuration.revision,
        bundlePath: self.root.appendingPathComponent("old.appex").path,
        supportedVersion: LockScreenConfiguration.supportedVersion, error: nil)
      try? JSONEncoder().encode(report).write(to: self.exchange.appendingPathComponent(LockScreenExtensionStatus.fileName))
    }, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" }, expectedExtensionBundle: root.appendingPathComponent("intended.appex"))
    service.setEnabled(true)
    await waitFor("repair started") { finishRepair != nil }
    service.refresh()
    finishRepair?.resume()
    await waitFor("bounded repair after refresh") { !service.isBusy }
    XCTAssertEqual(preparations, 2)
    XCTAssertFalse(service.isEnabled)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertFalse(service.canRefreshAutomatically)
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    service.refresh(retryingLockScreen: true)
    await waitFor("explicit retry") { !service.isBusy }
    XCTAssertEqual(preparations, 4, "An explicit retry allows one new recovery attempt")
    XCTAssertFalse(service.isEnabled)
    try await service.shutdown()
  }

  private func switchedOff(_ message: String = "the renderer is switched off") -> LockScreenWallpaperFailure {
    LockScreenWallpaperFailure(message: message, reason: .extensionTurnedOff)
  }

  @MainActor
  private func electionService(
    prepare: @escaping () async throws -> Void, enable: @escaping () async throws -> Void,
    scenes: @escaping () async throws -> [BridgeLockScreenScene]
  ) -> LockScreenWallpaperService {
    LockScreenWallpaperService(prepareExtension: prepare, enableExtension: enable,
      notifyConfigurationChanged: {}, scenes: scenes,
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" })
  }

  @MainActor
  func testRetryRepairsAnIgnoredExtensionButNothingElseDoes() async throws {
    // A saved request, as after a relaunch: the first activation is the monitor's.
    defaults.set(true, forKey: preference)
    var record = scene()
    record.displayId = 1
    var off = true
    var events: [String] = []
    let service = electionService(prepare: {
      events.append("prepare")
      if off { throw self.switchedOff() }
    }, enable: {
      events.append("enable")
      off = false
    }, scenes: { [record] })
    try service.start()
    let monitor = try XCTUnwrap(timers.first)
    monitor.fire()
    await waitFor("activation stopped by the switched-off renderer") { !service.isBusy }
    XCTAssertEqual(service.errorMessage, "the renderer is switched off")
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.canRefreshAutomatically)
    XCTAssertFalse(monitor.isValid, "No steady refresh runs while the error stands")
    XCTAssertEqual(events, ["prepare"], "Activation alone never changes an election")
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: exchange.appendingPathComponent(LockScreenConfiguration.fileName).path),
      "Nothing is published for a renderer macOS will not run")
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")

    let responder = readinessResponder()
    defer { responder.cancel() }
    service.retry(lockScreen: true)
    await waitFor("Retry") { !service.isBusy }
    XCTAssertEqual(events, ["prepare", "enable", "prepare"], "The election is repaired first, once")
    XCTAssertTrue(service.isEnabled)
    XCTAssertNil(service.errorMessage)

    service.refresh()
    await waitFor("steady refresh") { !service.isBusy }
    service.retry(lockScreen: true)
    await waitFor("another Retry") { !service.isBusy }
    XCTAssertEqual(events.filter { $0 == "enable" }.count, 1, "Only a stopped activation is repaired")
    try await service.shutdown()
  }

  @MainActor
  func testScreenSaverRetryRepairsOncePerClickAndKeepsReportingAStubbornElection() async throws {
    var record = scene()
    record.displayId = 1
    var enables = 0
    var stubborn = true
    let service = electionService(prepare: {
      if enables == 0 { throw self.switchedOff() }
    }, enable: {
      enables += 1
      if stubborn { throw self.switchedOff("the renderer stayed switched off") }
    }, scenes: { [record] })
    try service.start()
    service.setScreenSaverEnabled(true)
    await waitFor("activation stopped") { !service.isBusy }
    XCTAssertEqual(service.screenSaverError, "the renderer is switched off")
    XCTAssertEqual(enables, 0)

    service.retry(lockScreen: false)
    await waitFor("first Retry") { !service.isBusy }
    XCTAssertEqual(enables, 1)
    XCTAssertEqual(service.screenSaverError, "the renderer stayed switched off")
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle", "A failed repair leaves the selection restored")
    service.retry(lockScreen: false)
    await waitFor("second Retry") { !service.isBusy }
    XCTAssertEqual(enables, 2, "Every click tries again; nothing retries on its own")

    stubborn = false
    service.retry(lockScreen: false)
    await waitFor("Retry after the user switched it on") { !service.isBusy }
    XCTAssertEqual(enables, 3)
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertNil(service.screenSaverError)
    try await service.shutdown()
  }

  @MainActor
  func testOtherFailuresAreNeverRepairedByRetry() async throws {
    var record = scene()
    record.displayId = 1
    var failures = [switchedOff(), LockScreenWallpaperFailure(message: "registration unavailable")]
    var enables = 0
    let service = electionService(prepare: {
      if !failures.isEmpty { throw failures.removeFirst() }
      throw LockScreenWallpaperFailure(message: "still unavailable")
    }, enable: { enables += 1 }, scenes: { [record] })
    service.setEnabled(true)
    await waitFor("switched-off failure") { !service.isBusy }
    XCTAssertEqual(service.errorMessage, "the renderer is switched off")
    service.retry(lockScreen: true)
    await waitFor("Retry that repairs, then fails differently") { !service.isBusy }
    XCTAssertEqual(enables, 1)
    XCTAssertEqual(service.errorMessage, "registration unavailable")
    for _ in 0..<2 {
      service.retry(lockScreen: true)
      await waitFor("Retry after another failure") { !service.isBusy }
    }
    XCTAssertEqual(enables, 1, "Retry repairs only the failure it was offered for")
    XCTAssertEqual(service.errorMessage, "still unavailable")
    try await service.shutdown()
  }

  @MainActor
  func testSwitchingModesOffAndOnNeverRepairsAnElectionOnlyRetryMay() async throws {
    var record = scene()
    record.displayId = 1
    var events: [String] = []
    let service = electionService(prepare: {
      events.append("prepare")
      throw self.switchedOff()
    }, enable: { events.append("enable") }, scenes: { [record] })
    service.setEnabled(true)
    await waitFor("switched-off failure") { !service.isBusy }
    XCTAssertEqual(service.errorMessage, "the renderer is switched off")

    // The user answers the message with the switch instead of Retry: the offer is withdrawn
    // with the request, and the next request is a new one, not a Retry.
    service.setEnabled(false)
    await waitFor("switched off") { !service.isBusy }
    XCTAssertNil(service.errorMessage)
    service.setEnabled(true)
    await waitFor("switched on again") { !service.isBusy }
    XCTAssertEqual(events, ["prepare", "prepare"], "A switch never changes the election")
    XCTAssertEqual(service.errorMessage, "the renderer is switched off", "The failure is reported afresh")

    service.retry(lockScreen: true)
    await waitFor("Retry") { !service.isBusy }
    XCTAssertEqual(events, ["prepare", "prepare", "enable", "prepare"])

    // Same for the screen saver, and for the quick off-on that cancels the withdrawal's update.
    service.setScreenSaverEnabled(true)
    await waitFor("screen saver failure") { !service.isBusy }
    service.setEnabled(false)
    service.setScreenSaverEnabled(false)
    service.setScreenSaverEnabled(true)
    await waitFor("screen saver switched on again") { !service.isBusy }
    XCTAssertEqual(events.filter { $0 == "enable" }.count, 1)
    try await service.shutdown()
  }

  @MainActor
  func testSwitchingOneModeOffNeverRepairsTheElectionTheOtherModeShows() async throws {
    var record = scene()
    record.displayId = 1
    var events: [String] = []
    let service = electionService(prepare: {
      events.append("prepare")
      throw self.switchedOff()
    }, enable: { events.append("enable") }, scenes: { [record] })
    service.setScreenSaverEnabled(true)
    service.setEnabled(true)
    await waitFor("both modes stopped") { !service.isBusy }
    XCTAssertEqual(service.screenSaverError, "the renderer is switched off")

    service.setEnabled(false)
    await waitFor("lock screen switched off") { !service.isBusy }
    XCTAssertFalse(events.contains("enable"), "Only a Retry may change the election")
    XCTAssertEqual(service.screenSaverError, "the renderer is switched off")

    service.retry(lockScreen: false)
    await waitFor("screen-saver Retry") { !service.isBusy }
    XCTAssertEqual(events.filter { $0 == "enable" }.count, 1, "The offer survives for the row that still shows it")
    try await service.shutdown()
  }

  @MainActor
  func testAClickWithNothingToActivateDoesNotSaveTheRepairForTheMonitor() async throws {
    var record = scene()
    record.displayId = 1
    var records = [record]
    var events: [String] = []
    let service = electionService(prepare: {
      events.append("prepare")
      throw self.switchedOff()
    }, enable: { events.append("enable") }, scenes: { records })
    service.setEnabled(true)
    await waitFor("activation stopped") { !service.isBusy }
    XCTAssertEqual(events, ["prepare"])

    // Retry while no wallpaper is applied needs no renderer, so it repairs nothing.
    records = []
    service.retry(lockScreen: true)
    await waitFor("Retry without a wallpaper") { !service.isBusy }
    XCTAssertEqual(events, ["prepare"])
    XCTAssertNil(service.errorMessage)

    // The wallpaper applied later reaches the monitor, which only reports the failure again.
    records = [record]
    let monitor = try XCTUnwrap(timers.last)
    XCTAssertTrue(monitor.isValid)
    monitor.fire()
    await waitFor("monitor activation") { !service.isBusy }
    XCTAssertEqual(events, ["prepare", "prepare"], "The earlier click does not authorize this activation")
    XCTAssertEqual(service.errorMessage, "the renderer is switched off")
    try await service.shutdown()
  }

  @MainActor
  func testConfigurationFailureRestoresSelectionWithoutWaitingForFrameTimeout() async throws {
    let bundle = root.appendingPathComponent("extension.appex")
    var record = scene()
    record.displayId = 1
    var loadFailed = false
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {
      guard let configuration = try? self.publishedConfiguration(), !configuration.scenes.isEmpty else { return }
      do {
        let invalid = ["version": 2, "revision": configuration.revision, "scenes": false] as [String: Any]
        try JSONSerialization.data(withJSONObject: invalid).write(
          to: self.exchange.appendingPathComponent(LockScreenConfiguration.fileName), options: .atomic)
        _ = try LockScreenExtensionStatus.loadConfiguration(
          exchange: self.exchange, bundleURL: bundle, reportWriteFailure: { XCTFail("\($0)") })
      } catch { loadFailed = true }
    }, scenes: { [record] }, selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" }, expectedExtensionBundle: bundle,
    runningExtensionBundles: { XCTFail("Should fail before the timeout"); return [] })
    var handedBack = false
    service.afterDeactivation = { handedBack = true }
    try service.start()
    service.setEnabled(true)
    await waitFor("configuration failure rollback", timeout: 3) { !service.isBusy }
    XCTAssertTrue(loadFailed)
    XCTAssertTrue(handedBack)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertFalse(defaults.bool(forKey: preference))
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertTrue(try publishedConfiguration().scenes.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    try await service.shutdown()
  }

  @MainActor
  func testHealthyDiagnosticStillWaitsForPixelsAndIgnoresStaleFailures() async throws {
    let bundle = root.appendingPathComponent("extension.appex")
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {
      _ = try? LockScreenExtensionStatus.loadConfiguration(
        exchange: self.exchange, bundleURL: bundle, reportWriteFailure: { XCTFail("\($0)") })
    }, scenes: { [record] }, selection: LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" }, expectedExtensionBundle: bundle)
    try service.start()
    service.setEnabled(true)
    await waitFor("diagnostic") {
      FileManager.default.fileExists(atPath: self.exchange.appendingPathComponent(LockScreenExtensionStatus.fileName).path)
    }
    XCTAssertTrue(service.isBusy)
    XCTAssertFalse(service.isEnabled)
    let stale = LockScreenExtensionStatus(
      revision: "old", bundlePath: "/old.appex", supportedVersion: 1, error: "old failure")
    try JSONEncoder().encode(stale).write(
      to: exchange.appendingPathComponent(LockScreenExtensionStatus.fileName), options: .atomic)
    let responder = readinessResponder()
    defer { responder.cancel() }
    await waitFor("frame readiness") { !service.isBusy }
    XCTAssertTrue(service.isEnabled)
    XCTAssertNil(service.errorMessage)
    try await service.shutdown()
  }

  @MainActor
  func testLegacyExtensionTimeoutInspectsRunningCopyAndRestoresSelection() async throws {
    var record = scene()
    record.displayId = 1
    var inspected = false
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
    selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" }, expectedExtensionBundle: root.appendingPathComponent("intended.appex"),
    runningExtensionBundles: {
      inspected = true
      return [self.root.appendingPathComponent("old.appex")]
    }, readinessTimeout: 0)
    service.setEnabled(true)
    await waitFor("legacy timeout") { !service.isBusy }
    XCTAssertTrue(inspected)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertFalse(service.isEnabled)
    XCTAssertEqual(try selectedProvider("Desktop"), "display-one-desktop")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    try await service.shutdown()
  }

  @MainActor
  func testConfigurationVersionFailureAfterSaverSelectionRestoresIdle() async throws {
    let bundle = root.appendingPathComponent("extension.appex")
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
    selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
    exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
    displayUUID: { _ in "one" }, expectedExtensionBundle: bundle)
    try service.start()
    service.setScreenSaverEnabled(true)
    await waitFor("saver selection") { !service.isBusy }
    XCTAssertTrue(service.screenSaverEnabled)
    XCTAssertThrowsError(try LockScreenExtensionStatus.loadConfiguration(
      exchange: exchange, bundleURL: bundle, supportedVersion: 1,
      reportWriteFailure: { XCTFail("\($0)") }))
    try XCTUnwrap(timers.last).fire()
    await waitFor("configuration failure after selection") { !service.isBusy }
    XCTAssertFalse(service.screenSaverEnabled)
    XCTAssertNotNil(service.screenSaverError)
    XCTAssertEqual(try selectedProvider("Idle"), "display-one-idle")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    try await service.shutdown()
  }

  private func selectedProvider(_ key: String) throws -> String? {
    let value = try XCTUnwrap(try PropertyListSerialization.propertyList(
      from: Data(contentsOf: store), format: nil) as? [String: Any])
    let displays = value["Displays"] as? [String: [String: Any]]
    let selected = displays?["one"]?[key] as? [String: Any]
    let content = selected?["Content"] as? [String: Any]
    return (content?["Choices"] as? [[String: Any]])?.first?["Provider"] as? String
  }

  /// The asset revision is the one holding a `cover` directory; the project payload
  /// revision holds `project.json`.
  private func publishedAssetRevision() throws -> URL? {
    let revisions = exchange.appendingPathComponent("revisions", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: revisions.path)) ?? []
    return names.map { revisions.appendingPathComponent($0, isDirectory: true) }
      .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("cover").path) }
  }

  private func answerPublishedReadiness() throws {
    let configuration = try JSONDecoder().decode(
      LockScreenConfiguration.self,
      from: Data(contentsOf: exchange.appendingPathComponent(LockScreenConfiguration.fileName)))
    for scene in configuration.scenes {
      let readiness = LockScreenReadiness(
        revision: configuration.revision, displayID: scene.displayID, error: nil)
      try JSONEncoder().encode(readiness).write(
        to: exchange.appendingPathComponent("ready-\(scene.displayID).json"), options: .atomic)
    }
  }

  private func failPublishedReadiness(_ message: String) throws {
    let configuration = try JSONDecoder().decode(
      LockScreenConfiguration.self,
      from: Data(contentsOf: exchange.appendingPathComponent(LockScreenConfiguration.fileName)))
    for scene in configuration.scenes {
      let readiness = LockScreenReadiness(
        revision: configuration.revision, displayID: scene.displayID, error: message)
      try JSONEncoder().encode(readiness).write(
        to: exchange.appendingPathComponent("ready-\(scene.displayID).json"), options: .atomic)
    }
  }

  private func setGlobalWallpaperLinked() throws {
    let data = try Data(contentsOf: store)
    var root = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    var global = try XCTUnwrap(root["AllSpacesAndDisplays"] as? [String: Any])
    global["Type"] = "linked"
    root["AllSpacesAndDisplays"] = global
    try write(root)
  }

  /// A refresh that changes nothing publishes nothing, so the extension is not told to reload a
  /// configuration that is the same.
  @MainActor
  func testARefreshThatChangesNothingPublishesNothing() async throws {
    var record = scene()
    record.displayId = 1
    var publications = 0
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" },
      persistConfiguration: { url, bytes in
        try bytes.write(to: url, options: .atomic)
        publications += 1
      })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("first publication") { service.isEnabled && !service.isBusy }
    let first = try publishedConfiguration()
    let count = publications

    service.refresh()
    await waitFor("unchanged refresh") { !service.isBusy }
    XCTAssertEqual(publications, count, "the same inputs publish nothing")
    XCTAssertEqual(try publishedConfiguration().revision, first.revision)
    try await service.shutdown()
  }

  /// The scene the app publishes for a project of `type` with the Video backend `backend`.
  @MainActor
  private func publishedVideoScene(
    type: String, file: String = "clip.mp4", makeFile: Bool = true
  ) async throws -> LockScreenScene {
    try Data(#"{"type":"\#(type)","title":"t","file":"\#(file)"}"#.utf8).write(
      to: project.appendingPathComponent("project.json"))
    let media = project.appendingPathComponent(file)
    if makeFile { try Data("bytes".utf8).write(to: media) }
    var record = scene()
    record.displayId = 1
    let service = LockScreenWallpaperService(prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [record] },
      selection: LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {}),
      exchange: exchange, defaults: defaults, scheduleMonitor: scheduleMonitor,
      displayUUID: { _ in "one" })
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("\(type) published") { service.isEnabled && !service.isBusy }
    let published = try XCTUnwrap(publishedConfiguration().scenes.first)
    try await service.shutdown()
    return published
  }

  /// A plain video project always says it is a video and carries its media file for the extension,
  /// which plays it itself. Scenes carry neither.
  @MainActor
  func testAVideoAlwaysCarriesItsMediaFile() async throws {
    let video = try await publishedVideoScene(type: "video")
    XCTAssertEqual(video.plainVideo, true)
    XCTAssertEqual(video.nativeVideoFile, "clip.mp4")
    let scene = try await publishedVideoScene(type: "scene")
    XCTAssertNil(scene.plainVideo, "a scene is not a plain video")
    XCTAssertNil(scene.nativeVideoFile, "a scene is not a plain video")
  }

  /// A video whose file is not a regular file inside its project is still published as a video, with
  /// no file: the extension holds it and says the clip is missing, and no scene engine takes it over.
  @MainActor
  func testAMediaFileThatIsNotARegularFileInsideTheProjectIsPublishedAsAVideoWithNoFile() async throws {
    let missing = try await publishedVideoScene(type: "video", makeFile: false)
    XCTAssertEqual(missing.plainVideo, true)
    XCTAssertNil(missing.nativeVideoFile)
    let folder = project.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
    let directory = try await publishedVideoScene(
      type: "video", file: "sub", makeFile: false)
    XCTAssertEqual(directory.plainVideo, true)
    XCTAssertNil(directory.nativeVideoFile, "a folder is not a clip")
    let outside = try await publishedVideoScene(
      type: "video", file: "../escape.mp4", makeFile: false)
    XCTAssertEqual(outside.plainVideo, true)
    XCTAssertNil(outside.nativeVideoFile)
  }
}
