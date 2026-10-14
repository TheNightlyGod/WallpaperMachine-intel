import XCTest

@testable import WallpaperMachine

/// Every case runs against a temporary file with an injected clock, process id and
/// boot session, so no test depends on the real support folder or on how the
/// test host itself started.
final class SessionLedgerTests: XCTestCase {
    private var root: URL!
    private var url: URL { root.appendingPathComponent("Session/ledger.json") }
    private let thisBoot = "AAAAAAAA-0000-4000-8000-000000000001"
    private let otherBoot = "BBBBBBBB-0000-4000-8000-000000000002"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func makeLedger(
        pid: Int32 = 100, boot: String? = nil, at time: TimeInterval = 1_800_000_000,
        write: @escaping (Data, URL) throws -> Void = SessionLedger.writeAtomically
    ) -> SessionLedger {
        SessionLedger(url: url, clock: { Date(timeIntervalSince1970: time) }, pid: pid,
                      bootSession: boot ?? thisBoot, write: write)
    }

    // MARK: How the previous session ended

    func testFirstRunHasNothingOnRecord() {
        let previous = makeLedger().begin(app: "1.0 (1)")

        XCTAssertEqual(previous.outcome, .firstRun)
        XCTAssertNil(previous.launch)
        XCTAssertTrue(previous.recent.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the run is on record from launch")
    }

    func testASessionThatEndedIsACleanQuit() {
        let first = makeLedger(pid: 41)
        _ = first.begin(app: "1.0 (1)")
        first.markQuitting(reason: "update")
        first.markEnded()

        let previous = makeLedger(pid: 42).begin(app: "1.1 (2)")

        XCTAssertEqual(previous.outcome, .cleanQuit(reason: "update"))
        XCTAssertEqual(previous.launch?.pid, 41)
        XCTAssertEqual(previous.launch?.app, "1.0 (1)")
        XCTAssertEqual(previous.unexpectedCount, 0)
    }

    func testAQuitThatNeverFinishedIsStalled() {
        let first = makeLedger()
        _ = first.begin(app: "1.0 (1)")
        first.markQuitting(reason: "logout")

        XCTAssertEqual(makeLedger(pid: 101).begin(app: "1.0 (1)").outcome, .quitStalled(reason: "logout"))
    }

    func testAQuitThatWasCalledOffIsRunningAgain() {
        let first = makeLedger()
        _ = first.begin(app: "1.0 (1)")
        first.markQuitting(reason: nil)
        first.markRunning()

        XCTAssertEqual(makeLedger(pid: 101).begin(app: "1.0 (1)").outcome, .endedUnexpectedly,
                       "a run that went on after a refused quit and then died did not stall a quit")
    }

    func testARunningSessionOnTheSameBootEndedUnexpectedly() {
        _ = makeLedger().begin(app: "1.0 (1)")

        XCTAssertEqual(makeLedger(pid: 101).begin(app: "1.0 (1)").outcome, .endedUnexpectedly)
    }

    func testARunningSessionFromAnotherBootWasEndedByTheSystem() {
        _ = makeLedger(boot: otherBoot).begin(app: "1.0 (1)")

        XCTAssertEqual(makeLedger(pid: 101, boot: thisBoot).begin(app: "1.0 (1)").outcome, .systemRestart)
    }

    func testBootSessionsCompareWithoutCase() {
        _ = makeLedger(boot: thisBoot.lowercased()).begin(app: "1.0 (1)")

        XCTAssertEqual(makeLedger(pid: 101, boot: thisBoot).begin(app: "1.0 (1)").outcome, .endedUnexpectedly)
    }

    func testAnUnknownBootIsNeverCalledARestart() {
        func launch(boot: String?) -> SessionLedger.Launch {
            SessionLedger.Launch(id: "x", pid: 1, startedAt: Date(timeIntervalSince1970: 0), bootSession: boot,
                                 app: "1.0 (1)", phase: .running, quitReason: nil, exception: nil)
        }

        XCTAssertEqual(SessionLedger.classify(previous: launch(boot: nil), currentBoot: thisBoot), .endedUnexpectedly)
        XCTAssertEqual(SessionLedger.classify(previous: launch(boot: otherBoot), currentBoot: nil), .endedUnexpectedly)
    }

    func testAnExceptionOutranksWhateverPhaseTheRunWasIn() {
        let first = makeLedger()
        _ = first.begin(app: "1.0 (1)")
        first.noteException(named: "NSRangeException")

        let previous = makeLedger(pid: 101).begin(app: "1.0 (1)")

        XCTAssertEqual(previous.outcome, .exception(name: "NSRangeException"))
        XCTAssertTrue(previous.outcome.isUnexpectedEnd)
    }

    func testTheBootSessionComesFromTheKernel() {
        let boot = SessionLedger.currentBootSession()

        XCTAssertNotNil(boot.flatMap { UUID(uuidString: $0) })
        XCTAssertEqual(boot, SessionLedger.currentBootSession(), "stable for as long as the machine stays up")
    }

    // MARK: The ring of recent sessions

    func testTheRingKeepsTheLastFiveAndCountsUnexpectedEndsInARow() {
        // Oldest first: quit, crash, quit, then four crashes, then the run being classified.
        let endings = ["quit", "crash", "quit", "crash", "crash", "crash", "crash"]
        for (index, ending) in endings.enumerated() {
            let ledger = makeLedger(pid: Int32(10 + index))
            _ = ledger.begin(app: "1.0 (1)")
            if ending == "quit" { ledger.markEnded() }
        }

        let previous = makeLedger(pid: 99).begin(app: "1.0 (1)")

        XCTAssertEqual(previous.recent.count, SessionLedger.recentLimit)
        XCTAssertEqual(previous.recent.map(\.pid), [12, 13, 14, 15, 16], "the oldest two are forgotten")
        XCTAssertEqual(previous.unexpectedCount, 4)
        XCTAssertEqual(previous.consecutiveUnexpected, 4)
    }

    func testACleanQuitEndsTheRunOfUnexpectedEnds() {
        for ending in ["crash", "crash", "quit", "crash"] {
            let ledger = makeLedger()
            _ = ledger.begin(app: "1.0 (1)")
            if ending == "quit" { ledger.markEnded() }
        }

        let previous = makeLedger().begin(app: "1.0 (1)")

        XCTAssertEqual(previous.unexpectedCount, 3)
        XCTAssertEqual(previous.consecutiveUnexpected, 1)
    }

    func testEveryQuitReasonSurvivesToTheNextLaunchAndIsNamedInItsReport() {
        for (index, reason) in QuitReason.allCases.enumerated() {
            let finished = makeLedger(pid: Int32(200 + index))
            _ = finished.begin(app: "1.0 (1)")
            finished.markQuitting(reason: reason.rawValue)
            finished.markEnded()

            let afterQuit = makeLedger(pid: 300).begin(app: "1.0 (1)")
            XCTAssertEqual(afterQuit.outcome, .cleanQuit(reason: reason.rawValue))
            XCTAssertTrue(afterQuit.summary.contains(reason.rawValue), afterQuit.summary)

            let stalled = makeLedger(pid: Int32(400 + index))
            _ = stalled.begin(app: "1.0 (1)")
            stalled.markQuitting(reason: reason.rawValue)

            let afterStall = makeLedger(pid: 500).begin(app: "1.0 (1)")
            XCTAssertEqual(afterStall.outcome, .quitStalled(reason: reason.rawValue))
            XCTAssertTrue(afterStall.summary.contains(reason.rawValue), afterStall.summary)
        }
    }

    func testTheRingRemembersWhyEarlierSessionsEnded() {
        let quit = makeLedger(pid: 1)
        _ = quit.begin(app: "1.0 (1)")
        quit.markQuitting(reason: "shutdown")
        quit.markEnded()
        _ = makeLedger(pid: 2).begin(app: "1.0 (1)")

        let previous = makeLedger(pid: 3).begin(app: "1.0 (1)")

        XCTAssertEqual(previous.recent.map(\.outcome), [.cleanQuit(reason: "shutdown"), .endedUnexpectedly])
    }

    // MARK: The file

    func testAFileThatIsNotALedgerReadsAsAFirstRunAndIsReplaced() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: url)

        XCTAssertEqual(makeLedger().begin(app: "1.0 (1)").outcome, .firstRun)
        XCTAssertEqual(makeLedger(pid: 101).begin(app: "1.0 (1)").outcome, .endedUnexpectedly,
                       "the unreadable file was replaced by a readable one")
    }

    func testALedgerOfAnotherFormatIsStartedOver() throws {
        let first = makeLedger()
        _ = first.begin(app: "1.0 (1)")
        let future = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"format\" : 1", with: "\"format\" : 2")
        try Data(future.utf8).write(to: url)

        XCTAssertEqual(makeLedger(pid: 101).begin(app: "1.0 (1)").outcome, .firstRun)
    }

    func testAFailedWriteNeverStopsTheLaunch() {
        struct Refused: Error {}
        let ledger = makeLedger(write: { _, _ in throw Refused() })

        XCTAssertEqual(ledger.begin(app: "1.0 (1)").outcome, .firstRun)
        ledger.markQuitting(reason: nil)
        ledger.markEnded()
    }

    func testASessionWritesTheFileThreeTimes() {
        let writes = Counter()
        let ledger = makeLedger(write: { data, url in
            writes.increment()
            try SessionLedger.writeAtomically(data, to: url)
        })

        _ = ledger.begin(app: "1.0 (1)")
        ledger.markQuitting(reason: "user")
        ledger.markEnded()
        // Repeating a mark, or one that no longer applies, changes nothing and writes nothing.
        ledger.markEnded()
        ledger.markRunning()
        ledger.markQuitting(reason: "user")

        XCTAssertEqual(writes.value, 3)
    }

    // MARK: Ended from outside

    func testARunCutShortBeforeItsQuitBeganIsAQuitThatDidNotFinishNotACrash() {
        let first = makeLedger()
        _ = first.begin(app: "1.0 (1)")

        first.markCutShort(reason: "terminated by SIGTERM; ended by force")

        XCTAssertEqual(makeLedger(pid: 101).begin(app: "1.0 (1)").outcome,
                       .quitStalled(reason: "terminated by SIGTERM; ended by force"))
    }

    func testARunCutShortDuringItsQuitKeepsWhatTheQuitAlreadySaid() {
        let first = makeLedger()
        _ = first.begin(app: "1.0 (1)")
        first.markQuitting(reason: "terminated by SIGTERM; left running: bridge")

        first.markCutShort(reason: "terminated by SIGTERM; ended by force")

        XCTAssertEqual(makeLedger(pid: 101).begin(app: "1.0 (1)").outcome,
                       .quitStalled(reason: "terminated by SIGTERM; left running: bridge"))
    }

    func testARunThatHasEndedIsNotCutShort() {
        let first = makeLedger()
        _ = first.begin(app: "1.0 (1)")
        first.markQuitting(reason: "user")
        first.markEnded()

        first.markCutShort(reason: "terminated by SIGTERM; ended by force")

        XCTAssertEqual(makeLedger(pid: 101).begin(app: "1.0 (1)").outcome, .cleanQuit(reason: "user"))
    }

    func testAnOlderCopyDoesNotRewriteTheRecordOfTheNewerOne() {
        let older = makeLedger(pid: 1)
        _ = older.begin(app: "1.0 (1)")
        let newer = makeLedger(pid: 2)
        _ = newer.begin(app: "1.0 (1)")

        older.markQuitting(reason: nil)
        older.markEnded()

        // The newer copy is still running, and a crash of it is not hidden by the older one's exit.
        let previous = makeLedger(pid: 3).begin(app: "1.0 (1)")
        XCTAssertEqual(previous.outcome, .endedUnexpectedly)
        XCTAssertEqual(previous.launch?.pid, 2)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
}
