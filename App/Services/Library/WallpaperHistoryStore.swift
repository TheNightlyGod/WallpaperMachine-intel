import Foundation
import Observation

/// Successful wallpaper switches, kept separately for each display.
@MainActor
@Observable
final class WallpaperHistoryStore {
    static let preferenceKey = "WallpaperMachine.wallpaperHistory"
    static let limit = 50
    /// How many wallpapers each display remembers the last use of, newest kept.
    static let usedLimit = 1_000

    struct Entry: Encodable, Equatable {
        var past: [String] = []
        var recent: [String] = []
        /// When each wallpaper was last put on the display.
        var used: [String: Date] = [:]
    }

    /// An entry as saved. History saved before uses were dated has no `used`.
    private struct Stored: Decodable {
        var past: [String]?
        var recent: [String]?
        var used: [String: Date]?
    }

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let now: @MainActor () -> Date
    private(set) var entries: [String: Entry] {
        didSet { revision &+= 1 }
    }
    /// Moves with every change of `entries`, so a sort that reads the history knows to sort again.
    private(set) var revision: UInt64 = 0

    /// A nil defaults store keeps history in memory, including in snapshot-only test hosts.
    init(defaults: UserDefaults? = nil, now: @escaping @MainActor () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        let stored = defaults?.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        let loaded = now()
        entries = stored.mapValues { entry in
            var seen = Set<String>()
            let recent = Array((entry.recent ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(Self.limit))
            return Entry(past: Array((entry.past ?? []).filter { !$0.isEmpty }.suffix(Self.limit)),
                         recent: recent,
                         used: entry.used.map { Self.bounded($0.filter { !$0.key.isEmpty }) }
                             ?? Self.dating(recent, from: loaded))
        }
        // Dated once: a later launch must not move them ahead of what was used in between.
        if stored.values.contains(where: { $0.used == nil }) { persist() }
    }

    func previous(on display: String, current: String?, available: Set<String>) -> String? {
        entries[display]?.past.last { $0 != current && available.contains($0) }
    }

    func recent(on display: String, available: Set<String>) -> [String] {
        (entries[display]?.recent ?? []).filter(available.contains)
    }

    /// When each wallpaper was last put on a display, the newest use across displays. History
    /// saved before uses were dated got its dates once, when it was first loaded, in its recent
    /// order (`dating(_:from:)`). A wallpaper the history has no record of, or has forgotten, is
    /// not listed.
    func lastUsedDates() -> [String: Date] {
        var dates: [String: Date] = [:]
        for entry in entries.values {
            dates.merge(entry.used) { max($0, $1) }
        }
        return dates
    }

    /// Call only after saving and confirming the new assignment. Going back consumes the
    /// visited part of the stack, so repeated Previous does not toggle between two wallpapers.
    func recordSwitch(from previous: String?, to wallpaper: String, on display: String,
                      returningToPrevious: Bool = false) {
        guard !wallpaper.isEmpty, wallpaper != previous else { return }
        var entry = entries[display] ?? Entry()
        if returningToPrevious, let index = entry.past.lastIndex(of: wallpaper) {
            entry.past.removeSubrange(index...)
        } else if let previous, !previous.isEmpty, entry.past.last != previous {
            entry.past.append(previous)
        }
        entry.past = Array(entry.past.suffix(Self.limit))
        if let previous, !previous.isEmpty, !entry.recent.contains(previous) {
            entry.recent.insert(previous, at: 0)
        }
        entry.recent.removeAll { $0 == wallpaper }
        entry.recent.insert(wallpaper, at: 0)
        entry.recent = Array(entry.recent.prefix(Self.limit))
        entry.used[wallpaper] = now()
        entry.used = Self.bounded(entry.used)
        entries[display] = entry
        persist()
    }

    func clear(on display: String) {
        guard entries.removeValue(forKey: display) != nil else { return }
        persist()
    }

    func forget(_ ids: Set<String>) {
        var updated = entries
        for display in updated.keys {
            updated[display]?.past.removeAll(where: ids.contains)
            updated[display]?.recent.removeAll(where: ids.contains)
            for id in ids { updated[display]?.used[id] = nil }
        }
        guard updated != entries else { return }
        entries = updated
        persist()
    }

    /// Uses for history saved before they were dated, the recent list in its order: the newest at
    /// `date`, the time it is loaded, and each older one a second before the one after it. The
    /// wallpaper on screen and those used before it then sort ahead of the wallpapers never used,
    /// and behind every one put on a display afterwards.
    private static func dating(_ recent: [String], from date: Date) -> [String: Date] {
        Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, date - TimeInterval($0)) })
    }

    /// The newest `usedLimit` of `used`.
    private static func bounded(_ used: [String: Date]) -> [String: Date] {
        guard used.count > usedLimit else { return used }
        let newest = used.sorted { $0.value > $1.value }.prefix(usedLimit)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
}
