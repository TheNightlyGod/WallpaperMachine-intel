import XCTest
@testable import WallpaperMachine

/// Finder's desktop icons: read the way Finder reads its own switch, and changed only by one write
/// and one Finder restart, through a stand-in Finder so the developer's is never touched.
@MainActor
final class FinderDesktopIconsTests: XCTestCase {
    /// A Finder that keeps its `CreateDesktop` in memory and counts what it was asked to do.
    @MainActor
    private final class StandInFinder {
        var stored: Any?
        var accepts = true
        var ends = true
        private(set) var writes: [Bool] = []
        private(set) var restarts = 0

        var icons: FinderDesktopIcons {
            var actions = DesktopActionLog.shared.actions
            actions.finderDesktopPreference = { [unowned self] in stored }
            actions.setFinderDesktopPreference = { [unowned self] shown in
                writes.append(shown)
                guard accepts else { return false }
                stored = shown
                return true
            }
            actions.restartFinder = { [unowned self] in
                restarts += 1
                return ends
            }
            return FinderDesktopIcons(desktop: actions)
        }
    }

    func testEveryWayTheValueCanBeStoredReadsAsFinderReadsIt() {
        let cases: [(stored: Any?, shown: Bool, how: String)] = [
            (nil, true, "never set: Finder's default"),
            (true, true, "defaults write -bool true"), (false, false, "defaults write -bool false"),
            (NSNumber(value: 1), true, "-int 1"), (NSNumber(value: 0), false, "-int 0"),
            ("1", true, "a string 1"), ("0", false, "a string 0"),
            ("false", false, "a string false"), ("FALSE", false, "in capitals"), ("No", false, "no"),
            ("true", true, "a string true"), ("YES", true, "yes"),
            (Date(), true, "a value of another kind"),
        ]
        for (stored, shown, how) in cases {
            XCTAssertEqual(FinderDesktopIcons.areShown(storedValue: stored), shown, how)
        }
    }

    func testHidingWritesOnceAndRestartsFinderOnce() throws {
        let finder = StandInFinder()
        XCTAssertTrue(finder.icons.areShown)

        XCTAssertTrue(try finder.icons.setShown(false))
        XCTAssertEqual(finder.writes, [false])
        XCTAssertEqual(finder.restarts, 1)
        XCTAssertFalse(finder.icons.areShown, "the next reading asks Finder again and finds them hidden")

        XCTAssertTrue(try finder.icons.setShown(true))
        XCTAssertEqual(finder.writes, [false, true])
        XCTAssertEqual(finder.restarts, 2)
    }

    func testAChoiceFinderAlreadyHasRestartsNothing() throws {
        let finder = StandInFinder()
        finder.stored = "0"
        XCTAssertFalse(try finder.icons.setShown(false), "hidden by hand in Terminal already")
        XCTAssertEqual(finder.writes, [])
        XCTAssertEqual(finder.restarts, 0, "Finder is never restarted for nothing")
    }

    func testARefusedWriteLeavesFinderRunning() {
        let finder = StandInFinder()
        finder.accepts = false
        XCTAssertThrowsError(try finder.icons.setShown(false))
        XCTAssertEqual(finder.restarts, 0, "a restart would show the old icons again for nothing")
        XCTAssertTrue(finder.icons.areShown)
    }

    func testAFinderThatCannotBeRestartedIsReportedAndKeepsTheChoiceForItsNextStart() {
        let finder = StandInFinder()
        finder.ends = false
        XCTAssertThrowsError(try finder.icons.setShown(false)) { error in
            XCTAssertTrue(error is FinderDesktopIcons.RestartFailed, "not taken for a change that worked")
        }
        XCTAssertEqual(finder.writes, [false])
        XCTAssertEqual(finder.restarts, 1)
        XCTAssertFalse(finder.icons.areShown, "the stored choice, which Finder applies when it next starts")
    }

    // MARK: Restarting the live Finder, apart from its processes

    func testWithNoFinderRunningNothingIsEndedAndNoFinderIsOpened() {
        var checks = 0
        let restarted = FinderDesktopIcons.restart(
            finders: [], end: { _ in XCTFail("no Finder to end"); return 0 }, checkBackLater: { checks += 1 })
        XCTAssertTrue(restarted, "nothing to restart is no failure")
        XCTAssertEqual(checks, 0, "a Finder the user had quit is not opened for them")
    }

    func testARunningFinderIsEndedOnceAndCheckedOnOnce() {
        var ended: [pid_t] = []
        var checks = 0
        let restarted = FinderDesktopIcons.restart(
            finders: [412], end: { ended.append($0); return 0 }, checkBackLater: { checks += 1 })
        XCTAssertTrue(restarted)
        XCTAssertEqual(ended, [412])
        XCTAssertEqual(checks, 1, "so a Finder macOS does not bring back is opened")
    }

    func testAFinderThatHadAlreadyQuitCountsAsEnded() {
        var checks = 0
        XCTAssertTrue(FinderDesktopIcons.restart(finders: [412], end: { _ in ESRCH }, checkBackLater: { checks += 1 }))
        XCTAssertEqual(checks, 1)
    }

    func testAFinderThatWillNotEndFailsTheRestart() {
        var checks = 0
        XCTAssertFalse(FinderDesktopIcons.restart(finders: [412], end: { _ in EPERM }, checkBackLater: { checks += 1 }))
        XCTAssertEqual(checks, 0, "the Finder still running needs no opening")
    }
}
