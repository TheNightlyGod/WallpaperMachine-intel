import CoreMedia
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperCompatibilityTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("compatibility-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func context(id: String = "one", kind: WallpaperCompatibilityContext.Kind = .video,
                       fps: UInt32 = 60, revision: UInt64 = 0)
    -> WallpaperCompatibilityContext {
    .init(wallpaperID: id, displayID: "7", kind: kind, supported: true, targetFPS: fps,
          targetAvailable: true, libraryRevision: revision, assetsConfiguration: "")
  }

  @discardableResult private func install(type: String = "video", entry: String = "clip.mp4", bytes: Int = 10) throws -> URL {
    let folder = root.appendingPathComponent("one")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest: [String: Any] = ["type": type, "file": entry]
    try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("project.json"))
    if !entry.contains("/") { try Data(repeating: 1, count: bytes).write(to: folder.appendingPathComponent(entry)) }
    return folder
  }

  private func status(_ checks: [WallpaperCompatibilityCheck], _ id: String) -> WallpaperCompatibilityCheck.Status? {
    checks.first { $0.id == id }?.status
  }

  func testATargetFrameRateNeverRefusesAClip() async throws {
    // The clip plays at its own frame rate, so the display's target (or a cap on it) takes no part
    // in whether macOS can play it.
    try install()
    let probe = ProbeRecorder()
    let service = WallpaperCompatibilityService(libraryURL: root, probe: { await probe.read($0) })
    let accepted = await service.check(context())
    let capped = await service.check(context(fps: 30))
    XCTAssertEqual(status(accepted, "nativeVideo"), .ok)
    XCTAssertEqual(status(capped, "nativeVideo"), .ok)
    XCTAssertFalse(capped.first { $0.id == "nativeVideo" }!.detail.contains("target frame rate"))
  }

  func testAFileTheNativePlayerCannotOpenIsAWarning() async throws {
    try install()
    let service = WallpaperCompatibilityService(libraryURL: root, probe: { _ in
      .refused(.notPlayable("asset reports itself unplayable"))
    })
    let checks = await service.check(context())
    XCTAssertEqual(status(checks, "nativeVideo"), .warning)
    XCTAssertTrue(checks.first { $0.id == "nativeVideo" }!.detail.contains("unplayable"))
  }

  func testCacheSeparatesContentSettingsAndRetry() async throws {
    let folder = try install()
    let recorder = ProbeRecorder()
    let service = WallpaperCompatibilityService(libraryURL: root, probe: { await recorder.read($0) })
    _ = await service.check(context())
    _ = await service.check(context())
    var count = await recorder.count
    XCTAssertEqual(count, 1, "Unchanged content/config reuses the metadata verdict")
    _ = await service.check(context(fps: 30))
    count = await recorder.count
    XCTAssertEqual(count, 2, "A new target frame rate is a new question, not a stale answer")
    try Data(repeating: 2, count: 20).write(to: folder.appendingPathComponent("clip.mp4"))
    _ = await service.check(context())
    count = await recorder.count
    XCTAssertEqual(count, 3, "A same-path media replacement is new content")
    _ = await service.check(context(), retry: true)
    count = await recorder.count
    XCTAssertEqual(count, 4, "Retry performs a fresh metadata check")
  }

  func testMissingEntryAndEscapingEntryCannotGetCodecPromise() async throws {
    let folder = try install()
    try FileManager.default.removeItem(at: folder.appendingPathComponent("clip.mp4"))
    let recorder = ProbeRecorder()
    let service = WallpaperCompatibilityService(libraryURL: root, probe: { await recorder.read($0) })
    let missing = await service.check(context())
    XCTAssertEqual(status(missing, "entry"), .unavailable)
    XCTAssertEqual(status(missing, "nativeVideo"), .unavailable)
    try install(entry: "../external.mp4")
    let escape = await service.check(context())
    XCTAssertEqual(status(escape, "entry"), .unavailable)
    let count = await recorder.count
    XCTAssertEqual(count, 0, "No metadata loads for absent or unauthorized media")
  }

  func testWorkshopWithoutFilesIsUnavailableNotCodecCompatible() async {
    let service = WallpaperCompatibilityService(libraryURL: root)
    let checks = await service.check(context(id: "not-installed"))
    XCTAssertEqual(status(checks, "project"), .unavailable)
    XCTAssertNil(status(checks, "nativeVideo"))
  }

  func testPackedSceneNeedsRuntimeAndMissingSharedAssetsAreDiagnosed() async throws {
    let folder = try install(type: "scene", entry: "scene.json")
    try FileManager.default.removeItem(at: folder.appendingPathComponent("scene.json"))
    try Data([1]).write(to: folder.appendingPathComponent("scene.pkg"))
    let assets = root.appendingPathComponent("shared")
    let service = WallpaperCompatibilityService(libraryURL: root, assetsURL: { assets })
    let checks = await service.check(context(kind: .scene))
    XCTAssertEqual(status(checks, "entry"), .unknown)
    XCTAssertEqual(status(checks, "sharedResources"), .unavailable)
    XCTAssertEqual(status(checks, "sceneCapability"), .unknown)
    for marker in ["shaders/genericimage2.vert", "shaders/genericimage2.frag", "materials/util/effectpassthrough.json"] {
      let path = assets.appendingPathComponent(marker)
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data([1]).write(to: path)
    }
    let installed = await service.check(context(kind: .scene))
    XCTAssertEqual(status(installed, "sharedResources"), .ok)
    XCTAssertEqual(status(installed, "sceneCapability"), .unknown, "Baseline resources cannot certify author shader/graph support")
  }

  func testWebLockScreenRemainsNotApplicable() async throws {
    try install(type: "web", entry: "index.html")
    let service = WallpaperCompatibilityService(libraryURL: root)
    let checks = await service.check(context(kind: .web))
    XCTAssertEqual(status(checks, "lockScreen"), .unavailable)
    XCTAssertEqual(status(checks, "webRuntime"), .unknown)
  }

  func testSelectionChangeDiscardsLateAdmission() async throws {
    try install()
    let entered = expectation(description: "Metadata load suspended")
    let gate = ProbeGate()
    let service = WallpaperCompatibilityService(libraryURL: root, probe: { url in
      await gate.read(url, entered: entered)
    })
    let store = WallpaperCompatibilityStore(service: service)
    let request = Task { await store.check(context()) }
    await fulfillment(of: [entered], timeout: 2)
    store.select(context(id: "two"))
    await gate.release()
    await request.value
    XCTAssertEqual(store.context?.wallpaperID, "two")
    XCTAssertFalse(store.checking)
    XCTAssertEqual(store.checks, [], "An old selection's result must never paint the new inspector")
  }

  func testReplacementDuringAdmissionCannotBeCachedAsAccepted() async throws {
    let folder = try install()
    let entered = expectation(description: "Metadata load suspended")
    let gate = ProbeGate()
    let service = WallpaperCompatibilityService(libraryURL: root, probe: { url in
      await gate.read(url, entered: entered)
    })
    let request = Task { await service.check(context()) }
    await fulfillment(of: [entered], timeout: 2)
    try Data(repeating: 2, count: 99).write(to: folder.appendingPathComponent("clip.mp4"))
    await gate.release()
    let result = await request.value
    XCTAssertEqual(status(result, "contentChanged"), .unknown)
    XCTAssertNil(status(result, "nativeVideo"), "The old metadata cannot certify replaced media")
  }
}

private actor ProbeRecorder {
  private(set) var count = 0
  func read(_ url: URL) -> NativeVideoProbeOutcome {
    count += 1
    return .probed(.init(isPlayable: true, hasVideoTrack: true))
  }
}

private actor ProbeGate {
  private var pending: CheckedContinuation<NativeVideoProbeOutcome, Never>?
  func read(_ url: URL, entered: XCTestExpectation) async -> NativeVideoProbeOutcome {
    await withCheckedContinuation { continuation in
      pending = continuation
      entered.fulfill()
    }
  }
  func release() {
    pending?.resume(returning: .probed(.init(isPlayable: true, hasVideoTrack: true)))
    pending = nil
  }
}
