import XCTest

@testable import WallpaperMachine

/// The Black bars card's native half: the snapshot it is drawn from and the two actions it can
/// send, checking and staging the suggested scale factor. The probe is injected and counted, so
/// every case also shows what did and did not decode.
@MainActor
final class WebPanelLetterboxTests: XCTestCase {
  private final class Probes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    func record() {
      lock.lock()
      value += 1
      lock.unlock()
    }
  }

  /// Refreshing the library is the only thing that moves `libraryRefreshRevision`.
  private final class RefreshingBridge: LayoutSnapshotBridge {
    override func refreshLibrary() async throws -> BridgeSnapshotBundle {
      guard let snapshot else { throw CancellationError() }
      return snapshot
    }
  }

  func testBuildingTheSnapshotNeverStartsAProbe() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    for _ in 0..<50 { _ = fixture.controller.snapshot() }
    XCTAssertEqual(fixture.probes.count, 0)
    let payload = try fixture.payload()
    XCTAssertEqual(payload["state"] as? String, "idle")
    XCTAssertEqual(payload["wallpaperID"] as? String, "one")
    XCTAssertEqual(payload["eligible"] as? Bool, true)
    let current = try XCTUnwrap(payload["current"] as? [String: Any])
    XCTAssertEqual(current["scalingMode"] as? String, "fill")
    XCTAssertEqual(current["scalingFactor"] as? Double, 1)
  }

  func testOnlyAnInstalledVideoGetsTheCard() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    fixture.store.librarySnapshot.wallpapers = [
      .init(id: "one", title: "one", kind: .projectScene, supported: true, active: false, selected: true, previewPath: nil)
    ]
    XCTAssertNil(fixture.controller.letterboxSnapshot(), "a scene has no baked-in bars to look for")
    fixture.store.librarySnapshot.wallpapers[0] = .init(
      id: "one", title: "one", kind: .webpage, supported: true, active: false, selected: true, previewPath: nil)
    XCTAssertNil(fixture.controller.letterboxSnapshot())
    fixture.store.appSnapshot.selectedWallpaperId = nil
    XCTAssertNil(fixture.controller.letterboxSnapshot())
    XCTAssertTrue(fixture.controller.snapshot()["videoLetterbox"] is NSNull)
  }

  func testRequestsThatDoNotMatchTheCardAreRejectedWithoutStartingAProbe() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    for body: [String: Any] in [
      ["id": "two", "displayID": "7"],  // not the selected wallpaper
      ["id": "one", "displayID": "8"],  // not the target display
      ["id": "missing", "displayID": "7"],  // not installed
      ["id": "one", "displayID": true],
    ] {
      do {
        _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(body))
        XCTFail("\(body) must be rejected")
      } catch {}
    }
    let ok: [String: Any] = ["id": "one", "displayID": "7"]

    fixture.store.settingsSnapshot.displays[0].mode = .mirror
    await assertRejected(fixture, ok, "a mirror follows its source and cannot be checked on its own")
    fixture.store.settingsSnapshot.displays[0].mode = .standalone
    fixture.store.settingsSnapshot.displays[0].enabled = false
    await assertRejected(fixture, ok, "a disabled display")
    fixture.store.settingsSnapshot.displays[0].enabled = true
    fixture.store.wallpaperOptionsSnapshot = nil
    await assertRejected(fixture, ok, "no settings snapshot for the wallpaper")
    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "one", kind: .video)
    fixture.store.librarySnapshot.wallpapers[0] = .init(
      id: "one", title: "one", kind: .projectScene, supported: true, active: false, selected: true, previewPath: nil)
    await assertRejected(fixture, ok, "a scene")

    XCTAssertEqual(fixture.probes.count, 0)
    XCTAssertEqual(fixture.letterbox.phase(for: "one", revision: fixture.store.libraryRefreshRevision), .idle)
  }

  func testSuggestionFollowsTheTargetDisplayWithoutAnotherProbe() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    fixture.letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1080) }
    let handled = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
    XCTAssertTrue(handled)
    XCTAssertEqual(fixture.probes.count, 1)

    var payload = try fixture.payload()
    XCTAssertEqual(payload["state"] as? String, "bars")
    let bars = try XCTUnwrap(payload["bars"] as? [String: Double])
    XCTAssertEqual(try XCTUnwrap(bars["left"]), 0.125, accuracy: 0.005)
    XCTAssertEqual(bars["top"], 0)
    // A 4:3 picture in a 16:9 clip: 1 / 0.75 on a 16:9 display, plus half a percent.
    XCTAssertEqual(try fixture.suggestion(payload)["kind"] as? String, "factor")
    XCTAssertEqual(try fixture.suggestion(payload)["factor"] as? Double, 1.34)

    // A 16:10 display already shows only 90% of the width, so less zoom hides the same bars.
    fixture.letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1200) }
    payload = try fixture.payload()
    XCTAssertEqual(try fixture.suggestion(payload)["factor"] as? Double, 1.21)
    // A 4:3 display shows exactly the picture.
    fixture.letterbox.viewportProvider = { _ in CGSize(width: 1600, height: 1200) }
    payload = try fixture.payload()
    XCTAssertEqual(try fixture.suggestion(payload)["kind"] as? String, "hidden")
    // A display that cannot be found gives no suggestion at all.
    fixture.letterbox.viewportProvider = { _ in nil }
    XCTAssertNil(try fixture.payload()["suggestion"])
    XCTAssertEqual(fixture.probes.count, 1, "the viewport is read when the snapshot is built, not by looking again")
  }

  func testOnlyFillGetsASuggestion() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(top: 23, bottom: 23) })
    defer { fixture.stop() }
    fixture.letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1080) }
    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .match, factor: 1)])
    _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))

    let payload = try fixture.payload()
    XCTAssertEqual(payload["state"] as? String, "bars", "the bars are still reported")
    XCTAssertNotNil(payload["bars"])
    XCTAssertNil(payload["suggestion"], "a scale factor only crops them in Fill")
    XCTAssertEqual((payload["current"] as? [String: Any])?["scalingMode"] as? String, "match")

    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .fill, factor: 1.25)])
    let fill = try fixture.payload()
    // 23 of 180 rows a side leaves 134 rows: 180 / 134 = 1.3433, plus half a percent is 1.35.
    XCTAssertEqual(try fixture.suggestion(fill)["factor"] as? Double, 1.35)
    XCTAssertEqual((fill["current"] as? [String: Any])?["scalingFactor"] as? Double, 1.25)
  }

  func testOutcomesThatAreNotBarsCarryTheirReason() async throws {
    let cases: [(frames: () -> VideoLetterboxProbe.Frames, state: String, reason: String?)] = [
      ({ LetterboxFixtures.frames() }, "none", nil),
      ({ LetterboxFixtures.frames(top: 22, bottom: 5) }, "uneven", nil),
      ({ LetterboxFixtures.frames(top: 90, bottom: 90) }, "unclear", "dark"),
      ({ LetterboxFixtures.frames(top: 44, bottom: 44) }, "unclear", "implausible"),
      ({ LetterboxFixtures.frames(count: 2) }, "unclear", "fewFrames"),
    ]
    for expected in cases {
      let fixture = try Fixture(frames: expected.frames)
      defer { fixture.stop() }
      _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
      let payload = try fixture.payload()
      XCTAssertEqual(payload["state"] as? String, expected.state)
      XCTAssertEqual(payload["reason"] as? String, expected.reason)
      XCTAssertNil(payload["suggestion"])
    }
  }

  func testFailuresAreReportedByTheirCode() async throws {
    let failures: [(VideoLetterboxProbe.Failure, String)] = [
      (.unreadable("x"), "unreadable"), (.noVideoTrack, "noVideo"), (.timedOut, "timedOut"), (.fileChanged, "changed"),
    ]
    for (failure, code) in failures {
      let fixture = try Fixture(frames: { throw failure })
      defer { fixture.stop() }
      _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
      let payload = try fixture.payload()
      XCTAssertEqual(payload["state"] as? String, "failed")
      XCTAssertEqual(payload["reason"] as? String, code)
    }
  }

  func testResultReadsAsIdleOnceTheLibraryHasBeenRefreshed() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
    XCTAssertEqual(try fixture.payload()["state"] as? String, "bars")

    fixture.bridge.snapshot = BridgeSnapshotBundle(
      app: fixture.store.appSnapshot, library: fixture.store.librarySnapshot,
      wallpaperOptions: fixture.store.wallpaperOptionsSnapshot,
      monitorInformation: fixture.store.monitorInformationSnapshot, settings: fixture.store.settingsSnapshot)
    let before = fixture.store.libraryRefreshRevision
    try await fixture.store.refreshLibraryAsync()
    XCTAssertNotEqual(fixture.store.libraryRefreshRevision, before)
    XCTAssertEqual(try fixture.payload()["state"] as? String, "idle")
    XCTAssertEqual(fixture.probes.count, 1)
  }

  func testSelectingAnotherWallpaperDropsTheCardAndItsResultWaitsForTheRevision() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
    fixture.store.appSnapshot.selectedWallpaperId = "two"
    XCTAssertEqual(try fixture.payload()["wallpaperID"] as? String, "two")
    XCTAssertEqual(try fixture.payload()["state"] as? String, "idle", "two was never checked")
    fixture.store.appSnapshot.selectedWallpaperId = "one"
    XCTAssertEqual(try fixture.payload()["state"] as? String, "bars", "one still has its result")
  }

  // MARK: Staging the suggested scale factor

  func testStagingSetsTheFactorRecomputedFromTheStoredBarsAndNotTheRequest() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()
    var stage = try fixture.stage(fixture.payload())
    XCTAssertEqual(stage["available"] as? Bool, true)
    XCTAssertEqual(stage["applied"] as? Bool, false)

    // Whatever the page claims, only the wallpaper and the display count.
    let handled = try await fixture.stageRequest(["factor": 9, "value": 9, "scalingFactor": 9, "key": "scalingFactor"])
    XCTAssertTrue(handled)
    let calls = fixture.bridge.scalingFactorCalls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.wallpaperId, "one")
    XCTAssertEqual(calls.first?.displayId, "7")
    XCTAssertEqual(try XCTUnwrap(calls.first?.factor), 1.34, accuracy: 0.0001)

    let payload = try fixture.payload()
    stage = try fixture.stage(payload)
    XCTAssertEqual(stage["applied"] as? Bool, true, "the options snapshot now carries the factor")
    XCTAssertEqual(stage["pending"] as? Bool, true, "and it is in the draft that Apply changes saves")
    XCTAssertEqual(stage["available"] as? Bool, false)
    XCTAssertEqual((payload["current"] as? [String: Any])?["scalingFactor"] as? Double, 1.34)
    XCTAssertEqual(try fixture.suggestion(payload)["factor"] as? Double, 1.34, "the suggestion itself does not move")

    await assertStageRefused(fixture, "the display already has the factor, and a stale button must not lower it")
    XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, 1)
    fixture.store.wallpaperOptionsSnapshot?.dirty = false
    XCTAssertEqual(try fixture.stage(fixture.payload())["pending"] as? Bool, false, "once applied it is no longer waiting")
    XCTAssertEqual(try fixture.stage(fixture.payload())["applied"] as? Bool, true)
  }

  func testASavedFactorIsNeverReportedAsWaitingBecauseOfAnUnrelatedEdit() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()
    // Another property is being edited, so the wallpaper's draft is dirty. The display's factor
    // was saved earlier, by hand or by an earlier session, so there is nothing for Revert to undo.
    for saved in [1.34, 2] {
      fixture.setOptions(factor: saved, dirty: true)
      let stage = try fixture.stage(fixture.payload())
      XCTAssertEqual(stage["applied"] as? Bool, true, "the display already hides the bars")
      XCTAssertEqual(stage["pending"] as? Bool, false, "a saved factor of \(saved) is not an unsaved change")
    }
  }

  func testTheStagedFactorStopsBeingPendingOnceAppliedEvenIfAnotherEditFollows() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()
    _ = try await fixture.stageRequest()
    XCTAssertEqual(try fixture.stage(fixture.payload())["pending"] as? Bool, true)

    // Apply changes saves the draft, factor included.
    fixture.setOptions(factor: 1.34, dirty: false)
    XCTAssertEqual(try fixture.stage(fixture.payload())["pending"] as? Bool, false)
    // Moving another slider makes the draft dirty again. The factor is saved and stays quiet.
    fixture.setOptions(factor: 1.34, dirty: true)
    let stage = try fixture.stage(fixture.payload())
    XCTAssertEqual(stage["applied"] as? Bool, true)
    XCTAssertEqual(stage["pending"] as? Bool, false)
  }

  func testTheStagedFactorIsForgottenWhenItIsRevertedEditedOrLeft() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()

    // Revert puts the earlier factor back; the same number typed in later is the user's own.
    _ = try await fixture.stageRequest()
    fixture.setOptions(factor: 1, dirty: false)
    XCTAssertEqual(try fixture.stage(fixture.payload())["available"] as? Bool, true)
    fixture.setOptions(factor: 1.34, dirty: true)
    XCTAssertEqual(try fixture.stage(fixture.payload())["pending"] as? Bool, false)

    // Typing another factor into the field replaces the staged one, and going back to its value
    // does not make it the card's again.
    fixture.setOptions(factor: 1, dirty: false)
    _ = try fixture.payload()
    _ = try await fixture.stageRequest()
    fixture.setOptions(factor: 1.5, dirty: true)
    XCTAssertEqual(try fixture.stage(fixture.payload())["pending"] as? Bool, false)
    fixture.setOptions(factor: 1.34, dirty: true)
    XCTAssertEqual(try fixture.stage(fixture.payload())["pending"] as? Bool, false)

    // Another wallpaper or another target display in between ends it too, though the draft of
    // the first one is still waiting when it is selected again.
    fixture.setOptions(factor: 1, dirty: false)
    _ = try fixture.payload()
    _ = try await fixture.stageRequest()
    XCTAssertEqual(try fixture.stage(fixture.payload())["pending"] as? Bool, true)
    fixture.store.appSnapshot.selectedWallpaperId = "two"
    XCTAssertEqual(try fixture.payload()["wallpaperID"] as? String, "two")
    fixture.store.appSnapshot.selectedWallpaperId = "one"
    XCTAssertEqual(try fixture.stage(fixture.payload())["pending"] as? Bool, false)

    fixture.setOptions(factor: 1, dirty: false)
    _ = try fixture.payload()
    _ = try await fixture.stageRequest()
    fixture.controller.navigation.targetDisplayID = "8"
    XCTAssertEqual(try fixture.payload()["displayID"] as? String, "8")
    fixture.controller.navigation.targetDisplayID = "7"
    XCTAssertEqual(try fixture.stage(fixture.payload())["pending"] as? Bool, false)
  }

  func testStagedFactorIsWorkedOutForTheDisplayAtTheMomentOfStaging() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()
    // The card was drawn for a 16:9 display; this one is 16:10, which already crops a tenth.
    fixture.letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1200) }
    _ = try await fixture.stageRequest()
    XCTAssertEqual(try XCTUnwrap(fixture.bridge.scalingFactorCalls.first?.factor), 1.21, accuracy: 0.0001)

    // A display that cannot be found stages nothing.
    let other = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { other.stop() }
    try await other.check()
    other.letterbox.viewportProvider = { _ in nil }
    await assertStageRefused(other, "no viewport to work the factor out for")
    XCTAssertTrue(other.bridge.scalingFactorCalls.isEmpty)
  }

  func testStagingIsRefusedWhenTheCardDoesNotMatchWhatIsSelectedAndConfigured() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()
    for body: [String: Any] in [
      ["id": "two", "displayID": "7"],  // not the selected wallpaper
      ["id": "one", "displayID": "8"],  // not the target display
      ["id": "missing", "displayID": "7"],  // not installed
      ["id": "one", "displayID": true],
      ["displayID": "7"],
    ] {
      do {
        _ = try await fixture.controller.performLetterbox("videoLetterboxStage", request: .init(body))
        XCTFail("\(body) must be rejected")
      } catch {}
    }
    fixture.store.appSnapshot.selectedWallpaperId = "two"
    await assertStageRefused(fixture, "a stale selected id")
    fixture.store.appSnapshot.selectedWallpaperId = "one"
    fixture.store.settingsSnapshot.displays[0].mode = .mirror
    await assertStageRefused(fixture, "a mirror follows its source")
    fixture.store.settingsSnapshot.displays[0].mode = .standalone
    fixture.store.settingsSnapshot.displays[0].enabled = false
    await assertStageRefused(fixture, "a disabled display")
    fixture.store.settingsSnapshot.displays[0].enabled = true
    fixture.store.wallpaperOptionsSnapshot = nil
    await assertStageRefused(fixture, "no settings snapshot for the wallpaper")
    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "one", kind: .video)
    fixture.store.settingsSnapshot.displays[0].scalingMode = .match
    await assertStageRefused(fixture, "a factor only crops in Fill")
    fixture.store.settingsSnapshot.displays[0].scalingMode = .fill
    fixture.store.librarySnapshot.wallpapers[0] = .init(
      id: "one", title: "one", kind: .projectScene, supported: true, active: false, selected: true, previewPath: nil)
    await assertStageRefused(fixture, "a scene")

    XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
    XCTAssertEqual(fixture.probes.count, 1, "refusing never decodes anything")
  }

  func testOnlyAResultThatFoundBarsCanBeStaged() async throws {
    let cases: [() -> VideoLetterboxProbe.Frames] = [
      { LetterboxFixtures.frames() },  // none
      { LetterboxFixtures.frames(top: 22, bottom: 5) },  // uneven
      { LetterboxFixtures.frames(top: 90, bottom: 90) },  // too dark
      { LetterboxFixtures.frames(top: 44, bottom: 44) },  // implausible
      { LetterboxFixtures.frames(count: 2) },  // too few frames
    ]
    for frames in cases {
      let fixture = try Fixture(frames: frames)
      defer { fixture.stop() }
      try await fixture.check()
      await assertStageRefused(fixture, "a result without bars")
      XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
    }

    let failed = try Fixture(frames: { throw VideoLetterboxProbe.Failure.timedOut })
    defer { failed.stop() }
    try await failed.check()
    await assertStageRefused(failed, "a failed check")

    let idle = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { idle.stop() }
    await assertStageRefused(idle, "nothing was checked yet")

    // A 4:3 display already shows exactly the picture, so there is no factor to set.
    let hidden = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { hidden.stop() }
    try await hidden.check()
    hidden.letterbox.viewportProvider = { _ in CGSize(width: 1600, height: 1200) }
    XCTAssertEqual(try hidden.stage(hidden.payload())["available"] as? Bool, false)
    await assertStageRefused(hidden, "Fill already crops the bars")

    XCTAssertTrue([failed, idle, hidden].allSatisfy { $0.bridge.scalingFactorCalls.isEmpty })
  }

  func testAResultFromBeforeALibraryRefreshCannotBeStaged() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()
    fixture.bridge.snapshot = BridgeSnapshotBundle(
      app: fixture.store.appSnapshot, library: fixture.store.librarySnapshot,
      wallpaperOptions: fixture.store.wallpaperOptionsSnapshot,
      monitorInformation: fixture.store.monitorInformationSnapshot, settings: fixture.store.settingsSnapshot)
    try await fixture.store.refreshLibraryAsync()
    XCTAssertEqual(try fixture.payload()["state"] as? String, "idle")
    XCTAssertNil(try fixture.payload()["stage"])
    await assertStageRefused(fixture, "the files may have been replaced")
    XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
  }

  func testStagingAfterTheFileWasReplacedIsRefusedAndTheResultIsDropped() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()
    try Data("a different, longer video file".utf8).write(to: fixture.video)
    do {
      _ = try await fixture.stageRequest()
      XCTFail("A replaced file must not be staged from the old measurement")
    } catch let error as WallpaperActionError {
      XCTAssertEqual(error.message, String(localized: "The video changed since it was checked. Look for black bars again."))
    }
    XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
    XCTAssertEqual(try fixture.payload()["state"] as? String, "idle", "the card offers a new look")
    await assertStageRefused(fixture, "the old result is gone")

    try await fixture.check()
    XCTAssertEqual(fixture.probes.count, 2)
    _ = try await fixture.stageRequest()
    XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, 1)
  }

  func testStagingIsRefusedWhenTheSelectionMovesWhileTheFileIsBeingConfirmed() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()
    fixture.hooks.onResolve = { fixture.store.appSnapshot.selectedWallpaperId = "two" }
    await assertStageRefused(fixture, "the card belongs to a wallpaper that is no longer selected")
    XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
  }

  func testStagingDoesNotDependOnWhichVideoBackendPlaysTheClip() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()

    // Both backends apply the scale factor, so neither the preference nor a running report that
    // names the native player holds the button back.
    fixture.store.settingsSnapshot.videoBackend = "native_preferred"
    fixture.store.settingsSnapshot.videoBackends = [
      .init(displayId: 7, displayName: "Display", wallpaperId: "one", wallpaperTitle: "one",
            backend: "native", fallbackReason: nil)
    ]
    XCTAssertEqual(try fixture.stage(fixture.payload())["available"] as? Bool, true)
    _ = try await fixture.stageRequest()
    XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, 1)
  }

  func testStageStateNamesTheModeThatCannotUseAFactorAndKeepsABiggerOne() async throws {
    let fixture = try Fixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) })
    defer { fixture.stop() }
    try await fixture.check()
    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .match, factor: 1)])
    var payload = try fixture.payload()
    XCTAssertNil(payload["suggestion"])
    var stage = try fixture.stage(payload)
    XCTAssertEqual(stage["available"] as? Bool, false)
    await assertStageRefused(fixture, "only Fill turns a scale factor into a crop")
    XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)

    // The user's own larger factor already hides the bars, and staging would only lower it.
    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .fill, factor: 2)])
    payload = try fixture.payload()
    stage = try fixture.stage(payload)
    XCTAssertEqual(stage["applied"] as? Bool, true)
    XCTAssertEqual(stage["available"] as? Bool, false)
    await assertStageRefused(fixture, "a larger factor is already set")
    XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)

    // Just under the suggestion still hides the bars: it carries half a percent of overscan.
    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .fill, factor: 1.336)])
    XCTAssertEqual(try fixture.stage(fixture.payload())["applied"] as? Bool, true)
    fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .fill, factor: 1.3)])
    XCTAssertEqual(try fixture.stage(fixture.payload())["applied"] as? Bool, false)
    XCTAssertEqual(try fixture.stage(fixture.payload())["available"] as? Bool, true)
  }

  private func assertStageRefused(_ fixture: Fixture, _ why: String,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    let before = fixture.bridge.scalingFactorCalls.count
    do {
      _ = try await fixture.stageRequest()
      XCTFail("Must refuse: \(why)", file: file, line: line)
    } catch {}
    XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, before, "Refused: \(why)", file: file, line: line)
  }

  private func assertRejected(_ fixture: Fixture, _ body: [String: Any], _ why: String,
                              file: StaticString = #filePath, line: UInt = #line) async {
    do {
      _ = try await fixture.controller.performLetterbox("videoLetterboxCheck", request: .init(body))
      XCTFail("Must reject: \(why)", file: file, line: line)
    } catch {}
  }

  /// Runs when the store resolves the video file, so a test can change the panel while a staging
  /// request is waiting for it.
  @MainActor
  private final class ResolveHooks {
    var onResolve: (@MainActor () -> Void)?
  }

  @MainActor
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-letterbox-\(UUID().uuidString)")
    let defaults: UserDefaults
    let bridge: RefreshingBridge
    let store: BridgeStore
    let controller: WebPanelController
    let letterbox: VideoLetterboxStore
    let probes: Probes
    let video: URL
    let hooks: ResolveHooks

    init(frames: @escaping @Sendable () throws -> VideoLetterboxProbe.Frames = { LetterboxFixtures.frames(top: 23, bottom: 23) }) throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let video = root.appendingPathComponent("video.mp4")
      self.video = video
      try Data("x".utf8).write(to: video)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      bridge = RefreshingBridge(noPointer: .init())
      store = BridgeStore(bridge: bridge)
      let counter = Probes()
      probes = counter
      let hooks = ResolveHooks()
      self.hooks = hooks
      letterbox = VideoLetterboxStore(
        probe: VideoLetterboxProbe(frames: { _ in
          counter.record()
          return try frames()
        }, timeout: .seconds(600)),
        entry: { _, _ in
          hooks.onResolve?()
          return video
        })
      let navigation = ControlPanelNavigation()
      navigation.targetDisplayID = "7"
      let workshop = WorkshopStore(downloader: WorkshopDownloadManager(sessionDirectory: root),
                                  supportDirectory: root, defaults: defaults)
      controller = WebPanelController(store: store, navigation: navigation, workshop: workshop,
                                     defaults: defaults, appLanguage: .english(), letterbox: letterbox)
      store.appSnapshot.selectedWallpaperId = "one"
      store.librarySnapshot.wallpapers = ["one", "two"].map {
        .init(id: $0, title: $0, kind: .video, supported: true, active: false, selected: $0 == "one", previewPath: nil)
      }
      store.settingsSnapshot.displays = [
        .init(displayId: "7", title: "Display", enabled: true, mode: .standalone, mirrorTargets: [],
              selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
              targetFps: 60, maxFps: 60, muted: false, volume: 1)
      ]
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "one", kind: .video)
      letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1080) }
      // The engine's reply: the same snapshots with the factor in the draft, as the bridge answers.
      bridge.scalingFactorReply = { [store] _, display, factor in
        var options = try XCTUnwrap(store.wallpaperOptionsSnapshot)
        let mode = options.displayConfigurations.first { $0.displayId == display }?.scalingMode
          ?? store.settingsSnapshot.displays.first { $0.displayId == display }?.scalingMode ?? .fill
        options.displayConfigurations = [
          BridgeDisplayConfigRow(displayId: display, title: "Display", enabled: true, scalingMode: mode,
                                 scalingFactor: factor, framing: .centered, targetFps: 60, maxFps: 60,
                                 muted: false, volume: 1, dirty: true, canRestoreDefaults: true)
        ]
        options.dirty = true
        return BridgeWallpaperMutationBundle(
          app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: options,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
    }

    func check() async throws {
      _ = try await controller.performLetterbox("videoLetterboxCheck", request: .init(["id": "one", "displayID": "7"]))
    }

    /// The page's stage request; `extra` is whatever else a tampered page might add.
    @discardableResult
    func stageRequest(_ extra: [String: Any] = [:]) async throws -> Bool {
      let body = ["id": "one", "displayID": "7"].merging(extra) { _, new in new } as [String: Any]
      return try await controller.performLetterbox("videoLetterboxStage", request: .init(body))
    }

    func stage(_ payload: [String: Any]) throws -> [String: Any] {
      try XCTUnwrap(payload["stage"] as? [String: Any])
    }

    /// The wallpaper's options as the engine would report them with the display at `factor`.
    func setOptions(mode: BridgeScalingMode = .fill, factor: Double, dirty: Bool) {
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "one", kind: .video, dirty: dirty, displayConfigurations: [configuration(mode: mode, factor: factor)])
    }

    func configuration(mode: BridgeScalingMode, factor: Double) -> BridgeDisplayConfigRow {
      BridgeDisplayConfigRow(displayId: "7", title: "Display", enabled: true, scalingMode: mode,
                             scalingFactor: factor, framing: .centered, targetFps: 60, maxFps: 60,
                             muted: false, volume: 1, dirty: false, canRestoreDefaults: false)
    }

    func payload() throws -> [String: Any] {
      try XCTUnwrap(controller.letterboxSnapshot())
    }

    func suggestion(_ payload: [String: Any]) throws -> [String: Any] {
      try XCTUnwrap(payload["suggestion"] as? [String: Any])
    }

    func stop() {
      controller.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }
}
