import Foundation
import Observation

/// Whether the user has turned on **Send performance data**, and the bookkeeping that goes
/// with it. Off unless turned on.
///
/// Turning it on creates a random install id; turning it off forgets that id and queues a
/// request asking the website to delete what was sent under it, retried at each launch
/// until it is answered. Turning it on again starts a new id, so the two periods cannot be
/// joined.
@MainActor
@Observable
final class TelemetryPreferences {
    struct State: Codable, Equatable {
        var enabled = false
        var installID: String?
        var enabledAt: Date?
        var lastSentAt: Date?
        /// Energy ratings updated after this were not sent yet.
        var energySentThrough: Date?
        /// Ids whose data the website has not yet confirmed deleting.
        var pendingDeletions: [String] = []

        init() {}

        // Each field is optional on disk, so a later build that adds one still reads this.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            installID = try container.decodeIfPresent(String.self, forKey: .installID)
            enabledAt = try container.decodeIfPresent(Date.self, forKey: .enabledAt)
            lastSentAt = try container.decodeIfPresent(Date.self, forKey: .lastSentAt)
            energySentThrough = try container.decodeIfPresent(Date.self, forKey: .energySentThrough)
            pendingDeletions = try container.decodeIfPresent([String].self, forKey: .pendingDeletions) ?? []
        }
    }

    static let key = "WallpaperMachine.telemetry.state"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var state: State

    var isEnabled: Bool { state.enabled }
    var installID: String? { state.enabled ? state.installID : nil }
    var lastSentAt: Date? { state.lastSentAt }

    /// A day after it was turned on, then a day after each upload.
    func isUploadDue(now: Date, interval: TimeInterval) -> Bool {
        guard state.enabled, let since = state.lastSentAt ?? state.enabledAt else { return false }
        return now.timeIntervalSince(since) >= interval
    }

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            do {
                state = try JSONDecoder().decode(State.self, from: data)
            } catch {
                AppLog.warn("telemetry preferences could not be loaded: \(error.localizedDescription)")
                state = State()
            }
        } else {
            state = State()
        }
    }

    /// Turns sending on or off. Off forgets the install id and queues its deletion.
    func setEnabled(_ enabled: Bool, now: Date = Date(), newID: () -> String = { UUID().uuidString }) {
        guard enabled != state.enabled else { return }
        var next = state
        next.enabled = enabled
        if enabled {
            next.installID = newID()
            next.enabledAt = now
            next.lastSentAt = nil
            next.energySentThrough = nil
        } else {
            if let id = next.installID, !next.pendingDeletions.contains(id) { next.pendingDeletions.append(id) }
            next.installID = nil
            next.enabledAt = nil
            next.lastSentAt = nil
            next.energySentThrough = nil
        }
        persist(next)
    }

    func markSent(at date: Date, energyThrough: Date?) {
        guard state.enabled else { return }
        var next = state
        next.lastSentAt = date
        if let energyThrough { next.energySentThrough = energyThrough }
        persist(next)
    }

    func markDeleted(_ id: String) {
        guard state.pendingDeletions.contains(id) else { return }
        var next = state
        next.pendingDeletions.removeAll { $0 == id }
        persist(next)
    }

    private func persist(_ next: State) {
        do {
            defaults.set(try JSONEncoder().encode(next), forKey: Self.key)
            state = next
        } catch {
            AppLog.warn("telemetry preferences could not be saved: \(error.localizedDescription)")
        }
    }
}
