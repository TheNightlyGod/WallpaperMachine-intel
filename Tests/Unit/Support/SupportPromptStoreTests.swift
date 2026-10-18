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

    // MARK: - Scheduling of the three prompts

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
