import Foundation
import Observation

/// How the run before this one ended, as the launch found it before the app started.
/// `WallpaperEngineApp.recordSessionStart` fills it in; the crash report lookup it starts
/// sets `crashReportFound` once it has looked.
@MainActor
enum TelemetryLaunchRecord {
    static var previousOutcome: SessionLedger.Outcome?
    static var crashReportFound: Bool?
}

/// Collects the performance report and sends it, only while **Send performance data** is
/// on ([docs/features/telemetry.md](../../../docs/features/telemetry.md)).
///
/// Nothing new is measured except the frame windows: activation times, energy ratings,
/// memory pressure and how runs ended are what the app already keeps for its log, read
/// here as numbers and fixed words. One task drives everything. A minute after launch it
/// records how the previous run ended and sends if a day has passed; ten minutes after
/// launch, and every four hours from then, it moves this run's checkpoint, opens one
/// frame window and sends again if due. While sending is off the task does not exist and
/// nothing is recorded.
@MainActor
@Observable
final class TelemetryService {
    static let uploadInterval: TimeInterval = 24 * 60 * 60
    static let firstCheck: Duration = .seconds(60)
    static let firstWindow: Duration = .seconds(10 * 60)
    static let cycleInterval: Duration = .seconds(4 * 60 * 60)

    /// What the service reads from the rest of the app.
    struct Inputs {
        var app: @MainActor () -> TelemetryReport.AppInfo = { TelemetryEnvironment.app() }
        var mac: @MainActor () -> TelemetryReport.MacInfo = { TelemetryEnvironment.mac() }
        var kind: @MainActor (String) -> BridgeWallpaperKind? = { _ in nil }
        var energy: @MainActor () -> [String: WallpaperEnergyRating] = { [:] }
        var loadJournal: URL?
        var footprint: () -> UInt64? = { ProcessFootprint.current() }
        var previousOutcome: @MainActor () -> SessionLedger.Outcome? = { TelemetryLaunchRecord.previousOutcome }
        var crashReportFound: @MainActor () -> Bool? = { TelemetryLaunchRecord.crashReportFound }
    }

    let preferences: TelemetryPreferences
    @ObservationIgnored let spool: TelemetrySpool
    @ObservationIgnored private let uploader: TelemetryUploading
    @ObservationIgnored private let sampler: TelemetrySampler?
    @ObservationIgnored private let inputs: Inputs
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var deletions: Task<Void, Never>?
    @ObservationIgnored private var previousRun: TelemetrySpool.RunRecord?
    @ObservationIgnored private var uploading = false
    @ObservationIgnored private var criticalPressure = false

    var isEnabled: Bool { preferences.isEnabled }
    var lastSentAt: Date? { preferences.lastSentAt }

    /// `sampler` is nil when the environment asks for a diagnostic window
    /// (`RuntimeDiagnosticsRequest`): both would switch the same renderer counters, and a
    /// power measurement must not include telemetry's windows.
    init(
        preferences: TelemetryPreferences, spool: TelemetrySpool, uploader: TelemetryUploading,
        sampler: TelemetrySampler?, inputs: Inputs = Inputs(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.preferences = preferences
        self.spool = spool
        self.uploader = uploader
        self.sampler = sampler
        self.inputs = inputs
        self.now = now
        self.sleep = sleep
    }

    /// At launch: finish any deletion still owed, then start collecting if sending is on.
    func start() {
        retryDeletions()
        guard preferences.isEnabled, loop == nil else { return }
        previousRun = spool.beginRun(at: now(), app: inputs.app().version)
        startLoop()
    }

    /// At quit: this run's record says how long it lasted.
    func stop() {
        loop?.cancel()
        loop = nil
        if preferences.isEnabled { spool.checkpoint(at: now(), footprint: inputs.footprint()) }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != preferences.isEnabled else { return }
        if enabled {
            preferences.setEnabled(true, now: now())
            // A record left by an earlier period of sending belongs to nobody now.
            _ = spool.beginRun(at: now(), app: inputs.app().version)
            previousRun = nil
            startLoop()
            AppLog.info("telemetry: sending turned on")
        } else {
            loop?.cancel()
            loop = nil
            previousRun = nil
            spool.removeAll()
            preferences.setEnabled(false)
            AppLog.info("telemetry: sending turned off; asking the website to delete what was sent")
            retryDeletions()
        }
    }

    func recordActivation(
        _ kind: ActivationLog.Kind, wallpaper: String, origin: ActivationOrigin,
        outcome: ActivationLog.Outcome, milliseconds: Int?
    ) {
        guard preferences.isEnabled else { return }
        spool.append(activation: TelemetryReport.Activation(
            day: TelemetryDay.string(now()), type: kind.rawValue,
            wallpaper: TelemetryWallpaper.workshopID(wallpaper), source: TelemetryWallpaper.source(wallpaper),
            kind: TelemetryReport.Kind(inputs.kind(wallpaper)), origin: origin.rawValue,
            outcome: TelemetryVocabulary.outcome(outcome), ms: milliseconds))
    }

    func recordPressure(_ report: MemoryPressureMonitor.Report) {
        switch report {
        case let .pressure(level, footprint, _):
            criticalPressure = level == .critical
            guard preferences.isEnabled, level != .normal else { return }
            spool.recordPressure(critical: level == .critical, footprint: footprint, at: now())
        case .recovered:
            criticalPressure = false
        }
    }

    /// Presentation changed: a frame window in progress would describe two states.
    func invalidateFrames() {
        sampler?.invalidate()
    }

    /// Writes the report the next upload would send, readable, and returns where.
    func writePreview() throws -> URL {
        guard let built = makeReport() else { throw TelemetryUploadError(status: nil) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try spool.writePreview(try encoder.encode(built.report))
    }

    // MARK: - The steps the task runs, internal so a test can run them one at a time

    func recordPreviousRun() {
        defer { previousRun = nil }
        guard preferences.isEnabled, let run = previousRun, let outcome = inputs.previousOutcome(),
              let ended = TelemetryVocabulary.ending(outcome) else { return }
        let crashed = ended == .unexpected || ended == .exception
        spool.append(session: TelemetryReport.Session(
            day: TelemetryDay.string(run.startedAt), app: run.app, ended: ended,
            crashReport: crashed ? inputs.crashReportFound() ?? false : nil,
            minutes: max(0, Int(run.checkpointAt.timeIntervalSince(run.startedAt) / 60)),
            pressureWarnings: run.pressureWarnings, pressureCritical: run.pressureCritical,
            peakFootprintMB: run.peakFootprintBytes.map { Int($0 / 1_048_576) }))
    }

    func cycle() async {
        guard preferences.isEnabled else { return }
        spool.checkpoint(at: now(), footprint: inputs.footprint())
        if let sampler, !criticalPressure {
            let rows = await sampler.sample(day: TelemetryDay.string(now()))
            if preferences.isEnabled { spool.append(frames: rows) }
        }
        await uploadIfDue()
    }

    /// Sends once a day. A failure is tried again at the next cycle; a report with no rows
    /// is not sent at all.
    func uploadIfDue() async {
        guard !uploading, preferences.isUploadDue(now: now(), interval: Self.uploadInterval),
              let built = makeReport(), built.rows > 0 else { return }
        uploading = true
        defer { uploading = false }
        do {
            try await uploader.send(try JSONEncoder().encode(built.report))
            // Turned off while the request was out: the deletion request covers it.
            guard preferences.installID == built.report.install else { return }
            spool.clearBatch(sent: built.batch)
            preferences.markSent(at: now(), energyThrough: built.energyThrough)
            AppLog.info("telemetry: sent \(built.rows) rows")
        } catch {
            AppLog.info("telemetry: not sent (\(error.localizedDescription)); trying again later")
        }
    }

    struct Built {
        var report: TelemetryReport
        var batch: TelemetrySpool.Batch
        var energyThrough: Date?
        var rows: Int
    }

    func makeReport() -> Built? {
        guard let install = preferences.installID else { return nil }
        let batch = spool.batch
        let since = preferences.state.energySentThrough
        let ratings = inputs.energy()
            .filter { _, rating in
                rating.seconds >= WallpaperEnergyRatings.minimumSeconds
                    && rating.version == WallpaperEnergyRating.currentVersion
                    && since.map { rating.updated > $0 } ?? true
            }
            .sorted { $0.value.updated < $1.value.updated }
            .suffix(TelemetryReport.Limit.energy)
        let energy = ratings.map { id, rating in
            TelemetryReport.Energy(
                wallpaper: TelemetryWallpaper.workshopID(id), source: TelemetryWallpaper.source(id),
                kind: TelemetryReport.Kind(inputs.kind(id)),
                milliwatts: (rating.milliwatts * 10).rounded() / 10, seconds: rating.seconds.rounded(),
                displays: rating.conditions.displays,
                frameRateCap: rating.conditions.frameRateCap.map { Int($0) },
                renderScale: rating.conditions.renderScale)
        }
        let strikes = loadStrikes(since: preferences.lastSentAt ?? preferences.state.enabledAt)
        let report = TelemetryReport(
            install: install, app: inputs.app(), mac: inputs.mac(),
            sessions: batch.sessions, activations: batch.activations, frames: batch.frames,
            energy: energy, loadStrikes: strikes)
        let rows = batch.sessions.count + batch.activations.count + batch.frames.count
            + energy.count + strikes.count
        return Built(report: report, batch: batch, energyThrough: ratings.map(\.value.updated).max(), rows: rows)
    }

    /// Workshop wallpapers the renderer's crash guard caught loading when the app died,
    /// since the last upload. The journal is the bridge's (docs/features/crash-recovery.md).
    private func loadStrikes(since: Date?) -> [TelemetryReport.LoadStrike] {
        struct Journal: Decodable {
            struct Strike: Decodable {
                var count: Int
                var last_at: Double
            }
            var strikes: [String: Strike]?
        }
        guard let url = inputs.loadJournal, FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            let after = since?.timeIntervalSince1970 ?? 0
            return (journal.strikes ?? [:])
                .compactMap { id, strike -> TelemetryReport.LoadStrike? in
                    guard let id = TelemetryWallpaper.workshopID(id), strike.count > 0, strike.last_at > after
                    else { return nil }
                    return TelemetryReport.LoadStrike(wallpaper: id, count: min(strike.count, 1000))
                }
                .sorted { $0.wallpaper < $1.wallpaper }
                .prefix(TelemetryReport.Limit.loadStrikes)
                .map { $0 }
        } catch {
            AppLog.warn("telemetry: load journal could not be read: \(error.localizedDescription)")
            return []
        }
    }

    private func startLoop() {
        loop?.cancel()
        let sleep = sleep
        loop = Task { [weak self] in
            do {
                try await sleep(Self.firstCheck)
                guard let self else { return }
                self.recordPreviousRun()
                await self.uploadIfDue()
                try await sleep(Self.firstWindow - Self.firstCheck)
                while !Task.isCancelled {
                    await self.cycle()
                    try await sleep(Self.cycleInterval)
                }
            } catch {
                // Cancelled: sending was turned off or the app is quitting.
            }
        }
    }

    /// Each owed deletion is asked for once per launch, and once when sending is turned off.
    private func retryDeletions() {
        guard !preferences.state.pendingDeletions.isEmpty, deletions == nil else { return }
        let uploader = uploader
        deletions = Task { [weak self] in
            var asked = Set<String>()
            while let self, let id = self.preferences.state.pendingDeletions.first(where: { !asked.contains($0) }) {
                asked.insert(id)
                do {
                    try await uploader.delete(install: id)
                    self.preferences.markDeleted(id)
                    AppLog.info("telemetry: the website deleted the data of an earlier install id")
                } catch {
                    AppLog.info("telemetry: deletion not confirmed (\(error.localizedDescription)); trying again at next launch")
                }
            }
            self?.deletions = nil
        }
    }

    /// Lets a test wait for the deletion requests `start` or `setEnabled(false)` sent.
    func waitForDeletions() async { await deletions?.value }
}
