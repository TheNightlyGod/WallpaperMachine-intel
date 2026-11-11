import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    func testPreviousWalksBackAndRecentTracksActualUseAcrossRelaunch() {
        let history = WallpaperHistoryStore(defaults: defaults)
        let available: Set<String> = ["a", "b", "c"]
        history.recordSwitch(from: "a", to: "b", on: "primary")
        history.recordSwitch(from: "b", to: "c", on: "primary")
        history.recordSwitch(from: "c", to: "c", on: "primary")
        XCTAssertEqual(history.previous(on: "primary", current: "c", available: available), "b")
        history.recordSwitch(from: "c", to: "b", on: "primary", returningToPrevious: true)
        XCTAssertEqual(history.previous(on: "primary", current: "b", available: available), "a")
        history.recordSwitch(from: "b", to: "a", on: "primary", returningToPrevious: true)
        XCTAssertNil(history.previous(on: "primary", current: "a", available: available))
        let reloaded = WallpaperHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.recent(on: "primary", available: available), ["a", "b", "c"])
        XCTAssertNil(reloaded.previous(on: "primary", current: "a", available: available))
    }

    func testUnavailableWallpapersAreSkippedAndDeletionCleansEveryDisplay() {
        let history = WallpaperHistoryStore(defaults: defaults)
        history.recordSwitch(from: "a", to: "b", on: "primary")
        history.recordSwitch(from: "b", to: "c", on: "primary")
        history.recordSwitch(from: "b", to: "d", on: "secondary")
        XCTAssertEqual(history.previous(on: "primary", current: "c", available: ["a", "c"]), "a")
        history.forget(["b"])
        let reloaded = WallpaperHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.recent(on: "primary", available: ["a", "b", "c"]), ["c", "a"])
        XCTAssertNil(reloaded.previous(on: "secondary", current: "d", available: ["a", "b", "c", "d"]))
    }

    func testEachDisplayCanBeClearedWithoutChangingTheOther() {
        let history = WallpaperHistoryStore(defaults: defaults)
        history.recordSwitch(from: "a", to: "b", on: "primary")
        history.recordSwitch(from: "x", to: "y", on: "secondary")
        history.clear(on: "primary")
        let reloaded = WallpaperHistoryStore(defaults: defaults)
        XCTAssertTrue(reloaded.recent(on: "primary", available: ["a", "b"]).isEmpty)
        XCTAssertEqual(reloaded.previous(on: "secondary", current: "y", available: ["x", "y"]), "x")
    }

    func testHistoryStaysBoundedAndAChoiceAfterGoingBackStartsANewPath() {
        let history = WallpaperHistoryStore(defaults: defaults)
        for index in 1...100 {
            history.recordSwitch(from: "\(index - 1)", to: "\(index)", on: "primary")
        }
        let available = Set((0...100).map(String.init))
        XCTAssertEqual(history.recent(on: "primary", available: available).count, WallpaperHistoryStore.limit)
        XCTAssertEqual(history.entries["primary"]?.past.count, WallpaperHistoryStore.limit)
        history.recordSwitch(from: "100", to: "99", on: "primary", returningToPrevious: true)
        history.recordSwitch(from: "99", to: "new", on: "primary")
        XCTAssertEqual(history.previous(on: "primary", current: "new", available: available), "99")
        history.recordSwitch(from: "new", to: "99", on: "primary", returningToPrevious: true)
        XCTAssertEqual(history.previous(on: "primary", current: "99", available: available), "98")
    }

    func testTheLastUseOfAWallpaperIsItsNewestOnAnyDisplayAndSurvivesRelaunch() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let history = WallpaperHistoryStore(defaults: defaults, now: { clock })
        history.recordSwitch(from: nil, to: "a", on: "primary")
        clock += 60
        history.recordSwitch(from: "a", to: "b", on: "primary")
        clock += 60
        history.recordSwitch(from: nil, to: "a", on: "secondary")
        clock += 60
        history.recordSwitch(from: "a", to: "a", on: "secondary")
        XCTAssertEqual(
            history.lastUsedDates(),
            ["a": Date(timeIntervalSince1970: 1_120), "b": Date(timeIntervalSince1970: 1_060)],
            "put on the second display later; reapplying an unchanged assignment is no use")
        XCTAssertEqual(WallpaperHistoryStore(defaults: defaults).lastUsedDates(), history.lastUsedDates())
    }

    func testForgettingOrClearingADisplayDropsItsUses() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let history = WallpaperHistoryStore(defaults: defaults, now: { clock })
        history.recordSwitch(from: nil, to: "a", on: "primary")
        history.recordSwitch(from: "a", to: "b", on: "primary")
        clock += 60
        history.recordSwitch(from: nil, to: "a", on: "secondary")
        history.forget(["b"])
        XCTAssertEqual(history.lastUsedDates(), ["a": Date(timeIntervalSince1970: 1_060)])
        history.clear(on: "secondary")
        XCTAssertEqual(
            WallpaperHistoryStore(defaults: defaults).lastUsedDates(), ["a": Date(timeIntervalSince1970: 1_000)],
            "the primary display's use is all that is left")
    }

    func testHistorySavedBeforeUsesWereDatedIsDatedOnceInTheOrderOfItsRecentList() {
        defaults.set(
            Data(#"{"primary":{"past":["a"],"recent":["b","a"]},"secondary":{"past":[],"recent":["c"],"used":{}}}"#.utf8),
            forKey: WallpaperHistoryStore.preferenceKey)
        var clock = Date(timeIntervalSince1970: 1_000)
        let history = WallpaperHistoryStore(defaults: defaults, now: { clock })
        XCTAssertEqual(history.recent(on: "primary", available: ["a", "b"]), ["b", "a"])
        XCTAssertEqual(history.previous(on: "primary", current: "b", available: ["a", "b"]), "a")
        XCTAssertEqual(
            history.lastUsedDates(),
            ["b": Date(timeIntervalSince1970: 1_000), "a": Date(timeIntervalSince1970: 999)],
            "the wallpaper on screen and the one before it keep their order ahead of the never-used; "
                + "a display saved with dates, even none, is not dated again")

        clock += 3_600
        XCTAssertEqual(
            WallpaperHistoryStore(defaults: defaults, now: { clock }).lastUsedDates(), history.lastUsedDates(),
            "dated once: a later launch does not move them ahead of what was used in between")
        history.recordSwitch(from: nil, to: "d", on: "secondary")
        XCTAssertEqual(history.lastUsedDates()["d"], clock, "a wallpaper put on a display afterwards comes first")
    }

    func testEachDisplayRemembersTheLastUseOfABoundedNumberOfWallpapers() {
        var clock = Date(timeIntervalSince1970: 0)
        let history = WallpaperHistoryStore(defaults: defaults, now: { clock })
        let count = WallpaperHistoryStore.usedLimit + 5
        for index in 0..<count {
            clock += 1
            history.recordSwitch(from: index == 0 ? nil : "\(index - 1)", to: "\(index)", on: "primary")
        }
        let dates = WallpaperHistoryStore(defaults: defaults).lastUsedDates()
        XCTAssertEqual(dates.count, WallpaperHistoryStore.usedLimit)
        XCTAssertNil(dates["0"], "the oldest use goes first")
        XCTAssertEqual(dates["\(count - 1)"], clock)
    }

    func testCorruptHistoryDoesNotPreventNewSwitches() {
        defaults.set(Data("broken".utf8), forKey: WallpaperHistoryStore.preferenceKey)
        let history = WallpaperHistoryStore(defaults: defaults)
        history.recordSwitch(from: nil, to: "first", on: "primary")
        XCTAssertEqual(history.recent(on: "primary", available: ["first"]), ["first"])
        XCTAssertNil(history.previous(on: "primary", current: "first", available: ["first"]))
    }
}
