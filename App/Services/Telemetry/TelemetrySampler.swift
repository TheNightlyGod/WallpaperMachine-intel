import Foundation

/// The renderer's own counters, as far as a sampling window needs them.
@MainActor
protocol TelemetryCounterSource: AnyObject {
    func setRendererCountersEnabled(_ enabled: Bool) async throws
    func rendererCounters() async throws -> BridgeRendererCountersReport
}

/// What was on screen when a window opened or closed, keyed by display id.
struct TelemetryFrameContext: Equatable {
    struct Scene: Equatable {
        var wallpaperID: String
        var kind: TelemetryReport.Kind
        var backend: String
        var mode: String?
    }

    var scenes: [UInt32: Scene]
    var displays: [UInt32: TelemetryReport.Display]
    var frameRateCap: UInt32?
    var renderScale: Float
    var reducedQuality: Bool
    var battery: Bool
    var lowPower: Bool
    var thermal: String
}

/// Measures frame delivery for one bounded window when performance data is on.
///
/// The renderer counts nothing unless its counters are on; each increment then costs one
/// relaxed atomic add. A window turns them on, reads them, waits `window`, reads them
/// again and turns them off, whatever happens in between. Counting is cumulative and is
/// not reset by turning it on, so a row is the difference between the two readings of
/// the same surface. A surface that was paused at either end, that appeared or went away
/// during the window, or whose display changed wallpaper is not reported, and nor is any
/// window during which presentation changed (`invalidate()`), so a covered or paused
/// wallpaper is never recorded as dropping to zero frames.
@MainActor
final class TelemetrySampler {
    static let window: Duration = .seconds(60)

    private let source: TelemetryCounterSource
    private let context: @MainActor () -> TelemetryFrameContext?
    private let now: () -> ContinuousClock.Instant
    private let sleep: (Duration) async throws -> Void
    private var invalidated = false
    private(set) var isSampling = false

    init(
        source: TelemetryCounterSource,
        context: @escaping @MainActor () -> TelemetryFrameContext?,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.source = source
        self.context = context
        self.now = now
        self.sleep = sleep
    }

    /// Presentation changed (a pause, a cover, a switch): the window in progress is void.
    func invalidate() {
        if isSampling { invalidated = true }
    }

    /// One window's rows. Empty when nothing was on screen, the window was voided, or the
    /// counters could not be read.
    func sample(day: String) async -> [TelemetryReport.Frame] {
        guard !isSampling, let opening = context(), !opening.scenes.isEmpty else { return [] }
        isSampling = true
        invalidated = false
        defer { isSampling = false }
        var counting = false
        do {
            try await source.setRendererCountersEnabled(true)
            counting = true
            let start = try await source.rendererCounters()
            let started = now()
            try await sleep(Self.window)
            let end = try await source.rendererCounters()
            let elapsed = started.duration(to: now())
            try await source.setRendererCountersEnabled(false)
            counting = false
            guard !invalidated, let closing = context() else { return [] }
            return Self.rows(start: start, end: end, elapsed: elapsed,
                             opening: opening, closing: closing, day: day)
        } catch {
            if counting {
                do {
                    try await source.setRendererCountersEnabled(false)
                } catch {
                    AppLog.error("renderer counters could not be turned off: \(error.localizedDescription)")
                }
            }
            if !(error is CancellationError) {
                AppLog.warn("telemetry frame window failed: \(error.localizedDescription)")
            }
            return []
        }
    }

    static func rows(
        start: BridgeRendererCountersReport, end: BridgeRendererCountersReport, elapsed: Duration,
        opening: TelemetryFrameContext, closing: TelemetryFrameContext, day: String
    ) -> [TelemetryReport.Frame] {
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds >= 1 else { return [] }
        let before = Dictionary(start.surfaces.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [TelemetryReport.Frame] = []
        for surface in end.surfaces {
            guard let base = before[key(surface)], !base.paused, !surface.paused,
                  base.effectivePauseReasons.isEmpty, surface.effectivePauseReasons.isEmpty,
                  let display = UInt32(surface.displayId),
                  let scene = closing.scenes[display], opening.scenes[display]?.wallpaperID == scene.wallpaperID
            else { continue }
            let screen = closing.displays[display]
            rows.append(TelemetryReport.Frame(
                day: day,
                wallpaper: TelemetryWallpaper.workshopID(scene.wallpaperID),
                source: TelemetryWallpaper.source(scene.wallpaperID),
                kind: scene.kind,
                backend: TelemetryVocabulary.backend(scene.backend),
                fallback: false,
                mode: TelemetryVocabulary.mode(scene.mode),
                seconds: (seconds * 10).rounded() / 10,
                tickHz: hertz(surface.tickIntervalMicros),
                contentHz: hertz(surface.contentPeriodMicros),
                draws: delta(surface.drawsExecuted, base.drawsExecuted),
                dropped: delta(surface.drawsDropped, base.drawsDropped),
                suppressed: delta(surface.drawTicksSuppressed, base.drawTicksSuppressed),
                skippedUnchanged: delta(surface.presentsSkippedUnchanged, base.presentsSkippedUnchanged),
                presents: delta(surface.presentRequests, base.presentRequests),
                renderFailures: delta(surface.renderFailures, base.renderFailures),
                displayWidth: screen?.width, displayHeight: screen?.height, displayHz: screen?.hz,
                frameRateCap: closing.frameRateCap.map { Int($0) },
                renderScale: (Double(closing.renderScale) * 100).rounded() / 100,
                reducedQuality: closing.reducedQuality || opening.reducedQuality,
                battery: closing.battery,
                lowPower: closing.lowPower,
                thermal: closing.thermal))
        }
        return rows
    }

    private static func key(_ surface: BridgeRendererSurfaceCounters) -> String {
        "\(surface.surfaceId)#\(surface.generation)"
    }

    private static func delta(_ end: UInt64, _ start: UInt64) -> UInt64 { end >= start ? end - start : 0 }

    private static func hertz(_ micros: UInt64) -> Double? {
        guard micros > 0 else { return nil }
        return (1_000_000 / Double(micros) * 10).rounded() / 10
    }
}

extension BridgeStore: TelemetryCounterSource {
    func setRendererCountersEnabled(_ enabled: Bool) async throws {
        try await setRendererCountersEnabledAsync(enabled)
    }

    func rendererCounters() async throws -> BridgeRendererCountersReport {
        try await rendererCountersAsync()
    }
}
