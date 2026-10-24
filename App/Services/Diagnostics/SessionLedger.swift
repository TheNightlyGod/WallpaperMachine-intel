import Darwin
import Foundation
import os

/// Remembers how each run of the app ended, so the next launch can say so in its log.
///
/// A run is one record with a phase: `running` from launch, `quitting` once a quit
/// starts, `ended` as the app's last act. What a launch finds in the file tells how
/// the run before it ended; see `classify`. There are no handlers for crash signals,
/// which could clash with the ones other libraries install or alter a crash report
/// (`TerminationSignalRelay` handles only SIGTERM and SIGHUP), and no heartbeat: a
/// normal session writes the file three times (launch, quit start, exit).
///
/// `kern.bootsessionuuid` is the same value macOS reports as `bootSessionUUID` in a
/// crash report. A record still `running` after the machine restarted therefore
/// cannot be mistaken for a crash, and one from this boot cannot be mistaken for a
/// restart.
final class SessionLedger: @unchecked Sendable {
    enum Phase: String, Codable {
        case running, quitting, ended
    }

    /// One run of the app.
    struct Launch: Codable, Equatable {
        var id: String
        var pid: Int32
        var startedAt: Date
        /// `nil` when the kernel would not say; such a run is never called a restart.
        var bootSession: String?
        /// The build, as `ClientPaths.buildStamp` words it.
        var app: String
        var phase: Phase
        var quitReason: String?
        /// Name of the Objective-C exception that nothing caught, if one ended the run.
        var exception: String?
    }

    enum Outcome: Equatable {
        /// Nothing on record: a first launch, or a ledger that could not be read.
        case firstRun
        case cleanQuit(reason: String?)
        /// A quit began and the run ended without finishing it.
        case quitStalled(reason: String?)
        /// Still `running` on the same boot: a crash, a force quit or a kill.
        case endedUnexpectedly
        /// Still `running` on an earlier boot: a restart, a power loss or a kernel panic.
        case systemRestart
        case exception(name: String)

        /// The run died without the app's help, which is what crash reports explain.
        var isUnexpectedEnd: Bool {
            switch self {
            case .endedUnexpectedly, .exception: true
            default: false
            }
        }

        /// Worth a warning in the log rather than a note.
        var isAbnormal: Bool {
            switch self {
            case .firstRun, .cleanQuit: false
            default: true
            }
        }
    }

    /// A finished run, as the ring of recent sessions keeps it.
    struct Entry: Codable, Equatable {
        var outcome: Outcome
        var app: String
        var pid: Int32
        var startedAt: Date
    }

    /// What the file said about the run before this one.
    struct PreviousSession: Equatable {
        var outcome: Outcome
        /// The record that was found, `nil` on a first run.
        var launch: Launch?
        /// The last runs including this one, oldest first, at most `recentLimit`.
        var recent: [Entry]

        var unexpectedCount: Int { recent.filter { $0.outcome.isUnexpectedEnd }.count }

        /// Unexpected ends in a row, counted back from the run just classified.
        var consecutiveUnexpected: Int {
            recent.reversed().prefix(while: { $0.outcome.isUnexpectedEnd }).count
        }

        /// The text of the `previous session:` log line.
        var summary: String {
            var text = outcome.description
            if let launch { text += " (\(launch.app), pid \(launch.pid))" }
            guard !recent.isEmpty else { return text }
            text += "; \(unexpectedCount) of the last \(recent.count) sessions ended unexpectedly"
            if consecutiveUnexpected >= 2 { text += ", \(consecutiveUnexpected) in a row" }
            return text
        }
    }

    /// How many finished runs the file remembers.
    static let recentLimit = 5

    static let currentFormat = 1

    private struct File: Codable {
        var format = SessionLedger.currentFormat
        var current: Launch?
        var recent: [Entry] = []
    }

    private let url: URL
    private let clock: () -> Date
    private let pid: Int32
    private let bootSession: String?
    private let write: (Data, URL) throws -> Void
    private let lock = NSLock()
    private var file = File()

    init(
        url: URL = SessionLedger.defaultURL,
        clock: @escaping () -> Date = Date.init,
        pid: Int32 = getpid(),
        bootSession: String? = SessionLedger.currentBootSession(),
        write: @escaping (Data, URL) throws -> Void = SessionLedger.writeAtomically
    ) {
        self.url = url
        self.clock = clock
        self.pid = pid
        self.bootSession = bootSession
        self.write = write
    }

    static var defaultURL: URL {
        ClientPaths.supportURL.appendingPathComponent("Session/ledger.json")
    }

    // MARK: Process-wide instance

    private static let sharedLedger = OSAllocatedUnfairLock<SessionLedger?>(initialState: nil)

    /// The ledger of this process, or `nil` before `beginProcessSession` (and in tests).
    static var shared: SessionLedger? { sharedLedger.withLock { $0 } }

    /// Starts this process's session, makes the ledger `shared` and returns how the
    /// previous one ended.
    @discardableResult
    static func beginProcessSession(app: String = ClientPaths.buildStamp()) -> PreviousSession {
        let ledger = SessionLedger()
        let previous = ledger.begin(app: app)
        sharedLedger.withLock { $0 = ledger }
        return previous
    }

    // MARK: Classification

    /// What the record left by the run before this one says about how it ended.
    /// Pure, so every case can be exercised without a real crash.
    static func classify(previous: Launch?, currentBoot: String?) -> Outcome {
        guard let previous else { return .firstRun }
        // Recorded by the handler of an uncaught exception, which ends the run.
        if let name = previous.exception { return .exception(name: name) }
        switch previous.phase {
        case .ended:
            return .cleanQuit(reason: previous.quitReason)
        case .quitting:
            return .quitStalled(reason: previous.quitReason)
        case .running:
            if let before = previous.bootSession, let now = currentBoot,
               before.caseInsensitiveCompare(now) != .orderedSame {
                return .systemRestart
            }
            return .endedUnexpectedly
        }
    }

    // MARK: Lifecycle

    /// Reads the record of the previous run, classifies it, and writes this run as
    /// `running`. A file that cannot be read counts as a first run and is replaced.
    func begin(app: String) -> PreviousSession {
        lock.lock()
        defer { lock.unlock() }
        let loaded = load()
        var recent = loaded?.recent ?? []
        let outcome = Self.classify(previous: loaded?.current, currentBoot: bootSession)
        if let previous = loaded?.current {
            recent.append(Entry(outcome: outcome, app: previous.app, pid: previous.pid, startedAt: previous.startedAt))
            recent = Array(recent.suffix(Self.recentLimit))
        }
        let now = Launch(id: UUID().uuidString, pid: pid, startedAt: clock(), bootSession: bootSession,
                         app: app, phase: .running, quitReason: nil, exception: nil)
        file = File(current: now, recent: recent)
        persist()
        return PreviousSession(outcome: outcome, launch: loaded?.current, recent: recent)
    }

    /// A quit has started. `reason` says who asked for it, once that is known.
    func markQuitting(reason: String?) {
        update { launch in
            guard launch.phase != .ended else { return false }
            launch.phase = .quitting
            launch.quitReason = reason
            return true
        }
    }

    /// A quit that began was called off and the app keeps running.
    func markRunning() {
        update { launch in
            guard launch.phase == .quitting else { return false }
            launch.phase = .running
            launch.quitReason = nil
            return true
        }
    }

    /// The app is about to be ended from outside its own quit: a second termination signal,
    /// or the deadline for the first. A run whose quit never began is recorded as a quit that
    /// did not finish, so the next launch does not take a requested stop for a crash. A quit
    /// that began keeps the reason and the stages it already named. May be called from any
    /// thread and gives up after a second, so a lock another thread never releases cannot
    /// keep the app from being ended.
    func markCutShort(reason: String) {
        guard lock.lock(before: Date(timeIntervalSinceNow: 1)) else { return }
        defer { lock.unlock() }
        mutate { launch in
            guard launch.phase == .running else { return false }
            launch.phase = .quitting
            launch.quitReason = reason
            return true
        }
    }

    /// The app's last act before it exits.
    func markEnded() {
        update { launch in
            guard launch.phase != .ended else { return false }
            launch.phase = .ended
            return true
        }
    }

    /// Records the exception that is about to end the run. May be called from any
    /// thread, including the one that threw, so it gives up after a second rather
    /// than hold the crash behind a lock another thread never releases.
    func noteException(named name: String) {
        guard lock.lock(before: Date(timeIntervalSinceNow: 1)) else { return }
        defer { lock.unlock() }
        mutate { launch in
            guard launch.exception == nil else { return false }
            launch.exception = name
            return true
        }
    }

    // MARK: Storage

    private func update(_ change: (inout Launch) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        mutate(change)
    }

    /// Applies `change` to this run's record and writes it, unless a newer launch
    /// has taken the file over: a second copy of the app on the same support folder
    /// must not rewrite the record of the run that is still going.
    private func mutate(_ change: (inout Launch) -> Bool) {
        guard var launch = file.current else { return }
        if let onDisk = load()?.current, onDisk.id != launch.id { return }
        guard change(&launch) else { return }
        file.current = launch
        persist()
    }

    private func load() -> File? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if (error as? CocoaError)?.code != .fileReadNoSuchFile {
                AppLog.warn("session ledger: could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let decoded = try? decoder.decode(File.self, from: data), decoded.format == Self.currentFormat else {
            AppLog.warn("session ledger: \(url.lastPathComponent) is not a ledger this build can read")
            return nil
        }
        return decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(try encoder.encode(file), url)
        } catch {
            // A write that fails here shows up next launch as a crash that did not happen.
            AppLog.warn("session ledger: could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// The identifier macOS gives each boot; `nil` if the kernel does not answer.
    static func currentBootSession() -> String? {
        let value = DiagnosticEnvironment.sysctl("kern.bootsessionuuid")
        return value?.isEmpty == false ? value : nil
    }
}

extension SessionLedger.Outcome: Codable {
    private enum CodingKeys: String, CodingKey { case kind, detail }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let detail = try container.decodeIfPresent(String.self, forKey: .detail)
        switch try container.decode(String.self, forKey: .kind) {
        case "firstRun": self = .firstRun
        case "cleanQuit": self = .cleanQuit(reason: detail)
        case "quitStalled": self = .quitStalled(reason: detail)
        case "endedUnexpectedly": self = .endedUnexpectedly
        case "systemRestart": self = .systemRestart
        case "exception": self = .exception(name: detail ?? "unknown")
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown outcome")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .firstRun: try container.encode("firstRun", forKey: .kind)
        case let .cleanQuit(reason):
            try container.encode("cleanQuit", forKey: .kind)
            try container.encodeIfPresent(reason, forKey: .detail)
        case let .quitStalled(reason):
            try container.encode("quitStalled", forKey: .kind)
            try container.encodeIfPresent(reason, forKey: .detail)
        case .endedUnexpectedly: try container.encode("endedUnexpectedly", forKey: .kind)
        case .systemRestart: try container.encode("systemRestart", forKey: .kind)
        case let .exception(name):
            try container.encode("exception", forKey: .kind)
            try container.encode(name, forKey: .detail)
        }
    }
}

extension SessionLedger.Outcome: CustomStringConvertible {
    var description: String {
        switch self {
        case .firstRun: "none recorded"
        case let .cleanQuit(reason): "quit normally" + Self.suffix(reason)
        case let .quitStalled(reason): "quit did not finish" + Self.suffix(reason)
        case .endedUnexpectedly: "ended unexpectedly (a crash, a force quit or a kill)"
        case .systemRestart: "ended by a restart, shutdown or power loss"
        case let .exception(name): "ended by uncaught exception \(name)"
        }
    }

    private static func suffix(_ reason: String?) -> String {
        reason.map { " (\($0))" } ?? ""
    }
}
