import Foundation

/// What the daily active count sends: that this copy ran on a UTC day, with no install id
/// ([docs/features/telemetry.md](../../../docs/features/telemetry.md#daily-active-count)).
///
/// `ping` is random and made fresh each day. It lets the website ignore a retry of a
/// ping it already counted, and two days' pings cannot be told to come from one Mac.
struct TelemetryActivePing: Codable, Equatable {
    static let schemaVersion = 1

    var schema = Self.schemaVersion
    var ping: String
    /// The UTC day the ping counts, by this Mac's clock.
    var day: String
    var version: String
    /// Built from source rather than downloaded as the signed release.
    var source: Bool
    /// The first day this copy is counted in this UTC month: the website adds these up
    /// into the month's count.
    var monthFirst: Bool
}

/// Where the daily ping goes.
protocol TelemetryActiveSending: Sendable {
    func sendActive(_ ping: Data) async throws
}

/// Counts this copy of the app once a UTC day toward the number of Macs that use it, for
/// everyone and with no switch: the ping carries no install id, so the website can only
/// add it up. The performance report stays behind **Send performance data**
/// (`TelemetryService`).
///
/// A minute after launch it sends today's ping. Once the website has it, the task sleeps
/// into the first quarter hour of the next UTC day; a failed ping is tried again an hour
/// later, with the same random `ping`, so a retry the website already counted is not
/// counted twice.
@MainActor
final class TelemetryActiveCount {
    nonisolated static let firstCount: Duration = .seconds(60)
    nonisolated static let retryInterval: Duration = .seconds(60 * 60)
    /// Copies that ran over midnight do not all send at the same second.
    nonisolated static let dayStartSpread: TimeInterval = 15 * 60

    struct State: Codable, Equatable {
        /// The UTC day of the current ping, its random id, and whether the website has it.
        var day: String?
        var ping: String?
        var counted = false
        /// The UTC month (`2026-10`) this copy was last counted in.
        var month: String?

        init() {}

        // Each field is optional on disk, so a later build that adds one still reads this.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            day = try container.decodeIfPresent(String.self, forKey: .day)
            ping = try container.decodeIfPresent(String.self, forKey: .ping)
            counted = try container.decodeIfPresent(Bool.self, forKey: .counted) ?? false
            month = try container.decodeIfPresent(String.self, forKey: .month)
        }
    }

    static let key = "WallpaperMachine.telemetry.active"

    private let defaults: UserDefaults
    private let sender: TelemetryActiveSending
    private let app: @MainActor () -> TelemetryReport.AppInfo
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private let spread: () -> TimeInterval
    private let newPing: () -> String
    private var loop: Task<Void, Never>?
    private var sending = false
    private(set) var state: State

    init(
        sender: TelemetryActiveSending, defaults: UserDefaults = ClientPreferences.defaults,
        app: @escaping @MainActor () -> TelemetryReport.AppInfo = { TelemetryEnvironment.app() },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        spread: @escaping () -> TimeInterval = { .random(in: 0..<TelemetryActiveCount.dayStartSpread) },
        newPing: @escaping () -> String = { UUID().uuidString }
    ) {
        self.sender = sender
        self.defaults = defaults
        self.app = app
        self.now = now
        self.sleep = sleep
        self.spread = spread
        self.newPing = newPing
        if let data = defaults.data(forKey: Self.key) {
            do {
                state = try JSONDecoder().decode(State.self, from: data)
            } catch {
                AppLog.warn("telemetry: active count state could not be loaded: \(error.localizedDescription)")
                state = State()
            }
        } else {
            state = State()
        }
    }

    /// A run with its own app-support folder or preferences (the UI tests, a development
    /// run) is not a Mac that uses the app, so it sends nothing.
    nonisolated static func countsRun(environment: [String: String]) -> Bool {
        ["WALLPAPER_MACHINE_HOME", ClientPreferences.suiteEnvironmentKey].allSatisfy {
            environment[$0]?.isEmpty ?? true
        }
    }

    func start() {
        guard loop == nil else { return }
        let sleep = sleep
        loop = Task { [weak self] in
            do {
                try await sleep(Self.firstCount)
                guard let self else { return }
                while !Task.isCancelled {
                    let counted = await self.countIfDue()
                    try await sleep(counted ? Self.untilNextDay(from: self.now(), spread: self.spread()) : Self.retryInterval)
                }
            } catch {
                // Cancelled: the app is quitting.
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Sends today's ping unless the website already has it. Returns whether today is counted.
    func countIfDue() async -> Bool {
        let today = TelemetryDay.string(now())
        if state.day == today, state.counted { return true }
        guard !sending else { return false }
        if state.day != today || state.ping == nil {
            var next = state
            next.day = today
            next.ping = newPing()
            next.counted = false
            persist(next)
        }
        guard let ping = state.ping else { return false }
        let month = String(today.prefix(7))
        let info = app()
        let body = TelemetryActivePing(
            ping: ping, day: today, version: info.version, source: info.source, monthFirst: state.month != month)
        sending = true
        defer { sending = false }
        do {
            try await sender.sendActive(try JSONEncoder().encode(body))
        } catch {
            AppLog.info("telemetry: active count not sent (\(error.localizedDescription)); trying again in an hour")
            return false
        }
        guard state.ping == ping else { return false }
        var next = state
        next.counted = true
        next.month = month
        persist(next)
        AppLog.info("telemetry: counted as active today")
        return true
    }

    /// From `now` to `spread` seconds into the next UTC day. UTC days are all 86,400 s long.
    nonisolated static func untilNextDay(from now: Date, spread: TimeInterval) -> Duration {
        let seconds = now.timeIntervalSince1970
        let nextDay = (seconds / 86_400).rounded(.down) * 86_400 + 86_400
        return .milliseconds(Int64(((nextDay - seconds + max(0, spread)) * 1000).rounded(.up)))
    }

    private func persist(_ next: State) {
        do {
            defaults.set(try JSONEncoder().encode(next), forKey: Self.key)
        } catch {
            AppLog.warn("telemetry: active count state could not be saved: \(error.localizedDescription)")
        }
        state = next
    }
}
