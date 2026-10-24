import XCTest

@testable import WallpaperMachine

/// The Black bars card at the panel level: the state it is drawn from and the two actions it can
/// start, checking and staging the suggested scale factor. The probe is injected and counted, so
/// every case also shows what did and did not decode.
@MainActor
final class PanelLetterboxTests: PanelTestCase {
  private final class Probes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
  }

  /// Runs when the store resolves the video file, so a test can change the panel while a staging
  /// request is waiting for it.
  @MainActor
  private final class ResolveHooks { var onResolve: (@MainActor () -> Void)? }

  @MainActor
  private final class Fixture {
    let panel: PanelFixture
    let letterbox: VideoLetterboxStore
    let probes: Probes
    let video: URL
    let hooks: ResolveHooks

    var controller: PanelController { panel.controller }
    var store: BridgeStore { panel.store }
    var bridge: LayoutSnapshotBridge { panel.bridge }

    init(
      test: PanelLetterboxTests,
      frames: @escaping @Sendable () throws -> VideoLetterboxProbe.Frames = {
        LetterboxFixtures.frames(top: 23, bottom: 23)
      }
    ) throws {
      let counter = Probes()
      let hooks = ResolveHooks()
      probes = counter
      self.hooks = hooks
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "panel-letterbox-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let video = root.appendingPathComponent("video.mp4")
      self.video = video
      try Data("x".utf8).write(to: video)
      letterbox = VideoLetterboxStore(
        probe: VideoLetterboxProbe(
          frames: { _ in
            counter.record()
            return try frames()
          }, timeout: .seconds(600)),
        entry: { _, _ in
          hooks.onResolve?()
          return video
        })
      panel = try test.makeController(letterbox: letterbox)
      panel.navigation.targetDisplayID = "7"
      store.appSnapshot.selectedWallpaperId = "one"
      store.librarySnapshot.wallpapers = ["one", "two"].map {
        .init(
          id: $0, title: $0, kind: .video, supported: true, active: false, selected: $0 == "one",
          previewPath: nil)
      }
      store.settingsSnapshot.displays = [
        .init(
          displayId: "7", title: "Display", enabled: true, mode: .standalone, mirrorTargets: [],
          selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 60, maxFps: 60,
          muted: false, volume: 1)
      ]
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "one", kind: .video)
      letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1080) }
      // The engine's reply: the same snapshots with the factor in the draft, as the bridge answers.
      bridge.scalingFactorReply = { [store = panel.store] _, display, factor in
        var options = try XCTUnwrap(store.wallpaperOptionsSnapshot)
        let mode =
          options.displayConfigurations.first { $0.displayId == display }?.scalingMode
          ?? store.settingsSnapshot.displays.first { $0.displayId == display }?.scalingMode ?? .fill
        options.displayConfigurations = [
          BridgeDisplayConfigRow(
            displayId: display, title: "Display", enabled: true, scalingMode: mode, scalingFactor: factor,
            framing: .centered, targetFps: 60, maxFps: 60, muted: false, volume: 1, dirty: true,
            canRestoreDefaults: true)
        ]
        options.dirty = true
        return BridgeWallpaperMutationBundle(
          app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: options,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
    }

    func check() async throws { try await controller.checkLetterbox("one", display: "7") }

    func stage() async throws { try await controller.stageLetterboxFactor("one", display: "7") }

    /// What building the card used to do on every snapshot, then the card: the explicit context
    /// reconcile, then the state.
    func card() throws -> LetterboxState {
      controller.reconcileInspectorContext()
      return try XCTUnwrap(controller.letterboxState)
    }

    /// The wallpaper's options as the engine would report them with the display at `factor`.
    func setOptions(mode: BridgeScalingMode = .fill, factor: Double, dirty: Bool) {
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "one", kind: .video, dirty: dirty,
        displayConfigurations: [configuration(mode: mode, factor: factor)])
    }

    func configuration(mode: BridgeScalingMode, factor: Double) -> BridgeDisplayConfigRow {
      BridgeDisplayConfigRow(
        displayId: "7", title: "Display", enabled: true, scalingMode: mode, scalingFactor: factor,
        framing: .centered, targetFps: 60, maxFps: 60, muted: false, volume: 1, dirty: false,
        canRestoreDefaults: false)
    }

    func refreshLibrary() async throws {
      bridge.snapshot = BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot,
        wallpaperOptions: store.wallpaperOptionsSnapshot,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      try await store.refreshLibraryAsync()
    }

    func shutdown() async {
      await panel.shutdown()
      try? FileManager.default.removeItem(at: video.deletingLastPathComponent())
    }
  }

  private func withFixture(
    frames: @escaping @Sendable () throws -> VideoLetterboxProbe.Frames = {
      LetterboxFixtures.frames(top: 23, bottom: 23)
    },
    _ body: (Fixture) async throws -> Void
  ) async throws {
    let fixture = try Fixture(test: self, frames: frames)
    do { try await body(fixture) } catch {
      await fixture.shutdown()
      throw error
    }
    await fixture.shutdown()
  }

  private func barsCard(_ state: LetterboxState) throws -> (
    bars: LetterboxDetector.Bars, suggestion: LetterboxState.Suggestion?, stage: LetterboxState.Stage
  ) {
    guard case .bars(let bars, let suggestion, let stage) = state.outcome else {
      XCTFail("the card found no bars: \(state.outcome)")
      throw InspectorTestRefusal()
    }
    return (bars, suggestion, stage)
  }

  private func assertStageRefused(
    _ fixture: Fixture, _ why: String, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let before = fixture.bridge.scalingFactorCalls.count
    do {
      try await fixture.stage()
      XCTFail("Must refuse: \(why)", file: file, line: line)
    } catch {}
    XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, before, "Refused: \(why)", file: file, line: line)
  }

  // MARK: The card

  func testBuildingTheStateNeverStartsAProbe() async throws {
    try await withFixture { fixture in
      for _ in 0..<50 {
        _ = fixture.controller.letterboxState
        fixture.controller.reconcileInspectorContext()
      }
      XCTAssertEqual(fixture.probes.count, 0)
      let state = try fixture.card()
      XCTAssertEqual(state.outcome, .idle)
      XCTAssertEqual(state.wallpaperID, "one")
      XCTAssertEqual(state.displayID, "7")
      XCTAssertTrue(state.isEligible)
      XCTAssertEqual(state.scalingMode, .fill)
      XCTAssertEqual(state.scalingFactor, 1)
    }
  }

  func testOnlyAnInstalledVideoGetsTheCard() async throws {
    try await withFixture { fixture in
      fixture.store.librarySnapshot.wallpapers = [
        .init(
          id: "one", title: "one", kind: .projectScene, supported: true, active: false, selected: true,
          previewPath: nil)
      ]
      XCTAssertNil(fixture.controller.letterboxState, "a scene has no baked-in bars to look for")
      fixture.store.librarySnapshot.wallpapers[0] = .init(
        id: "one", title: "one", kind: .webpage, supported: true, active: false, selected: true,
        previewPath: nil)
      XCTAssertNil(fixture.controller.letterboxState)
      fixture.store.appSnapshot.selectedWallpaperId = nil
      XCTAssertNil(fixture.controller.letterboxState)
    }
  }

  func testRequestsThatDoNotMatchTheCardAreRejectedWithoutStartingAProbe() async throws {
    try await withFixture { fixture in
      for (id, display) in [("two", "7"), ("one", "8"), ("missing", "7")] {
        do {
          try await fixture.controller.checkLetterbox(id, display: display)
          XCTFail("\(id) on \(display) must be rejected")
        } catch {}
      }
      func assertRejected(_ why: String) async {
        do {
          try await fixture.check()
          XCTFail("Must reject: \(why)")
        } catch {}
      }
      fixture.store.settingsSnapshot.displays[0].mode = .mirror
      await assertRejected("a mirror follows its source and cannot be checked on its own")
      XCTAssertEqual(fixture.controller.letterboxState?.isEligible, false)
      fixture.store.settingsSnapshot.displays[0].mode = .standalone
      fixture.store.settingsSnapshot.displays[0].enabled = false
      await assertRejected("a disabled display")
      fixture.store.settingsSnapshot.displays[0].enabled = true
      fixture.store.wallpaperOptionsSnapshot = nil
      await assertRejected("no settings snapshot for the wallpaper")
      fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "one", kind: .video)
      fixture.store.librarySnapshot.wallpapers[0] = .init(
        id: "one", title: "one", kind: .projectScene, supported: true, active: false, selected: true,
        previewPath: nil)
      await assertRejected("a scene")

      XCTAssertEqual(fixture.probes.count, 0)
      XCTAssertEqual(
        fixture.letterbox.phase(for: "one", revision: fixture.store.libraryRefreshRevision), .idle)
    }
  }

  func testSuggestionFollowsTheTargetDisplayWithoutAnotherProbe() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      XCTAssertEqual(fixture.probes.count, 1)

      var card = try barsCard(fixture.card())
      XCTAssertEqual(card.bars.left, 0.125, accuracy: 0.005)
      XCTAssertEqual(card.bars.top, 0)
      // A 4:3 picture in a 16:9 clip: 1 / 0.75 on a 16:9 display, plus half a percent.
      XCTAssertEqual(card.suggestion, .factor(1.34))
      XCTAssertEqual(LetterboxState.layout(of: card.bars), .leftAndRight(percent: 13))

      // A 16:10 display already shows only 90% of the width, so less zoom hides the same bars.
      fixture.letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1200) }
      card = try barsCard(fixture.card())
      XCTAssertEqual(card.suggestion, .factor(1.21))
      // A 4:3 display shows exactly the picture.
      fixture.letterbox.viewportProvider = { _ in CGSize(width: 1600, height: 1200) }
      card = try barsCard(fixture.card())
      XCTAssertEqual(card.suggestion, .alreadyHidden)
      // A display that cannot be found gives no suggestion at all.
      fixture.letterbox.viewportProvider = { _ in nil }
      XCTAssertNil(try barsCard(fixture.card()).suggestion)
      XCTAssertEqual(fixture.probes.count, 1, "the viewport is read when the card is built, not by looking again")
    }
  }

  func testOnlyFillGetsASuggestion() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(top: 23, bottom: 23) }) { fixture in
      fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .match, factor: 1)])
      try await fixture.check()

      var state = try fixture.card()
      var card = try barsCard(state)
      XCTAssertNil(card.suggestion, "a scale factor only crops the bars in Fill")
      XCTAssertEqual(LetterboxState.layout(of: card.bars), .topAndBottom(percent: 13), "the bars are still reported")
      XCTAssertEqual(state.scalingMode, .match)
      XCTAssertFalse(card.stage.isAvailable)

      fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .fill, factor: 1.25)])
      state = try fixture.card()
      card = try barsCard(state)
      // 23 of 180 rows a side leaves 134 rows: 180 / 134 = 1.3433, plus half a percent is 1.35.
      XCTAssertEqual(card.suggestion, .factor(1.35))
      XCTAssertEqual(state.scalingFactor, 1.25)
    }
  }

  func testOutcomesThatAreNotBarsCarryTheirReason() async throws {
    let cases: [(frames: @Sendable () -> VideoLetterboxProbe.Frames, outcome: LetterboxState.Outcome?)] = [
      ({ LetterboxFixtures.frames() }, LetterboxState.Outcome.none),
      ({ LetterboxFixtures.frames(top: 22, bottom: 5) }, nil),  // uneven: bars, but never a suggestion
      ({ LetterboxFixtures.frames(top: 90, bottom: 90) }, .unclear(.dark)),
      ({ LetterboxFixtures.frames(top: 44, bottom: 44) }, .unclear(.implausible)),
      ({ LetterboxFixtures.frames(count: 2) }, .unclear(.fewFrames)),
    ]
    for expected in cases {
      try await withFixture(frames: expected.frames) { fixture in
        try await fixture.check()
        let state = try fixture.card()
        if let outcome = expected.outcome {
          XCTAssertEqual(state.outcome, outcome)
        } else {
          guard case .uneven(let bars) = state.outcome else { return XCTFail("\(state.outcome)") }
          XCTAssertGreaterThan(bars.widest, 0)
        }
      }
    }
  }

  func testFailuresAreReportedByTheirCode() async throws {
    let failures: [(VideoLetterboxProbe.Failure, LetterboxState.Failure)] = [
      (.unreadable("x"), .unreadable), (.noVideoTrack, .noVideo), (.timedOut, .timedOut),
      (.fileChanged, .changed),
    ]
    for (failure, code) in failures {
      try await withFixture(frames: { throw failure }) { fixture in
        try await fixture.check()
        XCTAssertEqual(try fixture.card().outcome, .failed(code))
      }
    }
  }

  func testResultReadsAsIdleOnceTheLibraryHasBeenRefreshed() async throws {
    try await withFixture { fixture in
      try await fixture.check()
      _ = try barsCard(fixture.card())

      let before = fixture.store.libraryRefreshRevision
      try await fixture.refreshLibrary()
      XCTAssertNotEqual(fixture.store.libraryRefreshRevision, before)
      XCTAssertEqual(try fixture.card().outcome, .idle, "the file may have been replaced")
      XCTAssertEqual(fixture.probes.count, 1)
    }
  }

  func testSelectingAnotherWallpaperDropsTheCardAndItsResultWaitsForTheRevision() async throws {
    try await withFixture { fixture in
      try await fixture.check()
      fixture.store.appSnapshot.selectedWallpaperId = "two"
      XCTAssertEqual(try fixture.card().wallpaperID, "two")
      XCTAssertEqual(try fixture.card().outcome, .idle, "two was never checked")
      fixture.store.appSnapshot.selectedWallpaperId = "one"
      _ = try barsCard(fixture.card())
    }
  }

  func testTheCardShowsTheMeasuredBarsAndTheFactorForTheTargetDisplayOnlyForAVideo() async throws {
    try await withFixture { fixture in
      XCTAssertEqual(try fixture.card().outcome, .idle)
      try await fixture.check()
      var card = try barsCard(fixture.card())
      // 23 of 180 rows a side: about 13% of the picture on each side, and 180 / 134 plus half a
      // percent, rounded up, on a 16:9 display.
      XCTAssertEqual(LetterboxState.layout(of: card.bars), .topAndBottom(percent: 13))
      XCTAssertEqual(card.suggestion, .factor(1.35))
      XCTAssertEqual(card.stage, .init(isAvailable: true, isApplied: false, isPending: false))
      // Whichever video player plays the clip, the factor can be set.
      XCTAssertTrue(try barsCard(fixture.card()).stage.isAvailable)

      try await fixture.stage()
      XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, 1)
      XCTAssertEqual(fixture.bridge.scalingFactorCalls.first?.wallpaperId, "one")
      XCTAssertEqual(fixture.bridge.scalingFactorCalls.first?.displayId, "7")
      XCTAssertEqual(try XCTUnwrap(fixture.bridge.scalingFactorCalls.first?.factor), 1.35, accuracy: 0.0001)
      card = try barsCard(fixture.card())
      XCTAssertEqual(card.stage, .init(isAvailable: false, isApplied: true, isPending: true))

      fixture.store.appSnapshot.selectedWallpaperId = "scene"
      fixture.store.librarySnapshot.wallpapers.append(
        .init(
          id: "scene", title: "Scene", kind: .projectScene, supported: true, active: false, selected: false,
          previewPath: nil))
      XCTAssertNil(fixture.controller.letterboxState)
    }
  }

  func testTheLayoutWordsTheBarsByWhereTheyAreAndHowWideTheWidestIs() {
    func bars(_ top: Double, _ bottom: Double, _ left: Double, _ right: Double) -> LetterboxDetector.Bars {
      .init(top: top, bottom: bottom, left: left, right: right)
    }
    XCTAssertEqual(LetterboxState.layout(of: bars(0.1, 0.1, 0.05, 0.05)), .allFourSides(percent: 10))
    XCTAssertEqual(LetterboxState.layout(of: bars(0, 0, 0.2, 0.2)), .leftAndRight(percent: 20))
    XCTAssertEqual(LetterboxState.layout(of: bars(0.13, 0.12, 0, 0)), .topAndBottom(percent: 13))
    XCTAssertEqual(
      LetterboxState.layout(of: bars(0.001, 0.001, 0, 0)), .topAndBottom(percent: 1),
      "a bar is never worded as less than one percent")
    XCTAssertEqual(
      LetterboxState.layout(of: bars(0, 0, 0.05, 0)), .topAndBottom(percent: 1),
      "anything that is not a matching pair falls to the top and bottom wording")
  }

  // MARK: Staging the suggested scale factor

  func testStagingSetsTheFactorRecomputedFromTheStoredBarsAndTheDisplay() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      var card = try barsCard(fixture.card())
      XCTAssertEqual(card.stage, .init(isAvailable: true, isApplied: false, isPending: false))

      try await fixture.stage()
      let calls = fixture.bridge.scalingFactorCalls
      XCTAssertEqual(calls.count, 1)
      XCTAssertEqual(calls.first?.wallpaperId, "one")
      XCTAssertEqual(calls.first?.displayId, "7")
      XCTAssertEqual(try XCTUnwrap(calls.first?.factor), 1.34, accuracy: 0.0001)

      let state = try fixture.card()
      card = try barsCard(state)
      XCTAssertEqual(
        card.stage, .init(isAvailable: false, isApplied: true, isPending: true),
        "the options now carry the factor, and it is in the draft that Apply changes saves")
      XCTAssertEqual(state.scalingFactor, 1.34)
      XCTAssertEqual(card.suggestion, .factor(1.34), "the suggestion itself does not move")

      await assertStageRefused(fixture, "the display already has the factor, and a stale button must not lower it")
      XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, 1)
      fixture.store.wallpaperOptionsSnapshot?.dirty = false
      card = try barsCard(fixture.card())
      XCTAssertFalse(card.stage.isPending, "once applied it is no longer waiting")
      XCTAssertTrue(card.stage.isApplied)
    }
  }

  func testASavedFactorIsNeverReportedAsWaitingBecauseOfAnUnrelatedEdit() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      // Another property is being edited, so the wallpaper's draft is dirty. The display's factor was
      // saved earlier, so there is nothing for Revert to undo.
      for saved in [1.34, 2] {
        fixture.setOptions(factor: saved, dirty: true)
        let stage = try barsCard(fixture.card()).stage
        XCTAssertTrue(stage.isApplied, "the display already hides the bars")
        XCTAssertFalse(stage.isPending, "a saved factor of \(saved) is not an unsaved change")
      }
    }
  }

  func testTheStagedFactorStopsBeingPendingOnceAppliedEvenIfAnotherEditFollows() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      try await fixture.stage()
      XCTAssertTrue(try barsCard(fixture.card()).stage.isPending)

      // Apply changes saves the draft, factor included.
      fixture.setOptions(factor: 1.34, dirty: false)
      XCTAssertFalse(try barsCard(fixture.card()).stage.isPending)
      // Moving another slider makes the draft dirty again. The factor is saved and stays quiet.
      fixture.setOptions(factor: 1.34, dirty: true)
      let stage = try barsCard(fixture.card()).stage
      XCTAssertTrue(stage.isApplied)
      XCTAssertFalse(stage.isPending)
    }
  }

  func testTheStagedFactorIsForgottenWhenItIsRevertedEditedOrLeft() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()

      // Revert puts the earlier factor back; the same number typed in later is the user's own.
      try await fixture.stage()
      fixture.setOptions(factor: 1, dirty: false)
      XCTAssertTrue(try barsCard(fixture.card()).stage.isAvailable)
      XCTAssertNil(fixture.controller.letterboxStaged, "the claim ended with the revert")
      fixture.setOptions(factor: 1.34, dirty: true)
      XCTAssertFalse(try barsCard(fixture.card()).stage.isPending)

      // Typing another factor into the field replaces the staged one, and going back to its value
      // does not make it the card's again.
      fixture.setOptions(factor: 1, dirty: false)
      _ = try fixture.card()
      try await fixture.stage()
      fixture.setOptions(factor: 1.5, dirty: true)
      XCTAssertFalse(try barsCard(fixture.card()).stage.isPending)
      fixture.setOptions(factor: 1.34, dirty: true)
      XCTAssertFalse(try barsCard(fixture.card()).stage.isPending)

      // Another wallpaper or another target display in between ends it too, though the draft of the
      // first one is still waiting when it is selected again.
      fixture.setOptions(factor: 1, dirty: false)
      _ = try fixture.card()
      try await fixture.stage()
      XCTAssertTrue(try barsCard(fixture.card()).stage.isPending)
      fixture.store.appSnapshot.selectedWallpaperId = "two"
      XCTAssertEqual(try fixture.card().wallpaperID, "two")
      fixture.store.appSnapshot.selectedWallpaperId = "one"
      XCTAssertFalse(try barsCard(fixture.card()).stage.isPending)

      fixture.setOptions(factor: 1, dirty: false)
      _ = try fixture.card()
      try await fixture.stage()
      fixture.panel.navigation.targetDisplayID = "8"
      XCTAssertEqual(try fixture.card().displayID, "8")
      fixture.panel.navigation.targetDisplayID = "7"
      XCTAssertFalse(try barsCard(fixture.card()).stage.isPending)
    }
  }

  func testTheObservationForgetsAStagedFactorWithoutAnyoneBuildingTheCard() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      fixture.controller.start()
      _ = fixture.controller.letterboxState  // an inspector reading its state starts the observation
      try await fixture.check()
      try await fixture.stage()
      XCTAssertNotNil(fixture.controller.letterboxStaged)

      // The draft is applied and reverted elsewhere; only the stores change.
      fixture.setOptions(factor: 1, dirty: false)
      try await fixture.panel.waitUntil { fixture.controller.letterboxStaged == nil }
      XCTAssertNil(fixture.controller.letterboxStaged)

      fixture.controller.stopInspectorContextObservation()
      XCTAssertNil(fixture.controller.inspectorContextLoop)
    }
  }

  func testStagedFactorIsWorkedOutForTheDisplayAtTheMomentOfStaging() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      // The card was drawn for a 16:9 display; this one is 16:10, which already crops a tenth.
      fixture.letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1200) }
      try await fixture.stage()
      XCTAssertEqual(try XCTUnwrap(fixture.bridge.scalingFactorCalls.first?.factor), 1.21, accuracy: 0.0001)
    }
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { other in
      try await other.check()
      // A display that cannot be found stages nothing.
      other.letterbox.viewportProvider = { _ in nil }
      await assertStageRefused(other, "no viewport to work the factor out for")
      XCTAssertTrue(other.bridge.scalingFactorCalls.isEmpty)
    }
  }

  func testStagingIsRefusedWhenTheCardDoesNotMatchWhatIsSelectedAndConfigured() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      for (id, display) in [("two", "7"), ("one", "8"), ("missing", "7")] {
        do {
          try await fixture.controller.stageLetterboxFactor(id, display: display)
          XCTFail("\(id) on \(display) must be rejected")
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
        id: "one", title: "one", kind: .projectScene, supported: true, active: false, selected: true,
        previewPath: nil)
      await assertStageRefused(fixture, "a scene")

      XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
      XCTAssertEqual(fixture.probes.count, 1, "refusing never decodes anything")
    }
  }

  func testOnlyAResultThatFoundBarsCanBeStaged() async throws {
    let cases: [@Sendable () -> VideoLetterboxProbe.Frames] = [
      { LetterboxFixtures.frames() },  // none
      { LetterboxFixtures.frames(top: 22, bottom: 5) },  // uneven
      { LetterboxFixtures.frames(top: 90, bottom: 90) },  // too dark
      { LetterboxFixtures.frames(top: 44, bottom: 44) },  // implausible
      { LetterboxFixtures.frames(count: 2) },  // too few frames
    ]
    for frames in cases {
      try await withFixture(frames: frames) { fixture in
        try await fixture.check()
        await assertStageRefused(fixture, "a result without bars")
        XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
      }
    }
    try await withFixture(frames: { throw VideoLetterboxProbe.Failure.timedOut }) { failed in
      try await failed.check()
      await assertStageRefused(failed, "a failed check")
    }
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { idle in
      await assertStageRefused(idle, "nothing was checked yet")
    }
    // A 4:3 display already shows exactly the picture, so there is no factor to set.
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { hidden in
      try await hidden.check()
      hidden.letterbox.viewportProvider = { _ in CGSize(width: 1600, height: 1200) }
      XCTAssertFalse(try barsCard(hidden.card()).stage.isAvailable)
      await assertStageRefused(hidden, "Fill already crops the bars")
      XCTAssertTrue(hidden.bridge.scalingFactorCalls.isEmpty)
    }
  }

  func testAResultFromBeforeALibraryRefreshCannotBeStaged() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      try await fixture.refreshLibrary()
      XCTAssertEqual(try fixture.card().outcome, .idle)
      await assertStageRefused(fixture, "the files may have been replaced")
      XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
    }
  }

  func testStagingAfterTheFileWasReplacedIsRefusedAndTheResultIsDropped() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      try Data("a different, longer video file".utf8).write(to: fixture.video)
      do {
        try await fixture.stage()
        XCTFail("a replaced file must not be staged from the old measurement")
      } catch let error as WallpaperActionError {
        XCTAssertEqual(error.message, L("The video changed since it was checked. Look for black bars again."))
      }
      XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
      XCTAssertEqual(try fixture.card().outcome, .idle, "the card offers a new look")
      await assertStageRefused(fixture, "the old result is gone")

      try await fixture.check()
      XCTAssertEqual(fixture.probes.count, 2)
      try await fixture.stage()
      XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, 1)
    }
  }

  func testStagingIsRefusedWhenTheSelectionMovesWhileTheFileIsBeingConfirmed() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      fixture.hooks.onResolve = { fixture.store.appSnapshot.selectedWallpaperId = "two" }
      await assertStageRefused(fixture, "the card belongs to a wallpaper that is no longer selected")
      XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)
    }
  }

  func testStagingDoesNotDependOnWhichVideoPlayerPlaysTheClip() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      // Both players apply the scale factor, so a running report that names the native player
      // does not hold the button back.
      fixture.store.settingsSnapshot.videoBackends = [
        .init(
          displayId: 7, displayName: "Display", wallpaperId: "one", wallpaperTitle: "one", backend: "native",
          fallbackReason: nil)
      ]
      XCTAssertTrue(try barsCard(fixture.card()).stage.isAvailable)
      try await fixture.stage()
      XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, 1)
    }
  }

  func testStageStateNamesTheModeThatCannotUseAFactorAndKeepsABiggerOne() async throws {
    try await withFixture(frames: { LetterboxFixtures.frames(left: 40, right: 40) }) { fixture in
      try await fixture.check()
      fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .match, factor: 1)])
      var state = try fixture.card()
      var card = try barsCard(state)
      XCTAssertNil(card.suggestion)
      XCTAssertFalse(card.stage.isAvailable)
      XCTAssertEqual(state.scalingMode, .match, "the card says which mode the display uses")
      await assertStageRefused(fixture, "only Fill turns a scale factor into a crop")

      // The user's own larger factor already hides the bars, and staging would only lower it.
      fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .fill, factor: 2)])
      state = try fixture.card()
      card = try barsCard(state)
      XCTAssertTrue(card.stage.isApplied)
      XCTAssertFalse(card.stage.isAvailable)
      await assertStageRefused(fixture, "a larger factor is already set")
      XCTAssertTrue(fixture.bridge.scalingFactorCalls.isEmpty)

      // Just under the suggestion still hides the bars: it carries half a percent of overscan.
      fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .fill, factor: 1.336)])
      XCTAssertTrue(try barsCard(fixture.card()).stage.isApplied)
      fixture.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "one", kind: .video, displayConfigurations: [fixture.configuration(mode: .fill, factor: 1.3)])
      card = try barsCard(fixture.card())
      XCTAssertFalse(card.stage.isApplied)
      XCTAssertTrue(card.stage.isAvailable)
    }
  }
}
