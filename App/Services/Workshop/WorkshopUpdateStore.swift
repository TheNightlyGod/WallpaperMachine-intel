import Foundation
import Observation

/// Which installed Workshop wallpapers their authors have changed since they were installed.
///
/// A wallpaper counts as installed from the moment this app finished downloading it. One it did
/// not download (imported, or downloaded before installs were recorded) counts from when its
/// `project.json` was last written, which for an import is when it was copied in, so an import
/// that was already out of date is not caught. Steam's public details endpoint says when each
/// item last changed; it needs no sign-in, and only the items' ids are sent. An installed
/// Workshop preset holds its base wallpaper's content too, so a change to that base after the
/// preset was installed is an update of the preset, and the base's id is asked about with it.
@MainActor
@Observable
final class WorkshopUpdateStore {
    /// Installed items with a newer version on the Workshop, with Steam's current details.
    private(set) var availableRevision: UInt64 = 0
    private(set) var available: [String: WorkshopItem] = [:] {
        didSet { if available != oldValue { availableRevision &+= 1 } }
    }
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    private(set) var errorMessage: String?
    /// Whether the app checks by itself, at most once a day. On unless turned off.
    var checksAutomatically: Bool {
        didSet { defaults.set(checksAutomatically, forKey: Self.automaticKey) }
    }

    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Steam's clock and this Mac's may disagree a little; a change within this of the install
    /// is the version that was installed.
    nonisolated static let tolerance: TimeInterval = 60
    private static let installedKey = "WallpaperMachine.workshopInstalledAt"
    private static let availableKey = "WallpaperMachine.workshopUpdates"
    private static let lastCheckedKey = "WallpaperMachine.workshopUpdatesCheckedAt"
    nonisolated static let automaticKey = "WallpaperMachine.workshopUpdateChecks"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable ([String]) async throws -> [WorkshopItem]
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var installedAt: [String: Date]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var installedIDs: Set<String> = []
    @ObservationIgnored private var itemRevisions: [String: UInt64] = [:]

    init(
        defaults: UserDefaults = ClientPreferences.defaults,
        fetch: @escaping @Sendable ([String]) async throws -> [WorkshopItem] = { try await WorkshopService().details(ids: $0) },
        now: (@MainActor () -> Date)? = nil
    ) {
        self.defaults = defaults
        self.fetch = fetch
        self.now = now ?? { Date() }
        checksAutomatically = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        installedAt = (defaults.dictionary(forKey: Self.installedKey) as? [String: Double] ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
        available = (defaults.data(forKey: Self.availableKey))
            .flatMap { try? JSONDecoder().decode([WorkshopItem].self, from: $0) }
            .map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
        lastChecked = (defaults.object(forKey: Self.lastCheckedKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// Workshop ids are numbers; anything else in the library came from somewhere else.
    nonisolated static func isWorkshopID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber } && UInt64(id) != nil
    }

    /// Checks `installed` (the library's wallpaper ids) against the Workshop, unless a check is
    /// already running. `library` is where their folders are.
    func check(installed: [String], library: URL) {
        let ids = installed.filter(Self.isWorkshopID)
        let currentIDs = Set(ids)
        for id in installedIDs.subtracting(currentIDs) {
            itemRevisions[id, default: 0] &+= 1
            available[id] = nil
        }
        installedIDs = currentIDs
        guard task == nil else { persist(); return }
        let recorded = installedAt
        let revisions = itemRevisions
        let fetch = fetch
        isChecking = true
        errorMessage = nil
        task = Task { [weak self] in
            do {
                // Reading each project.json's date is file-system work; it stays off the main actor.
                let (local, bases) = await Task.detached(priority: .utility) {
                    (Self.localVersions(ids, recorded: recorded, library: library), Self.presetBases(ids, library: library))
                }.value
                let asked = ids + Set(bases.values).subtracting(ids).sorted()
                let remote = asked.isEmpty ? [] : try await fetch(asked)
                self?.finish(Self.outdated(remote: remote, local: local, bases: bases), recorded: recorded, revisions: revisions)
            } catch {
                self?.fail(error)
            }
        }
    }

    /// Checks when automatic checks are on and the last check is a day old.
    func checkIfDue(installed: [String], library: URL) {
        guard checksAutomatically else { return }
        if let lastChecked, now().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        check(installed: installed, library: library)
    }

    /// Records that `id` was just downloaded, which makes it current.
    func recordInstalled(_ id: String) {
        installedIDs.insert(id)
        itemRevisions[id, default: 0] &+= 1
        installedAt[id] = now()
        available[id] = nil
        persist()
    }

    /// Drops wallpapers that left the library.
    func forget(_ ids: [String]) {
        for id in ids {
            installedIDs.remove(id)
            itemRevisions[id, default: 0] &+= 1
            installedAt[id] = nil
            available[id] = nil
        }
        persist()
    }

    /// The items whose Workshop version is newer than the one installed, and the presets (by
    /// `bases`, preset to base) whose base is.
    nonisolated static func outdated(remote: [WorkshopItem], local: [String: Date],
                                     bases: [String: String] = [:]) -> [String: WorkshopItem] {
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newer = { (id: String, installed: Date) -> Bool in
            guard let changed = byID[id]?.timeUpdated else { return false }
            return changed > installed.addingTimeInterval(tolerance)
        }
        var outdated: [String: WorkshopItem] = [:]
        for (id, installed) in local {
            guard let item = byID[id] else { continue }
            if newer(id, installed) || bases[id].map({ newer($0, installed) }) == true { outdated[id] = item }
        }
        return outdated
    }

    /// The base each installed preset names in its `project.json` (`dependency`), by the
    /// preset's id; wallpapers that are not presets are left out.
    nonisolated static func presetBases(_ ids: [String], library: URL) -> [String: String] {
        var bases: [String: String] = [:]
        for id in ids {
            let manifest = library.appendingPathComponent(id).appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: manifest),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let base = WallpaperImportService.workshopID(object["dependency"]), base != id
            else { continue }
            bases[id] = base
        }
        return bases
    }

    /// When each installed item was installed: recorded downloads first, then the date its
    /// `project.json` was last written. An item with neither is left out and never flagged.
    nonisolated static func localVersions(_ ids: [String], recorded: [String: Date], library: URL) -> [String: Date] {
        var versions: [String: Date] = [:]
        for id in ids {
            if let date = recorded[id] {
                versions[id] = date
            } else if let date = try? library.appendingPathComponent(id).appendingPathComponent("project.json")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            {
                versions[id] = date
            }
        }
        return versions
    }

    /// `recorded` is what the check compared against; an item downloaded while it ran is current.
    private func finish(_ outdated: [String: WorkshopItem], recorded: [String: Date], revisions: [String: UInt64]) {
        available = outdated.filter {
            installedIDs.contains($0.key)
                && itemRevisions[$0.key, default: 0] == revisions[$0.key, default: 0]
                && installedAt[$0.key] == recorded[$0.key]
        }
        lastChecked = now()
        isChecking = false
        task = nil
        AppLog.info("Workshop update check: \(available.count) of the installed items have updates")
        persist()
    }

    private func fail(_ error: Error) {
        errorMessage = String(localized: "Couldn’t check the Workshop for updates: \(error.localizedDescription)")
        isChecking = false
        task = nil
        AppLog.warn("Workshop update check failed: \(error.localizedDescription)")
    }

    private func persist() {
        defaults.set(installedAt.mapValues(\.timeIntervalSince1970), forKey: Self.installedKey)
        if let data = try? JSONEncoder().encode(available.values.sorted { $0.id < $1.id }) {
            defaults.set(data, forKey: Self.availableKey)
        }
        if let lastChecked {
            defaults.set(lastChecked.timeIntervalSince1970, forKey: Self.lastCheckedKey)
        }
    }
}
