import Foundation
import Observation

/// The panel's four one-time prompts and when each may appear.
///
/// - `support` asks for support once a successfully downloaded wallpaper has been applied.
/// - `star` asks for a GitHub star, once, from someone who did not choose it in the support
///   prompt, after 14 days and on at least 5 different days of opening the panel. Someone who
///   never downloads a wallpaper, and so never sees the support prompt, gets it too.
/// - `telemetry` asks once whether to send performance data, only someone who had finished the
///   welcome guide before it offered the switch; the guide asks everyone else.
/// - `subscriptions` offers once to import the Steam subscriptions, to someone who finished the
///   guide and is signed in to Steam but has never signed in to Steam Community here: someone who
///   finished the guide before it offered the import, or skipped its Steam page. The guide's
///   offer, or signing in to Steam Community anywhere, spends it.
///
/// At most one is pending at a time, in that order of priority (telemetry, subscriptions,
/// support, star), and
/// none appears on the same day as another. "First use" for the star prompt is the first day
/// the panel was opened with a build that counts it, so an existing user's clock starts at the
/// update.
@MainActor
@Observable
final class SupportPromptStore {
    enum Prompt: String {
        case telemetry, subscriptions, support, star
    }

    static let starDelay: TimeInterval = 14 * 24 * 60 * 60
    static let starUseDays = 5

    private struct State: Codable {
        var downloadedWallpaperIDs: Set<String> = []
        var pending = false
        var presented = false
        var starChosen = false
        var starPresented = false
        var telemetryAsked = false
        var subscriptionsOffered = false
        var firstUseAt: Date?
        var useDays = 0
        var lastUseDay: Date?
        var lastPromptAt: Date?

        init() {}

        // The first builds saved only the first three fields; the rest read as unset.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            downloadedWallpaperIDs = try container.decodeIfPresent(Set<String>.self, forKey: .downloadedWallpaperIDs) ?? []
            pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
            presented = try container.decodeIfPresent(Bool.self, forKey: .presented) ?? false
            starChosen = try container.decodeIfPresent(Bool.self, forKey: .starChosen) ?? false
            starPresented = try container.decodeIfPresent(Bool.self, forKey: .starPresented) ?? false
            telemetryAsked = try container.decodeIfPresent(Bool.self, forKey: .telemetryAsked) ?? false
            subscriptionsOffered = try container.decodeIfPresent(Bool.self, forKey: .subscriptionsOffered) ?? false
            firstUseAt = try container.decodeIfPresent(Date.self, forKey: .firstUseAt)
            useDays = try container.decodeIfPresent(Int.self, forKey: .useDays) ?? 0
            lastUseDay = try container.decodeIfPresent(Date.self, forKey: .lastUseDay)
            lastPromptAt = try container.decodeIfPresent(Date.self, forKey: .lastPromptAt)
        }
    }

    private static let key = "WallpaperMachine.supportPrompt.state"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    private var state: State

    /// The support prompt is waiting to be shown.
    var isPending: Bool { state.pending && !state.presented }

    init(defaults: UserDefaults = ClientPreferences.defaults, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        if let data = defaults.data(forKey: Self.key) {
            do {
                state = try JSONDecoder().decode(State.self, from: data)
            } catch {
                AppLog.warn("support prompt state could not be loaded: \(error.localizedDescription)")
                state = State()
            }
        } else {
            state = State()
        }
    }

    /// The prompt to show now, if any. `welcomeSeen` is whether the welcome guide had been
    /// finished; `telemetryOn` whether sending performance data is already on; `steamSignedIn`
    /// whether a Steam account is signed in for downloads.
    func pendingPrompt(
        welcomeSeen: Bool, telemetryOn: Bool, steamSignedIn: Bool = false, now: Date = Date()
    ) -> Prompt? {
        if let last = state.lastPromptAt, calendar.isDate(last, inSameDayAs: now) { return nil }
        if welcomeSeen, !telemetryOn, !state.telemetryAsked { return .telemetry }
        if welcomeSeen, steamSignedIn, !state.subscriptionsOffered { return .subscriptions }
        if isPending { return .support }
        if !state.starChosen, !state.starPresented, let first = state.firstUseAt,
           now.timeIntervalSince(first) >= Self.starDelay, state.useDays >= Self.starUseDays {
            return .star
        }
        return nil
    }

    func recordDownload(wallpaperID: String) {
        guard !wallpaperID.isEmpty, !state.pending, !state.presented,
              !state.downloadedWallpaperIDs.contains(wallpaperID) else { return }
        var next = state
        next.downloadedWallpaperIDs.insert(wallpaperID)
        persist(next)
    }

    func recordSuccessfulActivation(wallpaperID: String) {
        guard !wallpaperID.isEmpty, !state.pending, !state.presented,
              state.downloadedWallpaperIDs.contains(wallpaperID) else { return }
        var next = state
        next.downloadedWallpaperIDs.removeAll()
        next.pending = true
        persist(next)
    }

    func forgetDownload(wallpaperID: String) {
        guard state.downloadedWallpaperIDs.contains(wallpaperID) else { return }
        var next = state
        next.downloadedWallpaperIDs.remove(wallpaperID)
        persist(next)
    }

    /// The panel was opened today. Counts each calendar day once.
    func recordPanelUse(now: Date = Date()) {
        let day = calendar.startOfDay(for: now)
        guard state.lastUseDay.map({ !calendar.isDate($0, inSameDayAs: day) }) ?? true else { return }
        var next = state
        next.lastUseDay = day
        next.useDays += 1
        if next.firstUseAt == nil { next.firstUseAt = now }
        persist(next)
    }

    /// The user chose to star the repository, here or anywhere else that offers it.
    func recordStarChosen() {
        guard !state.starChosen else { return }
        var next = state
        next.starChosen = true
        persist(next)
    }

    /// The welcome guide showed the performance data switch, so the prompt is not needed.
    func recordTelemetryAsked() {
        guard !state.telemetryAsked else { return }
        var next = state
        next.telemetryAsked = true
        persist(next)
    }

    /// The import of the Steam subscriptions was offered, or the person found it: the guide showed
    /// it, or they signed in to Steam Community. The prompt is then not needed.
    func recordSubscriptionsOffered() {
        guard !state.subscriptionsOffered else { return }
        var next = state
        next.subscriptionsOffered = true
        persist(next)
    }

    func markPresented(_ prompt: Prompt = .support, now: Date = Date()) {
        var next = state
        switch prompt {
        case .support:
            guard isPending else { return }
            next.pending = false
            next.presented = true
        case .star:
            guard !state.starPresented else { return }
            next.starPresented = true
        case .telemetry:
            guard !state.telemetryAsked else { return }
            next.telemetryAsked = true
        case .subscriptions:
            guard !state.subscriptionsOffered else { return }
            next.subscriptionsOffered = true
        }
        next.lastPromptAt = now
        persist(next)
    }

    private func persist(_ next: State) {
        do {
            let data = try JSONEncoder().encode(next)
            defaults.set(data, forKey: Self.key)
            state = next
        } catch {
            AppLog.warn("support prompt state could not be saved: \(error.localizedDescription)")
        }
    }
}
