import Foundation

/// A stamp for each installed wallpaper's preview file, which the Installed tiles' cover addresses
/// carry (`LibraryPreviewFetcher.coverStamp`). A cover is requested again only when its preview
/// changed, so a rescan that replaced nothing (every Workshop download, import and delete rescans)
/// leaves every tile's image alone.
///
/// Reading a stamp is a file system call, and the panel builds its snapshot many times a second,
/// so none is read on the snapshot path: `stamps(for:revision:)` answers from the cache and queues
/// whatever is missing, or everything again after a rescan, for a background pass. Then `onChange`
/// asks the panel for a fresh snapshot, but only if a stamp is new or moved. Until a wallpaper has
/// its stamp the snapshot offers no cover for it (and the page no image at all), so the tile
/// never loads a full-size preview while it waits.
@MainActor
final class LibraryCoverStamps {
    /// Called on the main actor after a pass found a preview that is new or changed.
    var onChange: (@MainActor () -> Void)?
    /// Moves whenever `stamps` gained or changed an entry; part of the panel's library section key.
    private(set) var contentRevision: UInt64 = 0
    private(set) var stamps: [String: UInt64] = [:]
    private var wanted: [String: URL] = [:]
    private var revision: UInt64?
    private var task: Task<Void, Never>?
    /// The request moved while a pass was reading, so that pass may have missed a file.
    private var stale = false

    /// What is known for the preview files `files` names, by wallpaper id. The ones that are not
    /// known yet, and all of them again when `revision` (the library was rescanned) moved, are
    /// read in the background; a replaced preview keeps its old stamp until the new one lands.
    func stamps(for files: [String: URL], revision: UInt64) -> [String: UInt64] {
        guard files != wanted || self.revision != revision else { return stamps }
        // A wallpaper that left, or whose preview moved, has nothing known.
        for id in Array(stamps.keys) where files[id] != wanted[id] { stamps[id] = nil }
        wanted = files
        self.revision = revision
        read()
        return stamps
    }

    /// Resolves once no pass is running or waiting, so a test never sleeps for one.
    func settled() async {
        while let task { await task.value }
    }

    private func read() {
        guard task == nil else {
            stale = true
            return
        }
        let files = wanted
        task = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [String: UInt64] in
                // A file that cannot be read is stamped 0: the panel offers its cover anyway, and
                // the page falls back to the preview file when none can be made.
                files.mapValues { LibraryPreviewFetcher.coverStamp(of: $0) ?? 0 }
            }.value
            self?.finish(found, for: files)
        }
    }

    private func finish(_ found: [String: UInt64], for files: [String: URL]) {
        task = nil
        var changed = false
        for (id, stamp) in found where wanted[id] == files[id] && stamps[id] != stamp {
            stamps[id] = stamp
            changed = true
        }
        if stale {
            stale = false
            read()
        }
        if changed {
            contentRevision &+= 1
            onChange?()
        }
    }
}
