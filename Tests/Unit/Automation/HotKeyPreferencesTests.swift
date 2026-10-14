import XCTest
@testable import WallpaperMachine

@MainActor
final class HotKeyPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    private let playPause = HotKey(keyCode: 35, modifiers: 6400, label: "⌃⌥⌘P")

    func testNoShortcutIsTakenUntilTheUserRecordsOne() {
        XCTAssertTrue(HotKeyPreferences(defaults: defaults).bindings.isEmpty)
    }

    func testRecordedShortcutsOutliveTheAppAndCanBeCleared() throws {
        let preferences = HotKeyPreferences(defaults: defaults)
        try preferences.set(playPause, for: .togglePlayback)
        XCTAssertEqual(HotKeyPreferences(defaults: defaults).bindings[.togglePlayback], playPause)
        try preferences.set(nil, for: .togglePlayback)
        XCTAssertNil(HotKeyPreferences(defaults: defaults).bindings[.togglePlayback])
    }

    func testOneCombinationServesOneActionOnly() throws {
        let preferences = HotKeyPreferences(defaults: defaults)
        try preferences.set(playPause, for: .togglePlayback)
        XCTAssertThrowsError(try preferences.set(playPause, for: .nextWallpaper))
        XCTAssertNil(preferences.bindings[.nextWallpaper])
        XCTAssertNoThrow(try preferences.set(playPause, for: .togglePlayback), "setting the same one again is fine")
    }

    func testARefusalIsForgottenOnceTheShortcutChanges() throws {
        let preferences = HotKeyPreferences(defaults: defaults)
        try preferences.set(playPause, for: .togglePlayback)
        preferences.recordFailure("taken", for: .togglePlayback)
        XCTAssertEqual(preferences.failures[.togglePlayback], "taken")
        try preferences.set(HotKey(keyCode: 45, modifiers: 6400, label: "⌃⌥⌘N"), for: .togglePlayback)
        XCTAssertNil(preferences.failures[.togglePlayback])
    }

    func testEachShortcutRunsTheCommandItNames() {
        XCTAssertEqual(Set(HotKeyAction.allCases.map(\.identifier)).count, HotKeyAction.allCases.count)
        XCTAssertFalse(HotKeyAction.allCases.contains { $0.identifier == 0 })
    }

    func testTheMuteShortcutTogglesTheMuteOfEveryWallpaper() throws {
        XCTAssertTrue(HotKeyAction.allCases.contains(.toggleMute))
        XCTAssertEqual(HotKeyAction.toggleMute.command, .toggleMute)
        XCTAssertEqual(HotKeyAction.toggleMute.identifier, 6)
        XCTAssertEqual(HotKeyAction(rawValue: "toggleMute"), .toggleMute, "the name a saved shortcut and a backup use")
        XCTAssertEqual(Set(HotKeyAction.allCases.map(\.identifier)).count, HotKeyAction.allCases.count,
                       "every shortcut keeps an identifier of its own, which is how a press finds its action")

        let preferences = HotKeyPreferences(defaults: defaults)
        try preferences.set(playPause, for: .toggleMute)
        XCTAssertEqual(HotKeyPreferences(defaults: defaults).bindings[.toggleMute], playPause)
        XCTAssertThrowsError(try preferences.set(playPause, for: .togglePlayback), "it shares the one-action-per-combination rule")
        XCTAssertNil(preferences.bindings[.togglePlayback])
    }

    func testTheRandomShortcutPicksFromEveryWallpaperOnTheTargetDisplay() throws {
        XCTAssertTrue(HotKeyAction.allCases.contains(.randomWallpaper))
        XCTAssertEqual(HotKeyAction.randomWallpaper.command, .random(display: nil, pool: .all))
        XCTAssertEqual(HotKeyAction.randomWallpaper.identifier, 5)
        XCTAssertEqual(HotKeyAction(rawValue: "randomWallpaper"), .randomWallpaper, "the name a saved shortcut and a backup use")

        let preferences = HotKeyPreferences(defaults: defaults)
        try preferences.set(playPause, for: .randomWallpaper)
        XCTAssertEqual(HotKeyPreferences(defaults: defaults).bindings[.randomWallpaper], playPause)
        XCTAssertThrowsError(try preferences.set(playPause, for: .nextWallpaper), "it shares the one-action-per-combination rule")
    }
}
