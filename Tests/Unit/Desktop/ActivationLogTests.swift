import XCTest
@testable import WallpaperMachine

/// "Why did my wallpaper change?" has to be answered by one log line: which wallpaper, on
/// which display, asked for by whom, and how it ended, without the title or the error text.
@MainActor
final class ActivationLogTests: XCTestCase {
    private var bridge: DisplayTransferTestBridge!
    private var store: BridgeStore!
    private var root: URL!
    private var previousHome: String?
    private var lines = LogLines()

    override func setUp() async throws {
        previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("activation-log-\(UUID().uuidString)")
        setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
        bridge = DisplayTransferTestBridge(noPointer: .init())
        try bridge.installProjects(in: root.appendingPathComponent("Library"))
        store = BridgeStore(bridge: bridge)
        let collected = lines
        store.activationLogWriter = { line, isFailure in collected.add(line, isFailure: isFailure) }
        try await store.refreshAllAsync()
    }

    override func tearDown() async throws {
        if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
        try FileManager.default.removeItem(at: root)
    }

    // MARK: Format

    func testEveryOriginAndOutcomeNamesTheWallpaperDisplayAndOrigin() {
        let outcomes: [ActivationLog.Outcome] = [
            .applied, .noOp, .skipped, .failed(.cancelled), .failed(.refused), .failed(.error),
        ]
        for kind in [ActivationLog.Kind.activation, .reload, .reapply] {
            for origin in [ActivationOrigin.user, .playlist, .automation, .layout, .updateReload] {
                var seen: Set<String> = []
                for outcome in outcomes {
                    let line = ActivationLog.line(kind, wallpaper: "1234", display: "disp-7", origin: origin,
                                                  outcome: outcome, milliseconds: 42)
                    XCTAssertTrue(line.hasPrefix("\(kind.rawValue): wallpaper 1234 display disp-7 origin \(origin.rawValue) "), line)
                    seen.insert(line)
                }
                XCTAssertEqual(seen.count, outcomes.count, "Each way an activation can end reads differently: \(kind) \(origin)")
            }
        }
    }

    func testOnlyAnActivationThatRanReportsHowLongItTook() {
        func line(_ outcome: ActivationLog.Outcome, _ milliseconds: Int?) -> String {
            ActivationLog.line(.reload, wallpaper: "w", display: "d", origin: .updateReload,
                               outcome: outcome, milliseconds: milliseconds)
        }
        XCTAssertTrue(line(.applied, 350).hasSuffix(" in 350 ms"))
        XCTAssertTrue(line(.failed(.error), 5).hasSuffix(" in 5 ms"))
        XCTAssertFalse(line(.skipped, nil).contains(" ms"))
    }

    func testFailuresAreSortedByWhoStoppedThem() {
        XCTAssertEqual(ActivationLog.failure(of: CancellationError()), .cancelled)
        XCTAssertEqual(ActivationLog.failure(of: WallpaperActionError(message: "Refresh Library and retry.")), .refused)
        XCTAssertEqual(ActivationLog.failure(of: CocoaError(.fileWriteUnknown)), .error)
    }

    func testDurationsAreWholeMilliseconds() {
        XCTAssertEqual(ActivationLog.milliseconds(.seconds(2) + .milliseconds(345)), 2345)
        XCTAssertEqual(ActivationLog.milliseconds(.microseconds(900)), 0)
        XCTAssertEqual(ActivationLog.milliseconds(.zero), 0)
    }

    // MARK: Results

    func testActivationReportsAppliedForANewAssignmentAndNoOpForOneAlreadyShown() async throws {
        let first = try await store.performActivation(
            id: "c", displayId: "primary", origin: .user, returningToPrevious: false, recordsHistory: true)
        XCTAssertEqual(first, .applied)
        XCTAssertEqual(bridge.assignments["primary"], "c")

        let again = try await store.performActivation(
            id: "c", displayId: "primary", origin: .user, returningToPrevious: false, recordsHistory: true)
        XCTAssertEqual(again, .noOp, "A display already showing the wallpaper is left alone")
        XCTAssertEqual(bridge.applications.filter { $0 == ("primary", "c") }.count, 1)
    }

    // MARK: What the store logs

    func testEachActivationLogsWhoAskedAndHowItEnded() async throws {
        try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .user)
        try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .user)
        try await store.activateWallpaperAsync(id: "b", displayId: "primary", origin: .playlist)

        XCTAssertEqual(lines.entries.count, 3)
        XCTAssertTrue(lines.entries[0].text.hasPrefix("activation: wallpaper c display primary origin user applied in "), lines.entries[0].text)
        XCTAssertTrue(lines.entries[1].text.hasPrefix("activation: wallpaper c display primary origin user noOp in "), lines.entries[1].text)
        XCTAssertTrue(lines.entries[2].text.hasPrefix("activation: wallpaper b display primary origin playlist applied in "), lines.entries[2].text)
        XCTAssertTrue(lines.entries.allSatisfy { !$0.isFailure })
        for entry in lines.entries {
            XCTAssertNotNil(entry.text.range(of: #" in \d+ ms$"#, options: .regularExpression), entry.text)
        }
    }

    func testALineNamesTheWallpaperById() async throws {
        // Wallpaper "a" is titled with markup in the fixture; the title must not reach the log.
        try await store.activateWallpaperAsync(id: "a", displayId: "secondary", origin: .automation)

        let line = try XCTUnwrap(lines.entries.first).text
        XCTAssertTrue(line.contains("wallpaper a "), line)
        XCTAssertFalse(line.contains("Ocean"), line)
    }

    func testARefusedActivationIsLoggedAsAWarningWithoutItsMessage() async throws {
        do {
            try await store.activateWallpaperAsync(id: "gone", displayId: "primary", origin: .user)
            XCTFail("a wallpaper outside the library was activated")
        } catch {}

        let entry = try XCTUnwrap(lines.entries.first)
        XCTAssertTrue(entry.isFailure)
        XCTAssertTrue(entry.text.hasPrefix("activation: wallpaper gone display primary origin user failed (refused) in "), entry.text)
        XCTAssertFalse(entry.text.contains("library"), "The message belongs to the panel, not the log: \(entry.text)")
    }

    func testABridgeFailureIsLoggedAsAnErrorWithoutItsMessage() async throws {
        bridge.failOnce = "primary=c"
        do {
            try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .layout)
            XCTFail("the failing apply succeeded")
        } catch {}

        let entry = try XCTUnwrap(lines.entries.last)
        XCTAssertTrue(entry.isFailure)
        XCTAssertTrue(entry.text.hasPrefix("activation: wallpaper c display primary origin layout failed (error) in "), entry.text)
        XCTAssertFalse(entry.text.contains(CocoaError(.fileWriteUnknown).localizedDescription), entry.text)
    }

    func testAnUpdateReloadLogsItselfAndTheActivationItPerformed() async throws {
        try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .user)
        lines.entries.removeAll()

        try await store.reloadWallpaperAsync(id: "c")

        XCTAssertEqual(bridge.assignments["primary"], "c")
        XCTAssertEqual(lines.entries.count, 2)
        XCTAssertTrue(lines.entries[0].text.hasPrefix("activation: wallpaper c display primary origin updateReload applied in "), lines.entries[0].text)
        XCTAssertTrue(lines.entries[1].text.hasPrefix("reload: wallpaper c display primary origin updateReload applied in "), lines.entries[1].text)
    }

    func testAReloadThatGaveWayToTheUsersChoiceSaysSoAndDoesNotActivate() async throws {
        try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .user)
        lines.entries.removeAll()
        let slot = BridgeStore.activationSlot(displayId: "primary")
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await store.commands.run { await withCheckedContinuation { release = $0 } } }
        for _ in 0..<1_000 where release == nil { await Task.yield() }
        let choice = Task { await store.commands.run(slot: slot, subject: "b") {} }
        for _ in 0..<1_000 where !store.commands.hasWaiting(slot: slot) { await Task.yield() }
        XCTAssertTrue(store.commands.hasWaiting(slot: slot))

        try await store.reloadWallpaperAsync(id: "c")

        XCTAssertEqual(lines.entries.count, 1, "A reload that never ran has no activation to report")
        let entry = lines.entries[0]
        XCTAssertFalse(entry.isFailure)
        XCTAssertTrue(entry.text.hasPrefix("reload: wallpaper c display primary origin updateReload skipped"), entry.text)
        XCTAssertFalse(entry.text.contains(" ms"), entry.text)

        release?.resume()
        _ = await blocker.value
        _ = await choice.value
    }

    func testAFailedReloadIsLoggedAndStillThrows() async throws {
        try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .user)
        lines.entries.removeAll()
        bridge.failOnce = "primary=c"

        do {
            try await store.reloadWallpaperAsync(id: "c")
            XCTFail("the failing reload succeeded")
        } catch {}

        let reload = try XCTUnwrap(lines.entries.last)
        XCTAssertTrue(reload.isFailure)
        XCTAssertTrue(reload.text.hasPrefix("reload: wallpaper c display primary origin updateReload failed (error) in "), reload.text)
    }
}

private final class LogLines {
    struct Entry {
        let text: String
        let isFailure: Bool
    }

    var entries: [Entry] = []

    func add(_ text: String, isFailure: Bool) { entries.append(Entry(text: text, isFailure: isFailure)) }
}
