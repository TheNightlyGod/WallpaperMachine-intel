import XCTest
@testable import WallpaperMachine

@MainActor
final class SupportPromptStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    func testDownloadsWaitForSuccessfulActivation() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordDownload(wallpaperID: "wallpaper-1")
        store.recordDownload(wallpaperID: "wallpaper-1")
        store.recordDownload(wallpaperID: "wallpaper-2")
        XCTAssertFalse(store.isPending)
    }

    func testUnrelatedActivationDoesNotConsumeDownloadedWallpaper() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordDownload(wallpaperID: "downloaded")
        store.recordSuccessfulActivation(wallpaperID: "local-import")
        XCTAssertFalse(store.isPending)

        store.recordSuccessfulActivation(wallpaperID: "downloaded")
        XCTAssertTrue(store.isPending)
    }

    func testActivationBeforeDownloadDoesNotQualify() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        store.recordDownload(wallpaperID: "wallpaper-1")
        XCTAssertFalse(store.isPending)

        store.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(store.isPending)
    }

    func testAnySuccessfullyDownloadedWallpaperCanQualify() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordDownload(wallpaperID: "wallpaper-1")
        store.recordDownload(wallpaperID: "wallpaper-2")
        store.recordSuccessfulActivation(wallpaperID: "wallpaper-2")
        XCTAssertTrue(store.isPending)
    }

    func testDownloadedWallpaperCanBeActivatedAfterRelaunch() {
        let original = SupportPromptStore(defaults: defaults)
        original.recordDownload(wallpaperID: "wallpaper-1")

        let relaunched = SupportPromptStore(defaults: defaults)
        XCTAssertFalse(relaunched.isPending)
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(relaunched.isPending)
    }

    func testPendingPromptSurvivesRelaunchAndFurtherDownloads() {
        let original = SupportPromptStore(defaults: defaults)
        original.recordDownload(wallpaperID: "wallpaper-1")
        original.recordSuccessfulActivation(wallpaperID: "wallpaper-1")

        let relaunched = SupportPromptStore(defaults: defaults)
        XCTAssertTrue(relaunched.isPending)
        relaunched.recordDownload(wallpaperID: "wallpaper-2")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-2")
        XCTAssertTrue(relaunched.isPending)
        XCTAssertTrue(SupportPromptStore(defaults: defaults).isPending)
    }

    func testPresentedPromptNeverReturnsAfterFurtherDownloadsOrRelaunch() {
        let original = SupportPromptStore(defaults: defaults)
        original.recordDownload(wallpaperID: "wallpaper-1")
        original.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        original.markPresented()
        XCTAssertFalse(original.isPending)

        original.recordDownload(wallpaperID: "wallpaper-2")
        original.recordSuccessfulActivation(wallpaperID: "wallpaper-2")
        XCTAssertFalse(original.isPending)

        let relaunched = SupportPromptStore(defaults: defaults)
        relaunched.recordDownload(wallpaperID: "wallpaper-3")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-3")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        relaunched.markPresented()
        XCTAssertFalse(relaunched.isPending)
        XCTAssertFalse(SupportPromptStore(defaults: defaults).isPending)
    }

    func testMarkPresentedWithoutPendingPromptDoesNotSuppressFutureOffer() {
        let original = SupportPromptStore(defaults: defaults)
        original.markPresented()

        let relaunched = SupportPromptStore(defaults: defaults)
        relaunched.recordDownload(wallpaperID: "wallpaper-1")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(relaunched.isPending)
    }

    func testDeletedDownloadCannotQualifyUntilDownloadedAgain() {
        let original = SupportPromptStore(defaults: defaults)
        original.recordDownload(wallpaperID: "wallpaper-1")
        original.forgetDownload(wallpaperID: "wallpaper-1")

        let relaunched = SupportPromptStore(defaults: defaults)
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertFalse(relaunched.isPending)
        relaunched.recordDownload(wallpaperID: "wallpaper-1")
        relaunched.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(relaunched.isPending)
    }

    func testEmptyWallpaperIDCannotQualifyOrConsumeValidDownload() {
        let store = SupportPromptStore(defaults: defaults)
        store.recordDownload(wallpaperID: "")
        store.recordSuccessfulActivation(wallpaperID: "")
        XCTAssertFalse(store.isPending)

        store.recordDownload(wallpaperID: "wallpaper-1")
        store.recordSuccessfulActivation(wallpaperID: "")
        XCTAssertFalse(store.isPending)
        store.recordSuccessfulActivation(wallpaperID: "wallpaper-1")
        XCTAssertTrue(store.isPending)
    }

    // MARK: - Scheduling of the prompts

    private let day: TimeInterval = 86_400
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let start = Date(timeIntervalSince1970: 1_791_000_000)

    private func useOnDays(_ store: SupportPromptStore, _ count: Int) {
        for index in 0..<count { store.recordPanelUse(now: start + Double(index) * day) }
    }

    func testOnlyOnePromptADayInPriorityOrder() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordDownload(wallpaperID: "downloaded")
        store.recordSuccessfulActivation(wallpaperID: "downloaded")
        XCTAssertEqual(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start), .telemetry)

        store.markPresented(.telemetry, now: start)
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 60),
                     "a second prompt waits for another day")
        XCTAssertEqual(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + day), .support)
    }

    func testTelemetryPromptIsForThoseWhoFinishedTheGuideWithoutIt() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        XCTAssertNil(store.pendingPrompt(welcomeSeen: false, telemetryOn: false, now: start), "the guide asks new users")
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: true, now: start), "already on")
        store.recordTelemetryAsked()
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start))
        XCTAssertNil(SupportPromptStore(defaults: defaults, calendar: calendar)
            .pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + day))
    }

    /// The import offer is for someone signed in to Steam who finished the guide without meeting
    /// it; the guide's card or a Steam Community sign-in spends it, and it comes after the
    /// performance data question.
    func testSubscriptionsOfferIsForSignedInUsersWhoNeverMetTheImport() throws {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        XCTAssertNil(store.pendingPrompt(welcomeSeen: false, telemetryOn: true, steamSignedIn: true, now: start),
                     "the guide offers it to new users")
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: true, steamSignedIn: false, now: start),
                     "nothing to import without a Steam account")
        XCTAssertEqual(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, steamSignedIn: true, now: start),
                       .telemetry)
        XCTAssertEqual(store.pendingPrompt(welcomeSeen: true, telemetryOn: true, steamSignedIn: true, now: start),
                       .subscriptions)

        store.markPresented(.subscriptions, now: start)
        XCTAssertNil(SupportPromptStore(defaults: defaults, calendar: calendar)
            .pendingPrompt(welcomeSeen: true, telemetryOn: true, steamSignedIn: true, now: start + day),
                     "offered once, for good")

        let other = SupportPromptStore(defaults: try TemporaryDefaults.make(for: self).defaults, calendar: calendar)
        other.recordSubscriptionsOffered()
        XCTAssertNil(other.pendingPrompt(welcomeSeen: true, telemetryOn: true, steamSignedIn: true, now: start))
    }

    func testStarPromptWaitsForTwoWeeksAndFiveDaysOfUse() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordTelemetryAsked()
        useOnDays(store, 4)
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 20 * day))
        store.recordPanelUse(now: start + 4 * day + 60)
        store.recordPanelUse(now: start + 4 * day + 120)
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 13 * day),
                     "five days of use, but not two weeks yet")
        XCTAssertEqual(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 14 * day), .star)

        store.markPresented(.star, now: start + 14 * day)
        XCTAssertNil(SupportPromptStore(defaults: defaults, calendar: calendar)
            .pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 60 * day), "asked once")
    }

    func testRepeatedUseOnOneDayCountsOnce() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordTelemetryAsked()
        for minute in 0..<10 { store.recordPanelUse(now: start + Double(minute) * 60) }
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 30 * day))
    }

    func testChoosingTheStarInTheSupportPromptSkipsTheStarPrompt() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordTelemetryAsked()
        useOnDays(store, 6)
        store.recordStarChosen()
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 30 * day))
    }

    /// The Discord invitation runs on the star's clock, later: three weeks and seven days of use.
    /// Once shown it never returns, a relaunch included.
    func testDiscordInvitationWaitsForThreeWeeksAndSevenDaysOfUse() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordTelemetryAsked()
        store.recordStarChosen()
        useOnDays(store, 6)
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 40 * day),
                     "three weeks, but six days of use")
        store.recordPanelUse(now: start + 6 * day)
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 20 * day),
                     "seven days of use, but not three weeks yet")
        XCTAssertEqual(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 21 * day), .discord)

        store.markPresented(.discord, now: start + 21 * day)
        XCTAssertNil(SupportPromptStore(defaults: defaults, calendar: calendar)
            .pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 90 * day), "invited once, for good")
    }

    /// When everything is due at once the invitation is the last of the prompts, each on a day of
    /// its own.
    func testTheDiscordInvitationComesAfterEveryOtherPromptOnADayOfItsOwn() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordDownload(wallpaperID: "downloaded")
        store.recordSuccessfulActivation(wallpaperID: "downloaded")
        useOnDays(store, 8)
        var now = start + 30 * day
        var shown = [SupportPromptStore.Prompt]()
        while let prompt = store.pendingPrompt(welcomeSeen: true, telemetryOn: false, steamSignedIn: true, now: now) {
            shown.append(prompt)
            store.markPresented(prompt, now: now)
            XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, steamSignedIn: true, now: now + 60),
                         "one prompt a day")
            now += day
        }
        XCTAssertEqual(shown, [.telemetry, .subscriptions, .support, .star, .discord])
    }

    // MARK: - The battery question

    /// A Mac with a battery, on battery, a wallpaper playing and both battery choices on Keep running.
    private let unplugged = SupportPromptStore.BatteryFacts(
        hasBattery: true, onBattery: true, wallpaperPlaying: true)

    func testTheBatteryQuestionNeedsABatteryABatteryUseAWallpaperAndNothingChosen() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordTelemetryAsked()
        func due(_ change: (inout SupportPromptStore.BatteryFacts) -> Void = { _ in },
                 welcomeSeen: Bool = true) -> SupportPromptStore.Prompt? {
            var facts = unplugged
            change(&facts)
            return store.pendingPrompt(welcomeSeen: welcomeSeen, telemetryOn: false, battery: facts, now: start)
        }
        XCTAssertEqual(due(), .battery)
        XCTAssertNil(due { $0.hasBattery = false }, "a UPS or a desktop Mac is not asked")
        XCTAssertNil(due { $0.onBattery = false }, "plugged in, and never seen on battery since launch")
        XCTAssertNil(due { $0.wallpaperPlaying = false }, "nothing playing, nothing to save")
        XCTAssertNil(due { $0.batteryMode = .reducedQuality }, "a battery choice was made")
        XCTAssertNil(due { $0.batteryMode = .pause })
        for action in [OtherAppInFrontAction.mute, .pause, .pauseOnBattery] {
            XCTAssertNil(due { $0.otherAppInFront = action }, "\(action) already saves energy")
        }
        XCTAssertNil(due(welcomeSeen: false), "the guide shows the On battery choice to new users")
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start),
                     "without the panel's facts nothing is asked")
    }

    /// A wallpaper that played on battery since launch counts once plugged in again; a relaunch
    /// has to see it again.
    func testABatteryUseSinceLaunchCountsUntilTheAppQuits() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordTelemetryAsked()
        var pluggedIn = unplugged
        pluggedIn.onBattery = false
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, battery: pluggedIn, now: start))
        store.recordBatteryUse()
        XCTAssertEqual(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, battery: pluggedIn, now: start), .battery)
        XCTAssertNil(SupportPromptStore(defaults: defaults, calendar: calendar)
            .pendingPrompt(welcomeSeen: true, telemetryOn: false, battery: pluggedIn, now: start),
                     "the battery use is not saved")
    }

    /// Shown once it is spent for good; the guide's Preferences page, or a choice in Settings or
    /// the menu bar, spends it without showing it; state saved before it existed loads it unspent.
    func testTheBatteryQuestionIsAskedOnceForGood() throws {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordTelemetryAsked()
        XCTAssertEqual(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, battery: unplugged, now: start), .battery)
        store.markPresented(.battery, now: start)
        XCTAssertNil(store.pendingPrompt(welcomeSeen: true, telemetryOn: false, battery: unplugged, now: start + 60))
        XCTAssertNil(SupportPromptStore(defaults: defaults, calendar: calendar)
            .pendingPrompt(welcomeSeen: true, telemetryOn: false, battery: unplugged, now: start + 30 * day),
                     "asked once, a relaunch included")

        let elsewhere = SupportPromptStore(defaults: try TemporaryDefaults.make(for: self).defaults, calendar: calendar)
        elsewhere.recordTelemetryAsked()
        elsewhere.recordBatteryAsked()
        XCTAssertNil(elsewhere.pendingPrompt(welcomeSeen: true, telemetryOn: false, battery: unplugged, now: start))

        let key = "WallpaperMachine.supportPrompt.state"
        let earlierDefaults = try TemporaryDefaults.make(for: self).defaults
        let earlier = SupportPromptStore(defaults: earlierDefaults, calendar: calendar)
        earlier.recordTelemetryAsked()
        var saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(earlierDefaults.data(forKey: key))) as? [String: Any])
        XCTAssertNotNil(saved.removeValue(forKey: "batteryAsked"))
        earlierDefaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: key)
        XCTAssertEqual(SupportPromptStore(defaults: earlierDefaults, calendar: calendar)
            .pendingPrompt(welcomeSeen: true, telemetryOn: false, battery: unplugged, now: start), .battery,
                       "an existing user who finished the guide earlier is asked once")
    }

    /// Right after the performance data question, before everything else, each on a day of its own.
    func testTheBatteryQuestionComesRightAfterThePerformanceDataQuestion() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordDownload(wallpaperID: "downloaded")
        store.recordSuccessfulActivation(wallpaperID: "downloaded")
        useOnDays(store, 8)
        var now = start + 30 * day
        var shown = [SupportPromptStore.Prompt]()
        while let prompt = store.pendingPrompt(
            welcomeSeen: true, telemetryOn: false, steamSignedIn: true, battery: unplugged, now: now) {
            shown.append(prompt)
            store.markPresented(prompt, now: now)
            XCTAssertNil(store.pendingPrompt(
                welcomeSeen: true, telemetryOn: false, steamSignedIn: true, battery: unplugged, now: now + 60),
                         "one prompt a day")
            now += day
        }
        XCTAssertEqual(shown, [.telemetry, .battery, .subscriptions, .support, .star, .discord])
    }

    /// Someone who joined from Settings › About or the Help menu is not invited.
    func testJoiningDiscordElsewhereSkipsTheInvitation() {
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        store.recordTelemetryAsked()
        store.recordStarChosen()
        useOnDays(store, 8)
        store.recordDiscordChosen()
        XCTAssertNil(SupportPromptStore(defaults: defaults, calendar: calendar)
            .pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 30 * day))
    }

    /// State saved by a build without the invitation reads it as not yet shown, so an existing
    /// user who has used the app for a while is invited once after the update.
    func testStateSavedBeforeTheDiscordInvitationLoadsWithItUnspent() throws {
        let earlier = SupportPromptStore(defaults: defaults, calendar: calendar)
        earlier.recordTelemetryAsked()
        useOnDays(earlier, 8)
        earlier.markPresented(.star, now: start + 20 * day)
        let key = "WallpaperMachine.supportPrompt.state"
        var saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        saved["discordChosen"] = nil
        saved["discordPresented"] = nil
        defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: key)

        let updated = SupportPromptStore(defaults: defaults, calendar: calendar)
        XCTAssertEqual(updated.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: start + 30 * day), .discord)
    }

    func testStateSavedByEarlierBuildsStillLoads() throws {
        let earlier = try JSONSerialization.data(withJSONObject: [
            "downloadedWallpaperIDs": ["a"], "pending": true, "presented": false,
        ])
        defaults.set(earlier, forKey: "WallpaperMachine.supportPrompt.state")
        let store = SupportPromptStore(defaults: defaults, calendar: calendar)
        XCTAssertTrue(store.isPending)
        XCTAssertEqual(store.pendingPrompt(welcomeSeen: false, telemetryOn: true, now: start), .support)
    }
}
