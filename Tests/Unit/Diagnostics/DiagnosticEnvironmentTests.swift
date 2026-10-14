import XCTest

@testable import WallpaperMachine

/// What the exported environment says about each running scene. The live mode
/// is the part a bug report cannot do without: a scene that stopped drawing
/// after a failure and one the user paused look the same on screen.
final class DiagnosticEnvironmentTests: XCTestCase {
  private func scene(
    displayId: UInt32 = 1, backend: String = "legacy_vulkan", fallbackReason: String? = nil
  ) -> BridgeSceneBackendReport {
    BridgeSceneBackendReport(
      displayId: displayId, displayName: "Studio Display", wallpaperId: "rain-1",
      wallpaperTitle: "Rain", backend: backend, fallbackReason: fallbackReason, videoPath: "none",
      optimizationApplied: true)
  }

  func testRunningSceneLineIncludesTheLiveMode() {
    let stopped = DiagnosticEnvironment.runningSceneLine(scene(), mode: "stopped_after_failure")
    let paused = DiagnosticEnvironment.runningSceneLine(scene(), mode: "user_paused")

    XCTAssertTrue(
      stopped.contains("mode stopped_after_failure"),
      "A report has to say that the scene stopped after a failure: \(stopped)")
    XCTAssertTrue(paused.contains("mode user_paused"))
    XCTAssertFalse(
      stopped.contains("user_paused") || paused.contains("stopped_after_failure"),
      "A failure and a pause must never read as one another")
  }

  func testRunningSceneLineKeepsWhereTheSceneRunsAndWhatDrewIt() {
    let line = DiagnosticEnvironment.runningSceneLine(
      scene(displayId: 7, backend: "legacy_vulkan", fallbackReason: "the scene uses a puppet"),
      mode: "continuous")

    for part in [
      "display 7", "Studio Display", "rain-1", "Rain", "legacy_vulkan",
      "fell back: the scene uses a puppet", "video path none",
    ] {
      XCTAssertTrue(line.contains(part), "\"\(part)\" is missing from: \(line)")
    }
  }

  func testRunningSceneLineWithoutAReadingSaysNothingAboutTheMode() {
    let line = DiagnosticEnvironment.runningSceneLine(scene(), mode: nil)

    XCTAssertFalse(
      line.contains("mode"),
      "No live reading is not a mode, and the report must not invent one: \(line)")
    XCTAssertFalse(line.contains("fell back"), "A scene that got its backend did not fall back")
  }
}
