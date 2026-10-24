import Darwin
import Foundation
import os

/// WallpaperMachine keeps imports separate from Steam's installation and never edits source wallpapers.
enum ClientPaths {
    static var supportURL: URL {
        if let override = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WallpaperMachine", isDirectory: true)
    }

    /// The folder that holds the library and the downloads (`StorageLocation`): the app-support
    /// folder unless they were moved. While a chosen folder is missing this is still that folder,
    /// never the app-support one, so nothing fills a new library on this Mac meanwhile; `prepare`
    /// refuses to start the library then.
    static var storageURL: URL {
        switch storageResolution {
        case .support: return supportURL
        case .chosen(let url): return url
        case .unavailable(let location?): return location.url
        // Nothing to name: a folder no one may write to, so nothing is created anywhere.
        case .unavailable(nil): return URL(fileURLWithPath: "/var/empty/WallpaperMachine", isDirectory: true)
        }
    }

    /// Read once per app-support folder (tests move it with `WALLPAPER_MACHINE_HOME`). The choice
    /// changes only at launch, before anything reads it, and `reloadStorageLocation` follows it.
    static var storageResolution: StorageLocation.Resolution {
        let support = supportURL.path
        return storageCache.withLock { cached in
            if let cached, cached.support == support { return cached.resolution }
            let resolution = StorageLocation.resolve(support: URL(fileURLWithPath: support, isDirectory: true))
            cached = (support, resolution)
            return resolution
        }
    }

    static func reloadStorageLocation() {
        storageCache.withLock { $0 = nil }
    }

    private static let storageCache = OSAllocatedUnfairLock<(support: String, resolution: StorageLocation.Resolution)?>(
        initialState: nil)

    static var libraryURL: URL { storageURL.appendingPathComponent("Library", isDirectory: true) }
    static var managedAssetsURL: URL { supportURL.appendingPathComponent("SceneAssets", isDirectory: true) }
    /// Where user-picked `file`/`directory` property assets are kept for good.
    ///
    /// Deliberately not under any directory named `Cache`, not inside `Library/`
    /// (the wallpaper library, which a re-download replaces) and not inside the
    /// Steam workshop tree, so deleting or re-downloading a wallpaper cannot take
    /// the user's imported files with it.
    static var userAssetsURL: URL { supportURL.appendingPathComponent("UserAssets", isDirectory: true) }
    static var assetsURL: URL {
        if let chosen = ClientPreferences.defaults.string(forKey: "WallpaperMachineAssetsPath"), !chosen.isEmpty {
            let url = URL(fileURLWithPath: chosen, isDirectory: true)
            if hasSceneAssets(at: url) { return url }
        }
        let steamInstall = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets", isDirectory: true)
        let supportCopy = supportURL
            .appendingPathComponent("Steam/steamapps/common/wallpaper_engine/assets", isDirectory: true)
        // None usable: the managed folder, so an install knows where to write.
        return [managedAssetsURL, steamInstall, supportCopy].first { hasSceneAssets(at: $0) } ?? managedAssetsURL
    }
    static var managedSteamCMDURL: URL { supportURL.appendingPathComponent("SteamCMD", isDirectory: true) }
    /// Performance data waiting to be sent, kept only while sending is on (docs/features/telemetry.md).
    static var telemetryURL: URL { supportURL.appendingPathComponent("Telemetry", isDirectory: true) }
    /// Everything below is rebuilt on demand, so it stays out of Time Machine.
    static var cacheURL: URL { supportURL.appendingPathComponent("Cache", isDirectory: true) }
    static var thumbnailCacheURL: URL { cacheURL.appendingPathComponent("WorkshopThumbnails", isDirectory: true) }
    static var pixivThumbnailCacheURL: URL { cacheURL.appendingPathComponent("PixivThumbnails", isDirectory: true) }
    /// Still covers of the installed wallpapers' own preview files, for the Installed grid.
    static var libraryThumbnailCacheURL: URL { cacheURL.appendingPathComponent("LibraryThumbnails", isDirectory: true) }
    /// The last poster of each wallpaper a desktop Space is set to, for desktops not visited yet.
    static var spacePosterCacheURL: URL { cacheURL.appendingPathComponent("SpacePosters", isDirectory: true) }
    /// The saved Steam sign-in. Kept out of backups so a token never travels to a backup drive.
    static func steamSessionURL(in support: URL = supportURL) -> URL {
        support.appendingPathComponent("SteamSession", isDirectory: true)
    }
    /// Partial downloads kept for later, with the queue that names them, beside the library so a
    /// resumed download lands on its disk. `Downloads/workshop-requests.json` is tiny, stays in
    /// app support and stays backed up.
    static func workshopDownloadsURL(in storage: URL = storageURL) -> URL {
        storage.appendingPathComponent("Downloads/Workshop", isDirectory: true)
    }

    static func prepare() throws {
        if case .unavailable(let location) = storageResolution { throw StorageUnavailableError(location: location) }
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        prepareExcludedFolders()
        installStarterWallpaper()
        setenv("WALLPAPER_MACHINE_SUPPORT_ROOT", supportURL.path, 1)
        setenv("WALLPAPER_MACHINE_LIBRARY_ROOT", libraryURL.path, 1)
        setenv("WALLPAPER_MACHINE_ASSETS_ROOT", assetsURL.path, 1)
        setenv("WALLPAPER_MACHINE_USER_ASSETS_ROOT", userAssetsURL.path, 1)
        setenv("WALLPAPER_MACHINE_BUILD", buildStamp(), 1)
    }

    /// Puts the bundled sample wallpaper into the library exactly once. The marker outlives the
    /// folder, so a user who deletes the sample never gets it back.
    private static func installStarterWallpaper(bundle: Bundle = .main) {
        let fileManager = FileManager.default
        let marker = libraryURL.appendingPathComponent(".starter-installed")
        let destination = libraryURL.appendingPathComponent("starter-aurora", isDirectory: true)
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            // An older library that has the folder but not the marker.
            try? Data().write(to: marker, options: .atomic)
            return
        }
        guard let resource = bundle.url(forResource: "StarterWallpaper", withExtension: nil) else { return }
        let pending = storageURL.appendingPathComponent(".starter-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: pending) }
        do {
            try fileManager.copyItem(at: resource, to: pending)
            try fileManager.moveItem(at: pending, to: destination)
            try? Data().write(to: marker, options: .atomic)
        } catch {
            AppLog.warn("could not install the starter wallpaper: \(error.localizedDescription)")
        }
    }

    /// Names the running build for the renderer's load journal, which releases
    /// every held wallpaper when the build changes: the code that crashed is gone.
    static func buildStamp(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    /// Keeps a folder (and so everything inside it) out of Time Machine and other backups of
    /// this Mac, for the Steam sign-in, partial downloads, staging and caches. The wallpaper
    /// library, imported files and scene assets are never passed here.
    ///
    /// The flag is only written when it is not already set, so calling this on every launch or
    /// after every replacement costs one read. A failure (a volume that has no such flag, a
    /// read-only folder) is logged and never stops the work the folder is for.
    @discardableResult
    static func excludeFromBackup(_ url: URL) -> Bool {
        // A fresh URL value: resource values are cached on the value that read them.
        let target = URL(fileURLWithPath: url.path)
        do {
            if try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true { return true }
            var flag = target
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try flag.setResourceValues(values)
            return true
        } catch {
            AppLog.warn("could not keep \(url.lastPathComponent) out of backups: \(error.localizedDescription)")
            return false
        }
    }

    /// Creates the disposable top-level folders and flags them, and flags the Steam sign-in and
    /// the partial downloads of an earlier version that are already there. Those two are only
    /// flagged where they exist: a folder is created by the work it is for, and is flagged then.
    /// Subfolders created later (the thumbnail caches) inherit the exclusion from `Cache`.
    static func prepareExcludedFolders() {
        for folder in [steamSessionURL(), workshopDownloadsURL()]
        where FileManager.default.fileExists(atPath: folder.path) {
            excludeFromBackup(folder)
        }
        do {
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        } catch {
            AppLog.warn("could not create the cache folder: \(error.localizedDescription)")
            return
        }
        excludeFromBackup(cacheURL)
    }

    static func hasSceneAssets(at url: URL) -> Bool {
        let required = ["shaders/genericimage2.vert", "shaders/genericimage2.frag",
                        "materials/util/effectpassthrough.json"]
        let fileManager = FileManager.default
        return required.allSatisfy { relative in
            let path = url.appendingPathComponent(relative).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else { return false }
            return fileManager.isReadableFile(atPath: path)
        }
    }

    static func configureAssetsFolder(at url: URL) throws {
        guard hasSceneAssets(at: url) else {
            throw WorkshopFailure(message: String(localized: "This folder does not contain Wallpaper Engine’s shared shaders and materials. Choose its complete assets folder, or install scene assets through Steam."))
        }
        ClientPreferences.defaults.set(url.path, forKey: "WallpaperMachineAssetsPath")
        setenv("WALLPAPER_MACHINE_ASSETS_ROOT", url.path, 1)
    }

    static func installSceneAssets(from source: URL, to destination: URL) throws {
        guard hasSceneAssets(at: source) else {
            throw WorkshopFailure(message: String(localized: "Steam did not produce complete scene assets. Confirm this account owns Wallpaper Engine and retry. Existing assets have not been changed."))
        }
        try Task.checkCancellation()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
        }
    }
}
