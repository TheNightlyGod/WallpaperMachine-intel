import XCTest

@testable import WallpaperMachine

/// A frame window reports only what a surface did between its two readings, and never a
/// surface whose zero frames would mean "covered" or "paused" rather than "slow".
@MainActor
final class TelemetrySamplerTests: XCTestCase {
    private final class Counters: TelemetryCounterSource {
        var readings: [BridgeRendererCountersReport] = []
        var enabledCalls: [Bool] = []
        var failRead = false
        /// Runs between the two readings, as the window's wait would.
        var duringWindow: (() -> Void)?

        func setRendererCountersEnabled(_ enabled: Bool) async throws { enabledCalls.append(enabled) }

        func rendererCounters() async throws -> BridgeRendererCountersReport {
            if failRead { throw URLError(.cannotConnectToHost) }
            return readings.removeFirst()
        }
    }

    private static func surface(
        display: String = "7", generation: UInt64 = 1, draws: UInt64, dropped: UInt64 = 0,
        presents: UInt64 = 0, paused: Bool = false, reasons: [String] = [], tick: UInt64 = 16_667
    ) -> BridgeRendererSurfaceCounters {
        BridgeRendererSurfaceCounters(
            displayId: display, surfaceId: "surface-\(display)", generation: generation,
            sourceId: "unknown", sourcePath: "/Users/alice/Library/scene.pkg", sourceCount: 0,
            backend: "scene", effectivePauseReasons: reasons, paused: paused,
            timerWakeups: 0, drawRequests: 0, drawTicksSuppressed: 0, drawsExecuted: draws,
            drawsDropped: dropped, renderSubmissions: 0, renderFailures: 0, presentRequests: presents,
            gpuCompletions: 0, simulationTicks: 0, presentsSkippedUnchanged: 0,
            tickIntervalMicros: tick, contentPeriodMicros: 0, videoDecodeOutputs: 0, videoSeeks: 0,
            videoFramesSelected: 0, videoFramesReused: 0, videoFramesSkipped: 0,
            videoSelectedGeneration: 0, videoConversions: 0, videoImports: 0,
            videoConversionLiveBytes: 0, videoConversionPeakLiveBytes: 0)
    }

    private static func reading(_ surfaces: BridgeRendererSurfaceCounters...) -> BridgeRendererCountersReport {
        BridgeRendererCountersReport(
            recording: true, surfaces: surfaces, audioAnalysisDeliveries: 0, audioAcceptedFrames: 0,
            audioActiveConsumers: 0, presentationFeedbackAvailable: false)
    }

    private static func context(wallpaper: String = "2873461829") -> TelemetryFrameContext {
        TelemetryFrameContext(
            scenes: [7: .init(wallpaperID: wallpaper, kind: .scene, backend: "native_metal",
                              mode: "continuous")],
            displays: [7: .init(width: 3024, height: 1964, scale: 2, hz: 120, main: true)],
            frameRateCap: nil, renderScale: 1, reducedQuality: false, battery: false,
            lowPower: false, thermal: "nominal")
    }

    private func sampler(
        _ counters: Counters, contexts: [TelemetryFrameContext?]
    ) -> TelemetrySampler {
        var contexts = contexts
        var clock = ContinuousClock.now
        return TelemetrySampler(
            source: counters,
            context: { contexts.isEmpty ? nil : contexts.removeFirst() },
            now: { clock },
            sleep: { duration in
                clock = clock.advanced(by: duration)
                counters.duringWindow?()
            })
    }

    func testRowIsTheDifferenceBetweenTheTwoReadings() async throws {
        let counters = Counters()
        // Counting is cumulative: an earlier window left 500 draws behind.
        counters.readings = [Self.reading(Self.surface(draws: 500, dropped: 4, presents: 500)),
                             Self.reading(Self.surface(draws: 4_100, dropped: 10, presents: 4_100))]
        let rows = await sampler(counters, contexts: [Self.context(), Self.context()]).sample(day: "2026-10-14")

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.draws, 3_600)
        XCTAssertEqual(row.dropped, 6)
        XCTAssertEqual(row.presents, 3_600)
        XCTAssertEqual(row.seconds, 60)
        XCTAssertEqual(row.tickHz, 60)
        XCTAssertEqual(row.wallpaper, "2873461829")
        XCTAssertEqual(row.backend, "native_metal")
        XCTAssertEqual(row.displayHz, 120)
        XCTAssertEqual(counters.enabledCalls, [true, false])
    }

    func testPausedOrCoveredSurfaceIsNotReportedAsSlow() async {
        for (start, end) in [
            (Self.surface(draws: 0), Self.surface(draws: 0, paused: true)),
            (Self.surface(draws: 0, reasons: ["occluded"]), Self.surface(draws: 10)),
        ] {
            let counters = Counters()
            counters.readings = [Self.reading(start), Self.reading(end)]
            let rows = await sampler(counters, contexts: [Self.context(), Self.context()]).sample(day: "2026-10-14")
            XCTAssertEqual(rows, [])
            XCTAssertEqual(counters.enabledCalls, [true, false])
        }
    }

    func testPresentationChangeDuringTheWindowVoidsIt() async {
        let counters = Counters()
        counters.readings = [Self.reading(Self.surface(draws: 0)), Self.reading(Self.surface(draws: 3_600))]
        let sampler = sampler(counters, contexts: [Self.context(), Self.context()])
        counters.duringWindow = { sampler.invalidate() }
        let rows = await sampler.sample(day: "2026-10-14")
        XCTAssertEqual(rows, [])
        XCTAssertEqual(counters.enabledCalls, [true, false])
    }

    func testSwitchedWallpaperOrNewSurfaceIsLeftOut() async {
        let counters = Counters()
        counters.readings = [Self.reading(Self.surface(draws: 0)),
                             Self.reading(Self.surface(generation: 2, draws: 3_600))]
        var rows = await sampler(counters, contexts: [Self.context(), Self.context()]).sample(day: "2026-10-14")
        XCTAssertEqual(rows, [], "a surface that appeared during the window has no start reading")

        counters.readings = [Self.reading(Self.surface(draws: 0)), Self.reading(Self.surface(draws: 3_600))]
        rows = await sampler(counters, contexts: [Self.context(), Self.context(wallpaper: "999")]).sample(day: "2026-10-14")
        XCTAssertEqual(rows, [], "the display changed wallpaper during the window")
    }

    func testLocalWallpaperIsSentWithoutItsName() async throws {
        let counters = Counters()
        counters.readings = [Self.reading(Self.surface(draws: 0)), Self.reading(Self.surface(draws: 1_800))]
        let local = Self.context(wallpaper: "My Holiday Photos")
        let rows = await sampler(counters, contexts: [local, local]).sample(day: "2026-10-14")
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.wallpaper)
        XCTAssertEqual(row.source, .local)
    }

    func testFailedReadStillTurnsCountingOff() async {
        let counters = Counters()
        counters.failRead = true
        let rows = await sampler(counters, contexts: [Self.context()]).sample(day: "2026-10-14")
        XCTAssertEqual(rows, [])
        XCTAssertEqual(counters.enabledCalls, [true, false])
    }

    func testNothingOnScreenOpensNoWindow() async {
        let counters = Counters()
        let rows = await sampler(counters, contexts: [nil]).sample(day: "2026-10-14")
        XCTAssertEqual(rows, [])
        XCTAssertEqual(counters.enabledCalls, [])
    }
}
