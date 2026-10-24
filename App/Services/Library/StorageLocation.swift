import Foundation

/// Where the wallpaper library and the downloads are kept: the app-support folder, or a folder the
/// user moved them to in Settings › Storage, such as one on an external drive.
///
/// The choice is a small file in the app-support folder, so it follows `WALLPAPER_MACHINE_HOME`
/// and is read before any preference or store. The chosen folder holds a marker with the same id:
/// a drive that is not connected, or another one mounted at the same path, is told apart from the
/// library itself, and nothing is created where the library is not.
struct StorageLocation: Codable, Equatable, Sendable {
    static let fileName = "StorageLocation.json"
    static let markerName = ".WallpaperMachineStorage"
    /// The folder created inside the one the user chooses.
    static let folderName = "WallpaperMachine"
    /// What lives in the storage root and moves with it, relative to it. Settings, sign-ins,
    /// caches, the files chosen for wallpapers and the download queue stay in app support.
    static let movedItems = ["Library", "Downloads/Workshop", "Downloads/Pixiv"]

    var path: String
    var id: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    enum Resolution: Equatable, Sendable {
        /// Nothing was moved: the library is in the app-support folder.
        case support
        /// The chosen folder, with its marker.
        case chosen(URL)
        /// A folder was chosen but is not there now (or not this library's). Nil when the record
        /// itself cannot be read.
        case unavailable(StorageLocation?)
    }

    static func recordURL(support: URL) -> URL { support.appendingPathComponent(fileName) }

    static func resolve(support: URL) -> Resolution {
        let file = recordURL(support: support)
        guard FileManager.default.fileExists(atPath: file.path) else { return .support }
        guard let data = try? Data(contentsOf: file),
              let location = try? JSONDecoder().decode(StorageLocation.self, from: data),
              location.path.hasPrefix("/"), !location.id.isEmpty else { return .unavailable(nil) }
        return marker(at: location.url) == location.id ? .chosen(location.url) : .unavailable(location)
    }

    /// Records `location`, or the app-support folder for nil. Atomic: a crash leaves the old
    /// choice or the new one.
    static func write(_ location: StorageLocation?, support: URL) throws {
        let file = recordURL(support: support)
        guard let location else {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(location).write(to: file, options: .atomic)
    }

    static func marker(at root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(markerName)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    static func writeMarker(_ id: String, at root: URL) throws {
        try Data(id.utf8).write(to: root.appendingPathComponent(markerName), options: .atomic)
    }
}

/// The library's drive is not connected: the app starts without its library instead of filling
/// a new, empty one on this Mac.
struct StorageUnavailableError: LocalizedError, Equatable {
    let location: StorageLocation?

    var errorDescription: String? {
        guard let location else {
            return String(localized: "WallpaperMachine could not read where your wallpaper library is kept.")
        }
        return String(localized: "Your wallpaper library is in “\(location.path)”, which is not available. Connect the drive that holds it, then quit and reopen WallpaperMachine. If it is connected, allow WallpaperMachine to use removable volumes in System Settings › Privacy & Security › Files and Folders.")
    }
}
