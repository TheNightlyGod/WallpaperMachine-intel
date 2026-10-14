import Darwin
import Foundation

/// WallpaperMachine keeps imports separate from Steam's installation and never edits source wallpapers.
enum ClientPaths {
    static var supportURL: URL {
        if let override = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WallpaperMachine", isDirectory: true)
    }

    static var libraryURL: URL { supportURL.appendingPathComponent("Library", isDirectory: true) }
    static var managedAssetsURL: URL { supportURL.appendingPathComponent("SceneAssets", isDirectory: true) }
    /// Where user-picked `file`/`directory` property assets are kept for good.
    ///
    /// Deliberately not under any directory named `Cache`, not inside `Library/`
    /// (the wallpaper library, which a re-download replaces) and not inside the
    /// Steam workshop tree, so deleting or re-downloading a wallpaper cannot take
    /// the user's imported files with it.
    static var userAssetsURL: URL { supportURL.appendingPathComponent("UserAssets", isDirectory: true) }
    static var assetsURL: URL {
        if let configured = ClientPreferences.defaults.string(forKey: "WallpaperMachineAssetsPath"), !configured.isEmpty {
            let url = URL(fileURLWithPath: configured, isDirectory: true)
            if hasSceneAssets(at: url) { return url }
        }
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets", isDirectory: true)
        let candidates = [managedAssetsURL, installed,
                          supportURL.appendingPathComponent("Steam/steamapps/common/wallpaper_engine/assets")]
        return candidates.first(where: { hasSceneAssets(at: $0) }) ?? managedAssetsURL
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
    /// The saved Steam sign-in. Kept out of backups so a token never travels to a backup drive.
    static func steamSessionURL(in support: URL = supportURL) -> URL {
        support.appendingPathComponent("SteamSession", isDirectory: true)
    }
    /// Partial downloads kept for later, with the queue that names them. Its sibling
    /// `Downloads/workshop-requests.json` is tiny and stays backed up.
    static func workshopDownloadsURL(in support: URL = supportURL) -> URL {
        support.appendingPathComponent("Downloads/Workshop", isDirectory: true)
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        prepareExcludedFolders()
        let starter = libraryURL.appendingPathComponent("starter-aurora", isDirectory: true)
        let starterMarker = supportURL.appendingPathComponent(".starter-installed")
        if !FileManager.default.fileExists(atPath: starterMarker.path),
           !FileManager.default.fileExists(atPath: starter.path),
           let bundled = Bundle.main.url(forResource: "StarterWallpaper", withExtension: nil) {
            let pending = supportURL.appendingPathComponent(".starter-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: pending) }
            try FileManager.default.copyItem(at: bundled, to: pending)
            try FileManager.default.moveItem(at: pending, to: starter)
        }
        // Remember installation so deleting the starter does not restore it on launch.
        if FileManager.default.fileExists(atPath: starter.path),
           !FileManager.default.fileExists(atPath: starterMarker.path) {
            try Data().write(to: starterMarker, options: .atomic)
        }
        setenv("WALLPAPER_MACHINE_SUPPORT_ROOT", supportURL.path, 1)
        setenv("WALLPAPER_MACHINE_LIBRARY_ROOT", libraryURL.path, 1)
        setenv("WALLPAPER_MACHINE_ASSETS_ROOT", assetsURL.path, 1)
        setenv("WALLPAPER_MACHINE_USER_ASSETS_ROOT", userAssetsURL.path, 1)
        setenv("WALLPAPER_MACHINE_BUILD", buildStamp(), 1)
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
        // These are referenced by the renderer's built-in image and effect materials.
        ["shaders/genericimage2.vert", "shaders/genericimage2.frag", "materials/util/effectpassthrough.json"].allSatisfy { path in
            let file = url.appendingPathComponent(path)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return false }
            return FileManager.default.isReadableFile(atPath: file.path)
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
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }
}
