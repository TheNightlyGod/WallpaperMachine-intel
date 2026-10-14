import XCTest

@testable import WallpaperMachine

final class CrashReportIndexTests: XCTestCase {
    private var folder: URL!
    private let launchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let boot = "AAAAAAAA-0000-4000-8000-000000000001"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "crash-report-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    /// Writes a report in the shape macOS uses: a one-line header, then the report as one document.
    private func writeReport(
        _ name: String, pid: Int, bootSession: String? = nil, type: String? = "EXC_BAD_ACCESS", signal: String? = "SIGSEGV",
        modified: TimeInterval = 60, body: String? = nil
    ) throws {
        var report: [String: Any] = ["pid": pid, "procName": "WallpaperMachine", "captureTime": "2026-10-12 08:36:18.0000 +0800"]
        if let bootSession { report["bootSessionUUID"] = bootSession }
        if type != nil || signal != nil {
            var exception: [String: Any] = [:]
            exception["type"] = type
            exception["signal"] = signal
            report["exception"] = exception
        }
        let header = #"{"app_name":"WallpaperMachine","bug_type":"309"}"#
        let json = try String(decoding: JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]), as: UTF8.self)
        let file = folder.appendingPathComponent(name)
        try Data((header + "\n" + (body ?? json)).utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: launchedAt.addingTimeInterval(modified)], ofItemAtPath: file.path)
    }

    private func find(pid: Int32 = 500, bootSession: String? = nil) -> CrashReportIndex.Report? {
        CrashReportIndex.report(forPid: pid, bootSession: bootSession, notBefore: launchedAt, in: folder)
    }

    func testPicksTheReportOfTheRunAndToleratesTheRest() throws {
        try writeReport("WallpaperMachine-2026-10-12-083618.ips", pid: 500, modified: 100)
        try writeReport("WallpaperMachine-2026-10-12-090000.ips", pid: 501, modified: 200)
        try writeReport("WallpaperMachine-2026-10-12-091000.ips", pid: 500, modified: 300, body: "{ this is not json")
        try writeReport("OtherApp-2026-10-12-092000.ips", pid: 500, signal: "SIGBUS", modified: 400)
        try writeReport("WallpaperMachine-2026-10-12-093000.crash", pid: 500, signal: "SIGBUS", modified: 500)

        XCTAssertEqual(find(), CrashReportIndex.Report(
            file: "WallpaperMachine-2026-10-12-083618.ips", type: "EXC_BAD_ACCESS", signal: "SIGSEGV"))
    }

    func testAHeaderWithoutABodyIsPassedOver() throws {
        let file = folder.appendingPathComponent("WallpaperMachine-header-only.ips")
        try Data(#"{"app_name":"WallpaperMachine"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: launchedAt.addingTimeInterval(60)], ofItemAtPath: file.path)
        try writeReport("WallpaperMachine-real.ips", pid: 500, modified: 10)

        XCTAssertEqual(find()?.file, "WallpaperMachine-real.ips")
    }

    func testAReportFromAnotherBootIsNotTheRuns() throws {
        try writeReport("WallpaperMachine-earlier-boot.ips", pid: 500, bootSession: "BBBBBBBB-0000-4000-8000-000000000002")

        XCTAssertNil(find(bootSession: boot))
        // Without a boot to compare, or when the report names none, the process id decides.
        XCTAssertEqual(find(bootSession: nil)?.file, "WallpaperMachine-earlier-boot.ips")
        try writeReport("WallpaperMachine-no-boot.ips", pid: 600)
        XCTAssertEqual(find(pid: 600, bootSession: boot)?.file, "WallpaperMachine-no-boot.ips")
    }

    func testTheBootSessionMatchesWithoutCase() throws {
        try writeReport("WallpaperMachine-lower.ips", pid: 500, bootSession: boot.lowercased())

        XCTAssertEqual(find(bootSession: boot)?.file, "WallpaperMachine-lower.ips")
    }

    func testAReportWrittenBeforeTheRunStartedIsNotTheRuns() throws {
        try writeReport("WallpaperMachine-before.ips", pid: 500, modified: -60)

        XCTAssertNil(find())
    }

    func testAReportWithoutAnExceptionStillNamesTheFile() throws {
        try writeReport("WallpaperMachine-bare.ips", pid: 500, type: nil, signal: nil)

        XCTAssertEqual(find(), CrashReportIndex.Report(file: "WallpaperMachine-bare.ips", type: nil, signal: nil))
    }

    func testNothingFoundIsNilNotAnError() {
        XCTAssertNil(find())
        XCTAssertNil(CrashReportIndex.report(
            forPid: 500, bootSession: nil, notBefore: launchedAt,
            in: folder.appendingPathComponent("does-not-exist")))
    }
}
