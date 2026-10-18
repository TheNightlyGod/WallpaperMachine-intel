import XCTest

@testable import WallpaperMachine

/// The words and rules of the scene and video diagnostics: what each row says, which readings
/// stay apart and which one offers Retry. Replaces the scene half of the old shell and settings tests.
@MainActor
final class SceneReportsTests: PanelTestCase {
  private func mode(_ id: UInt32, _ mode: String, _ reasons: [String] = []) -> SceneUpdateReport {
    SceneUpdateReport(
      BridgeSceneUpdateModeReport(
        displayId: id, displayName: "Display \(id)", wallpaperId: "w\(id)",
        wallpaperTitle: "Wallpaper \(id)", mode: mode, reasons: reasons))
  }

  private func renderer(
    _ id: UInt32, backend: String, fallback: String? = nil, videoPath: String = "none",
    applied: Bool? = true, display: String = "Display 1", title: String = "Forest"
  ) -> SceneRendererReport {
    SceneRendererReport(
      BridgeSceneBackendReport(
        displayId: id, displayName: display, wallpaperId: "w\(id)", wallpaperTitle: title,
        backend: backend, fallbackReason: fallback, videoPath: videoPath, optimizationApplied: applied))
  }

  /// A scene that failed before its first frame is stopped, not starting; the reasons are moot once
  /// it stopped; a genuine start keeps its own wording; and only a failure offers Retry.
  func testASceneThatStoppedAfterAFailureIsNeverWordedAsAPauseOrAsStarting() throws {
    try pinPanelLanguageToEnglish()
    let reports = [
      mode(1, "stopped_after_failure", ["no_frame_yet"]), mode(2, "stopped_after_failure", ["video"]),
      mode(3, "user_paused"), mode(4, "continuous", ["no_frame_yet"]),
    ]
    XCTAssertEqual(reports[0].line, "Display 1 — Wallpaper 1: stopped after a rendering failure")
    XCTAssertEqual(reports[1].line, "Display 2 — Wallpaper 2: stopped after a rendering failure")
    XCTAssertTrue(reports[2].line.hasSuffix("paused by you"), reports[2].line)
    XCTAssertTrue(reports[3].line.hasSuffix("starting — no frame drawn yet"), reports[3].line)
    XCTAssertEqual(
      reports.map(\.canRetry), [true, true, false, false],
      "A pause or a start is not a fault to retry")
  }

  /// Every mode survives intact and in order: an unreadable scene must not become continuous and a
  /// failure must not become a pause. No scene running is an empty list.
  func testSceneUpdateModesKeepUnknownApartFromEveryRealState() throws {
    try pinPanelLanguageToEnglish()
    let names = [
      "waiting_for_event", "continuous", "user_paused", "policy_suspended", "unknown",
      "stopped_after_failure", "waiting_for_deadline", "not_applicable",
    ]
    let modes = names.map { SceneUpdateMode(name: $0) }
    XCTAssertEqual(
      modes,
      [
        .waitingForEvent, .continuous, .userPaused, .policySuspended, .unknown, .stoppedAfterFailure,
        .waitingForDeadline, .notApplicable,
      ])
    XCTAssertEqual(Set(modes.map { $0.title }).count, modes.count, "No two states share words")
    XCTAssertEqual(
      mode(5, "unknown").line, "Display 5 — Wallpaper 5: running — state could not be read")
    XCTAssertEqual(SceneUpdateMode(name: "hibernating"), .other("hibernating"))
    XCTAssertEqual(
      mode(6, "hibernating").line, "Display 6 — Wallpaper 6: state reported as hibernating",
      "A mode this build does not know is reported as given")
  }

  func testTheReasonsAMovingSceneGivesAreNamedAndAnUnlistedOneIsKeptAsGiven() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertEqual(
      mode(2, "continuous", ["video", "audio_response"]).line,
      "Display 2 — Wallpaper 2: updating continuously (video, audio response)")
    XCTAssertEqual(
      mode(5, "unknown", ["unknown_input"]).line,
      "Display 5 — Wallpaper 5: running — state could not be read (an input the renderer could not account for)",
      "An input the renderer could not account for is the whole diagnosis")
    XCTAssertEqual(
      mode(7, "continuous", ["script", "novel_reason"]).line,
      "Display 7 — Wallpaper 7: updating continuously (a script, novel_reason)")
    XCTAssertEqual(SceneDemandReason(name: "no_frame_yet"), .noFrameYet)
  }

  func testAReportNamesTheDisplayAndWallpaperEvenWhenTheEngineGaveNoNames() throws {
    try pinPanelLanguageToEnglish()
    let bare = SceneUpdateReport(
      BridgeSceneUpdateModeReport(
        displayId: 9, displayName: "", wallpaperId: "", wallpaperTitle: "", mode: "continuous",
        reasons: []))
    XCTAssertEqual(bare.line, "Display 9 — wallpaper: updating continuously")
    let byID = SceneUpdateReport(
      BridgeSceneUpdateModeReport(
        displayId: 9, displayName: "", wallpaperId: "w9", wallpaperTitle: "", mode: "continuous",
        reasons: []))
    XCTAssertEqual(byID.line, "Display 9 — w9: updating continuously")
  }

  /// The renderer that drew a scene is a read-back, and only a real fallback is called one.
  func testSceneRendererLinesNameTheBackendInUseAndOnlyRealFallbacks() throws {
    try pinPanelLanguageToEnglish()
    let native = renderer(1, backend: "native_metal")
    XCTAssertEqual(native.backend, .nativeMetal)
    XCTAssertEqual(native.line(preferred: .nativeMetalPreferred), "Display 1 — Forest: Native Metal")

    let fellBack = renderer(2, backend: "legacy_vulkan", fallback: "the scene uses a puppet")
    XCTAssertEqual(
      fellBack.line(preferred: .nativeMetalPreferred),
      "Display 1 — Forest: Compatibility (fell back: the scene uses a puppet)")
    XCTAssertEqual(
      fellBack.line(preferred: .compatibility), "Display 1 — Forest: Compatibility",
      "Compatibility is not a fallback from a preference for Compatibility")

    let noReason = renderer(3, backend: "legacy_vulkan", fallback: nil)
    XCTAssertEqual(
      noReason.line(preferred: .nativeMetalPreferred), "Display 1 — Forest: Compatibility",
      "A fallback the renderer gave no reason for must not acquire an invented one")

    let preparing = renderer(4, backend: "unknown")
    XCTAssertEqual(preparing.backend, .preparing)
    XCTAssertEqual(
      preparing.line(preferred: .nativeMetalPreferred),
      "Display 1 — Forest: preparing — no backend chosen yet",
      "A backend the renderer could not name is not shown as the preference")
    XCTAssertNotEqual(preparing.backend, fellBack.backend, "Preparing and Compatibility stay different values")

    let other = renderer(5, backend: "future_backend")
    XCTAssertEqual(other.backend, .other("future_backend"))
    XCTAssertEqual(
      other.line(preferred: .nativeMetalPreferred), "Display 1 — Forest: future_backend",
      "A name this build does not know still drew the scene, so it is named as given")
  }

  func testTheVideoPathIsNamedOnlyWhenTheRendererObservedOne() throws {
    try pinPanelLanguageToEnglish()
    let paths: [(String, String?)] = [
      ("bgra", "sampled directly, no conversion"),
      ("nv12_direct", "planes sampled directly, no conversion"),
      ("nv12_converted", "converted once per frame"),
      ("nv12_mixed", "planes sampled directly, plus one shared conversion"),
      ("nv12_converted_preparing", "converted once per frame, direct sampling still being prepared"),
      ("none", nil), ("something_new", nil),
    ]
    for (name, words) in paths {
      let report = renderer(1, backend: "native_metal", videoPath: name)
      let line = report.line(preferred: .nativeMetalPreferred)
      if let words {
        XCTAssertEqual(line, "Display 1 — Forest: Native Metal — video: \(words)", name)
      } else {
        XCTAssertEqual(line, "Display 1 — Forest: Native Metal", "\(name) says nothing")
        XCTAssertNil(report.videoPath, name)
      }
    }
  }

  /// Whether the optimisation reached each scene is its own value: the saved preference is never
  /// reported as proof the setting took, and a scene that could not answer is not "applied".
  func testTheOptimisationStatusSetsTheSavedChoiceAgainstWhatTheScenesConfirmed() throws {
    try pinPanelLanguageToEnglish()
    func status(_ reports: [SceneRendererReport], saved: Bool = true) -> SceneOptimizationStatus {
      SceneOptimizationStatus(reports: reports, saved: saved)
    }
    XCTAssertNil(status([]).text, "No scene, nothing to say")
    XCTAssertNil(status([renderer(1, backend: "unknown")]).text, "A scene still choosing a backend cannot answer yet")

    XCTAssertEqual(
      status([renderer(1, backend: "native_metal", applied: true)]).text,
      "Saved on and in force on the running scene.")
    XCTAssertEqual(
      status([
        renderer(1, backend: "native_metal", applied: true),
        renderer(2, backend: "legacy_vulkan", applied: true),
      ], saved: false).text,
      "Saved off and in force on all 2 running scenes.")
    XCTAssertEqual(
      status([
        renderer(1, backend: "native_metal", applied: true),
        renderer(2, backend: "native_metal", applied: false),
      ]).text,
      "Saved on; applying to 1 of 2 running scenes on their next frame.",
      "A change that has not reached a scene yet is visible as not yet applied")
    XCTAssertEqual(
      status([
        renderer(1, backend: "native_metal", applied: true),
        renderer(2, backend: "legacy_vulkan", applied: nil),
      ]).text,
      "Saved on; 1 of 2 running scenes confirmed, the rest could not be read.",
      "A scene the renderer could not answer for is unknown, which is not the same as applied")
    let mixed = status([
      renderer(1, backend: "native_metal", applied: false),
      renderer(2, backend: "native_metal", applied: nil),
    ])
    XCTAssertEqual(mixed.pending, 1)
    XCTAssertEqual(mixed.unknown, 1)
    XCTAssertTrue(mixed.text?.hasPrefix("Saved on; applying to 1 of 2") == true, "Pending is said first")
  }

  func testTheVideoBackendLineNamesTheFallbackOnlyWhenOneWasGiven() throws {
    try pinPanelLanguageToEnglish()
    let fallback = VideoBackendReport(
      BridgeVideoBackendReport(
        displayId: 2, displayName: "Display 2", wallpaperId: "beach", wallpaperTitle: "Beach",
        backend: "legacy", fallbackReason: "29.97 fps is below the 30 fps target"))
    XCTAssertEqual(
      fallback.line, "Display 2 — Beach: legacy (fallback: 29.97 fps is below the 30 fps target)")
    let plain = VideoBackendReport(
      BridgeVideoBackendReport(
        displayId: 3, displayName: "", wallpaperId: "id3", wallpaperTitle: "", backend: "native",
        fallbackReason: nil))
    XCTAssertEqual(plain.line, "Display 3 — id3: native", "The id stands in for a missing title")
  }

  func testSharedDecodeIsReportedOnlyWhileSomethingIsShared() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertNil(SharedDecodeReport(sessions: 0, consumers: 0).text)
    XCTAssertEqual(SharedDecodeReport(sessions: 1, consumers: 3).text, "1 session serving 3 surfaces")
    XCTAssertEqual(SharedDecodeReport(sessions: 2, consumers: 1).text, "2 sessions serving 1 surface")
  }

  func testThePerformanceSettingsCarryTheReportsAndFlagANativeScene() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings(
        sceneRenderer: "native_metal_preferred",
        sceneUpdateModes: [
          BridgeSceneUpdateModeReport(
            displayId: 1, displayName: "Display 1", wallpaperId: "forest", wallpaperTitle: "Forest",
            mode: "stopped_after_failure", reasons: [])
        ],
        sceneRenderers: [
          BridgeSceneBackendReport(
            displayId: 1, displayName: "Display 1", wallpaperId: "forest", wallpaperTitle: "Forest",
            backend: "native_metal", fallbackReason: nil, videoPath: "none", optimizationApplied: true)
        ])
      let performance = panel.controller.performanceSettings
      XCTAssertEqual(performance.sceneRenderer, .nativeMetalPreferred)
      XCTAssertEqual(performance.sceneUpdates.map(\.canRetry), [true])
      XCTAssertTrue(performance.nativeSceneRunning)
      XCTAssertEqual(performance.optimization.total, 1)

      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      let empty = panel.controller.performanceSettings
      XCTAssertTrue(empty.sceneUpdates.isEmpty, "No scene running is an empty list, which is worded differently from unknown")
      XCTAssertFalse(empty.nativeSceneRunning)
    }
  }
}
