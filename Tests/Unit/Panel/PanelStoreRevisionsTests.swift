import Observation
import XCTest

@testable import WallpaperMachine

/// The counters that make views notice stores SwiftUI cannot observe. A getter that reads a
/// counter is asked again exactly when that store says it changed.
@MainActor
final class PanelStoreRevisionsTests: PanelTestCase {
  private final class Counter: @unchecked Sendable { var count = 0 }

  private func started(_ panel: PanelFixture) -> PanelStoreRevisions {
    let revisions = panel.controller.revisions
    revisions.start()
    return revisions
  }

  func testEachStoreNotificationCountsForItsOwnCounterOnly() throws {
    let panel = try makeController()
    let revisions = started(panel)
    defer { revisions.stop() }
    let posts: [(Notification.Name, AnyObject, PanelStoreRevisions.Source)] = [
      (PlaybackPreferences.didChangeNotification, panel.controller.playback, .playback),
      (HotKeyPreferences.didChangeNotification, panel.controller.hotKeys, .hotKeys),
      (PlaylistStore.didChangeNotification, panel.playlists, .playlists),
      (WallpaperCollectionStore.didChangeNotification, panel.collections, .collections),
      (WallpaperPresetStore.didChangeNotification, panel.presets, .presets),
      (StillImagePlacementStore.didChangeNotification, panel.imagePlacement, .imagePlacement),
      (WallpaperAutomationStore.didChangeNotification, panel.automations, .automationSettings),
      (WallpaperAutomationStore.statusChangedNotification, panel.automations, .automationStatus),
      (WallpaperDisplayLayoutStore.didChangeNotification, panel.controller.displayLayouts, .displayLayouts),
      (WallpaperSpaceMonitor.didChangeNotification, panel.spaces, .spaces),
      (SystemConditionState.didChangeNotification, panel.systemConditions, .conditions),
    ]
    for (name, object, source) in posts {
      let before = Dictionary(
        uniqueKeysWithValues: PanelStoreRevisions.Source.allCases.map { ($0, revisions.revision(of: $0)) })
      NotificationCenter.default.post(name: name, object: object)
      for other in PanelStoreRevisions.Source.allCases {
        let expected = before[other]! + (other == source ? 1 : 0)
        XCTAssertEqual(revisions.revision(of: other), expected, "\(name.rawValue) → \(other)")
      }
    }
  }

  func testAPostFromAnotherInstanceOfTheSameStoreIsIgnored() throws {
    let panel = try makeController()
    let revisions = started(panel)
    defer { revisions.stop() }
    let stranger = PlaylistStore(defaults: try TemporaryDefaults.make(for: self).defaults)
    NotificationCenter.default.post(name: PlaylistStore.didChangeNotification, object: stranger)
    XCTAssertEqual(revisions.playlists, 0)
  }

  func testPowerThermalAndFocusChangesCount() throws {
    let panel = try makeController()
    let revisions = started(panel)
    defer { revisions.stop() }
    NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    XCTAssertEqual(revisions.power, 2)
    NotificationCenter.default.post(name: FocusFilterState.didChangeNotification, object: nil)
    XCTAssertEqual(revisions.focus, 1)
  }

  func testAPostFromABackgroundThreadHopsToTheMainActor() async throws {
    let panel = try makeController()
    let revisions = started(panel)
    defer { revisions.stop() }
    await Task.detached {
      NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }.value
    try await panel.waitUntil { revisions.power == 1 }
  }

  func testThemeLanguageAndNavigationChangesCount() throws {
    let panel = try makeController()
    let revisions = started(panel)
    defer { revisions.stop() }
    XCTAssertEqual(revisions.theme, 0, "subscribing is not a change")
    try panel.theme.set("mode", value: "dark")
    XCTAssertEqual(revisions.theme, 1)
    try panel.theme.set("mode", value: "dark")
    XCTAssertEqual(revisions.theme, 1, "setting the same value changes nothing")

    try panel.controller.appLanguage.set("ja")
    XCTAssertEqual(revisions.language, 1)

    panel.navigation.selection = .settings
    XCTAssertEqual(revisions.navigation, 1)
    panel.navigation.targetDisplayID = "secondary"
    XCTAssertEqual(revisions.navigation, 2, "the target display is navigation too")
  }

  func testNothingIsCountedBeforeStartOrAfterStop() throws {
    let panel = try makeController()
    let revisions = panel.controller.revisions
    NotificationCenter.default.post(name: PlaylistStore.didChangeNotification, object: panel.playlists)
    XCTAssertEqual(revisions.playlists, 0, "nothing listens until start")
    revisions.start()
    revisions.start()
    NotificationCenter.default.post(name: PlaylistStore.didChangeNotification, object: panel.playlists)
    XCTAssertEqual(revisions.playlists, 1, "a second start does not subscribe twice")
    revisions.stop()
    NotificationCenter.default.post(name: PlaylistStore.didChangeNotification, object: panel.playlists)
    panel.navigation.selection = .pixiv
    XCTAssertEqual(revisions.playlists, 1)
    XCTAssertEqual(revisions.navigation, 0)
  }

  func testAReaderOfACounterIsToldWhenItsStoreChanges() throws {
    let panel = try makeController()
    let revisions = started(panel)
    defer { revisions.stop() }
    let told = Counter()
    withObservationTracking {
      _ = revisions.playlists
    } onChange: {
      told.count += 1
    }
    NotificationCenter.default.post(name: WallpaperCollectionStore.didChangeNotification, object: panel.collections)
    XCTAssertEqual(told.count, 0, "another store's counter is not this reader's")
    NotificationCenter.default.post(name: PlaylistStore.didChangeNotification, object: panel.playlists)
    XCTAssertEqual(told.count, 1)
  }

  func testTheClosureBackedStoresCountThroughTheController() throws {
    let panel = try makeController()
    let revisions = panel.controller.revisions
    panel.controller.libraryMetrics.onChange?()
    panel.controller.libraryCovers.onChange?()
    panel.controller.energyUsage.onChange?()
    XCTAssertEqual(revisions.libraryMetrics, 1)
    XCTAssertEqual(revisions.libraryCovers, 1)
    XCTAssertEqual(revisions.energy, 1)
  }
}
