import XCTest
@testable import WallpaperMachine

final class PlaylistPlannerTests: XCTestCase {
    /// Deterministic, so a shuffle test fails the same way every time it fails.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func playlist(_ source: PlaylistSource, list: [String] = []) -> DisplayPlaylist {
        var playlist = DisplayPlaylist()
        playlist.source = source
        playlist.wallpaperIDs = list
        return playlist
    }

    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ text: String, _ calendar: Calendar) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text))
    }

    func testCandidatesSkipWhatCannotPlay() {
        let library = ["a", "b", "c"]
        XCTAssertEqual(PlaylistPlanner.candidates(for: playlist(.all), library: library, favorites: [], collectionIDs: []), library)
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: playlist(.favorites), library: library, favorites: ["c", "a", "gone"], collectionIDs: []),
            ["a", "c"], "favorites follow the library order and skip what left it")
        XCTAssertEqual(
            PlaylistPlanner.candidates(for: playlist(.list, list: ["c", "gone", "a", "c"]), library: library, favorites: [], collectionIDs: []),
            ["c", "a"], "a list keeps its own order, once each, without missing wallpapers")
    }

    func testCollectionUsesLiveMembershipWithoutFallingBackToDisplayList() {
        let configuration = playlist(.collection, list: ["a"])
        XCTAssertEqual(PlaylistPlanner.candidates(
            for: configuration, library: ["a", "b", "c"], favorites: [],
            collectionIDs: ["c", "missing", "b", "c"]), ["c", "b"])
        XCTAssertEqual(PlaylistPlanner.candidates(
            for: configuration, library: ["a", "b", "c"], favorites: [], collectionIDs: []), [])
    }

    func testOlderPlaylistDataRetainsItsSelectionsWhenNewFieldsAreMissing() throws {
        let decoded = try JSONDecoder().decode(DisplayPlaylist.self, from: Data(
            #"{"mode":"rotate","source":"list","order":"shuffle","interval":60,"wallpaperIDs":["b","a"]}"#.utf8))
        XCTAssertEqual(decoded.mode, .rotate)
        XCTAssertEqual(decoded.source, .list)
        XCTAssertEqual(decoded.order, .shuffle)
        XCTAssertEqual(decoded.interval, 60)
        XCTAssertEqual(decoded.wallpaperIDs, ["b", "a"])
        XCTAssertNil(decoded.collectionID)
        XCTAssertNil(decoded.planID)
    }

    func testInOrderWrapsAndStartsFromTheTop() {
        var random = SplitMix(state: 1)
        let candidates = ["a", "b", "c"]
        XCTAssertEqual(PlaylistPlanner.next(after: "b", in: candidates, order: .sequential, recent: [], using: &random), "c")
        XCTAssertEqual(PlaylistPlanner.next(after: "c", in: candidates, order: .sequential, recent: [], using: &random), "a")
        XCTAssertEqual(PlaylistPlanner.next(after: "x", in: candidates, order: .sequential, recent: [], using: &random), "a")
        XCTAssertEqual(PlaylistPlanner.next(after: nil, in: candidates, order: .sequential, recent: [], using: &random), "a")
        XCTAssertNil(PlaylistPlanner.next(after: "a", in: ["a"], order: .sequential, recent: [], using: &random),
                     "a display already showing the only wallpaper has nothing to change to")
        XCTAssertNil(PlaylistPlanner.next(after: nil, in: [], order: .shuffle, recent: [], using: &random))
    }

    func testShuffleShowsEveryWallpaperBeforeRepeatingOneInANewOrderEachRound() throws {
        var random = SplitMix(state: 42)
        let candidates = (1...7).map { "w\($0)" }
        var current: String?
        var recent: [String] = []
        var orders: [[String]] = []
        for round in 0..<6 {
            var order: [String] = []
            for _ in candidates {
                let next = try XCTUnwrap(PlaylistPlanner.next(
                    after: current, in: candidates, order: .shuffle, recent: recent, using: &random))
                XCTAssertNotEqual(next, current, "a change always changes something")
                XCTAssertFalse(order.contains(next), "round \(round) repeated \(next)")
                order.append(next)
                current = next
                recent = PlaylistPlanner.remember(next, in: recent, candidates: candidates)
            }
            orders.append(order)
        }
        XCTAssertGreaterThan(Set(orders).count, 1, "rounds must not settle into one fixed cycle")
    }

    func testDayRunsFromDayStartUpToNightStart() throws {
        let calendar = try calendar("Europe/Berlin")
        let noon = PlaylistPlanner.phase(at: try date("2026-06-01 12:00", calendar), dayStart: 7 * 60, nightStart: 19 * 60, calendar: calendar)
        XCTAssertEqual(noon.phase, .day)
        XCTAssertEqual(noon.until, try date("2026-06-01 19:00", calendar))
        let evening = PlaylistPlanner.phase(at: try date("2026-06-01 19:00", calendar), dayStart: 7 * 60, nightStart: 19 * 60, calendar: calendar)
        XCTAssertEqual(evening.phase, .night, "the boundary minute belongs to the half it starts")
        XCTAssertEqual(evening.until, try date("2026-06-02 07:00", calendar))
        let early = PlaylistPlanner.phase(at: try date("2026-06-02 03:00", calendar), dayStart: 7 * 60, nightStart: 19 * 60, calendar: calendar)
        XCTAssertEqual(early.phase, .night)
        XCTAssertEqual(early.until, try date("2026-06-02 07:00", calendar))
    }

    func testADayThatStartsAfterTheNightWrapsPastMidnight() throws {
        let calendar = try calendar("UTC")
        // Someone who lives by night: "day" from 22:00, "night" from 06:00.
        let late = PlaylistPlanner.phase(at: try date("2026-06-01 23:30", calendar), dayStart: 22 * 60, nightStart: 6 * 60, calendar: calendar)
        XCTAssertEqual(late.phase, .day)
        XCTAssertEqual(late.until, try date("2026-06-02 06:00", calendar))
        let morning = PlaylistPlanner.phase(at: try date("2026-06-02 09:00", calendar), dayStart: 22 * 60, nightStart: 6 * 60, calendar: calendar)
        XCTAssertEqual(morning.phase, .night)
        XCTAssertEqual(morning.until, try date("2026-06-02 22:00", calendar))
    }

    func testClockChangeDaysSwitchAtTheTimeOnTheClock() throws {
        let calendar = try calendar("America/New_York")
        // Clocks skip 02:00–03:00 on 8 March 2026, so 07:30 is only 6.5 hours after midnight.
        let morning = PlaylistPlanner.phase(at: try date("2026-03-08 07:30", calendar), dayStart: 7 * 60, nightStart: 19 * 60, calendar: calendar)
        XCTAssertEqual(morning.phase, .day)
        XCTAssertEqual(morning.until, try date("2026-03-08 19:00", calendar))
    }

    func testSavedPlaylistsDecodeWithWhatTheyLack() throws {
        let decoded = try JSONDecoder().decode(
            DisplayPlaylist.self, from: Data(#"{"mode":"rotate","interval":0,"dayStart":9999,"source":"sideways"}"#.utf8))
        XCTAssertEqual(decoded.mode, .rotate)
        XCTAssertEqual(decoded.interval, DisplayPlaylist().interval, "an interval outside the range falls back")
        XCTAssertEqual(decoded.dayStart, DisplayPlaylist().dayStart)
        XCTAssertEqual(decoded.source, .all)
    }
}
