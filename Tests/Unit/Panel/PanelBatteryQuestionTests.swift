import XCTest

@testable import WallpaperMachine

/// The one-time battery question: when the panel reports it, what each of its choices sets (and
/// nothing else), what spends it without a choice, and what the sheet says about the wallpaper
/// playing now. When it may appear over the guide or a popover is the presenter's, as for every prompt.
@MainActor
final class PanelBatteryQuestionTests: PanelTestCase {
  /// A shown panel on a Mac with a battery, running on it, one wallpaper playing, both battery
  /// choices still Keep running and the performance data question already answered.
  private func withBatteryPanel(
    welcomeSeen: Bool = true,
    _ body: (PanelFixture, SettingsRecordingBridge, SupportPromptStore, UserDefaults) async throws -> Void
  ) async throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let prompt = SupportPromptStore(defaults: defaults)
    prompt.recordTelemetryAsked()
    try await withRecordingPanel(welcomeSeen: welcomeSeen, supportPrompt: prompt) { panel, bridge in
      try pinPanelLanguageToEnglish()
      let controller = panel.controller
      controller.openSupportURL = { _ in
        XCTFail("The battery question opens nothing")
        return false
      }
      controller.batteryPercent = 54
      panel.store.settingsSnapshot.onBatteryPower = true
      panel.store.settingsSnapshot.batteryMode = .keepRunning
      panel.store.settingsSnapshot.batteryTargetFps = 30
      panel.store.settingsSnapshot.batteryRenderScale = 0.75
      panel.store.librarySnapshot.wallpapers = [
        BridgeWallpaperEntry(
          id: "scene", title: "Scene", kind: .projectScene, supported: true, active: true,
          selected: false, previewPath: nil)
      ]
      panel.store.appSnapshot.activeWallpaperIds = ["scene"]
      panel.store.appSnapshot.playbackState = .playing
      panel.show()
      try await body(panel, bridge, prompt, defaults)
    }
  }

  func testTheQuestionComesOnBatteryWithAWallpaperPlayingAndNothingChosen() async throws {
    try await withBatteryPanel { panel, _, prompt, _ in
      let controller = panel.controller
      XCTAssertEqual(controller.pendingPrompt, .battery)

      panel.store.appSnapshot.playbackState = .paused
      XCTAssertNil(controller.pendingPrompt, "Paused by the user: nothing plays on battery")
      panel.store.appSnapshot.playbackState = .playing
      panel.store.settingsSnapshot.onBatteryPower = false
      XCTAssertNil(controller.pendingPrompt, "Plugged in and never seen on battery since launch")
      prompt.recordBatteryUse()
      XCTAssertEqual(controller.pendingPrompt, .battery, "A wallpaper played on battery since launch")

      controller.batteryPercent = nil
      XCTAssertNil(controller.pendingPrompt, "A Mac without an internal battery is never asked")
      controller.batteryPercent = 54
      panel.store.settingsSnapshot.batteryMode = .reducedQuality
      XCTAssertNil(controller.pendingPrompt, "A battery choice already made")
      panel.store.settingsSnapshot.batteryMode = .keepRunning
      controller.playback.otherAppInFrontAction = .mute
      XCTAssertNil(controller.pendingPrompt, "Mute in front already saves energy")
      controller.playback.otherAppInFrontAction = .keepRunning
      panel.store.appSnapshot.activeWallpaperIds = []
      XCTAssertNil(controller.pendingPrompt, "No wallpaper, nothing to save")
      panel.store.appSnapshot.activeWallpaperIds = ["scene"]
      XCTAssertEqual(controller.pendingPrompt, .battery)

      panel.hide()
      XCTAssertNil(controller.pendingPrompt, "A panel nobody can see does not report it")
    }
  }

  /// Each choice makes exactly its own setting, spends the question, and never touches the other.
  func testEachChoiceSetsExactlyItsSetting() async throws {
    let cases: [(SupportPromptChoice, [BridgeBatteryMode], OtherAppInFrontAction)] = [
      (.pauseWhileUsingOtherApps, [], .pauseOnBattery),
      (.reduceQualityOnBattery, [.reducedQuality], .keepRunning),
      (.alwaysPauseOnBattery, [.pause], .keepRunning),
      (.dismiss, [], .keepRunning),
    ]
    for (choice, modes, otherApp) in cases {
      try await withBatteryPanel { panel, bridge, _, defaults in
        let controller = panel.controller
        let presenter = controller.supportPrompt
        XCTAssertEqual(presenter.prompt, .battery)
        XCTAssertTrue(presenter.wantsPresentation)
        presenter.sheetDidAppear()
        XCTAssertTrue(bridge.batteryModeCalls.isEmpty, "\(choice): showing the question changes nothing")
        XCTAssertEqual(controller.playback.otherAppInFrontAction, .keepRunning)

        if choice == .dismiss {
          await presenter.dismiss().value
        } else {
          await presenter.choose(choice)
        }
        XCTAssertNil(presenter.error, "\(choice)")
        XCTAssertFalse(presenter.wantsPresentation, "\(choice): the sheet closes")
        XCTAssertEqual(bridge.batteryModeCalls, modes, "\(choice)")
        XCTAssertEqual(controller.playback.otherAppInFrontAction, otherApp, "\(choice)")
        XCTAssertNil(
          SupportPromptStore(defaults: defaults).pendingPrompt(
            welcomeSeen: true, telemetryOn: true, battery: controller.batteryPromptFacts,
            now: Date() + 2 * 86_400), "\(choice): asked once, for good")
      }
    }
  }

  /// An engine that refuses the battery choice keeps the sheet up with the reason.
  func testARefusedChoiceKeepsTheSheetUp() async throws {
    try await withBatteryPanel { panel, bridge, _, _ in
      let presenter = panel.controller.supportPrompt
      presenter.sheetDidAppear()
      bridge.bundleProvider = nil
      await presenter.choose(.alwaysPauseOnBattery)
      XCTAssertNotNil(presenter.error)
      XCTAssertTrue(presenter.wantsPresentation, "The other choices and Keep running remain")
      XCTAssertEqual(presenter.prompt, .battery)
    }
  }

  /// The choice's own turn in the command queue reads as a switch in progress, which holds other
  /// prompts back; it does not take down the sheet that made it while the engine answers.
  func testTheSheetStaysUpWhileItsChoiceIsApplied() async throws {
    try await withBatteryPanel { panel, bridge, _, _ in
      let presenter = panel.controller.supportPrompt
      presenter.sheetDidAppear()
      let answer = try XCTUnwrap(bridge.bundleProvider)
      var upWhileApplying: [Bool] = []
      bridge.bundleProvider = {
        upWhileApplying.append(presenter.wantsPresentation)
        return answer()
      }
      await presenter.choose(.reduceQualityOnBattery)
      XCTAssertFalse(upWhileApplying.isEmpty, "The engine was asked")
      XCTAssertEqual(Set(upWhileApplying), [true], "The sheet went down while its choice was applied")
      XCTAssertNil(presenter.error)
      XCTAssertFalse(presenter.wantsPresentation, "Answered")
    }
  }

  /// A battery choice made in Settings, and the guide's Preferences page, which shows the On
  /// battery choice, answer the question.
  func testSettingsAndTheGuideAnswerTheQuestion() async throws {
    try await withBatteryPanel { panel, _, _, _ in
      let controller = panel.controller
      XCTAssertEqual(controller.pendingPrompt, .battery)
      try await controller.setOtherAppInFrontAction(.keepRunning)
      XCTAssertNil(controller.pendingPrompt, "Choosing the row in Settings, even Keep running, answers it")
    }
    try await withBatteryPanel { panel, _, _, _ in
      let controller = panel.controller
      try await controller.setBatteryMode(.keepRunning)
      XCTAssertNil(controller.pendingPrompt, "So does choosing On battery")
    }
    try await withBatteryPanel(welcomeSeen: false) { panel, _, prompt, _ in
      let model = panel.controller.welcome
      model.open()
      defer { model.close() }
      model.go(to: .performance)
      XCTAssertEqual(
        prompt.pendingPrompt(
          welcomeSeen: true, telemetryOn: true, battery: panel.controller.batteryPromptFacts), .battery,
        "Not yet on the page with the On battery choice")
      model.go(to: .preferences)
      XCTAssertNil(
        prompt.pendingPrompt(
          welcomeSeen: true, telemetryOn: true, battery: panel.controller.batteryPromptFacts),
        "A new user is not asked twice")
    }
  }

  /// The sheet names the playing wallpaper's measured share of a charge, as the energy readout
  /// words it, and the reduced profile the Lower quality choice would use.
  func testTheSheetSaysWhatThePlayingWallpaperCostsAndWhatReducedQualityMeans() async throws {
    try await withBatteryPanel { panel, _, _, _ in
      let controller = panel.controller
      let plain = L(
        "Wallpapers now play on battery just as they do plugged in. Nothing changes unless you choose.")
      XCTAssertEqual(controller.batteryQuestionFacts.lead, plain, "No rating yet: no figure")
      XCTAssertEqual(
        controller.batteryQuestionFacts.reducedQualityNote,
        L("Plays at \(30) fps and \(75)% render scale."))

      let ratings = WallpaperEnergyRatings(
        file: panel.root.appendingPathComponent("energy-ratings.json"), batteryWattHours: { 50 })
      panel.store.wallpaperEnergyRatings = ratings
      ratings.record(
        WallpaperEnergyContext(
          wallpaperID: "scene",
          conditions: WallpaperEnergyConditions(displays: 1, frameRateCap: nil, renderScale: 1)),
        milliwatts: 4_600, seconds: 150)
      XCTAssertEqual(
        controller.batteryQuestionFacts.lead,
        plain + " " + L("The wallpaper playing now uses about \(9)% of a full battery charge per hour."),
        "4.6 W from a 50 Wh battery is about 9% an hour")

      XCTAssertEqual(
        BatteryQuestionFacts(percentPerHour: 0.4, reducedFrameRate: 30, reducedRenderScale: 0.75).energyLine,
        L("The wallpaper playing now uses less than 1% of a full battery charge per hour."))
      XCTAssertNil(
        BatteryQuestionFacts(percentPerHour: .nan, reducedFrameRate: 30, reducedRenderScale: 0.75).energyLine)

      panel.store.appSnapshot.activeWallpaperIds = ["scene", "other"]
      XCTAssertEqual(
        controller.batteryQuestionFacts.lead, plain, "Two wallpapers playing: no one wallpaper to name")
    }
  }

  /// With Pause on battery chosen, the row's line under its title is the declared note's sentence
  /// about the battery; the other choices keep the declared note as it is.
  func testTheRowNoteLeadsWithTheBatteryWhilePauseOnBatteryIsChosen() async throws {
    try await withBatteryPanel { panel, _, _, _ in
      let controller = panel.controller
      let declared = controller.settings.text(try XCTUnwrap(PlaybackSettingsSection.otherAppInFront.note))
      for action in [OtherAppInFrontAction.keepRunning, .mute, .pause] {
        controller.playback.otherAppInFrontAction = action
        XCTAssertNil(controller.playbackSettings.otherAppInFrontNote, "\(action)")
      }
      controller.playback.otherAppInFrontAction = .pauseOnBattery
      let live = try XCTUnwrap(controller.playbackSettings.otherAppInFrontNote)
      let lead = SettingsNote.parts(live).lead
      XCTAssertNotEqual(lead, SettingsNote.parts(declared).lead, "The battery sentence comes first")
      XCTAssertTrue(declared.contains(lead), "It says nothing the declared note does not")
      XCTAssertNotNil(SettingsNote.parts(live).more, "The rest stays behind the info button")
    }
  }
}
