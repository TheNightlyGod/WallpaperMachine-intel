import Darwin
import Foundation

/// Moves the wallpaper library and the downloads (`StorageLocation.movedItems`) to another folder,
/// such as one on an external drive, or back into the app-support folder.
///
/// A move has two halves. `prepare` copies everything to the new folder while the app runs, so the
/// long part has a progress bar and can be cancelled; nothing the app uses changes. The next launch
/// (`applyPending`, before any store, preference or renderer opens the library) copies what changed
/// since, puts the copy in place, records the new folder and only then retires the old copy, which
/// is deleted in the background. Until that record is written the old library is untouched and
/// still in use, so a failure at any step leaves the app as it was. On one volume nothing is
/// copied: the launch renames the folders.
struct StorageMoveService: Sendable {
    static let pendingFileName = ".PendingStorageMove.json"
    static let failureFileName = ".StorageMoveFailure.json"
    static let retiredListName = ".RetiredStorage.json"
    /// The copy being prepared, inside the new storage root until the launch publishes it.
    static let stagingName = ".WallpaperMachineMove"
    /// An old copy waiting to be deleted, inside the root it was moved out of.
    static let retiredPrefix = ".WallpaperMachineMoved-"

    /// A prepared move, waiting for the next launch.
    struct Pending: Codable, Equatable, Sendable {
        /// The storage root the library is moved out of.
        var source: String
        /// The chosen folder; nil moves back into the app-support folder.
        var target: StorageLocation?
        /// Whether everything was copied to the target (another volume) or is renamed at launch.
        var copied: Bool
        var bytes: Int64
    }

    /// What `plan` checked and `prepare` carries out.
    struct Plan: Equatable, Sendable {
        let source: URL
        let targetRoot: URL
        let target: StorageLocation?
        /// What the library and the downloads hold now.
        let bytes: Int64
        let copies: Bool
    }

    struct Report: Equatable, Sendable {
        let target: StorageLocation?
    }

    let support: URL
    private let volumes: any StorageVolumeInspecting

    init(support: URL = ClientPaths.supportURL, volumes: any StorageVolumeInspecting = FileSystemVolumes()) {
        self.support = support
        self.volumes = volumes
    }

    // MARK: State

    var pending: Pending? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent(Self.pendingFileName)) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    /// Why the last launch could not finish a move, until another move is prepared or it is dismissed.
    var lastFailure: String? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent(Self.failureFileName)) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    func dismissFailure() {
        try? FileManager.default.removeItem(at: support.appendingPathComponent(Self.failureFileName))
    }

    // MARK: Planning

    /// Checks a move into a `WallpaperMachine` folder inside `parent`, or back into the app-support
    /// folder for nil, without changing anything.
    func plan(moveTo parent: URL?) throws -> Plan {
        let resolution = StorageLocation.resolve(support: support)
        let source: URL
        switch resolution {
        case .support: source = support
        case .chosen(let url): source = url
        case .unavailable: throw StorageMoveError(String(localized: "The current wallpaper library is not available, so it cannot be moved."))
        }
        guard pending == nil else {
            throw StorageMoveError(String(localized: "A move is already waiting for the next launch. Cancel it before choosing another folder."))
        }
        try requireNoInterruptedRestore()
        let targetRoot: URL
        let target: StorageLocation?
        if let parent {
            let folder = Self.canonical(parent)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw StorageMoveError(String(localized: "Choose a folder that exists."))
            }
            targetRoot = folder.appendingPathComponent(StorageLocation.folderName, isDirectory: true)
            guard !Self.contains(targetRoot, in: Self.canonical(support)), !Self.contains(targetRoot, in: Self.canonical(source)),
                  !Self.contains(Self.canonical(source), in: targetRoot) else {
                throw StorageMoveError(String(localized: "Choose a folder outside WallpaperMachine’s own folders."))
            }
            if FileManager.default.fileExists(atPath: targetRoot.path) {
                guard Self.isEmptyDirectory(targetRoot, allowing: [StorageLocation.markerName, Self.stagingName]) else {
                    throw StorageMoveError(String(localized: "“\(folder.path)” already has a folder named WallpaperMachine. Choose another folder, or move that one away first."))
                }
            }
            try checkVolume(of: folder)
            target = StorageLocation(path: targetRoot.path, id: UUID().uuidString)
        } else {
            guard case .chosen = resolution else {
                throw StorageMoveError(String(localized: "The wallpaper library is already on this Mac."))
            }
            targetRoot = support
            target = nil
            for item in StorageLocation.movedItems {
                let existing = support.appendingPathComponent(item)
                guard !FileManager.default.fileExists(atPath: existing.path) || Self.isEmptyDirectory(existing) else {
                    throw StorageMoveError(String(localized: "WallpaperMachine’s folder on this Mac already holds “\(item)”. Move it away, then try again."))
                }
            }
        }
        let bytes = StorageCopier.bytes(in: StorageLocation.movedItems.map { source.appendingPathComponent($0) })
        let sourceVolume = try volumes.volume(of: source)
        let targetVolume = try volumes.volume(of: target == nil ? support : targetRoot.deletingLastPathComponent())
        let copies = sourceVolume.identifier != targetVolume.identifier
        // What the copy needs, and room left for the downloads it is moved for.
        if copies, let available = targetVolume.availableBytes, available < bytes + Self.headroom(for: bytes) {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            throw StorageMoveError(String(localized: "Not enough free space: the library and downloads need about \(formatter.string(fromByteCount: bytes + Self.headroom(for: bytes))) and only \(formatter.string(fromByteCount: available)) is available there."))
        }
        return Plan(source: source, targetRoot: targetRoot, target: target, bytes: bytes, copies: copies)
    }

    /// A drive that holds the library must publish downloads by an exclusive rename and keep the
    /// hard links the files chosen for wallpapers use: APFS and Mac OS Extended do, ExFAT, FAT and
    /// network shares do not.
    private func checkVolume(of folder: URL) throws {
        let volume = try volumes.volume(of: folder)
        guard volume.isLocal else {
            throw StorageMoveError(String(localized: "Choose a folder on a disk connected to this Mac, not a network share."))
        }
        guard !volume.isReadOnly, FileManager.default.isWritableFile(atPath: folder.path) else {
            throw StorageMoveError(String(localized: "WallpaperMachine cannot write to this folder. Choose another one."))
        }
        guard volume.supportsExclusiveRenaming, volume.supportsHardLinks else {
            throw StorageMoveError(String(localized: "This disk’s format cannot hold the wallpaper library. Use a disk formatted as APFS or Mac OS Extended."))
        }
    }

    private static func headroom(for bytes: Int64) -> Int64 { max(512 * 1024 * 1024, bytes / 20) }

    /// A backup restore that stopped part-way is put right at the next launch from a journal that
    /// names where the library was; moving the library first would take it away from there.
    private func requireNoInterruptedRestore() throws {
        let transaction = support.appendingPathComponent(WallpaperBackupService.transactionDirectoryName)
        guard !FileManager.default.fileExists(atPath: transaction.path) else {
            throw StorageMoveError(String(localized: "A backup restore that did not finish is put right the next time you open WallpaperMachine. Move the library after that."))
        }
    }

    // MARK: Preparing

    /// Copies the library and the downloads to the plan's folder when it is on another volume, and
    /// records the move for the next launch. Cancelling removes what it copied. `progress` gets the
    /// bytes copied so far.
    func prepare(_ plan: Plan, progress: @escaping @Sendable (Int64) -> Void = { _ in }) throws {
        guard pending == nil else {
            throw StorageMoveError(String(localized: "A move is already waiting for the next launch. Cancel it before choosing another folder."))
        }
        dismissFailure()
        let staging = plan.targetRoot.appendingPathComponent(Self.stagingName, isDirectory: true)
        // What a copy that was cut short (the app quit while copying) left behind is started over.
        try? FileManager.default.removeItem(at: staging)
        do {
            if let target = plan.target {
                try FileManager.default.createDirectory(at: plan.targetRoot, withIntermediateDirectories: true)
                try StorageLocation.writeMarker(target.id, at: plan.targetRoot)
            }
            if plan.copies {
                // A live library can change while it is read: what goes missing meanwhile is left
                // to the launch, which copies the library once more as it is then.
                let copier = StorageCopier(tolerant: true, onProgress: progress)
                for item in StorageLocation.movedItems {
                    try copier.mirror(plan.source.appendingPathComponent(item), to: staging.appendingPathComponent(item))
                }
            }
            let record = Pending(source: plan.source.path, target: plan.target, copied: plan.copies, bytes: plan.bytes)
            try JSONEncoder().encode(record).write(to: support.appendingPathComponent(Self.pendingFileName), options: .atomic)
        } catch {
            Self.discardTarget(root: plan.targetRoot, target: plan.target, removeRoot: true)
            throw error
        }
    }

    /// Removes a prepared move and what it copied.
    func cancelPending() throws {
        guard let pending else { return }
        let root = pending.target?.url ?? support
        Self.discardTarget(root: root, target: pending.target, removeRoot: true)
        try FileManager.default.removeItem(at: support.appendingPathComponent(Self.pendingFileName))
    }

    /// Removes a prepared copy, and the chosen folder's marker and the folder itself when nothing
    /// else is in it. A drive that is not connected is left alone.
    private static func discardTarget(root: URL, target: StorageLocation?, removeRoot: Bool) {
        if let target, StorageLocation.marker(at: root) != target.id { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(stagingName, isDirectory: true))
        guard target != nil else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(StorageLocation.markerName))
        if removeRoot, isEmptyDirectory(root) { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Finishing at launch

    /// Finishes a prepared move. Called once, before anything reads the library. Nil when no move
    /// was waiting; a failure is recorded for Settings › Storage and leaves the library where it was.
    @discardableResult
    static func applyPending(support: URL = ClientPaths.supportURL) -> Result<Report, Error>? {
        let service = StorageMoveService(support: support)
        guard let pending = service.pending else {
            // An unreadable record cannot be finished; it must not wait forever either.
            let file = support.appendingPathComponent(pendingFileName)
            if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(pendingFileName))
            ClientPaths.reloadStorageLocation()
        }
        do {
            try service.finish(pending)
            return .success(Report(target: pending.target))
        } catch {
            AppLog.error("storage move: \(error.localizedDescription)")
            if let data = try? JSONEncoder().encode(error.localizedDescription) {
                try? data.write(to: support.appendingPathComponent(failureFileName), options: .atomic)
            }
            return .failure(error)
        }
    }

    private func finish(_ pending: Pending) throws {
        let source = URL(fileURLWithPath: pending.source, isDirectory: true)
        let root = pending.target?.url ?? support
        let current: URL? = switch StorageLocation.resolve(support: support) {
        case .support: support
        case .chosen(let url): url
        case .unavailable: nil
        }
        // The last launch committed and stopped before it could clear the record.
        if let current, Self.canonical(current) == Self.canonical(root), Self.canonical(root) != Self.canonical(source) {
            if pending.copied { retire(StorageLocation.movedItems, in: source) }
            return
        }
        guard let current, Self.canonical(current) == Self.canonical(source) else {
            Self.discardTarget(root: root, target: pending.target, removeRoot: true)
            throw StorageMoveError(String(localized: "The wallpaper library was not moved: it is no longer where the move started from."))
        }
        if let target = pending.target, StorageLocation.marker(at: root) != target.id {
            throw StorageMoveError(String(localized: "The wallpaper library was not moved: “\(target.path)” was not available. Connect the drive and choose the folder again."))
        }
        do {
            try requireNoInterruptedRestore()
        } catch {
            Self.discardTarget(root: root, target: pending.target, removeRoot: true)
            throw error
        }
        let staging = root.appendingPathComponent(Self.stagingName, isDirectory: true)
        var moves: [(from: URL, to: URL)] = []
        do {
            let from = pending.copied ? staging : source
            if pending.copied {
                // The library as it is now: what changed since the copy was prepared.
                let copier = StorageCopier(tolerant: false)
                for item in StorageLocation.movedItems {
                    try copier.mirror(source.appendingPathComponent(item), to: staging.appendingPathComponent(item))
                }
            }
            for item in StorageLocation.movedItems where FileManager.default.fileExists(atPath: from.appendingPathComponent(item).path) {
                let destination = root.appendingPathComponent(item)
                if Self.isEmptyDirectory(destination) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.rename(from.appendingPathComponent(item), to: destination)
                moves.append((from.appendingPathComponent(item), destination))
            }
            // The commit: from here on the library is the new one.
            try StorageLocation.write(pending.target, support: support)
        } catch {
            for move in moves.reversed() { try? Self.rename(move.to, to: move.from) }
            Self.discardTarget(root: root, target: pending.target, removeRoot: true)
            throw error
        }
        try? FileManager.default.removeItem(at: staging)
        if pending.copied { retire(StorageLocation.movedItems, in: source) }
        AppLog.info("storage move: the library is now in \(root.path)")
    }

    /// Moves the old copy aside in one rename per item, so what is left is never mistaken for a
    /// library, and lists it for `removeRetiredCopies`.
    private func retire(_ items: [String], in root: URL) {
        let retired = root.appendingPathComponent(Self.retiredPrefix + UUID().uuidString, isDirectory: true)
        for item in items where FileManager.default.fileExists(atPath: root.appendingPathComponent(item).path) {
            do {
                let destination = retired.appendingPathComponent(item)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.rename(root.appendingPathComponent(item), to: destination)
            } catch {
                AppLog.warn("storage move: the old \(item) stays in \(root.path): \(error.localizedDescription)")
            }
        }
        guard FileManager.default.fileExists(atPath: retired.path) else { return }
        var list = Self.retiredList(support: support)
        list.append(retired.path)
        Self.writeRetiredList(list, support: support)
    }

    /// Deletes the old copies a finished move left. Slow on a large library, so it runs in the
    /// background after launch; what it does not finish is deleted at a later launch.
    static func removeRetiredCopies(support: URL) {
        var remaining: [String] = []
        for path in retiredList(support: support) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            // Only ever a folder this type named; a drive that is not connected waits.
            guard url.lastPathComponent.hasPrefix(retiredPrefix) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
                remaining.append(path)
                continue
            }
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                AppLog.warn("storage move: could not delete the old copy in \(path): \(error.localizedDescription)")
                remaining.append(path)
            }
        }
        writeRetiredList(remaining, support: support)
    }

    private static func retiredList(support: URL) -> [String] {
        guard let data = try? Data(contentsOf: support.appendingPathComponent(retiredListName)),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    private static func writeRetiredList(_ list: [String], support: URL) {
        let file = support.appendingPathComponent(retiredListName)
        if list.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: Paths

    /// Renames without replacing: a folder already at `destination` is an error, never overwritten.
    private static func rename(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            throw StorageMoveError(String(localized: "Could not move “\(source.lastPathComponent)” into place: \(String(cString: strerror(code)))."))
        }
    }

    static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func contains(_ url: URL, in root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    /// A folder that holds nothing but Finder's `.DS_Store` and the names in `allowing`.
    private static func isEmptyDirectory(_ url: URL, allowing: Set<String> = []) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" || allowing.contains($0) }
    }
}

struct StorageMoveError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What a move needs to know about the disk holding a folder.
struct StorageVolume: Equatable, Sendable {
    var identifier: UInt64
    var isLocal: Bool
    var isReadOnly: Bool
    var supportsExclusiveRenaming: Bool
    var supportsHardLinks: Bool
    var availableBytes: Int64?
}

protocol StorageVolumeInspecting: Sendable {
    func volume(of url: URL) throws -> StorageVolume
}

struct FileSystemVolumes: StorageVolumeInspecting {
    func volume(of url: URL) throws -> StorageVolume {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw StorageMoveError(String(localized: "Could not read the disk that holds “\(url.path)”."))
        }
        // A fresh URL value: resource values are cached on the value that read them.
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeSupportsExclusiveRenamingKey, .volumeSupportsHardLinksKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        let important = values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        return StorageVolume(
            identifier: UInt64(UInt32(bitPattern: info.st_dev)),
            isLocal: values.volumeIsLocal ?? false,
            isReadOnly: values.volumeIsReadOnly ?? true,
            supportsExclusiveRenaming: values.volumeSupportsExclusiveRenaming ?? false,
            supportsHardLinks: values.volumeSupportsHardLinks ?? false,
            availableBytes: important ?? values.volumeAvailableCapacity.map(Int64.init))
    }
}
