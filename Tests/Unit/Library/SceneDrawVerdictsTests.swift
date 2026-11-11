import XCTest

@testable import WallpaperMachine

/// What the app remembers about whether Native Metal can draw a scene, and when it forgets it.
final class SceneDrawVerdictsTests: XCTestCase {
  private var root: URL!
  private var file: URL { root.appendingPathComponent("SceneDrawVerdicts.json") }
  private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("verdicts-\(UUID().uuidString)")
    try install("scene")
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func install(_ id: String, manifest: String = #"{"type":"scene","file":"scene.json"}"#) throws {
    let folder = library.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
    try Data("{}".utf8).write(to: folder.appendingPathComponent("scene.json"))
  }

  private func verdicts(build: String = "1.0 (1)") -> SceneDrawVerdicts {
    let library = self.library
    return SceneDrawVerdicts(file: file, library: { library }, build: build)
  }

  private func report(_ id: String = "scene", backend: String, stage: String? = nil, reason: String? = nil)
    -> BridgeSceneBackendReport
  {
    BridgeSceneBackendReport(
      displayId: 1, displayName: "Main", wallpaperId: id, wallpaperTitle: id, backend: backend,
      failureStage: stage, failureReason: reason, videoPath: "none", optimizationApplied: nil,
      qualityInForce: nil)
  }

  func testADrawnSceneIsRememberedAcrossLaunchesForTheSameBuildAndFiles() async throws {
    await verdicts().record(reports: [report(backend: "native_metal")])
    let reopened = await verdicts().verdict(for: "scene")
    XCTAssertEqual(reopened?.outcome, .drawn)
    let otherBuild = await verdicts(build: "1.1 (2)").verdict(for: "scene")
    XCTAssertNil(otherBuild, "another build's renderer may decide otherwise")
  }

  func testChangedSceneFilesMakeTheVerdictUnknownAgain() async throws {
    let store = verdicts()
    await store.record(reports: [report(backend: "unknown", stage: "unsupported", reason: "a puppet")])
    let held = await store.verdict(for: "scene")
    XCTAssertEqual(held?.outcome, .notDrawn)
    XCTAssertEqual(held?.reason, "a puppet")
    try install("scene", manifest: #"{"type":"scene","file":"scene.json","title":"Updated"}"#)
    let updated = await store.verdict(for: "scene")
    XCTAssertNil(updated, "a Workshop update or a reinstall is judged afresh")
  }

  func testOnlyOutcomesTheContentDecidesAreKept() async throws {
    let store = verdicts()
    await store.record(reports: [
      report(backend: "unknown"),
      report(backend: "unknown", stage: "frame", reason: "a frame failed"),
      report(backend: "unknown", stage: "surface"),
      report(backend: "unknown", stage: "prepare"),
    ])
    let nothing = await store.verdict(for: "scene")
    XCTAssertNil(nothing, "preparing, and failures a retry can clear, say nothing about the scene")
    await store.record(reports: [report(backend: "unknown", stage: "compile", reason: "MSL error")])
    let compile = await store.verdict(for: "scene")
    XCTAssertEqual(compile?.outcome, .notDrawn)
  }

  func testACleanCheckDoesNotReplaceASceneSeenDrawing() async throws {
    let store = verdicts()
    await store.record(reports: [report(backend: "native_metal")])
    await store.record("scene", outcome: .passedCheck, stage: nil, reason: nil)
    let kept = await store.verdict(for: "scene")
    XCTAssertEqual(kept?.outcome, .drawn)
    await store.record("scene", outcome: .notDrawn, stage: "unsupported", reason: "a new effect")
    let replaced = await store.verdict(for: "scene")
    XCTAssertEqual(replaced?.outcome, .notDrawn, "a refusal is news, whatever was seen before")
  }

  func testAnOlderSnapshotsReportArrivingLateDoesNotUndoANewerOne() async throws {
    let store = verdicts()
    await store.record(reports: [report(backend: "native_metal")], revision: 8)
    await store.record(reports: [report(backend: "unknown", stage: "unsupported", reason: "old")], revision: 7)
    let kept = await store.verdict(for: "scene")
    XCTAssertEqual(kept?.outcome, .drawn, "the report of revision 7 describes a scene that has since changed")
    await store.record(reports: [report(backend: "unknown", stage: "unsupported", reason: "new")], revision: 9)
    let newer = await store.verdict(for: "scene")
    XCTAssertEqual(newer?.reason, "new")
  }

  func testAProjectWithoutAManifestGetsNoVerdict() async throws {
    let store = verdicts()
    await store.record(reports: [report("missing", backend: "native_metal")])
    let missing = await store.verdict(for: "missing")
    XCTAssertNil(missing)
  }
}
