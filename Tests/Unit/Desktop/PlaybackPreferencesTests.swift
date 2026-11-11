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
        XCTAssertEqual(preferences.otherAppInFrontAction, .keepRunning, "Which app is in front alone never changes playback")
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
        preferences.otherAppInFrontAction = .pause
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
        XCTAssertEqual(reloaded.otherAppInFrontAction, .pause)
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
        defaults.set("dim", forKey: "WallpaperMachine.otherAppInFrontAction")
        defaults.set("sometimes", forKey: "WallpaperMachine.desktopCoveredAction")
        defaults.set("nap", forKey: "WallpaperMachine.lowPowerModeAction")
        defaults.set(Data("not-json".utf8), forKey: "WallpaperMachine.appRules")

        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.displaySleepAction, .pause)
        XCTAssertEqual(preferences.otherAudioAction, .keepRunning)
        XCTAssertEqual(preferences.otherAppInFrontAction, .keepRunning)
        XCTAssertEqual(preferences.desktopCoveredAction, .pause)
        XCTAssertEqual(preferences.lowPowerModeAction, .keepRunning)
        XCTAssertTrue(preferences.appRules.isEmpty)
    }

    /// A rule with an action a newer build saved cannot be read here. The rule beside it still
    /// loads, and changing that one leaves the unreadable rule in the saved list.
    func testAnUnreadableAppRuleSurvivesAnEditOfAnother() throws {
        let known = AppRule(
            id: UUID(), bundleIdentifier: "com.example.Player", name: "Player", condition: .running, action: .pause)
        let knownJSON = String(decoding: try JSONEncoder().encode(known), as: UTF8.self)
        let future = #"{"id":"\#(UUID().uuidString)","bundleIdentifier":"com.example.Game","name":"Game","#
            + #""condition":"running","action":"someFutureAction"}"#
        defaults.set(Data("[\(knownJSON),\(future)]".utf8), forKey: "WallpaperMachine.appRules")

        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.appRules, [known])
        try preferences.updateRule(id: known.id, action: .mute)

        let saved = try XCTUnwrap(defaults.data(forKey: "WallpaperMachine.appRules"))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        XCTAssertEqual(rules.map { $0["action"] as? String }, ["mute", "someFutureAction"])
        XCTAssertEqual(rules.last?["bundleIdentifier"] as? String, "com.example.Game")

        // Reset All Settings removes every rule, the unreadable one too.
        preferences.resetToDefaults()
        preferences.addRule(bundleIdentifier: "com.example.Other", name: "Other")
        let afterReset = try XCTUnwrap(defaults.data(forKey: "WallpaperMachine.appRules"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: afterReset) as? [[String: Any]])?.count, 1)
    }

    /// Pause on battery is stored like the other choices, pauses only on battery, and Reset all
    /// settings puts the row back on Keep running.
    func testPauseOnBatteryIsStoredPausesOnlyOnBatteryAndResets() {
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.otherAppInFrontAction = .pauseOnBattery
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).otherAppInFrontAction, .pauseOnBattery)

        XCTAssertEqual(OtherAppInFrontAction.pauseOnBattery.ruleAction(onBattery: true), .pause)
        XCTAssertNil(OtherAppInFrontAction.pauseOnBattery.ruleAction(onBattery: false))
        for onBattery in [false, true] {
            XCTAssertNil(OtherAppInFrontAction.keepRunning.ruleAction(onBattery: onBattery))
            XCTAssertEqual(OtherAppInFrontAction.mute.ruleAction(onBattery: onBattery), .mute)
            XCTAssertEqual(OtherAppInFrontAction.pause.ruleAction(onBattery: onBattery), .pause)
        }

        preferences.resetToDefaults()
        XCTAssertEqual(preferences.otherAppInFrontAction, .keepRunning)
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).otherAppInFrontAction, .keepRunning)
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

    func testTheInactivityRuleIsOffUntilChosenAndKeepsOnlyAnOfferedTime() {
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.inactivityAction, .keepRunning, "Being away alone never changes playback")
        XCTAssertEqual(preferences.inactivityMinutes, 10)
        XCTAssertEqual(InactivityAction.allCases.map(\.conditionAction), [.keepRunning, .pause, .stop],
                       "Nobody is watching, so there is no Reduced quality to offer")

        preferences.inactivityAction = .stop
        preferences.inactivityMinutes = 30
        preferences.inactivityMinutes = 7
        let reloaded = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.inactivityAction, .stop)
        XCTAssertEqual(reloaded.inactivityMinutes, 30, "A time the menu does not offer is ignored")

        for stored: Any in [7, 0, -10, 10.5, "15", true] {
            defaults.set(stored, forKey: PlaybackPreferences.inactivityMinutesKey)
            XCTAssertEqual(PlaybackPreferences(defaults: defaults).inactivityMinutes, 10, "\(stored)")
        }
        defaults.set("reduceQuality", forKey: PlaybackPreferences.inactivityActionKey)
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).inactivityAction, .keepRunning)

        preferences.inactivityAction = .pause
        preferences.inactivityMinutes = 60
        preferences.resetToDefaults()
        XCTAssertEqual(preferences.inactivityAction, .keepRunning)
        XCTAssertEqual(preferences.inactivityMinutes, 10)
    }

    func testReduceVolumeIsAChoiceForOtherAudioAndKeepsOnlyAWholePercentage() {
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.otherAudioVolume, 30, "A level nobody has set yet is quieter, not silent")
        XCTAssertEqual(OtherAudioAction.allCases, [.keepRunning, .reduceVolume, .mute, .pause],
                       "The menu lists the choices from the mildest to the strongest")

        preferences.otherAudioAction = .reduceVolume
        preferences.otherAudioVolume = 45
        preferences.otherAudioVolume = 101
        preferences.otherAudioVolume = -1
        let reloaded = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.otherAudioAction, .reduceVolume)
        XCTAssertEqual(reloaded.otherAudioVolume, 45, "A level outside 0 to 100 is ignored")
        for edge in [0, 100] {
            preferences.otherAudioVolume = edge
            XCTAssertEqual(PlaybackPreferences(defaults: defaults).otherAudioVolume, edge)
        }

        for stored: Any in [101, -10, 45.5, "45", true, false] {
            defaults.set(stored, forKey: PlaybackPreferences.otherAudioVolumeKey)
            XCTAssertEqual(PlaybackPreferences(defaults: defaults).otherAudioVolume, 30, "\(stored)")
        }

        preferences.otherAudioVolume = 80
        preferences.resetToDefaults()
        XCTAssertEqual(preferences.otherAudioAction, .keepRunning)
        XCTAssertEqual(preferences.otherAudioVolume, 30)
    }

    func testChangingTheReducedVolumePostsAChangeSoThePolicyTakesTheNewLevel() {
        let preferences = PlaybackPreferences(defaults: defaults)
        let posts = ChangeCount()
        let token = NotificationCenter.default.addObserver(
            forName: PlaybackPreferences.didChangeNotification, object: preferences, queue: .main
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.otherAudioVolume = 60
        XCTAssertEqual(posts.value, 1)
        preferences.otherAudioVolume = 140
        XCTAssertEqual(posts.value, 1, "A refused level changes nothing")
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
