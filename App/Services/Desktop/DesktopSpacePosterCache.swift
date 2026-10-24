import CryptoKit
import Foundation

/// The last poster each wallpaper got on each display (by its settings id), kept for the
/// desktops that follow desktop Spaces but are not on screen.
///
/// A poster is taken only from a wallpaper that plays, and only the current desktop plays, so a
/// desktop that has not been visited since launch (the quit put the person's own picture back),
/// or whose wallpaper was just chosen, would show something else in Mission Control and during
/// the swipe to it. This keeps one JPEG per display and wallpaper, the one the poster sync
/// accepted last, so those desktops get their own wallpaper's picture without anything loading.
///
/// It holds only wallpapers some desktop is set to: `retain` deletes the rest, from memory and
/// disk. Files are read once and kept in memory, about one poster per desktop.
@MainActor
final class DesktopSpacePosterCache {
    struct Key: Hashable {
        var display: String
        var wallpaperID: String
    }

    private let folder: URL
    private let fileManager: FileManager
    private var loaded: [Key: Data] = [:]
    /// Keys looked for on disk and not found, so a miss costs one look per launch.
    private var missing = Set<Key>()

    init(folder: URL = ClientPaths.spacePosterCacheURL, fileManager: FileManager = .default) {
        self.folder = folder
        self.fileManager = fileManager
    }

    func store(_ poster: Data, display: String, wallpaperID: String) {
        let key = Key(display: display, wallpaperID: wallpaperID)
        guard loaded[key] != poster else { return }
        loaded[key] = poster
        missing.remove(key)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try poster.write(to: url(for: key), options: .atomic)
        } catch {
            AppLog.warn("space posters: could not keep the poster of \(wallpaperID): \(error.localizedDescription)")
        }
    }

    func poster(display: String, wallpaperID: String) -> Data? {
        let key = Key(display: display, wallpaperID: wallpaperID)
        if let poster = loaded[key] { return poster }
        guard !missing.contains(key) else { return nil }
        guard let poster = try? Data(contentsOf: url(for: key)), !poster.isEmpty else {
            missing.insert(key)
            return nil
        }
        loaded[key] = poster
        return poster
    }

    /// Forgets every poster but those of `keys`, on disk too.
    func retain(_ keys: Set<Key>) {
        loaded = loaded.filter { keys.contains($0.key) }
        missing = missing.filter { keys.contains($0) }
        let kept = Set(keys.map { url(for: $0).lastPathComponent })
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jpg" && !kept.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Named by a hash, since a wallpaper id is not guaranteed to be a safe file name.
    private func url(for key: Key) -> URL {
        let digest = SHA256.hash(data: Data((key.display + "\u{0}" + key.wallpaperID).utf8))
        return folder.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".jpg")
    }
}
