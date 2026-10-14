import Foundation

/// What is waiting to be sent, and the record of the run in progress, kept in
/// `<support>/Telemetry/` so a quit or a crash loses neither.
///
/// `pending.json` holds the rows since the last upload. `session.json` describes this run
/// and is read at the next launch, when the session ledger can say how the run ended.
/// `next-report.json` is written only when the user asks to see the data, and holds the
/// exact report the next upload would send.
@MainActor
final class TelemetrySpool {
    struct Batch: Codable, Equatable {
        var sessions: [TelemetryReport.Session] = []
        var activations: [TelemetryReport.Activation] = []
        var frames: [TelemetryReport.Frame] = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try container.decodeIfPresent([TelemetryReport.Session].self, forKey: .sessions) ?? []
            activations = try container.decodeIfPresent([TelemetryReport.Activation].self, forKey: .activations) ?? []
            frames = try container.decodeIfPresent([TelemetryReport.Frame].self, forKey: .frames) ?? []
        }
    }

    /// The run in progress. `checkpointAt` moves at each sampling cycle and at quit, so
    /// a run that crashed still has a lower bound for its length.
    struct RunRecord: Codable, Equatable {
        var startedAt: Date
        var app: String
        var checkpointAt: Date
        var pressureWarnings = 0
        var pressureCritical = 0
        var peakFootprintBytes: UInt64?
    }

    let folder: URL
    private(set) var batch: Batch
    private(set) var run: RunRecord?

    var pendingURL: URL { folder.appendingPathComponent("pending.json") }
    var runURL: URL { folder.appendingPathComponent("session.json") }
    var previewURL: URL { folder.appendingPathComponent("next-report.json") }

    init(folder: URL = ClientPaths.telemetryURL) {
        self.folder = folder
        batch = Self.read(Batch.self, from: folder.appendingPathComponent("pending.json")) ?? Batch()
    }

    /// Starts this run's record and returns the one the previous run left, if any.
    func beginRun(at date: Date, app: String) -> RunRecord? {
        let previous = Self.read(RunRecord.self, from: runURL)
        let record = RunRecord(startedAt: date, app: app, checkpointAt: date)
        run = record
        write(record, to: runURL)
        return previous
    }

    func checkpoint(at date: Date, footprint: UInt64?) {
        guard var record = run else { return }
        record.checkpointAt = date
        if let footprint { record.peakFootprintBytes = max(record.peakFootprintBytes ?? 0, footprint) }
        run = record
        write(record, to: runURL)
    }

    func recordPressure(critical: Bool, footprint: UInt64?, at date: Date) {
        guard var record = run else { return }
        if critical { record.pressureCritical += 1 } else { record.pressureWarnings += 1 }
        record.checkpointAt = date
        if let footprint { record.peakFootprintBytes = max(record.peakFootprintBytes ?? 0, footprint) }
        run = record
        write(record, to: runURL)
    }

    func append(session: TelemetryReport.Session) {
        batch.sessions = Self.keepingNewest(batch.sessions + [session], TelemetryReport.Limit.sessions)
        save()
    }

    func append(activation: TelemetryReport.Activation) {
        batch.activations = Self.keepingNewest(batch.activations + [activation], TelemetryReport.Limit.activations)
        save()
    }

    func append(frames: [TelemetryReport.Frame]) {
        guard !frames.isEmpty else { return }
        batch.frames = Self.keepingNewest(batch.frames + frames, TelemetryReport.Limit.frames)
        save()
    }

    /// The upload succeeded: what it carried is gone, the run record stays.
    func clearBatch(sent: Batch) {
        batch.sessions.removeFirst(min(sent.sessions.count, batch.sessions.count))
        batch.activations.removeFirst(min(sent.activations.count, batch.activations.count))
        batch.frames.removeFirst(min(sent.frames.count, batch.frames.count))
        save()
    }

    /// Sending was turned off: nothing collected is kept.
    func removeAll() {
        batch = Batch()
        run = nil
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        } catch {
            AppLog.warn("telemetry data could not be removed: \(error.localizedDescription)")
        }
    }

    func writePreview(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: previewURL, options: .atomic)
        return previewURL
    }

    private func save() { write(batch, to: pendingURL) }

    private func write<Value: Encodable>(_ value: Value, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            AppLog.warn("telemetry \(url.lastPathComponent) could not be saved: \(error.localizedDescription)")
        }
    }

    private static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            // Collected data is worth less than a working launch: start empty.
            AppLog.warn("telemetry \(url.lastPathComponent) could not be read: \(error.localizedDescription)")
            return nil
        }
    }

    private static func keepingNewest<Row>(_ rows: [Row], _ limit: Int) -> [Row] {
        rows.count > limit ? Array(rows.suffix(limit)) : rows
    }
}
