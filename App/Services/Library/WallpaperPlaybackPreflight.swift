import Foundation

/// The checks a library wallpaper passes before any display changes to it: a video needs a
/// readable, non-empty file in a format something can play, a scene the shared Wallpaper
/// Engine resources, a web page its entry file. Other kinds pass.
enum WallpaperPlaybackPreflight {
    /// What keeps a wallpaper from playing, found before any display changes to it.
    enum Failure: LocalizedError, Equatable {
        case undecodableVideo
        case missingSceneAssets
        case missingWebEntry

        var errorDescription: String? {
            switch self {
            case .undecodableVideo:
                return String(localized: "This video cannot be decoded. Import a complete, playable video file before applying it.")
            case .missingSceneAssets:
                return String(localized: "This wallpaper is downloaded, but Wallpaper Engine’s shared scene resources are not installed. Choose Get shared resources in the wallpaper’s details, or go to Settings → Library & Steam.")
            case .missingWebEntry:
                return String(localized: "This web wallpaper’s entry page is missing. Import the complete project folder, including its HTML file, before applying it.")
            }
        }
    }

    /// Largest `project.json` read; a manifest is a few kilobytes, so anything bigger is not one.
    static let manifestByteLimit = 16 * 1024 * 1024

    /// The two fields of `project.json` the checks need, read leniently: a missing or non-string
    /// value is empty, which the checks treat as an unknown kind or a missing entry.
    struct Manifest: Equatable {
        /// `type`, lowercased.
        var kind: String
        /// `file`, relative to the project folder.
        var entry: String

        init(data: Data) throws {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            kind = (object["type"] as? String ?? "").lowercased()
            entry = object["file"] as? String ?? ""
        }

        /// Reads `project.json` in `folder`, refusing one larger than `manifestByteLimit`.
        init(folder: URL) throws {
            let url = folder.appendingPathComponent("project.json")
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > WallpaperPlaybackPreflight.manifestByteLimit {
                throw CocoaError(.fileReadTooLarge, userInfo: [NSURLErrorKey: url])
            }
            try self.init(data: Data(contentsOf: url))
        }
    }

    /// Throws a `Failure`, or the error reading or parsing `project.json`, when the wallpaper
    /// `wallpaperID` in `library` cannot be played. `videoFormat` reads a video file's format; one
    /// nothing plays is a `WallpaperActionError`, which the activation log records as refused.
    /// Before a scene, points the renderer at the shared resources it was checked against.
    @MainActor
    static func check(
        wallpaperID: String,
        library: URL = ClientPaths.libraryURL,
        videoFormat: (URL) async -> VideoFormatSupport.Verdict
    ) async throws {
        let folder = library.appendingPathComponent(wallpaperID, isDirectory: true)
        let manifest = try Manifest(folder: folder)
        switch manifest.kind {
        case "video":
            let file = folder.appendingPathComponent(manifest.entry)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard !manifest.entry.isEmpty, FileManager.default.isReadableFile(atPath: file.path),
                  values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else {
                throw Failure.undecodableVideo
            }
            // A format nothing can play is refused here, before any display changes.
            if let message = VideoFormatSupport.message(for: await videoFormat(file)) {
                throw WallpaperActionError(message: message)
            }
        case "scene":
            let assets = ClientPaths.assetsURL
            guard ClientPaths.hasSceneAssets(at: assets) else { throw Failure.missingSceneAssets }
            // Which folder `assetsURL` resolves to can change after launch (an install, a restored
            // backup, a chosen folder that went away), so the renderer is pointed at it again.
            ClientPaths.exportAssetsRoot(assets)
        case "web":
            guard !manifest.entry.isEmpty,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent(manifest.entry).path) else {
                throw Failure.missingWebEntry
            }
        default:
            break
        }
    }
}
