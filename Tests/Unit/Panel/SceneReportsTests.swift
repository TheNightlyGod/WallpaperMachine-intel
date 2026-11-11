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
    _ id: UInt32, backend: String, failureStage: String? = nil,
    failureReason: String? = nil, videoPath: String = "none", applied: Bool? = true,
    display: String = "Display 1", title: String = "Forest"
  ) -> SceneRendererReport {
    SceneRendererReport(
      BridgeSceneBackendReport(
        displayId: id, displayName: display, wallpaperId: "w\(id)", wallpaperTitle: title,
        backend: backend, failureStage: failureStage,
        failureReason: failureReason, videoPath: videoPath, optimizationApplied: applied, qualityInForce: nil))
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

  /// The renderer that draws a scene is a read-back: the backend the engine named, "preparing" while it has
  /// named none, and a name this build does not know, as given.
  func testSceneRendererLinesNameTheBackendInUse() throws {
    try pinPanelLanguageToEnglish()
    let native = renderer(1, backend: "native_metal")
    XCTAssertEqual(native.backend, .nativeMetal)
    XCTAssertEqual(native.line, "Display 1 — Forest: Native Metal")

    let preparing = renderer(4, backend: "unknown")
    XCTAssertEqual(preparing.backend, .preparing)
    XCTAssertEqual(
      preparing.line, "Display 1 — Forest: preparing — no backend chosen yet",
      "A backend the renderer could not name is not shown as drawing")
    XCTAssertNotEqual(preparing.backend, native.backend, "Preparing and Native Metal stay different values")

    let other = renderer(5, backend: "future_backend")
    XCTAssertEqual(other.backend, .other("future_backend"))
    XCTAssertEqual(
      other.line, "Display 1 — Forest: future_backend",
      "A name this build does not know still drew the scene, so it is named as given")

    let retired = renderer(6, backend: "legacy_vulkan")
    XCTAssertEqual(
      retired.backend, .other("legacy_vulkan"),
      "the Compatibility renderer no longer exists, so its old name is not a backend this build knows")
  }

  /// A scene Native Metal cannot draw is held, not running on any backend.
  /// Its row says so in words the user can read, in a stage of its own and with the renderer's reason,
  /// instead of "preparing" for ever or the name of a backend that is not drawing.
  func testAHeldSceneIsWordedAsNotDrawnWithItsStageAndTheRenderersOwnReason() throws {
    try pinPanelLanguageToEnglish()
    let held = renderer(
      1, backend: "unknown", failureStage: "unsupported", failureReason: "the scene uses a puppet")
    XCTAssertEqual(held.failureStage, .unsupported)
    XCTAssertEqual(held.backend, .preparing, "nothing is drawing it, and the bridge says so")
    XCTAssertEqual(
      held.line,
      "Display 1 — Forest: not drawn — it uses something Native Metal can't draw "
        + "(reason: the scene uses a puppet). Showing its last picture.")
    XCTAssertNotEqual(
      held.line,
      renderer(1, backend: "unknown").line,
      "a held scene is not one that is still preparing")

    let words = ["unsupported", "prepare", "compile", "frame", "surface"].map {
      SceneFailureStage(name: $0).title
    }
    XCTAssertEqual(Set(words).count, words.count, "no two stages share words")
    XCTAssertEqual(SceneFailureStage(name: "future").title, "it stopped (future)")
    XCTAssertEqual(
      renderer(2, backend: "unknown", failureStage: "frame").line,
      "Display 1 — Forest: not drawn — a frame failed in Native Metal. Showing its last picture.",
      "an engine that gave no reason does not acquire an invented one")

    let running = [held, renderer(3, backend: "native_metal")]
    let status = SceneOptimizationStatus(reports: running, saved: true)
    XCTAssertEqual(status.total, 1, "a held scene has no backend to confirm a setting")
  }

  func testTheVideoPathIsNamedOnlyWhenTheRendererObservedOne() throws {
    try pinPanelLanguageToEnglish()
    let paths: [(String, String?)] = [
      ("bgra", "sampled directly, no conversion"),
      ("nv12_direct", "planes sampled directly, no conversion"),
      ("nv12_converted", "converted once per frame"),
      ("nv12_mixed", "planes sampled directly, plus one shared conversion"),
      ("nv12_converted_preparing", "converted once per frame, direct sampling still being prepared"),
      ("yuv10_converted", "10-bit, converted once per frame (HDR tone mapped to SDR)"),
      ("none", nil), ("something_new", nil),
    ]
    for (name, words) in paths {
      let report = renderer(1, backend: "native_metal", videoPath: name)
      let line = report.line
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
        renderer(2, backend: "native_metal", applied: true),
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
        renderer(2, backend: "native_metal", applied: nil),
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

  func testThePerformanceSettingsCarryTheReportsAndFlagANativeScene() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings(
        sceneUpdateModes: [
          BridgeSceneUpdateModeReport(
            displayId: 1, displayName: "Display 1", wallpaperId: "forest", wallpaperTitle: "Forest",
            mode: "stopped_after_failure", reasons: [])
        ],
        sceneRenderers: [
          BridgeSceneBackendReport(
            displayId: 1, displayName: "Display 1", wallpaperId: "forest", wallpaperTitle: "Forest",
            backend: "native_metal", failureStage: nil, failureReason: nil, videoPath: "none", optimizationApplied: true, qualityInForce: nil)
        ])
      let performance = panel.controller.performanceSettings
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
