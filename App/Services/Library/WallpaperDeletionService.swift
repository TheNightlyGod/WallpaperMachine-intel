import Foundation

enum WallpaperDeletionService {
    static func wallpaperURL(id: String, library: URL) throws -> URL {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else {
            throw failure(String(localized: "Invalid wallpaper ID. Nothing was deleted."))
        }
        let item = library.appendingPathComponent(id, isDirectory: true)
        let notManaged = String(localized: "This wallpaper is not a folder in the managed library. Nothing was deleted.")
        // A symbolic link is never followed: only a real directory directly inside the library qualifies.
        guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              item.resolvingSymlinksInPath().deletingLastPathComponent().path
                == library.resolvingSymlinksInPath().path else {
            throw failure(notManaged)
        }
        return item
    }

    static func moveToTrash(id: String, library: URL,
                            recycle: (URL) throws -> Void = { url in
                                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                            }) throws {
        try recycle(wallpaperURL(id: id, library: library))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WallpaperMachine.Deletion", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Outcome of a batch deletion; ids keep the order they were requested in.
struct WallpaperDeletionReport {
    var deleted: [String] = []
    var failures: [(id: String, error: Error)] = []
}
