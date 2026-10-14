import XCTest

@testable import WallpaperMachine

final class UncaughtExceptionLogTests: XCTestCase {
    private final class RecordingSink: AppLogSink {
        private let lock = NSLock()
        private var recorded: [(level: BridgeLogLevel, message: String)] = []
        var lines: [(level: BridgeLogLevel, message: String)] { lock.withLock { recorded } }

        func emitGuiLog(level: BridgeLogLevel, file: String, line: UInt32, message: String, load: UInt64?, unixMillis: Int64?) throws {
            lock.withLock { recorded.append((level, message)) }
        }

        func beginHostLoadLog(kind: String, projectPath: String, detail: String) -> UInt64 { 1 }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "uncaught-exception-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func makeLedger(pid: Int32) -> SessionLedger {
        SessionLedger(url: root.appendingPathComponent("ledger.json"), pid: pid,
                      bootSession: "AAAAAAAA-0000-4000-8000-000000000001")
    }

    func testTheExceptionIsLoggedOnOneLineAndLeftForTheNextLaunch() {
        let ledger = makeLedger(pid: 1)
        _ = ledger.begin(app: "1.0 (1)")
        let router = AppLogRouter()
        let sink = RecordingSink()
        router.attach(sink)
        let exception = NSException(
            name: NSExceptionName("NSInvalidArgumentException"),
            reason: "-[Foo bar]:\n  unrecognized selector", userInfo: nil)

        UncaughtExceptionLog.handle(exception, router: router, ledger: ledger)

        let errors = sink.lines.filter { $0.level == .error }.map(\.message)
        let named = errors.filter { $0.contains("NSInvalidArgumentException") }
        XCTAssertEqual(named.count, 1)
        XCTAssertTrue(named[0].contains("-[Foo bar]: unrecognized selector"), "a reason is one record on one line")
        XCTAssertFalse(errors.contains { $0.contains("\n") })
        XCTAssertEqual(makeLedger(pid: 2).begin(app: "1.0 (1)").outcome,
                       .exception(name: "NSInvalidArgumentException"))
    }

    func testAnExceptionWithoutAReasonIsStillLogged() {
        let router = AppLogRouter()
        let sink = RecordingSink()
        router.attach(sink)

        UncaughtExceptionLog.handle(NSException(name: NSExceptionName("Bare"), reason: nil, userInfo: nil),
                                    router: router, ledger: nil)

        XCTAssertTrue(sink.lines.first?.message.contains("Bare") == true)
    }
}
