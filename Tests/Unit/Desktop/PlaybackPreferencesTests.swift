import XCTest
@testable import WallpaperMachine

@MainActor
final class PlaybackPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    func testDefaultsWhenNothingIsStored() {
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.displaySleepAction, .pause)
        XCTAssertEqual(preferences.otherAudioAction, .keepRunning)
        XCTAssertEqual(preferences.desktopCoveredAction, .pause, "A covered desktop pauses unless the user opts out")
        XCTAssertEqual(preferences.lowPowerModeAction, .keepRunning, "Low Power Mode alone never changes playback")
        XCTAssertEqual(preferences.thermalAction, .keepRunning)
        XCTAssertEqual(preferences.lowBatteryAction, .keepRunning, "A low battery alone never changes playback")
        XCTAssertEqual(preferences.lowBatteryThreshold, 20)
        XCTAssertFalse(preferences.refreshesDesktopPicturePeriodically, "The Mission Control picture refreshes on a timer only when chosen")
        XCTAssertFalse(preferences.playsOnlyOnActiveDisplay, "Every display plays unless the user asks otherwise")
        XCTAssertFalse(preferences.wallpapersMuted, "Wallpapers keep their own sound until the user mutes them all")
        XCTAssertTrue(preferences.appRules.isEmpty)
    }

    func testMutationsPersistForALaterInstance() {
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.displaySleepAction = .stop
        preferences.otherAudioAction = .mute
        preferences.desktopCoveredAction = .keepRunning
        preferences.lowPowerModeAction = .pause
        preferences.thermalAction = .stop
        preferences.lowBatteryAction = .stop
        preferences.lowBatteryThreshold = 30
        preferences.refreshesDesktopPicturePeriodically = true
        preferences.playsOnlyOnActiveDisplay = true
        let added = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        try? preferences.updateRule(id: added.id, condition: .frontmost)
        try? preferences.updateRule(id: added.id, action: .stop)

        let reloaded = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.displaySleepAction, .stop)
        XCTAssertEqual(reloaded.otherAudioAction, .mute)
        XCTAssertEqual(reloaded.desktopCoveredAction, .keepRunning)
        XCTAssertEqual(reloaded.lowPowerModeAction, .pause)
        XCTAssertEqual(reloaded.thermalAction, .stop)
        XCTAssertEqual(reloaded.lowBatteryAction, .stop)
        XCTAssertEqual(reloaded.lowBatteryThreshold, 30)
        XCTAssertTrue(reloaded.refreshesDesktopPicturePeriodically)
        XCTAssertTrue(reloaded.playsOnlyOnActiveDisplay)
        XCTAssertEqual(reloaded.appRules.count, 1)
        XCTAssertEqual(reloaded.appRules[0].bundleIdentifier, "com.example.Player")
        XCTAssertEqual(reloaded.appRules[0].condition, .frontmost)
        XCTAssertEqual(reloaded.appRules[0].action, .stop)
        XCTAssertEqual(reloaded.appRules[0].id, added.id)
    }

    func testCorruptStoredValuesFallBackToDefaults() {
        defaults.set("not-an-action", forKey: "WallpaperMachine.displaySleepAction")
        defaults.set("louder", forKey: "WallpaperMachine.otherAudioAction")
        defaults.set("sometimes", forKey: "WallpaperMachine.desktopCoveredAction")
        defaults.set("nap", forKey: "WallpaperMachine.lowPowerModeAction")
        defaults.set(Data("not-json".utf8), forKey: "WallpaperMachine.appRules")

        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.displaySleepAction, .pause)
        XCTAssertEqual(preferences.otherAudioAction, .keepRunning)
        XCTAssertEqual(preferences.desktopCoveredAction, .pause)
        XCTAssertEqual(preferences.lowPowerModeAction, .keepRunning)
        XCTAssertTrue(preferences.appRules.isEmpty)
    }

    func testReducedQualityIsStoredForEachConditionAndIsNotARuleAction() {
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.lowPowerModeAction = .reduceQuality
        preferences.thermalAction = .reduceQuality
        preferences.lowBatteryAction = .reduceQuality
        let reloaded = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.lowPowerModeAction, .reduceQuality)
        XCTAssertEqual(reloaded.thermalAction, .reduceQuality)
        XCTAssertEqual(reloaded.lowBatteryAction, .reduceQuality)

        XCTAssertNil(SystemConditionAction.reduceQuality.ruleAction, "Reducing quality never pauses, mutes or stops")
        XCTAssertEqual(SystemConditionAction.allCases.filter(\.reducesQuality), [.reduceQuality])
        XCTAssertEqual(SystemConditionAction.pause.ruleAction, .pause)
        XCTAssertEqual(SystemConditionAction.stop.ruleAction, .stop)

        // The on-battery mode's own name is not a condition action, so it reads as the default.
        for key in ["lowPowerModeAction", "thermalAction", "lowBatteryAction"] {
            defaults.set("reducedQuality", forKey: "WallpaperMachine.\(key)")
        }
        let confused = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(confused.lowPowerModeAction, .keepRunning)
        XCTAssertEqual(confused.thermalAction, .keepRunning)
        XCTAssertEqual(confused.lowBatteryAction, .keepRunning)
    }

    func testQualityReductionsNameHeatFirstThenLowPowerModeThenALowBattery() {
        XCTAssertEqual([QualityReduction.lowBattery, .heat, .lowPowerMode].sorted(), [.heat, .lowPowerMode, .lowBattery])
        XCTAssertEqual(QualityReduction.allCases.sorted(), QualityReduction.allCases)
    }

    func testCorruptLowBatteryValuesFallBackToDefaults() {
        defaults.set("nap", forKey: "WallpaperMachine.lowBatteryAction")
        for stored: Any in [15, 0, -20, 20.5, "30", true, Data("20".utf8)] {
            defaults.set(stored, forKey: "WallpaperMachine.lowBatteryThreshold")
            let preferences = PlaybackPreferences(defaults: defaults)
            XCTAssertEqual(preferences.lowBatteryAction, .keepRunning)
            XCTAssertEqual(preferences.lowBatteryThreshold, 20, "\(stored) is not one of the offered levels")
        }
        defaults.set(10, forKey: "WallpaperMachine.lowBatteryThreshold")
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).lowBatteryThreshold, 10)
    }

    func testAnUnsupportedLowBatteryLevelIsIgnored() {
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.lowBatteryThreshold = 10
        let posts = ChangeCount()
        let token = NotificationCenter.default.addObserver(
            forName: PlaybackPreferences.didChangeNotification, object: preferences, queue: .main
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        for level in [0, 15, 25, 31, 100, -10] { preferences.lowBatteryThreshold = level }
        XCTAssertEqual(preferences.lowBatteryThreshold, 10)
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).lowBatteryThreshold, 10)
        XCTAssertEqual(posts.value, 0, "A refused level is not a change")

        preferences.lowBatteryThreshold = 30
        XCTAssertEqual(posts.value, 1)
        preferences.lowBatteryAction = .pause
        XCTAssertEqual(posts.value, 2)
    }

    func testWritingTheDesktopPictureIsOnUntilTurnedOff() {
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertTrue(preferences.writesDesktopPicture, "A fresh install keeps installing the Mission Control picture")
        preferences.lowBatteryThreshold = 30

        let posts = ChangeCount()
        let token = NotificationCenter.default.addObserver(
            forName: PlaybackPreferences.didChangeNotification, object: preferences, queue: .main
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.writesDesktopPicture = false
        XCTAssertFalse(preferences.writesDesktopPicture)
        XCTAssertEqual(posts.value, 1, "The app starts putting the picture back from this notification")
        XCTAssertFalse(PlaybackPreferences(defaults: defaults).writesDesktopPicture, "The choice survives a relaunch")
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).lowBatteryThreshold, 30, "No other choice moved")
        XCTAssertFalse(PlaybackPreferences(defaults: defaults).refreshesDesktopPicturePeriodically)

        preferences.writesDesktopPicture = true
        XCTAssertTrue(PlaybackPreferences(defaults: defaults).writesDesktopPicture)
        XCTAssertEqual(posts.value, 2)
    }

    func testMutingEveryWallpaperPersistsAndAnnouncesEachChangeOnce() {
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.lowBatteryThreshold = 30
        let posts = ChangeCount()
        let token = NotificationCenter.default.addObserver(
            forName: PlaybackPreferences.didChangeNotification, object: preferences, queue: .main
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.wallpapersMuted = true
        XCTAssertTrue(preferences.wallpapersMuted)
        XCTAssertEqual(posts.value, 1, "The presentation policy applies the mute from this notification")
        XCTAssertTrue(PlaybackPreferences(defaults: defaults).wallpapersMuted, "The choice survives a relaunch")
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).lowBatteryThreshold, 30, "No other choice moved")
        XCTAssertFalse(PlaybackPreferences(defaults: defaults).playsOnlyOnActiveDisplay)

        preferences.wallpapersMuted = true
        XCTAssertEqual(posts.value, 1, "Muting what is muted already is not a change")

        preferences.wallpapersMuted = false
        XCTAssertFalse(PlaybackPreferences(defaults: defaults).wallpapersMuted)
        XCTAssertEqual(posts.value, 2)
        preferences.wallpapersMuted = false
        XCTAssertEqual(posts.value, 2)
    }

    func testAddingTheSameBundleReturnsTheExistingRule() {
        let preferences = PlaybackPreferences(defaults: defaults)
        let first = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        let second = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Other name")
        XCTAssertEqual(first, second)
        XCTAssertEqual(preferences.appRules.count, 1)
        XCTAssertEqual(preferences.appRules[0].name, "Player")
    }

    func testUnknownRuleIDThrowsAndLeavesTheListAlone() {
        let preferences = PlaybackPreferences(defaults: defaults)
        let added = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        XCTAssertThrowsError(try preferences.updateRule(id: UUID(), condition: .frontmost)) { error in
            XCTAssertTrue(error is PlaybackPreferences.UnknownRule)
        }
        XCTAssertThrowsError(try preferences.updateRule(id: UUID(), action: .mute)) { error in
            XCTAssertTrue(error is PlaybackPreferences.UnknownRule)
        }
        preferences.removeRule(id: UUID())
        XCTAssertEqual(preferences.appRules, [added])
    }

    func testEachMutationPostsOneChangeAndADuplicateAddPostsNone() {
        let preferences = PlaybackPreferences(defaults: defaults)
        let posts = ChangeCount()
        let token = NotificationCenter.default.addObserver(
            forName: PlaybackPreferences.didChangeNotification, object: preferences, queue: .main
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.displaySleepAction = .stop
        XCTAssertEqual(posts.value, 1)
        preferences.otherAudioAction = .pause
        XCTAssertEqual(posts.value, 2)
        let added = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        XCTAssertEqual(posts.value, 3)
        _ = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        XCTAssertEqual(posts.value, 3, "Returning the existing rule is not a mutation")
        try? preferences.updateRule(id: added.id, action: .mute)
        XCTAssertEqual(posts.value, 4)
        preferences.removeRule(id: added.id)
        XCTAssertEqual(posts.value, 5)
        preferences.removeRule(id: added.id)
        XCTAssertEqual(posts.value, 5, "Removing an unknown rule changes nothing")
        preferences.playsOnlyOnActiveDisplay = true
        XCTAssertEqual(posts.value, 6, "The policy re-evaluates from this notification")
    }
}

private final class ChangeCount: @unchecked Sendable {
    var value = 0
}
