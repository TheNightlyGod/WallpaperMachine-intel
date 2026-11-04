import CryptoKit
import Foundation

/// What a display's poster shows: the wallpaper, the display, and a digest of everything else
/// that decides the picture (its placement and scaling, the screen, the wallpaper's saved
/// properties and settings, its files and the quality settings that change pixels). Two equal
/// looks are taken as the same picture, so whoever builds one must leave nothing out that can
/// change it; a look that cannot be told is nil, and nothing is reused for it.
struct DesktopPosterLook: Hashable, Sendable {
    var display: String
    var wallpaperID: String
    var digest: String

    /// `inputs` are named values; their order does not matter, and a name or value can never
    /// run into the next one.
    init(display: String, wallpaperID: String, inputs: [String: String]) {
        self.display = display
        self.wallpaperID = wallpaperID
        var hash = SHA256()
        for (name, value) in inputs.sorted(by: { $0.key < $1.key }) {
            for part in [name, value] {
                withUnsafeBytes(of: UInt64(part.utf8.count).littleEndian) { hash.update(bufferPointer: $0) }
                hash.update(data: Data(part.utf8))
            }
        }
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The settled poster each wallpaper last had on each display, kept so a wallpaper that comes
/// back (a playlist turning, switching back) gets the same picture at once instead of three new
/// captures. The same JPEG bytes give the same poster file name (`DesktopWallpaperLedger`), so a
/// return adds nothing to WallpaperAgent's cache, which keeps a full-size bitmap of every file a
/// desktop has shown and never deletes it ([desktop picture](docs/features/desktop-picture.md)).
///
/// One entry per display and wallpaper, replaced by the next settled poster of that pair, at
/// most `capacity` of them (the least recently used goes first), and none of a wallpaper that
/// left the library (`retain`). Entries hold only for this run: the folder is emptied when the
/// store is made, since a wallpaper's files or settings could have changed while the app was
/// not running to notice. Posters are read from disk when reused, not kept in memory.
@MainActor
final class DesktopSettledPosterStore {
    private struct Slot: Hashable {
        var display: String
        var wallpaperID: String
    }

    nonisolated static let defaultCapacity = 48

    private let folder: URL
    private let capacity: Int
    private let fileManager: FileManager
    /// What each slot's file holds: the look's digest and the poster's own hash.
    private var entries: [Slot: (look: String, poster: Data)] = [:]
    /// Slots from the least to the most recently used.
    private var recency: [Slot] = []

    /// Reused posters, counted since the store was made.
    private(set) var reuses = 0
    /// Settled posters written, counted since the store was made.
    private(set) var writes = 0

    init(folder: URL = ClientPaths.settledPosterCacheURL, capacity: Int = defaultCapacity,
         fileManager: FileManager = .default) {
        self.folder = folder
        self.capacity = max(1, capacity)
        self.fileManager = fileManager
        if let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == DesktopPosterEncoder.fileExtension {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// The settled poster of `look`'s wallpaper on its display, when the last one was taken with
    /// this same look. Nil otherwise, or when its file can no longer be read.
    func poster(for look: DesktopPosterLook) -> Data? {
        let slot = Slot(display: look.display, wallpaperID: look.wallpaperID)
        guard let entry = entries[slot], entry.look == look.digest else { return nil }
        guard let poster = try? Data(contentsOf: url(for: slot)), !poster.isEmpty,
              Data(SHA256.hash(data: poster)) == entry.poster else {
            forget(slot)
            return nil
        }
        touch(slot)
        reuses += 1
        return poster
    }

    /// Keeps `poster` as the settled poster of `look`, in place of the pair's last one.
    func store(_ poster: Data, for look: DesktopPosterLook) {
        let slot = Slot(display: look.display, wallpaperID: look.wallpaperID)
        let hash = Data(SHA256.hash(data: poster))
        if let entry = entries[slot], entry.look == look.digest, entry.poster == hash {
            touch(slot)
            return
        }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try poster.write(to: url(for: slot), options: .atomic)
        } catch {
            forget(slot)
            AppLog.warn("desktop poster: could not keep the settled poster of \(look.wallpaperID): \(error.localizedDescription)")
            return
        }
        entries[slot] = (look.digest, hash)
        touch(slot)
        writes += 1
        while recency.count > capacity, let oldest = recency.first { forget(oldest) }
    }

    /// Forgets the posters of every wallpaper not in `wallpaperIDs`, on disk too.
    func retain(wallpaperIDs: Set<String>) {
        for slot in entries.keys where !wallpaperIDs.contains(slot.wallpaperID) { forget(slot) }
    }

    var count: Int { entries.count }

    private func touch(_ slot: Slot) {
        recency.removeAll { $0 == slot }
        recency.append(slot)
    }

    private func forget(_ slot: Slot) {
        entries[slot] = nil
        recency.removeAll { $0 == slot }
        try? fileManager.removeItem(at: url(for: slot))
    }

    /// Named by a hash, since a wallpaper id is not guaranteed to be a safe file name; one file
    /// per display and wallpaper.
    private func url(for slot: Slot) -> URL {
        let digest = SHA256.hash(data: Data((slot.display + "\u{0}" + slot.wallpaperID).utf8))
        return folder.appendingPathComponent(
            digest.map { String(format: "%02x", $0) }.joined() + "." + DesktopPosterEncoder.fileExtension)
    }
}

extension DesktopPosterLook {
    /// The look of `wallpaperID` on physical display `display`, from the engine's snapshots; nil
    /// unless the display shows that wallpaper on its own (enabled, not mirroring) and the
    /// wallpaper is drawing: a scene Native Metal draws without a failure, or a web page or video
    /// whose host reports it ready. A scene still loading or held in a failure shows another
    /// picture, which must never be kept as this wallpaper's.
    ///
    /// The digest covers the display's placement and scaling, the screen's size and scale, the
    /// wallpaper's saved settings file (`wallpaperSettings`: properties, framing, engine options),
    /// its files (`contentRevision`), the quality settings that change pixels, and `extras` the
    /// caller adds (appearance, label languages, a web page's still-image placement).
    static func resolve(
        display: String, wallpaperID: String, kind: BridgeWallpaperKind?,
        settings: BridgeSettingsSnapshot, monitors: [BridgeMonitorInfoRow],
        hostPhase: HostWallpaperState.Phase?, screen: DesktopPosterLayout.Screen?,
        contentRevision: UInt64, wallpaperSettings: Data?, extras: [String: String] = [:],
        physicalDisplay: (BridgeDisplaySettingsRow) -> String?
    ) -> DesktopPosterLook? {
        guard !wallpaperID.isEmpty, let screen,
              let row = settings.displays.first(where: { physicalDisplay($0) == display }),
              row.isIndependent,
              let monitor = monitors.first(where: { $0.displayId == row.displayId }),
              monitor.wallpaperId == wallpaperID, monitor.mirrorTargetDisplayId == nil else { return nil }
        switch kind {
        case .projectScene:
            guard let id = UInt32(display), settings.sceneRenderers.contains(where: { scene in
                scene.displayId == id && scene.wallpaperId == wallpaperID && scene.backend != "unknown"
                    && scene.failureStage == nil
            }) else { return nil }
        case .webpage, .video:
            guard hostPhase == .ready else { return nil }
        case .unknown, nil:
            return nil
        }
        let quality = settings.sceneQuality
        var inputs = extras
        inputs["kind"] = String(describing: kind)
        inputs["scaling"] = "\(row.scalingMode) \(row.scalingFactor) \(monitor.scalingMode)"
        inputs["screen"] = "\(screen.frame.width)x\(screen.frame.height)@\(screen.scale)"
        inputs["renderScale"] = "\(settings.renderScale)"
        inputs["sceneResolution"] = settings.sceneResolution
        inputs["sceneQuality"] =
            "\(quality.msaa) \(quality.shadows) \(quality.volumetrics) \(quality.reflections) \(quality.postProcessing)"
        // Display framing joins the key only while it is on, so a key saved before the switch
        // existed still matches with it off and no poster is captured again for it.
        inputs["sceneSwitches"] = ([
            settings.metalfxUpscalingEnabled, settings.sceneOptimizationEnabled,
            settings.sceneOnDemandEnabled, settings.sceneVideoPlaneSamplingEnabled,
        ].map(String.init(describing:)) + (settings.sceneDisplayFramingEnabled ? ["framed"] : []))
            .joined(separator: " ")
        inputs["contentRevision"] = String(contentRevision)
        inputs["wallpaperSettings"] = wallpaperSettings.map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } ?? "none"
        return DesktopPosterLook(display: display, wallpaperID: wallpaperID, inputs: inputs)
    }
}
