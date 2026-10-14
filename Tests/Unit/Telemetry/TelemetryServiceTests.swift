import XCTest

@testable import WallpaperMachine

/// Performance data is collected and sent only while the user has it on, carries nothing
/// that names a person, a file or a local wallpaper, and turning it off deletes it.
@MainActor
final class TelemetryServiceTests: XCTestCase {
    private actor Uploads: TelemetryUploading {
        var reports: [Data] = []
        var deletions: [String] = []
        var fails = false

        func failing(_ value: Bool) { fails = value }

        func send(_ report: Data) async throws {
            if fails { throw TelemetryUploadError(status: 503) }
            reports.append(report)
        }

        func delete(install: String) async throws {
            if fails { throw TelemetryUploadError(status: nil) }
            deletions.append(install)
        }
    }

    private var defaults: UserDefaults!
    private var folder: URL!
    private var now = Date(timeIntervalSince1970: 1_791_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString)")
        addTeardownBlock { [folder] in try? FileManager.default.removeItem(at: folder!) }
    }

    private func inputs(
        energy: [String: WallpaperEnergyRating] = [:], outcome: SessionLedger.Outcome? = nil,
        crash: Bool? = nil, journal: URL? = nil
    ) -> TelemetryService.Inputs {
        var inputs = TelemetryService.Inputs()
        inputs.app = { .init(version: "1.4.1", build: "412", source: false) }
        inputs.mac = {
            .init(model: "Mac15,3", chip: "Apple M3 Pro", cores: 12, memoryGB: 18, os: "26.1.0",
                  gpu: "Apple M3 Pro", displays: [.init(width: 3024, height: 1964, scale: 2, hz: 120, main: true)])
        }
        inputs.kind = { $0 == "2873461829" ? .projectScene : .webpage }
        inputs.energy = { energy }
        inputs.footprint = { 512 * 1_048_576 }
        inputs.previousOutcome = { outcome }
        inputs.crashReportFound = { crash }
        inputs.loadJournal = journal
        return inputs
    }

    private func service(_ uploads: Uploads, inputs: TelemetryService.Inputs? = nil) -> TelemetryService {
        TelemetryService(
            preferences: TelemetryPreferences(defaults: defaults), spool: TelemetrySpool(folder: folder),
            uploader: uploads, sampler: nil, inputs: inputs ?? self.inputs(),
            // The task's waits end it at once; each test runs the steps itself.
            now: { [unowned self] in self.now }, sleep: { _ in throw CancellationError() })
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testOffByDefaultRecordsAndSendsNothing() async throws {
        let uploads = Uploads()
        let telemetry = service(uploads)
        telemetry.start()
        XCTAssertFalse(telemetry.isEnabled)

        telemetry.recordActivation(.activation, wallpaper: "2873461829", origin: .user, outcome: .applied, milliseconds: 40)
        telemetry.recordPressure(.pressure(.critical, footprint: 1, scenes: 1))
        now += 3 * 86_400
        await telemetry.uploadIfDue()

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing is written while it is off")
        let reports = await uploads.reports
        XCTAssertEqual(reports, [])
    }

    func testSendsOnceADayAndOnlyWhatIsNew() async throws {
        let uploads = Uploads()
        let telemetry = service(uploads)
        telemetry.setEnabled(true)
        telemetry.recordActivation(.activation, wallpaper: "2873461829", origin: .user, outcome: .applied, milliseconds: 812)

        await telemetry.uploadIfDue()
        var reports = await uploads.reports
        XCTAssertEqual(reports.count, 0, "not before a day has passed")

        now += 86_400
        await telemetry.uploadIfDue()
        reports = await uploads.reports
        XCTAssertEqual(reports.count, 1)
        let activations = try XCTUnwrap(try decode(reports[0])["activations"] as? [[String: Any]])
        XCTAssertEqual(activations.first?["wallpaper"] as? String, "2873461829")
        XCTAssertEqual(activations.first?["ms"] as? Int, 812)
        XCTAssertEqual(telemetry.lastSentAt, now)

        now += 3_600
        telemetry.recordActivation(.activation, wallpaper: "2873461829", origin: .playlist, outcome: .noOp, milliseconds: 3)
        await telemetry.uploadIfDue()
        reports = await uploads.reports
        XCTAssertEqual(reports.count, 1, "the next upload waits another day")

        now += 86_400
        await telemetry.uploadIfDue()
        reports = await uploads.reports
        XCTAssertEqual(reports.count, 2)
        let second = try XCTUnwrap(try decode(reports[1])["activations"] as? [[String: Any]])
        XCTAssertEqual(second.map { $0["origin"] as? String }, ["playlist"], "what was sent is not sent again")
    }

    func testFailedUploadKeepsTheRowsForTheNextTry() async throws {
        let uploads = Uploads()
        let telemetry = service(uploads)
        telemetry.setEnabled(true)
        telemetry.recordActivation(.activation, wallpaper: "1", origin: .user, outcome: .failed(.error), milliseconds: 9)
        now += 86_400
        await uploads.failing(true)
        await telemetry.uploadIfDue()
        XCTAssertNil(telemetry.lastSentAt)
        XCTAssertEqual(telemetry.spool.batch.activations.count, 1)

        await uploads.failing(false)
        await telemetry.uploadIfDue()
        let reports = await uploads.reports
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(telemetry.spool.batch.activations.count, 0)
    }

    func testTurningItOffDeletesLocallyAndAsksTheWebsiteToDelete() async throws {
        let uploads = Uploads()
        let telemetry = service(uploads)
        telemetry.setEnabled(true)
        let id = try XCTUnwrap(telemetry.preferences.installID)
        telemetry.recordActivation(.activation, wallpaper: "1", origin: .user, outcome: .applied, milliseconds: 9)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        telemetry.setEnabled(false)
        await telemetry.waitForDeletions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(telemetry.preferences.installID)
        let deletions = await uploads.deletions
        XCTAssertEqual(deletions, [id])
        XCTAssertEqual(telemetry.preferences.state.pendingDeletions, [])

        telemetry.setEnabled(true)
        XCTAssertNotEqual(telemetry.preferences.installID, id, "a new period gets a new id")
    }

    func testUnconfirmedDeletionIsAskedForAgainAtNextLaunch() async throws {
        let uploads = Uploads()
        await uploads.failing(true)
        let first = service(uploads)
        first.setEnabled(true)
        let id = try XCTUnwrap(first.preferences.installID)
        first.setEnabled(false)
        await first.waitForDeletions()
        XCTAssertEqual(first.preferences.state.pendingDeletions, [id])

        await uploads.failing(false)
        let relaunched = service(uploads)
        relaunched.start()
        await relaunched.waitForDeletions()
        let deletions = await uploads.deletions
        XCTAssertEqual(deletions, [id])
        XCTAssertEqual(relaunched.preferences.state.pendingDeletions, [])
    }

    func testReportNamesNoPersonPathOrLocalWallpaper() async throws {
        let uploads = Uploads()
        let journal = folder.appendingPathComponent("load-journal.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            {"version":1,"build":"x","session":"s","strikes":{
              "2873461829":{"count":2,"last_at":\(Int(now.timeIntervalSince1970) + 10),"display":1},
              "alice-holiday":{"count":2,"last_at":\(Int(now.timeIntervalSince1970) + 10),"display":1}},
             "in_flight":[]}
            """.utf8).write(to: journal)
        let rating = { (seconds: Double) in
            WallpaperEnergyRating(milliwatts: 812.44, seconds: seconds,
                                  conditions: .init(displays: 1, frameRateCap: nil, renderScale: 1), updated: self.now + 5)
        }
        let telemetry = service(uploads, inputs: inputs(
            energy: ["2873461829": rating(600), "/Users/alice/Wallpapers/Private": rating(600), "pixiv-123-p0": rating(600),
                     "too-new": rating(30)],
            journal: journal))
        telemetry.setEnabled(true)
        for wallpaper in ["2873461829", "/Users/alice/Wallpapers/Private", "pixiv-123-p0", "image-alice-cat"] {
            telemetry.recordActivation(.activation, wallpaper: wallpaper, origin: .user, outcome: .applied, milliseconds: 1)
        }
        now += 86_400
        await telemetry.uploadIfDue()

        let reports = await uploads.reports
        let data = try XCTUnwrap(reports.first)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for secret in ["alice", "Users", "pixiv", "image-", "Private", "holiday", NSUserName(), NSHomeDirectory()] {
            XCTAssertFalse(text.contains(secret), "\(secret) reached the report")
        }
        let report = try decode(data)
        let activations = try XCTUnwrap(report["activations"] as? [[String: Any]])
        XCTAssertEqual(activations.compactMap { $0["wallpaper"] as? String }, ["2873461829"])
        XCTAssertEqual(activations.map { $0["source"] as? String }, ["workshop", "local", "local", "local"])
        let energy = try XCTUnwrap(report["energy"] as? [[String: Any]])
        XCTAssertEqual(energy.count, 3, "a rating under two minutes is not a rating yet")
        let strikes = try XCTUnwrap(report["loadStrikes"] as? [[String: Any]])
        XCTAssertEqual(strikes.map { $0["wallpaper"] as? String }, ["2873461829"])
        XCTAssertEqual(Set(report.keys), ["schema", "install", "app", "mac", "sessions", "activations", "frames", "energy", "loadStrikes"])
    }

    func testPreviousRunIsReportedWithHowItEnded() async throws {
        let uploads = Uploads()
        let earlier = service(uploads)
        earlier.setEnabled(true)
        now += 7_200
        earlier.recordPressure(.pressure(.warning, footprint: 900 * 1_048_576, scenes: 1))
        now += 1_800
        earlier.stop()

        now += 600
        let relaunched = service(uploads, inputs: inputs(outcome: .endedUnexpectedly, crash: true))
        relaunched.start()
        relaunched.recordPreviousRun()
        let session = try XCTUnwrap(relaunched.spool.batch.sessions.first)
        XCTAssertEqual(session.ended, .unexpected)
        XCTAssertEqual(session.crashReport, true)
        XCTAssertEqual(session.minutes, 150)
        XCTAssertEqual(session.pressureWarnings, 1)
        XCTAssertEqual(session.peakFootprintMB, 900)
    }
}
