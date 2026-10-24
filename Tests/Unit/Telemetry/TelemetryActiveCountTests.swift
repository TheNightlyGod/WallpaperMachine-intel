import XCTest

@testable import WallpaperMachine

/// Every copy is counted at most once a UTC day, with no install id, and the first count
/// of a month says so; a failed ping is retried without being counted twice.
@MainActor
final class TelemetryActiveCountTests: XCTestCase {
    private actor Pings: TelemetryActiveSending {
        var sent: [Data] = []
        var fails = false

        func failing(_ value: Bool) { fails = value }

        func sendActive(_ ping: Data) async throws {
            if fails { throw TelemetryUploadError(status: nil) }
            sent.append(ping)
        }
    }

    private var defaults: UserDefaults!
    private var now = ISO8601DateFormatter().date(from: "2026-10-24T08:00:00Z")!
    private var made = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    private static func day(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func count(
        _ pings: Pings, sleep: @escaping (Duration) async throws -> Void = { _ in throw CancellationError() }
    ) -> TelemetryActiveCount {
        TelemetryActiveCount(
            sender: pings, defaults: defaults,
            app: { .init(version: "1.6.0", build: "160", source: false) },
            now: { [unowned self] in self.now }, sleep: sleep, spread: { 300 },
            newPing: { [unowned self] in
                self.made += 1
                return String(format: "00000000-0000-4000-8000-%012d", self.made)
            })
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCountsOnceADayAndCarriesNoInstallID() async throws {
        let pings = Pings()
        let active = count(pings)

        let counted = await active.countIfDue()
        XCTAssertTrue(counted)
        now += 6 * 3_600
        _ = await active.countIfDue()
        var sent = await pings.sent
        XCTAssertEqual(sent.count, 1, "a second ping the same UTC day is not sent")

        let first = try decode(sent[0])
        XCTAssertEqual(Set(first.keys), ["schema", "ping", "day", "version", "source", "monthFirst"])
        XCTAssertEqual(first["day"] as? String, "2026-10-24")
        XCTAssertEqual(first["version"] as? String, "1.6.0")
        XCTAssertEqual(first["source"] as? Bool, false)
        XCTAssertEqual(first["monthFirst"] as? Bool, true)

        now += 12 * 3_600
        _ = await active.countIfDue()
        sent = await pings.sent
        XCTAssertEqual(sent.count, 2)
        let second = try decode(sent[1])
        XCTAssertEqual(second["day"] as? String, "2026-10-25")
        XCTAssertEqual(second["monthFirst"] as? Bool, false)
        XCTAssertNotEqual(second["ping"] as? String, first["ping"] as? String, "each day's ping is new")
    }

    func testFailedPingIsRetriedWithTheSameRandomID() async throws {
        let pings = Pings()
        let active = count(pings)
        await pings.failing(true)
        let failed = await active.countIfDue()
        XCTAssertFalse(failed)

        await pings.failing(false)
        now += 3_600
        let counted = await active.countIfDue()
        XCTAssertTrue(counted)
        let sent = await pings.sent
        XCTAssertEqual(sent.count, 1)
        let ping = try decode(sent[0])
        XCTAssertEqual(ping["ping"] as? String, "00000000-0000-4000-8000-000000000001",
                       "the retry reuses the ping, so the website counts it once")
        XCTAssertEqual(ping["monthFirst"] as? Bool, true, "a month is not marked counted until the website has a ping")
    }

    func testFirstPingOfANewMonthIsMarked() async throws {
        let pings = Pings()
        let active = count(pings)
        now = Self.day("2026-10-31T23:30:00Z")
        _ = await active.countIfDue()
        now = Self.day("2026-11-01T00:05:00Z")
        _ = await active.countIfDue()
        now = Self.day("2026-11-02T10:00:00Z")
        _ = await active.countIfDue()

        let sent = await pings.sent
        let marks = try sent.map { try decode($0)["monthFirst"] as? Bool }
        XCTAssertEqual(marks, [true, true, false])
    }

    func testARelaunchTheSameDaySendsNothing() async {
        let pings = Pings()
        _ = await count(pings).countIfDue()
        now += 3_600
        _ = await count(pings).countIfDue()
        let sent = await pings.sent
        XCTAssertEqual(sent.count, 1)
    }

    func testSchedulesTheNextPingShortlyAfterUTCMidnight() {
        XCTAssertEqual(TelemetryActiveCount.untilNextDay(from: Self.day("2026-10-24T23:59:00Z"), spread: 0), .seconds(60))
        XCTAssertEqual(TelemetryActiveCount.untilNextDay(from: Self.day("2026-10-24T23:59:00Z"), spread: 600), .seconds(660))
        XCTAssertEqual(TelemetryActiveCount.untilNextDay(from: Self.day("2026-10-25T00:00:00Z"), spread: 0), .seconds(86_400))
    }

    func testRetriesHourlyUntilCountedThenWaitsForTheNextDay() async throws {
        let pings = Pings()
        await pings.failing(true)
        let waits = Waits()
        let done = expectation(description: "the task asked for its fourth wait")
        let active = count(pings) { [waits] duration in
            if await waits.append(duration) == 4 {
                done.fulfill()
                throw CancellationError()
            }
            if await waits.count == 2 { await pings.failing(false) }
        }
        active.start()
        await fulfillment(of: [done], timeout: 5)
        active.stop()

        let recorded = await waits.all
        XCTAssertEqual(recorded[0], TelemetryActiveCount.firstCount)
        XCTAssertEqual(recorded[1], TelemetryActiveCount.retryInterval, "a failed ping is tried again in an hour")
        // 08:00 UTC: sixteen hours to midnight, then the five minutes of spread.
        XCTAssertEqual(recorded[2], .seconds(16 * 3_600 + 300))
        let sent = await pings.sent
        XCTAssertEqual(sent.count, 1)
    }

    func testTestAndDevelopmentRunsAreNotCounted() {
        XCTAssertTrue(TelemetryActiveCount.countsRun(environment: [:]))
        XCTAssertTrue(TelemetryActiveCount.countsRun(environment: ["WALLPAPER_MACHINE_HOME": ""]))
        XCTAssertFalse(TelemetryActiveCount.countsRun(environment: ["WALLPAPER_MACHINE_HOME": "/tmp/home"]))
        XCTAssertFalse(TelemetryActiveCount.countsRun(environment: [ClientPreferences.suiteEnvironmentKey: "suite"]))
    }

    private actor Waits {
        var all: [Duration] = []
        var count: Int { all.count }

        func append(_ duration: Duration) -> Int {
            all.append(duration)
            return all.count
        }
    }
}
