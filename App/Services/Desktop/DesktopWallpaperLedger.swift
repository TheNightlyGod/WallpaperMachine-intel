import AppKit
import CryptoKit

struct DesktopPicture: Equatable, Codable {
    var url: URL
    var scaling: Int
    var allowClipping: Bool
    var fill: [Double]
    // Preserve the complete native per-Space configuration (including dynamic
    // wallpaper/slideshow options) rather than reconstructing it on restore.
    var nativeOptions: Data? = nil

    static func poster(_ url: URL) -> Self {
        // The poster already has the display's aspect ratio: fill the screen without scaling twice.
        Self(url: url, scaling: Int(NSImageScaling.scaleAxesIndependently.rawValue),
             allowClipping: false, fill: [0, 0, 0, 1])
    }

    var options: [NSWorkspace.DesktopImageOptionKey: Any] {
        var result: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: scaling),
            .allowClipping: NSNumber(value: allowClipping),
        ]
        if fill.count == 4 {
            result[.fillColor] = NSColor(srgbRed: fill[0], green: fill[1], blue: fill[2], alpha: fill[3])
        }
        return result
    }
}

/// A write was sent but does not read back yet. WallpaperAgent applies
/// per-Space selections asynchronously (about 0.3 s on macOS 27).
struct DesktopPictureUnconfirmed: Error {}

/// Tests use an in-memory workspace; no test changes the user's wallpaper.
@MainActor
protocol DesktopPictureWorkspace {
    func targets() throws -> [DesktopPictureTarget]
    func currentPicture(target: DesktopPictureTarget) throws -> DesktopPicture?
    func setPicture(_ picture: DesktopPicture, target: DesktopPictureTarget) throws
    /// Selections waiting for WallpaperAgent to reload may not be visible
    /// through the legacy picture API yet.
    func referencedPictureURLs(targets: [DesktopPictureTarget]) throws -> Set<URL>
    /// The macOS wallpaper store, or nil where there is none to put back.
    func storeContents() throws -> Data?
    /// Replaces the store if it still holds `expected`.
    func replaceStore(_ data: Data, expected: Data) throws
    /// Has WallpaperAgent load the store, which it reads only as it starts.
    func reloadStore() throws
}

extension DesktopPictureWorkspace {
    func storeContents() throws -> Data? { nil }
    func replaceStore(_ data: Data, expected: Data) throws {}
    func reloadStore() throws {}
}

@MainActor
final class DesktopWallpaperLedger {
    enum Failure: LocalizedError {
        case originalUnavailable
        /// macOS still names a poster in its wallpaper store.
        case restorationPending
        /// A desktop's restored wallpaper does not read back yet.
        case restorationUnconfirmed

        var errorDescription: String? {
            switch self {
            case .originalUnavailable:
                String(localized: "The original macOS wallpaper could not be recovered. Select your wallpaper again in System Settings.")
            case .restorationPending, .restorationUnconfirmed:
                String(localized: "macOS is still restoring the desktop wallpaper. Please try quitting again.")
            }
        }
    }

    /// Posters kept per display whose desktops could not all be seen or read.
    ///
    /// A desktop the public-API fallback cannot enumerate, one whose picture
    /// could not be read, or one on a disconnected display may still show a
    /// poster. It most plausibly shows one of the newest, so those stay and
    /// older ones are deleted rather than accumulating for as long as the
    /// display stays incomplete.
    static let retainedPostersPerIncompleteDisplay = 4

    /// Poster writes a desktop may refuse in a row before it is left alone.
    ///
    /// A refused write is retried for WallpaperAgent's asynchronous
    /// acknowledgement, and every snapshot starts that again. Some desktops
    /// never accept a poster; rewriting them on every snapshot logged the same
    /// refusal over a thousand times in one session. They are tried again
    /// after the next Space change or wake.
    static let refusalsBeforePause = 4
    private var refusals: [DesktopPictureTarget: Int] = [:]

    /// How long a poster write may stay unconfirmed before it counts as refused.
    static let confirmationWindow: Duration = .seconds(1)
    private let confirmationWindow: Duration
    private var unconfirmed: [DesktopPictureTarget: (url: URL, since: ContinuousClock.Instant)] = [:]
    /// Every poster file written without reading back, by when it was last
    /// written. WallpaperAgent copies a file some time after the write, so it
    /// stays for `confirmationWindow` even once a newer frame replaces it or
    /// its desktop stops receiving posters.
    private var inFlight: [URL: ContinuousClock.Instant] = [:]
    /// Desktops whose restoration did not read back in the last pass.
    private var unconfirmedRestorations = Set<DesktopPictureTarget>()
    /// Whether a poster write still waits to read back; the coordinator then
    /// synchronizes again after `confirmationWindow`, which also restores a
    /// late poster on a desktop that no longer receives them.
    var awaitsConfirmation: Bool { !unconfirmed.isEmpty || !inFlight.isEmpty }

    private static let journalName = "originals.json"
    private static let storeSnapshotName = "store-original.json"

    /// The wallpaper store as it was before the first poster, and every picture
    /// written back through the per-Space API since. That API cannot express an
    /// aerial or extension choice; see `DesktopWallpaperStoreRestoration`.
    private struct StoreSnapshot: Codable {
        var store: Data
        var written: [DesktopWallpaperStoreRestoration.Write] = []
        /// The store was put back but WallpaperAgent has not loaded it yet.
        var reloadPending: Bool? = nil
    }
    private var storeSnapshot: StoreSnapshot?
    private let storeSnapshotURL: URL

    /// What macOS shows a new user, through a link to the current release's
    /// picture. It is put back on a desktop whose original no longer exists
    /// when no other original does either.
    nonisolated static let systemDefaultPictureURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    private let systemDefaultPicture: URL
    /// What each desktop last got in place of a missing original, so a
    /// restoration that is retried logs it once.
    private var reportedStandIns: [DesktopPictureTarget: URL] = [:]

    private struct Entry: Codable {
        var original: DesktopPicture
        // nil for the previous alternating-file journal, which remains readable.
        var display: String?
    }
    private var entries: [String: Entry]
    private let folder: URL
    private let journal: URL
    private let workspace: any DesktopPictureWorkspace

    init(folder: URL, workspace: any DesktopPictureWorkspace,
         confirmationWindow: Duration = DesktopWallpaperLedger.confirmationWindow,
         systemDefaultPicture: URL = DesktopWallpaperLedger.systemDefaultPictureURL) throws {
        self.folder = folder
        self.workspace = workspace
        self.confirmationWindow = confirmationWindow
        self.systemDefaultPicture = systemDefaultPicture
        journal = folder.appendingPathComponent(Self.journalName)
        storeSnapshotURL = folder.appendingPathComponent(Self.storeSnapshotName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: journal.path) {
            // A journal that cannot be read must stop creation: writing posters without a way
            // back to the originals would strand the user's wallpaper.
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: journal))
        } else {
            entries = [:]
        }
        if FileManager.default.fileExists(atPath: storeSnapshotURL.path) {
            storeSnapshot = try JSONDecoder().decode(StoreSnapshot.self, from: Data(contentsOf: storeSnapshotURL))
        }
    }

    /// Whether the journal in `folder` still names a poster whose original has not been put back,
    /// so a crash, a relaunch or a switched-off preference may have left one on a desktop, or the
    /// store copy is still there: its selections, or WallpaperAgent's reload of them, may not be
    /// back yet. False for a missing, unreadable or empty journal and no store copy. Reads the
    /// files only; nothing is created.
    static func hasRecordedOriginals(in folder: URL) -> Bool {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(storeSnapshotName).path) {
            return true
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(journalName)),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return false }
        return !entries.isEmpty
    }

    /// Submit a fresh frame to EVERY desktop on its display, without a Space
    /// change event. A loading renderer keeps the previous poster until ready.
    ///
    /// `spacePosters` gives a display's desktops a picture of their own: a display that follows
    /// desktop Spaces sends the last poster of each desktop's wallpaper. A desktop outside
    /// `targetSpaces` takes only that; one inside it takes the fresh poster when there is one.
    func synchronize(posters: [String: Data], liveDisplays: Set<String>, targetSpaces: [String: Set<String>] = [:],
                     spacePosters: [String: [String: Data]] = [:]) throws {
        let targets = try workspace.targets()
        var firstError: Error?
        // Cache only within this pass: external edits/missing files must still
        // be detected on the next refresh. Retain no extra image buffers.
        var comparisons: [URL: Bool] = [:]
        let fallbacks = userWallpapers(targets: targets)
        // Found only once a desktop is put back, since it looks at the user's files.
        var restorable: [String: DesktopPicture]?
        let digests = posters.mapValues { Data(SHA256.hash(data: $0)) }
        var applied = Set<DesktopPictureTarget>(), restoring = Set<DesktopPictureTarget>()
        for target in targets {
            // A key with an empty set holds every Space on that display. The public
            // fallback has no identity and cannot safely accept a Space-specific poster.
            let otherDesktop = targetSpaces[target.display].map { allowed in target.space.map(allowed.contains) != true } ?? false
            // Only a display whose posters are scoped to its desktops takes saved ones.
            let ownPoster = targetSpaces[target.display] == nil ? nil
                : target.space.flatMap { spacePosters[target.display]?[$0] }
            if otherDesktop, ownPoster == nil { continue }
            let fresh = otherDesktop ? nil : posters[target.display]
            do {
                if let image = fresh ?? ownPoster, liveDisplays.contains(target.display) {
                    applied.insert(target)
                    let digest = fresh != nil ? digests[target.display]! : Data(SHA256.hash(data: image))
                    try apply(image: image, digest: digest, target: target,
                              comparisons: &comparisons, fallbacks: fallbacks)
                } else if !liveDisplays.contains(target.display) {
                    try restore(target: target) {
                        if let restorable { return restorable }
                        let found = userWallpapers(targets: targets, existing: true)
                        restorable = found
                        return found
                    }
                }
            } catch is DesktopPictureUnconfirmed {
                // `apply` handles its own unconfirmed writes, so this is a
                // restoration; the next pass reads it back.
                restoring.insert(target)
            } catch { if firstError == nil { firstError = error } }
        }
        unconfirmedRestorations = restoring
        // A desktop no longer receiving posters has nothing left to confirm;
        // its in-flight file stays until the window passes.
        unconfirmed = unconfirmed.filter { applied.contains($0.key) }
        let now = ContinuousClock.now
        inFlight = inFlight.filter { now - $0.value < confirmationWindow }
        // Pruned even when a desktop failed, or a failure that repeats on every
        // refresh would let posters pile up without bound. A desktop that
        // failed keeps what it shows: a readable picture is never deleted, and
        // an unreadable one leaves its display on the bounded retention.
        do { try removeUnreferencedPosters(targets: targets) } catch {
            if firstError == nil { firstError = error }
        }
        // Keep updating sibling Spaces/displays even when one native call fails.
        if let firstError { throw firstError }
    }

    /// A Space change or wake can make a refusing desktop accept posters again.
    func retryRefusedDesktops() {
        refusals.removeAll()
    }

    func restoreAll() throws {
        try synchronize(posters: [:], liveDisplays: [])
        // Until a restoration reads back, its desktop may still show a poster,
        // and a store without one does not prove otherwise. A poster write still
        // in flight can also land after its desktop was restored; the next pass
        // restores it, and the window ends well within quit's wait.
        guard unconfirmedRestorations.isEmpty, inFlight.isEmpty else { throw Failure.restorationUnconfirmed }
        let storeRestored = try restoreStore()
        let targets = try workspace.targets()
        guard try !workspace.referencedPictureURLs(targets: targets)
            .contains(where: { Self.isPoster($0, folder: folder) }) else {
            throw Failure.restorationPending
        }
        // A store that could not be read keeps its copy for the next restoration.
        if storeRestored, storeSnapshot != nil {
            try FileManager.default.removeItem(at: storeSnapshotURL)
            storeSnapshot = nil
        }
    }

    /// Once every desktop reads back without a poster, puts back the store
    /// selections the app replaced, including the aerial or extension choice
    /// the per-Space API could only write back as a still picture.
    /// A store written back but not yet loaded stays pending, so a retry or the
    /// next launch reloads it once rather than finding nothing left to change.
    /// False when there is a copy to put back but no store to read.
    private func restoreStore() throws -> Bool {
        guard var snapshot = storeSnapshot else { return true }
        guard let current = try workspace.storeContents() else { return false }
        if let restored = try DesktopWallpaperStoreRestoration.restored(
            current: current, original: snapshot.store, written: snapshot.written, posters: folder) {
            snapshot.reloadPending = true
            try save(snapshot)
            try workspace.replaceStore(restored, expected: current)
        }
        guard snapshot.reloadPending == true else { return true }
        try workspace.reloadStore()
        snapshot.reloadPending = nil
        try save(snapshot)
        return true
    }

    func apply(image: Data, target: DesktopPictureTarget) throws {
        var comparisons: [URL: Bool] = [:]
        try apply(image: image, digest: Data(SHA256.hash(data: image)), target: target,
                  comparisons: &comparisons, fallbacks: userWallpapers(targets: [target]))
    }

    private func apply(image: Data, digest: Data, target: DesktopPictureTarget,
                       comparisons: inout [URL: Bool], fallbacks: [String: DesktopPicture]) throws {
        guard refusals[target, default: 0] < Self.refusalsBeforePause else { return }
        guard let current = try workspace.currentPicture(target: target) else {
            throw NSError(domain: "DesktopWallpaperSync", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read the original wallpaper for display \(target.display), desktop \(target.space ?? "current"); poster synchronization was not applied."
            ])
        }
        if let pending = unconfirmed[target] {
            if current.url.standardizedFileURL == pending.url.standardizedFileURL {
                unconfirmed[target] = nil
                // Another Space's write of the same file keeps it by its own entry.
                inFlight[pending.url] = nil
                refusals[target] = nil
            } else if ContinuousClock.now - pending.since >= confirmationWindow {
                unconfirmed[target] = nil
                countRefusal(target)
                throw NSError(domain: "DesktopWallpaperSync", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "macOS has not accepted the wallpaper for desktop \(target.space ?? "current")."
                ])
            }
        }
        let owned = entry(for: current.url)
        var original = owned?.original ?? current
        if !Self.isUserWallpaper(original, folder: folder),
           let chosen = fallbacks[target.display] {
            original = chosen
        }
        // An empty legacy selection cannot undo a poster on modern macOS.
        // Keep live playback, but do not replace the system wallpaper unless
        // we have an actual original to put back on quit.
        guard Self.isUserWallpaper(original, folder: folder) else {
            throw Failure.originalUnavailable
        }
        if let owned, owned.original == original, owned.display == target.display {
            let matches: Bool
            if let cached = comparisons[current.url] { matches = cached }
            else {
                matches = (try? Data(contentsOf: current.url)) == image
                comparisons[current.url] = matches
            }
            if matches { refusals[target] = nil; return }
        } else if owned?.original == original, (try? Data(contentsOf: current.url)) == image {
            refusals[target] = nil
            return
        }
        // Never reuse a filename for different pixels: WallpaperAgent can cache
        // inactive-Space thumbnails by URL even after the file is overwritten.
        // Identical originals/frames may share an immutable file safely.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hash = SHA256()
        hash.update(data: Data(target.display.utf8))
        hash.update(data: try encoder.encode(original))
        // Hash large pixels once per display, not once per Space.
        hash.update(data: digest)
        // Posters from before the switch to JPEG keep their .png names until pruned.
        let name = "poster-" + hash.finalize().map { String(format: "%02x", $0) }.joined()
            + "." + DesktopPosterEncoder.fileExtension
        let url = folder.appendingPathComponent(name)
        // The same poster is still on its way; rewriting it would not land sooner.
        if unconfirmed[target]?.url == url { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try image.write(to: url, options: .atomic)
        }
        // The store as the user left it, before the first poster since the last full
        // restoration. A poster file journaled in an earlier run is written again under
        // its old name, so this cannot wait for a new journal entry.
        if storeSnapshot == nil, let store = try workspace.storeContents() {
            try save(StoreSnapshot(store: store))
        }
        if entries[name] == nil {
            entries[name] = Entry(original: original, display: target.display)
            // Journal BEFORE the native call, including crash/relaunch recovery.
            // Shared immutable files already have a durable entry.
            do { try save() }
            catch {
                entries.removeValue(forKey: name)
                throw error
            }
        }
        comparisons[url] = true
        do {
            try workspace.setPicture(.poster(url), target: target)
            refusals[target] = nil
        } catch is DesktopPictureUnconfirmed {
            let now = ContinuousClock.now
            unconfirmed[target] = (url, now)
            inFlight[url] = now
        } catch {
            countRefusal(target)
            throw error
        }
    }

    private func countRefusal(_ target: DesktopPictureTarget) {
        let count = refusals[target, default: 0] + 1
        refusals[target] = count
        if count == Self.refusalsBeforePause {
            AppLog.warn("macOS refused the wallpaper for display \(target.display), desktop \(target.space ?? "current") \(count) times in a row; its poster waits for the next Space change or wake")
        }
    }

    /// Puts back the wallpaper a desktop showed before its first poster. A
    /// desktop showing anything but a poster was changed outside this app and
    /// keeps that choice.
    ///
    /// Another app can delete a picture it set, and macOS refuses a file that
    /// does not exist, so writing such an original would fail on every attempt
    /// and refuse every quit. It gives way to the display's fallback and, when
    /// no original is left at all, to macOS's default picture.
    private func restore(target: DesktopPictureTarget, fallbacks: () -> [String: DesktopPicture]) throws {
        guard let current = try workspace.currentPicture(target: target),
              Self.isPoster(current.url, folder: folder) else { return }
        // A poster whose journal entry is gone is still ours, never the user's.
        let journaled = entry(for: current.url)?.original
        let named = journaled.flatMap { Self.isUserWallpaper($0, folder: folder) ? $0 : nil }
        if let named, Self.fileMayExist(named.url) {
            try recordWritten(named.url)
            try workspace.setPicture(named, target: target)
            return
        }
        let original: DesktopPicture
        let standIn: String
        if let chosen = fallbacks()[target.display] {
            (original, standIn) = (chosen, "another desktop's original")
        } else if named != nil, let systemDefault = systemDefault() {
            (original, standIn) = (systemDefault, "macOS's default picture")
        } else {
            throw Failure.originalUnavailable
        }
        if let named, reportedStandIns[target] != original.url {
            reportedStandIns[target] = original.url
            AppLog.warn("Desktop picture: the original of display \(target.display), desktop \(target.space ?? "current") no longer exists (\(named.url.path)); putting back \(standIn) \(original.url.path) instead")
        }
        try recordWritten(original.url)
        try workspace.setPicture(original, target: target)
    }

    /// macOS's default picture, as the file its link points to: a write is
    /// confirmed by reading its path back, which then names the same file
    /// whether or not macOS follows the link.
    private func systemDefault() -> DesktopPicture? {
        let url = systemDefaultPicture.resolvingSymlinksInPath()
        guard Self.fileMayExist(url) else { return nil }
        return DesktopPicture(url: url, scaling: Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                              allowClipping: true, fill: [0, 0, 0, 1])
    }

    /// Whether a picture's file may still be there. Only a definite "no such
    /// file" counts as gone: one the app may not look at, such as a file in a
    /// folder macOS's privacy protection covers, is still put back.
    private static func fileMayExist(_ url: URL) -> Bool {
        access(url.path, F_OK) == 0 || (errno != ENOENT && errno != ENOTDIR)
    }

    private func entry(for url: URL) -> Entry? {
        guard Self.isPoster(url, folder: folder) else { return nil }
        return entries[url.lastPathComponent]
    }

    private static func isPoster(_ url: URL, folder: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
    }

    /// Whether writing `picture` back shows a wallpaper the user chose. A
    /// poster does not, and neither does a pathless (inherited) selection:
    /// what it inherits from is replaced along with the desktop's own picture,
    /// so after quitting that desktop would keep showing a poster.
    private static func isUserWallpaper(_ picture: DesktopPicture, folder: URL) -> Bool {
        picture.url.isFileURL && !isPoster(picture.url, folder: folder)
    }

    /// Snapshot every display's effective wallpaper before the first write:
    /// setting a poster can also replace macOS's inherited/default selection.
    /// The public API can resolve an image even when the per-Space API is empty.
    /// `existing` also passes over pictures whose files are gone; only putting a
    /// desktop back needs that, so posters never look at the user's files.
    private func userWallpapers(targets: [DesktopPictureTarget], existing: Bool = false) -> [String: DesktopPicture] {
        let usable = { [folder] (picture: DesktopPicture) in
            Self.isUserWallpaper(picture, folder: folder) && (!existing || Self.fileMayExist(picture.url))
        }
        var originals: [String: DesktopPicture] = [:]
        for target in targets where originals[target.display] == nil {
            guard let current = try? workspace.currentPicture(target: target) else { continue }
            let candidate = entry(for: current.url)?.original ?? current
            if usable(candidate) {
                originals[target.display] = candidate
            }
        }
        let displays = Set(targets.map(\.display)).sorted()
        let journaled = entries.sorted { $0.key < $1.key }.map(\.value)
            .filter { usable($0.original) }
        for display in displays where originals[display] == nil {
            let visible = DesktopPictureTarget(display: display, space: nil)
            if let current = try? workspace.currentPicture(target: visible) {
                let candidate = entry(for: current.url)?.original ?? current
                if usable(candidate) {
                    originals[display] = candidate
                }
            }
            if originals[display] == nil {
                originals[display] = journaled.first { $0.display == display }?.original
            }
        }
        let fallback = displays.compactMap { originals[$0] }.first ?? journaled.first?.original
        for display in displays where originals[display] == nil {
            originals[display] = fallback
        }
        return originals
    }

    /// Deletes the posters no desktop can be showing.
    ///
    /// A display is complete when every desktop on it is a native Space whose
    /// picture was read; there, every poster none of them shows is unused and
    /// goes. Anywhere else an unseen desktop may still show one, so only posters
    /// older than the newest `retainedPostersPerIncompleteDisplay` go. A poster
    /// a readable desktop shows is never deleted, and entries of the legacy
    /// journal, which name no display, are left alone.
    private func removeUnreferencedPosters(targets: [DesktopPictureTarget]) throws {
        var targeted = Set<String>(), incomplete = Set<String>(), referenced = Set<String>()
        // A native-provider shutdown reloads WallpaperAgent asynchronously.
        // Its persisted poster is still in use even while the legacy API sees
        // an empty selection or an already-updated cache. Keep its original.
        for url in try workspace.referencedPictureURLs(targets: targets) where entry(for: url) != nil {
            referenced.insert(url.lastPathComponent)
        }
        // WallpaperAgent copies a poster some time after the write; deleting it
        // first makes the write fail as "no such file".
        for url in Set(inFlight.keys).union(unconfirmed.values.map(\.url)) where entry(for: url) != nil {
            referenced.insert(url.lastPathComponent)
        }
        for target in targets {
            targeted.insert(target.display)
            // The public-API fallback sees only the current Space.
            if target.space == nil { incomplete.insert(target.display) }
            guard let current = try? workspace.currentPicture(target: target) else {
                incomplete.insert(target.display)
                continue
            }
            if entry(for: current.url) != nil { referenced.insert(current.url.lastPathComponent) }
        }
        var byDisplay: [String: [String]] = [:]
        for (name, entry) in entries {
            guard let display = entry.display else { continue }
            byDisplay[display, default: []].append(name)
        }
        var obsolete: [String] = []
        for (display, names) in byDisplay {
            if targeted.contains(display) && !incomplete.contains(display) {
                obsolete += names.filter { !referenced.contains($0) }
                continue
            }
            let dated: [(name: String, date: Date)] = names.map { ($0, modificationDate(of: $0)) }
            let newestFirst: [String] = dated
                .sorted { (a, b) -> Bool in a.date != b.date ? a.date > b.date : a.name < b.name }
                .map { $0.name }
            obsolete += newestFirst.dropFirst(Self.retainedPostersPerIncompleteDisplay)
                .filter { !referenced.contains($0) }
        }
        var removed = false
        var firstError: Error?
        for name in obsolete {
            let url = folder.appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch {
                if firstError == nil { firstError = error }
                continue
            }
            entries.removeValue(forKey: name)
            removed = true
        }
        if removed { try save() }
        if let firstError { throw firstError }
    }

    /// When a poster file was last written; a missing file sorts oldest.
    private func modificationDate(of name: String) -> Date {
        let url = folder.appendingPathComponent(name)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    private func save() throws { try JSONEncoder().encode(entries).write(to: journal, options: .atomic) }

    private func save(_ snapshot: StoreSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: storeSnapshotURL, options: .atomic)
        storeSnapshot = snapshot
    }

    /// A picture written back is told apart from the same picture chosen in
    /// System Settings by this record of the write and its time, journaled
    /// before the write. A write of the same file moments after the last one
    /// is covered by that record.
    private func recordWritten(_ url: URL) throws {
        guard var snapshot = storeSnapshot else { return }
        let now = Date()
        if snapshot.written.contains(where: {
            $0.url == url && now.timeIntervalSince($0.at) < DesktopWallpaperStoreRestoration.writeTolerance.before
        }) { return }
        snapshot.written.append(.init(url: url, at: now))
        try save(snapshot)
    }
}
