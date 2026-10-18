import AppKit
import Darwin
import Foundation

/// The app-level view of managed user-asset storage: where it is, how to show it to
/// the user, and how to reclaim what nothing references any more.
///
/// The control panel's Storage row calls exactly these three. Everything else about
/// user assets goes through `UserAssetStore`, which is per-project and per-wallpaper.
@MainActor
enum UserAssetStorage {
    static var managedRootURL: URL { ClientPaths.userAssetsURL }
    static var managedRootPath: String { managedRootURL.path }

    /// Opens the managed directory in Finder, creating it first so the user is never
    /// shown an error for a folder they have simply not filled yet.
    static func revealManagedDirectory() {
        let url = managedRootURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        DesktopActions.current.reveal([url])
    }

    /// Deletes stored bytes that no manifest lists any more, and returns how many bytes
    /// that actually freed.
    ///
    /// Three kinds of leftover are reclaimed, all of them unreferenced by construction:
    /// a wallpaper folder with no manifest or an empty one, a property folder the
    /// manifest no longer mentions, and an `assetId` folder the property no longer
    /// lists. Anything a manifest still lists is never examined for deletion, so a
    /// property whose source file has gone missing keeps the copy that is now the only
    /// thing keeping it alive.
    @discardableResult
    nonisolated static func purgeUnreferencedDerivedCaches(
        store: ManagedUserAssetStore = ManagedUserAssetStore()
    ) async throws -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: store.root.path) else { return 0 }
        var released: Int64 = 0
        let wallpapers = try manager.contentsOfDirectory(
            at: store.root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        for wallpaper in wallpapers {
            guard (try? wallpaper.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let id = wallpaper.lastPathComponent
            guard id != WallpaperPresetStore.retainedDirectoryName else { continue }
            try Task.checkCancellation()
            do {
                released += try await store.withPreparation(wallpaperId: id) {
                    try purgeWallpaper(wallpaper, id: id, store: store, manager: manager)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.warn("User asset purge skipped \(id): \(error.localizedDescription)")
            }
        }
        return released
    }

    nonisolated private static func purgeWallpaper(_ wallpaper: URL, id: String,
        store: ManagedUserAssetStore, manager: FileManager) throws -> Int64 {
        var released: Int64 = 0
        let manifest = try store.manifest(wallpaperId: id)
        let referenced = manifest.properties.filter { !$0.value.assets.isEmpty }
        if referenced.isEmpty {
            released += remove(wallpaper, manager: manager)
            return released
        }
        let properties = (try? manager.contentsOfDirectory(
            at: wallpaper, includingPropertiesForKeys: [.isDirectoryKey],
            options: [])) ?? []
        for property in properties {
            guard (try? property.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            guard let record = referenced[property.lastPathComponent] else {
                released += remove(property, manager: manager)
                continue
            }
            let live = Set(record.assets.map(\.assetId))
            let stored = (try? manager.contentsOfDirectory(
                at: property, includingPropertiesForKeys: nil, options: [])) ?? []
            for entry in stored where !live.contains(entry.lastPathComponent) {
                released += remove(entry, manager: manager)
            }
        }
        return released
    }

    /// Bytes an unlink actually frees. A file another hard link still points at frees
    /// none, which is how every bridge entry on the same volume holds the store's copy.
    nonisolated private static func remove(_ url: URL, manager: FileManager) -> Int64 {
        let bytes = reclaimableBytes(at: url, manager: manager)
        guard (try? manager.removeItem(at: url)) != nil else { return 0 }
        return bytes
    }

    nonisolated private static func reclaimableBytes(at url: URL, manager: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return linkCount(url) > 1 ? 0 : Int64(values.fileSize ?? 0)
        }
        guard let enumerator = manager.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
            else { continue }
            guard linkCount(file) <= 1 else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    nonisolated private static func linkCount(_ url: URL) -> Int {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return 1 }
        return Int(status.st_nlink)
    }
}
