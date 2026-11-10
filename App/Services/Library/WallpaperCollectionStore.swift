import Foundation

struct WallpaperCollection: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var name: String
    var wallpaperIDs: [String]
}

/// Local organizational metadata, independent of Workshop collections and display selection.
@MainActor
final class WallpaperCollectionStore {
    static let shared = WallpaperCollectionStore()
    nonisolated static let storageKey = "WallpaperMachine.collections"
    static let didChangeNotification = Notification.Name("WallpaperMachine.collectionsDidChange")

    private let defaults: UserDefaults
    private(set) var collections: [WallpaperCollection]
    /// Saved collections this build could not read, as they were saved (`PreservedJSON`).
    private var unread: [Data] = []

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        // A collection this build cannot read stays as it was saved and is written back with the others.
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { PreservedJSON.readArray($0, as: WallpaperCollection.self) }
        collections = saved?.values ?? []
        unread = saved?.unread ?? []
    }

    func collection(id: String) -> WallpaperCollection? {
        collections.first { $0.id == id }
    }

    @discardableResult
    func create(name: String, wallpaperIDs: [String] = []) throws -> WallpaperCollection {
        let collection = WallpaperCollection(
            id: UUID().uuidString, name: try Self.validatedName(name),
            wallpaperIDs: Self.unique(wallpaperIDs))
        try commit(collections + [collection])
        return collection
    }

    func rename(_ id: String, name: String) throws {
        var updated = collections
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw LibraryOrganizationError.missingCollection }
        updated[index].name = try Self.validatedName(name)
        try commit(updated)
    }

    func delete(_ id: String) throws {
        guard collection(id: id) != nil else { throw LibraryOrganizationError.missingCollection }
        try commit(collections.filter { $0.id != id })
    }

    /// A batch preserves request order; an existing membership never moves or duplicates.
    func add(_ ids: [String], to id: String) throws {
        var updated = collections
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw LibraryOrganizationError.missingCollection }
        updated[index].wallpaperIDs = Self.unique(updated[index].wallpaperIDs + ids)
        try commit(updated)
    }

    func remove(_ ids: [String], from id: String) throws {
        var updated = collections
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw LibraryOrganizationError.missingCollection }
        let removed = Set(ids)
        updated[index].wallpaperIDs.removeAll(where: removed.contains)
        try commit(updated)
    }

    func forget(_ ids: [String]) throws {
        let removed = Set(ids)
        var updated = collections
        for index in updated.indices {
            updated[index].wallpaperIDs.removeAll(where: removed.contains)
        }
        try commit(updated)
    }

    static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128,
            !trimmed.contains(where: { $0.isNewline || $0 == "\0" })
        else { throw LibraryOrganizationError.invalidName }
        return trimmed
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func commit(_ updated: [WallpaperCollection]) throws {
        guard updated != collections else { return }
        let data = try PreservedJSON.writeArray(updated, keeping: unread)
        defaults.set(data, forKey: Self.storageKey)
        collections = updated
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

enum LibraryOrganizationError: LocalizedError {
    case invalidName, missingCollection, missingPlan

    var errorDescription: String? {
        switch self {
        case .invalidName:
            String(localized: "Enter a name between 1 and 128 characters, on one line.")
        case .missingCollection:
            String(localized: "This collection no longer exists. Refresh the library and retry.")
        case .missingPlan:
            String(localized: "This playlist plan no longer exists. Refresh the library and retry.")
        }
    }
}
