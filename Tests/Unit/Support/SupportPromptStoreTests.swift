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
