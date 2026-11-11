import XCTest

@testable import WallpaperMachine

/// Settings › Playback & Power › When another app plays sound › Reduce volume: one more choice
/// beside Mute, its level asked for only once it is the choice, and only a whole percentage from
/// 0 to 100 accepted.
@MainActor
final class OtherAudioVolumeSettingsTests: PanelTestCase {
  func testReduceVolumeIsOfferedBesideMute() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertEqual(
      OtherAudioAction.allCases.map(\.title), ["Keep running", "Reduce volume", "Mute", "Pause"])
  }

  func testTheLevelIsAskedForOnlyWhileReduceVolumeIsTheChoice() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      settings.query = "When another app plays sound"
      XCTAssertTrue(settings.search.shows(PlaybackSettingsSection.otherAudio))
      settings.query = "Reduce volume to"
      XCTAssertTrue(settings.search.hasNoResults, "Keep running is the default and needs no level")
      XCTAssertFalse(controller.playbackSettings.showsOtherAudioVolume)

      for action in [OtherAudioAction.mute, .pause] {
        try await controller.setOtherAudioAction(action)
        XCTAssertFalse(controller.playbackSettings.showsOtherAudioVolume, "\(action) has no level")
      }

      try await controller.setOtherAudioAction(.reduceVolume)
      XCTAssertTrue(settings.search.shows(PlaybackSettingsSection.otherAudioVolume))
      XCTAssertTrue(controller.playbackSettings.showsOtherAudioVolume)
    }
  }

  func testTheLevelReachesThePreferencesAndOneOutsideTheSliderIsRefused() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertEqual(controller.playbackSettings.otherAudioAction, .keepRunning)
      XCTAssertEqual(controller.playbackSettings.otherAudioVolume, 30)

      try await controller.setOtherAudioAction(.reduceVolume)
      try await controller.setOtherAudioVolume(55)
      XCTAssertEqual(controller.playback.otherAudioAction, .reduceVolume)
      XCTAssertEqual(controller.playback.otherAudioVolume, 55)
      XCTAssertEqual(controller.playbackSettings.otherAudioVolume, 55)

      for level in [0, 100] {
        try await controller.setOtherAudioVolume(level)
        XCTAssertEqual(controller.playbackSettings.otherAudioVolume, level)
      }
      for level in [-1, 101] {
        do {
          try await controller.setOtherAudioVolume(level)
          XCTFail("\(level)% is outside the slider")
        } catch is InvalidControlValue {}
      }
      XCTAssertEqual(controller.playback.otherAudioVolume, 100)
    }
  }
}
