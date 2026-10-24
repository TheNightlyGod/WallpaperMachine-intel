import Foundation

/// When a diagnostic window opens and how long it stays open, as the
/// environment asks for.
///
/// `WALLPAPER_MACHINE_DIAGNOSTICS=<seconds>` is the window's length.
/// `WALLPAPER_MACHINE_DIAGNOSTICS_DELAY=<seconds>` opens it that long after
/// launch rather than at launch, so its counts cover the steady-state window a
/// power measurement is taken over instead of the scene's start-up. A value
/// that is not a whole number of seconds starts nothing: counting from launch
/// instead would describe a different window without saying so.
struct RuntimeDiagnosticsRequest: Equatable {
    static let durationKey = "WALLPAPER_MACHINE_DIAGNOSTICS"
    static let delayKey = "WALLPAPER_MACHINE_DIAGNOSTICS_DELAY"

    let delay: Duration
    let duration: Duration

    init?(environment: [String: String]) {
        guard let raw = environment[Self.durationKey], let seconds = Int(raw), seconds > 0 else {
            return nil
        }
        var delaySeconds = 0
        if let raw = environment[Self.delayKey] {
            guard let parsed = Int(raw), parsed >= 0 else { return nil }
            delaySeconds = parsed
        }
        delay = .seconds(delaySeconds)
        duration = .seconds(seconds)
    }
}

/// One bounded diagnostic window over both halves of the runtime.
///
/// Two separate counter surfaces answer two different questions, and a claim
/// about power needs both. `RuntimeCounters` records what the application
/// decided and what the web host did; the renderer's own counters record what
/// the frame clock, the queue submissions, the present requests and the decoder
/// actually did. A suspend decision recorded on one side proves nothing about
/// the work on the other.
///
/// Everything here is off by default and bounded:
///
/// - The renderer performs no counting until `start` turns it on, and stops
///   again on `stop`. Enabling starts no thread, no timer and no output stream
///   inside the renderer.
/// - The session has a duration, so a forgotten switch cannot keep counting.
/// - Nothing is emitted per frame. One aggregated report is produced when the
///   caller asks for it, by pulling both sides.
///
/// The renderer's counters have one other user: the frame windows of **Send
/// performance data** (`TelemetrySampler`), which turn on only the renderer half.
/// A run that sets `WALLPAPER_MACHINE_DIAGNOSTICS` opens none of them, so this
/// session's counts are never mixed with theirs.
@MainActor
final class RuntimeDiagnosticsSession {
    private let store: BridgeStore
    private let counters: RuntimeCounters
    private var expiry: Task<Void, Never>?
    /// When the counters started, so a report can say how long they ran.
    private var openedAt: ContinuousClock.Instant?

    init(store: BridgeStore, counters: RuntimeCounters? = nil) {
        self.store = store
        self.counters = counters ?? .shared
    }

    /// Opens the window. The report is produced by `report()`; when `onExpiry`
    /// is given it is called once with the final report and the session closes
    /// itself.
    func start(
        duration: Duration,
        onExpiry: (@MainActor ([String]) -> Void)? = nil
    ) async throws {
        guard duration > .zero else { return }
        expiry?.cancel()
        counters.startSession(duration: duration)
        try await store.setRendererCountersEnabledAsync(true)
        openedAt = ContinuousClock.now
        guard let onExpiry else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            let lines = await self.report()
            onExpiry(lines)
            await self.stop()
        }
    }

    func stop() async {
        expiry?.cancel()
        expiry = nil
        counters.endSession()
        do {
            try await store.setRendererCountersEnabledAsync(false)
        } catch {
            AppLog.error("renderer counters could not be turned off: \(error.localizedDescription)")
        }
    }

    /// One aggregated report, newest reading per line. Never emitted per frame.
    ///
    /// Renderer rows are labelled so the two kinds of work stay apart:
    /// `surface=` counts work only that surface performs and that has to stop
    /// when nobody can see it, and `source=` counts decoding work that may
    /// legitimately continue while one consumer is hidden.
    func report() async -> [String] {
        var lines = counters.aggregatedReport()
        // Measured, not taken from the requested duration: a count becomes a
        // rate only over the time it was actually counted in.
        let elapsed = openedAt.map { ContinuousClock.now - $0 }
        do {
            let renderer = try await store.rendererCountersAsync()
            lines.append(contentsOf: Self.rendererLines(renderer))
        } catch {
            lines.append("renderer counters unavailable: \(error.localizedDescription)")
        }
        if let elapsed { lines.insert(Self.windowLine(elapsed), at: 0) }
        return lines
    }

    static func windowLine(_ elapsed: Duration) -> String {
        let (seconds, attoseconds) = elapsed.components
        return "window elapsed_ms=\(seconds * 1000 + attoseconds / 1_000_000_000_000_000)"
    }

    static func rendererLines(_ report: BridgeRendererCountersReport) -> [String] {
        var lines: [String] = []
        lines.append("renderer recording=\(report.recording)")
        for surface in report.surfaces {
            let reasons = surface.effectivePauseReasons.isEmpty
                ? "none" : surface.effectivePauseReasons.joined(separator: "+")
            // Work this surface performs alone, including the colour
            // conversions and GPU imports its own texture cache does. All of it
            // has to stop when nobody can see the surface.
            lines.append(
                "surface=\(surface.backend)/\(surface.displayId)"
                    + "/handle\(surface.surfaceId)/gen\(surface.generation) "
                    + "paused=\(surface.paused) reasons=\(reasons) "
                    + "timer_wakeups=\(surface.timerWakeups) "
                    + "draw_requests=\(surface.drawRequests) "
                    + "draw_ticks_suppressed=\(surface.drawTicksSuppressed) "
                    + "draws_executed=\(surface.drawsExecuted) "
                    + "draws_dropped=\(surface.drawsDropped) "
                    + "render_submissions=\(surface.renderSubmissions) "
                    + "render_failures=\(surface.renderFailures) "
                    + "present_requests=\(surface.presentRequests) "
                    + "gpu_completions=\(surface.gpuCompletions) "
                    + "simulation_ticks=\(surface.simulationTicks) "
                    + "presents_skipped_unchanged=\(surface.presentsSkippedUnchanged) "
                    + "tick_interval_us=\(surface.tickIntervalMicros) "
                    + "content_period_us=\(surface.contentPeriodMicros) "
                    + "frames_selected=\(surface.videoFramesSelected) "
                    + "frames_reused=\(surface.videoFramesReused) "
                    + "frames_skipped=\(surface.videoFramesSkipped) "
                    + "selected_generation=\(surface.videoSelectedGeneration) "
                    + "conversions=\(surface.videoConversions) "
                    + "imports=\(surface.videoImports) "
                    // Allocation ledger over this surface's video conversion
                    // destination textures, now and at its highest. Decode
                    // pixel buffers and the layer's drawables are not
                    // in it, so neither figure is a residency or footprint
                    // claim; the peak is what a ceiling has to be judged
                    // against, because the current value alone hides the
                    // destinations that were in flight a moment ago.
                    + "conversion_live_bytes=\(surface.videoConversionLiveBytes) "
                    + "conversion_peak_live_bytes=\(surface.videoConversionPeakLiveBytes)")
            // Work the decoder instance performs, which one hidden consumer
            // does not necessarily stop.
            lines.append(
                "source=\(surface.sourceId) instances=\(surface.sourceCount) "
                    + "path=\(surface.sourcePath) "
                    + "consumed_by=\(surface.displayId)/gen\(surface.generation) "
                    + "decode_outputs=\(surface.videoDecodeOutputs) "
                    + "seeks=\(surface.videoSeeks)")
        }
        lines.append(contentsOf: sourceRollupLines(report.surfaces))
        lines.append(
            "process audio_analysis_deliveries=\(report.audioAnalysisDeliveries) "
                + "audio_accepted_frames=\(report.audioAcceptedFrames) "
                + "audio_active_consumers=\(report.audioActiveConsumers)")
        // Present requests are requests. Whether the compositor displayed the
        // frame is a different measurement, and this backend cannot make it.
        lines.append(
            "presented_frames="
                + (report.presentationFeedbackAvailable ? "available" : "unavailable"))
        return lines
    }

    /// Totals decode work once per decoder instance.
    ///
    /// Two consumers of one decoder each report that decoder's running totals,
    /// so adding the rows together would count the same decode twice. Two
    /// decoders reading the same file are still two decoders and must stay
    /// separate, which is why the key is the running instance and never the
    /// path. A surface that consumes no decoder, or more than one, cannot be
    /// attributed to a single instance; its decode work is reported as unknown
    /// rather than folded into a total that would then be wrong.
    static func sourceRollupLines(_ surfaces: [BridgeRendererSurfaceCounters]) -> [String] {
        var decodeByInstance: [String: UInt64] = [:]
        var consumersByInstance: [String: Int] = [:]
        var pathByInstance: [String: String] = [:]
        var unattributedDecode: UInt64 = 0
        var unattributedSurfaces = 0

        for surface in surfaces where surface.videoDecodeOutputs > 0 || surface.sourceCount > 0 {
            guard surface.sourceCount == 1, surface.sourceId != "unknown" else {
                unattributedDecode += surface.videoDecodeOutputs
                unattributedSurfaces += 1
                continue
            }
            // Each consumer reports the same running total for one decoder, so
            // the instance's decode work is the maximum, not the sum.
            decodeByInstance[surface.sourceId] = max(
                decodeByInstance[surface.sourceId] ?? 0, surface.videoDecodeOutputs)
            consumersByInstance[surface.sourceId, default: 0] += 1
            pathByInstance[surface.sourceId] = surface.sourcePath
        }

        var lines = decodeByInstance.keys.sorted().map { instance in
            "source-total=\(instance) consumers=\(consumersByInstance[instance] ?? 0) "
                + "path=\(pathByInstance[instance] ?? "") "
                + "decode_outputs=\(decodeByInstance[instance] ?? 0)"
        }
        if unattributedSurfaces > 0 {
            lines.append(
                "source-total=unknown surfaces=\(unattributedSurfaces) "
                    + "decode_outputs=unknown observed=\(unattributedDecode)")
        }
        return lines
    }
}
