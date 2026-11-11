import XCTest

@testable import WallpaperMachine

final class DiagnosticsBundleTests: XCTestCase {
    private var root: URL!
    private let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "diagnostics-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testNewestSessionsKeepNumericSuffixOrder() throws {
        let logs = try makeLogs([
            "20260927-150000": ["0.log": "oldest"],
            "20260927-150200": ["0.log": "base"],
            "20260927-150200-1": ["0.log": "one"],
            "20260927-150200-9": ["0.log": "nine"],
            "20260927-150200-10": ["0.log": "ten"],
        ])
        let bundle = makeBundle(logs: logs, limits: limits(sessions: 2))
        let exported = try export(bundle)
        XCTAssertEqual(Set(logSessions(in: exported.report)), ["20260927-150200-10", "20260927-150200-9"])
        XCTAssertTrue(exported.report.missing.contains { $0.contains("20260927-150200-1") && $0.contains("omitted") })
        XCTAssertTrue(exported.report.missing.contains { $0.contains("20260927-150000") && $0.contains("omitted") })
        XCTAssertFalse(exported.report.included.contains { $0.contains("20260927-150200/") })
    }

    func testByteBudgetKeepsNewestTailAndNotesTheRest() throws {
        let logs = try makeLogs([
            "20260927-100000": ["0.log": "old\n"],
            "20260927-120000": ["0.log": "older-file\n", "1.log": "AAAA\nBBBB\nCCCC\n"],
        ])
        var limits = DiagnosticsBundle.Limits()
        limits.sessions = 5
        limits.logBytes = 8
        let bundle = makeBundle(logs: logs, limits: limits)
        let exported = try export(bundle)
        let newest = try text(exported, "logs/20260927-120000/1.log")
        XCTAssertEqual(newest, "[truncated: first 10 bytes omitted]\nCCCC\n")
        XCTAssertFalse(exported.report.included.contains("logs/20260927-120000/0.log"))
        XCTAssertFalse(exported.report.included.contains("logs/20260927-100000/0.log"))
        XCTAssertTrue(exported.report.missing.contains("logs/20260927-120000/0.log omitted: log size limit reached"))
        XCTAssertTrue(exported.report.missing.contains("logs/20260927-100000/0.log omitted: log size limit reached"))
    }

    func testTailThatStartsOnALineBoundaryKeepsThatLine() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "AAAA\nBBBB\n"]])
        var limits = DiagnosticsBundle.Limits()
        limits.logBytes = 5
        let exported = try export(makeBundle(logs: logs, limits: limits))
        XCTAssertEqual(try text(exported, "logs/20260927-120000/0.log"), "[truncated: first 5 bytes omitted]\nBBBB\n")
    }

    func testCrashReportsAreFilteredByPrefixAgeAndCount() throws {
        let crashes = root.appendingPathComponent("crashes", isDirectory: true)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        let age: TimeInterval = 14 * 24 * 60 * 60
        try writeCrash("WallpaperMachine-new.ips", at: exportedAt.addingTimeInterval(-3600), body: "path /Users/alice/Library", in: crashes)
        try writeCrash("WallpaperMachineExtension-older.ips", at: exportedAt.addingTimeInterval(-7200), body: "extension", in: crashes)
        try writeCrash("OtherApp-new.ips", at: exportedAt.addingTimeInterval(-60), body: "other", in: crashes)
        try writeCrash("WallpaperMachine-old.ips", at: exportedAt.addingTimeInterval(-(age + 60)), body: "stale", in: crashes)
        try writeCrash("WallpaperMachine-future.ips", at: exportedAt.addingTimeInterval(3600), body: "future", in: crashes)
        try writeCrash("WallpaperMachine.txt", at: exportedAt.addingTimeInterval(-60), body: "not ips", in: crashes)

        var limits = DiagnosticsBundle.Limits()
        limits.crashReports = 1
        limits.crashReportAge = age
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let exported = try export(makeBundle(logs: logs, crashes: crashes, limits: limits))
        let includedCrashes = exported.report.included.filter { $0.hasPrefix("crash-reports/") }
        XCTAssertEqual(includedCrashes, ["crash-reports/WallpaperMachine-new.ips"])
        XCTAssertEqual(try text(exported, "crash-reports/WallpaperMachine-new.ips"), "path ~/Library")
        XCTAssertFalse(exported.report.missing.contains("no crash reports in the last 14 days"))
    }

    func testNoRecentCrashReportsAreNoted() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let crashes = root.appendingPathComponent("empty-crashes", isDirectory: true)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        try writeCrash("WallpaperMachine-old.ips", at: exportedAt.addingTimeInterval(-(15 * 24 * 60 * 60)), body: "stale", in: crashes)
        let exported = try export(makeBundle(logs: logs, crashes: crashes))
        XCTAssertTrue(exported.report.missing.contains("no crash reports in the last 14 days"))
        XCTAssertFalse(exported.report.included.contains { $0.hasPrefix("crash-reports/") })
    }

    func testMissingExtensionLogIsNotedAndZipContainsTheRest() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "hello /Users/alice\n"]])
        let destination = root.appendingPathComponent("out.zip")
        try Data("previous".utf8).write(to: destination)
        let bundle = makeBundle(logs: logs, extensionLog: root.appendingPathComponent("missing-extension.log"))
        let report = try bundle.export(
            to: destination,
            environment: ["HOME=/Users/alice", "USER=alice"],
            at: exportedAt)
        XCTAssertTrue(report.missing.contains("lock-screen/extension.log was not readable"))
        XCTAssertFalse(report.included.contains("lock-screen/extension.log"))
        XCTAssertFalse(
            report.missing.contains { $0.hasPrefix("load-journal.json") },
            "a caller with no journal source gets no note about one")
        XCTAssertEqual(report.included, report.included.sorted())
        XCTAssertTrue(report.included.contains("logs/20260927-120000/0.log"))
        XCTAssertTrue(report.included.contains("environment.txt"))
        XCTAssertTrue(report.included.contains("README.txt"))

        let extracted = try unzip(destination)
        XCTAssertEqual(try Data(contentsOf: extracted.appending(path: "logs/20260927-120000/0.log")), Data("hello ~\n".utf8))
        XCTAssertEqual(try Data(contentsOf: extracted.appending(path: "environment.txt")), Data("HOME=~\nUSER=<user>\n".utf8))
        let readme = try String(contentsOf: extracted.appendingPathComponent("README.txt"), encoding: .utf8)
        let generated = ISO8601DateFormatter().string(from: exportedAt)
        XCTAssertTrue(readme.contains(generated))
        XCTAssertTrue(readme.contains("logs/20260927-120000/0.log"))
        XCTAssertTrue(readme.contains("lock-screen/extension.log was not readable"))
        XCTAssertNotEqual(try Data(contentsOf: destination), Data("previous".utf8))
    }

    func testLoadJournalIsIncludedAndRedacted() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let journal = root.appendingPathComponent("load-journal.json")
        let body = """
            {"version":1,"build":"1.3.2 (45)","session":"9f3a6c0d2b81e475",\
            "strikes":{"3177024520":{"count":1,"last_at":1791800000,"display":7}},\
            "in_flight":[],"note":"/Users/alice/Library/Application Support/WallpaperMachine"}
            """
        try Data(body.utf8).write(to: journal)

        let exported = try export(makeBundle(logs: logs, loadJournal: journal))
        XCTAssertTrue(exported.report.included.contains("load-journal.json"))
        XCTAssertFalse(exported.report.missing.contains { $0.hasPrefix("load-journal.json") })

        let written = try text(exported, "load-journal.json")
        XCTAssertTrue(written.contains("~/Library/Application Support/WallpaperMachine"))
        XCTAssertFalse(written.contains("alice"))
        let parsed = try JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any]
        let strikes = parsed?["strikes"] as? [String: [String: Any]]
        XCTAssertEqual(strikes?["3177024520"]?["count"] as? Int, 1, "the strike history survives redaction")
        XCTAssertTrue(try text(exported, "README.txt").contains("load-journal.json"))
    }

    func testSteamCMDFailureOutputIsIncludedRedactedAndAbsentWithoutANote() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let failures = root.appendingPathComponent(SteamCMDFailureLog.fileName)
        let quiet = try export(makeBundle(logs: logs, steamCMDFailures: failures))
        XCTAssertFalse(quiet.report.included.contains("steamcmd-failures.txt"))
        XCTAssertFalse(quiet.report.missing.contains { $0.contains("steamcmd") }, "No failure yet is the normal case")

        SteamCMDFailureLog(url: failures).append("""
            == SteamCMD sign-in: failed while signingIn
            Logging in user 'steamalice' [U:1:5] to Steam Public...
            Redirecting stderr to /Users/alice/Library/Application Support/Steam/logs/stderr.txt
            """)
        let exported = try export(makeBundle(logs: logs, steamCMDFailures: failures))
        XCTAssertTrue(exported.report.included.contains("steamcmd-failures.txt"))
        let written = try text(exported, "steamcmd-failures.txt")
        XCTAssertTrue(written.contains("Logging in user '<account>'"), written)
        XCTAssertTrue(written.contains("~/Library/Application Support/Steam"), written)
        XCTAssertFalse(written.contains("alice"), written)
    }

    func testMissingLoadJournalIsNotedAndTheRestIsStillExported() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let journal = root.appendingPathComponent("never-written/load-journal.json")

        let exported = try export(makeBundle(logs: logs, loadJournal: journal))
        XCTAssertEqual(exported.report.missing.filter { $0.hasPrefix("load-journal.json") }, ["load-journal.json was not present"])
        XCTAssertFalse(exported.report.included.contains("load-journal.json"))
        XCTAssertTrue(exported.report.included.contains("logs/20260927-120000/0.log"))
        XCTAssertTrue(exported.report.included.contains("environment.txt"))
        XCTAssertTrue(try text(exported, "README.txt").contains("load-journal.json was not present"))
    }

    func testUnreadableLoadJournalIsNotedDifferentlyFromAnAbsentOne() throws {
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let journal = root.appendingPathComponent("load-journal.json", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)

        let exported = try export(makeBundle(logs: logs, loadJournal: journal))
        XCTAssertEqual(exported.report.missing.filter { $0.hasPrefix("load-journal.json") }, ["load-journal.json was not readable"])
        XCTAssertFalse(exported.report.included.contains("load-journal.json"))
        XCTAssertTrue(exported.report.included.contains("logs/20260927-120000/0.log"))
    }

    // MARK: Resource, spin and hang reports

    /// The header of a real disk-writes report from macOS 27, with the values
    /// that identify a machine replaced.
    private let diskWritesReport = """
        Date/Time:        2026-10-10 15:55:51.167 +0800
        OS Version:       macOS 27.0.1 (Build 26A434)
        Command:          WallpaperMachine
        Path:             /Users/alice/Applications/WallpaperMachine.app/Contents/MacOS/WallpaperMachine
        Identifier:       app.wallpapermachine
        Beta Identifier:  00000000-1111-2222-3333-444444444444
        PID:              92566

        Event:            disk writes
        Action taken:     none

        Heaviest stack for the target process:
          137  Data.write(to:options:) + 568 (Foundation + 5140100) [0x1a0855e84]
        """

    func testResourceReportsComeFromBothReportFoldersByPrefixAgeAndCount() throws {
        let age: TimeInterval = 14 * 24 * 60 * 60
        let user = try makeFolder("user-reports")
        let system = try makeFolder("system-reports")
        let retired = try makeFolder("system-reports/Retired")
        let host = "Alices-MacBook-Pro"

        try writeCrash("WallpaperMachine_2026-10-10-193707_\(host).diag", at: exportedAt.addingTimeInterval(-3600), body: diskWritesReport, in: system)
        try writeCrash("WallpaperMachineExtension_2026-10-10-190000_\(host).cpu_resource.diag", at: exportedAt.addingTimeInterval(-7200), body: "extension cpu", in: system)
        try writeCrash("Chrome_2026-10-10-190000_\(host).diag", at: exportedAt.addingTimeInterval(-60), body: "other process", in: system)
        try writeCrash("WallpaperMachine_2026-09-01-000000_\(host).diag", at: exportedAt.addingTimeInterval(-(age + 60)), body: "stale", in: system)
        try writeCrash("WallpaperMachine_2030-01-01-000000_\(host).diag", at: exportedAt.addingTimeInterval(3600), body: "future", in: system)
        try writeCrash("WallpaperMachine_2026-10-10-200000_\(host).ips", at: exportedAt.addingTimeInterval(-60), body: "a crash, not a resource report", in: system)
        try writeCrash("WallpaperMachine_2026-10-01-000000_\(host).diag", at: exportedAt.addingTimeInterval(-60), body: "retired", in: retired)
        try writeCrash("WallpaperMachine_2026-10-10-180000_\(host).spin", at: exportedAt.addingTimeInterval(-10800), body: "spin /Users/alice/Library", in: user)
        try writeCrash("WallpaperMachine_2026-10-10-170000_\(host).hang", at: exportedAt.addingTimeInterval(-14400), body: "hang", in: user)

        var limits = DiagnosticsBundle.Limits()
        limits.resourceReports = 3
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let exported = try export(makeBundle(logs: logs, crashes: user, systemReports: system, limits: limits))

        let reports = exported.report.included.filter { $0.hasPrefix("diagnostic-reports/") }
        XCTAssertEqual(Set(reports), [
            "diagnostic-reports/WallpaperMachine_2026-10-10-193707.diag",
            "diagnostic-reports/WallpaperMachineExtension_2026-10-10-190000.cpu_resource.diag",
            "diagnostic-reports/WallpaperMachine_2026-10-10-180000.spin",
        ], "the three newest across both folders, without the host name in their names")
        XCTAssertEqual(reports.count, 3)
        XCTAssertFalse(exported.report.included.contains { $0.hasPrefix("crash-reports/") })
        XCTAssertFalse(exported.report.missing.contains { $0.contains("resource") }, "found reports are not noted as missing")

        let disk = try text(exported, "diagnostic-reports/WallpaperMachine_2026-10-10-193707.diag")
        XCTAssertTrue(disk.contains("Event:            disk writes"), "the body is kept")
        XCTAssertTrue(disk.contains("Data.write(to:options:)"))
        XCTAssertTrue(disk.contains("Path:             ~/Applications/WallpaperMachine.app"), "home paths become ~")
        XCTAssertTrue(disk.contains("Beta Identifier:  <redacted>"))
        XCTAssertFalse(disk.contains("00000000-1111-2222-3333-444444444444"))
        XCTAssertEqual(try text(exported, "diagnostic-reports/WallpaperMachine_2026-10-10-180000.spin"), "spin ~/Library")

        let readme = try text(exported, "README.txt")
        XCTAssertTrue(readme.contains("diagnostic-reports/WallpaperMachine_2026-10-10-193707.diag"))
        XCTAssertFalse(readme.contains("Alices"), "the host name is not in the report")
    }

    func testReportsWithTheSameNameOnceTheHostIsDroppedDoNotOverwriteEachOther() throws {
        let user = try makeFolder("user-reports")
        let system = try makeFolder("system-reports")
        try writeCrash("WallpaperMachine_2026-10-10-193707_Mac-A.diag", at: exportedAt.addingTimeInterval(-60), body: "from the system folder", in: system)
        try writeCrash("WallpaperMachine_2026-10-10-193707_Mac-B.diag", at: exportedAt.addingTimeInterval(-120), body: "from the account folder", in: user)

        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let exported = try export(makeBundle(logs: logs, crashes: user, systemReports: system))

        let reports = exported.report.included.filter { $0.hasPrefix("diagnostic-reports/") }
        XCTAssertEqual(reports.count, 2)
        let bodies = try Set(reports.map { try text(exported, $0) })
        XCTAssertEqual(bodies, ["from the system folder", "from the account folder"])
    }

    func testOversizedResourceReportKeepsItsTail() throws {
        let system = try makeFolder("system-reports")
        try writeCrash("WallpaperMachine_2026-10-10-193707_host.diag", at: exportedAt.addingTimeInterval(-60), body: "AAAA\nBBBB\nCCCC\n", in: system)
        try writeCrash("WallpaperMachine_2026-10-10-183707_host.diag", at: exportedAt.addingTimeInterval(-120), body: "small\n", in: system)

        var limits = DiagnosticsBundle.Limits()
        limits.resourceReportBytes = 10
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let exported = try export(makeBundle(logs: logs, systemReports: system, limits: limits))

        XCTAssertEqual(
            try text(exported, "diagnostic-reports/WallpaperMachine_2026-10-10-193707.diag"),
            "[truncated: first 5 bytes omitted]\nBBBB\nCCCC\n")
        XCTAssertEqual(try text(exported, "diagnostic-reports/WallpaperMachine_2026-10-10-183707.diag"), "small\n", "a report under the limit is whole")
    }

    func testUnreadableSystemFolderIsNotedWithoutFailingTheExport() throws {
        let user = try makeFolder("user-reports")
        try writeCrash("WallpaperMachine_2026-10-10-180000_host.spin", at: exportedAt.addingTimeInterval(-60), body: "spin", in: user)
        // A path that cannot be listed, as the folder is for an account outside _analyticsusers.
        let system = root.appendingPathComponent("not-a-folder")
        try Data("file".utf8).write(to: system)

        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])
        let exported = try export(makeBundle(logs: logs, crashes: user, systemReports: system))

        let note = "macOS resource reports were not readable (the account may not be in the _analyticsusers group)"
        XCTAssertEqual(exported.report.missing.filter { $0.contains("resource") }, [note])
        XCTAssertTrue(exported.report.included.contains("diagnostic-reports/WallpaperMachine_2026-10-10-180000.spin"), "what could be read is still exported")
        XCTAssertTrue(exported.report.included.contains("logs/20260927-120000/0.log"))
        XCTAssertTrue(exported.report.included.contains("environment.txt"))
        XCTAssertTrue(try text(exported, "README.txt").contains(note))
    }

    func testNoResourceReportsInEitherFolderIsNoted() throws {
        let user = try makeFolder("user-reports")
        let system = try makeFolder("system-reports")
        try writeCrash("WallpaperMachine_2026-09-01-000000_host.diag", at: exportedAt.addingTimeInterval(-(15 * 24 * 60 * 60)), body: "stale", in: system)
        let logs = try makeLogs(["20260927-120000": ["0.log": "ok\n"]])

        let readable = try export(makeBundle(logs: logs, crashes: user, systemReports: system))
        XCTAssertEqual(readable.report.missing.filter { $0.contains("resource") }, ["no resource, spin or hang reports in the last 14 days"])
        XCTAssertFalse(readable.report.included.contains { $0.hasPrefix("diagnostic-reports/") })

        let notOffered = try export(makeBundle(logs: logs, crashes: user))
        XCTAssertEqual(notOffered.report.missing.filter { $0.contains("resource") }, ["no resource, spin or hang reports in the last 14 days"])
    }

    /// Window state travels in `environment.txt` like every other environment
    /// line: the redactor must neither mangle it nor miss a user path beside it.
    func testWindowStateLinesSurviveRedactionIntoEnvironment() throws {
        let window = DesktopWindowObservation(
            windowNumber: 1234, className: "MWEWallpaperDesktopWindow", displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 3456, height: 2234),
            displayFrame: CGRect(x: 0, y: 0, width: 3456, height: 2234), level: -2_147_483_623, alpha: 1,
            isOrderedIn: true, isOnActiveSpace: false, occlusionVisible: false, collectionBehaviorRaw: 0x51,
            server: .init(layer: -2_147_483_623, alpha: 1, isOnScreen: false,
                          bounds: CGRect(x: 0, y: 0, width: 3456, height: 2234)))
        let windowLines = DesktopWindowDiagnostics.lines([window], separateSpaces: true)
        let destination = root.appendingPathComponent("windows.zip")
        _ = try makeBundle(logs: try makeLogs(["20260927-120000": ["0.log": "ok\n"]])).export(
            to: destination, environment: ["app /Users/alice/Applications/WallpaperMachine.app"] + windowLines,
            at: exportedAt)
        let environment = try String(
            contentsOf: try unzip(destination).appending(path: "environment.txt"), encoding: .utf8)
        XCTAssertEqual(
            environment, (["app ~/Applications/WallpaperMachine.app"] + windowLines).joined(separator: "\n") + "\n")
        XCTAssertTrue(environment.contains("; state notOnActiveSpace\n"))
    }

    func testSuggestedFileNameUsesLocalPOSIXTime() {
        let name = DiagnosticsBundle.suggestedFileName(at: exportedAt)
        XCTAssertTrue(name.hasPrefix("WallpaperMachine-diagnostics-"))
        XCTAssertTrue(name.hasSuffix(".zip"))
        let stamp = name.dropFirst("WallpaperMachine-diagnostics-".count).dropLast(".zip".count)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        XCTAssertEqual(String(stamp), formatter.string(from: exportedAt))
    }

    /// Reading the extension's own container would make macOS ask for access to
    /// another app's data; its log lives in the shared exchange directory instead.
    func testSourcesUseTheLockScreenExchangeAndDiagnosticReports() {
        let home = root.appendingPathComponent("home")
        let logs = root.appendingPathComponent("logs")
        let support = root.appendingPathComponent("support")
        let sources = DiagnosticsBundle.sources(logsRoot: logs, home: home, supportRoot: support)
        XCTAssertEqual(sources.logsRoot.standardizedFileURL, logs.standardizedFileURL)
        XCTAssertEqual(
            sources.extensionLog.standardizedFileURL,
            home.appending(path: "Library/Application Support/WallpaperMachine/LockScreenExchange/extension.log").standardizedFileURL)
        XCTAssertEqual(
            sources.crashReports.standardizedFileURL,
            home.appending(path: "Library/Logs/DiagnosticReports").standardizedFileURL)
        XCTAssertEqual(sources.loadJournal?.standardizedFileURL, support.appending(path: "load-journal.json").standardizedFileURL)
        XCTAssertEqual(
            sources.systemReports?.standardizedFileURL.path,
            "/Library/Logs/DiagnosticReports",
            "resource reports live outside the home folder on macOS 27")
    }

    private struct Exported {
        var report: DiagnosticsBundle.Report
        var root: URL
    }

    private func limits(sessions: Int) -> DiagnosticsBundle.Limits {
        var limits = DiagnosticsBundle.Limits()
        limits.sessions = sessions
        return limits
    }

    private func makeBundle(
        logs: URL,
        extensionLog: URL? = nil,
        crashes: URL? = nil,
        loadJournal: URL? = nil,
        systemReports: URL? = nil,
        steamCMDFailures: URL? = nil,
        limits: DiagnosticsBundle.Limits = DiagnosticsBundle.Limits()
    ) -> DiagnosticsBundle {
        DiagnosticsBundle(
            sources: DiagnosticsBundle.Sources(
                logsRoot: logs,
                extensionLog: extensionLog ?? root.appendingPathComponent("absent-extension.log"),
                crashReports: crashes ?? root.appendingPathComponent("absent-crashes"),
                loadJournal: loadJournal,
                systemReports: systemReports,
                steamCMDFailures: steamCMDFailures),
            limits: limits,
            redactor: DiagnosticsRedactor(homeDirectory: "/Users/alice", userNames: ["alice"], secrets: ["steamalice"]))
    }

    private func makeLogs(_ sessions: [String: [String: String]]) throws -> URL {
        let logs = root.appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        for (session, files) in sessions {
            let directory = logs.appendingPathComponent(session, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, body) in files {
                try Data(body.utf8).write(to: directory.appendingPathComponent(name))
            }
        }
        return logs
    }

    private func makeFolder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeCrash(_ name: String, at date: Date, body: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func export(_ bundle: DiagnosticsBundle) throws -> Exported {
        let destination = root.appendingPathComponent("export-\(UUID().uuidString).zip")
        let report = try bundle.export(to: destination, environment: ["USER=alice"], at: exportedAt)
        return Exported(report: report, root: try unzip(destination))
    }

    private func text(_ exported: Exported, _ path: String) throws -> String {
        try String(contentsOf: exported.root.appending(path: path), encoding: .utf8)
    }

    private func logSessions(in report: DiagnosticsBundle.Report) -> [String] {
        report.included.compactMap { path in
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "logs" else { return nil }
            return String(parts[1])
        }
    }

    private func unzip(_ zip: URL) throws -> URL {
        let destination = root.appendingPathComponent("unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let stem = DiagnosticsBundle.suggestedFileName(at: exportedAt).replacingOccurrences(of: ".zip", with: "")
        return destination.appendingPathComponent(stem, isDirectory: true)
    }
}
