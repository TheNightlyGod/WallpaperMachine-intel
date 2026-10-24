import Darwin
import Foundation

/// Makes one folder tree an exact copy of another for a library move (`StorageMoveService`):
/// what is missing or changed is copied, what is gone is removed, and a file that has the same size
/// and modification time is left alone, so a second pass over a finished copy only reads metadata.
///
/// Files are copied with their metadata (`copyfile`), so times survive and the next pass sees them
/// as unchanged; links and folders are recreated, and anything else (a socket, a pipe) is skipped.
/// Cancellation is honoured within a file, so a large video does not hold it up.
final class StorageCopier {
    private(set) var copiedBytes: Int64 = 0
    /// Whether an entry that disappears while it is read is skipped rather than failing the copy.
    private let tolerant: Bool
    private let onProgress: (Int64) -> Void
    private var reported: Int64 = 0
    /// Progress is passed on in steps of this many bytes, not once per chunk `copyfile` writes.
    private static let reportStep: Int64 = 8 * 1024 * 1024

    init(tolerant: Bool, onProgress: @escaping (Int64) -> Void = { _ in }) {
        self.tolerant = tolerant
        self.onProgress = onProgress
    }

    /// Mirrors `source` onto `destination`. A missing `source` removes `destination`.
    func mirror(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            let code = errno
            guard code == ENOENT else { throw Self.failure(code, source) }
            try removeIfPresent(destination)
            return
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            try ensureDirectory(destination)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: source.path)
            } catch where tolerant && !FileManager.default.fileExists(atPath: source.path) {
                return
            }
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            for name in names {
                try mirror(source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
            for extra in Set(existing).subtracting(names) {
                try FileManager.default.removeItem(at: destination.appendingPathComponent(extra))
            }
        case S_IFREG:
            guard !Self.matches(destination, info) else { return }
            try copyFile(source, to: destination, size: Int64(info.st_size))
        case S_IFLNK:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == target { return }
            try removeIfPresent(destination)
            try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        default:
            AppLog.warn("storage move: skipped \(source.path), which is neither a file, a folder nor a link")
        }
    }

    /// The bytes of the regular files under `roots`, for the progress bar and the free-space check.
    static func bytes(in roots: [URL]) -> Int64 {
        var total: Int64 = 0
        for root in roots {
            var info = stat()
            guard lstat(root.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFREG { total += Int64(info.st_size); continue }
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
            else { continue }
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: Entries

    /// Same size and the same modification time, to the microsecond `copyfile` keeps.
    private static func matches(_ destination: URL, _ source: stat) -> Bool {
        var info = stat()
        guard lstat(destination.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return info.st_size == source.st_size && info.st_mtimespec.tv_sec == source.st_mtimespec.tv_sec
            && info.st_mtimespec.tv_nsec / 1000 == source.st_mtimespec.tv_nsec / 1000
    }

    private func ensureDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            if info.st_mode & S_IFMT == S_IFDIR { return }
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func removeIfPresent(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Copies beside the destination and renames over it, so an interrupted copy never leaves a
    /// half-written file that a later pass would take for a finished one.
    private func copyFile(_ source: URL, to destination: URL, size: Int64) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            try FileManager.default.removeItem(at: destination)
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".wmcopy-\(UUID().uuidString)")
        defer { unlink(temporary.path) }
        let progress = CopyProgress(base: copiedBytes) { [unowned self] in report($0) }
        let context = Unmanaged.passRetained(progress)
        defer { context.release() }
        guard let state = copyfile_state_alloc() else { throw Self.failure(ENOMEM, source) }
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(Self.callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context.toOpaque())
        if copyfile(source.path, temporary.path, state, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)) != 0 {
            let code = errno
            if progress.cancelled { throw CancellationError() }
            if tolerant, !FileManager.default.fileExists(atPath: source.path) { return }
            throw Self.failure(code, source)
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw Self.failure(errno, destination) }
        copiedBytes += size
        report(copiedBytes)
    }

    private func report(_ bytes: Int64) {
        guard bytes - reported >= Self.reportStep else { return }
        reported = bytes
        onProgress(bytes)
    }

    private static func failure(_ code: Int32, _ url: URL) -> StorageMoveError {
        StorageMoveError(String(localized: "Could not copy “\(url.lastPathComponent)”: \(String(cString: strerror(code)))."))
    }

    /// Reports the bytes of the file being copied and stops when the task is cancelled. `copyfile`
    /// calls it on the copying thread, inside the task.
    private static let callback: copyfile_callback_t = { what, stage, state, _, _, context in
        guard let context else { return COPYFILE_CONTINUE }
        let progress = Unmanaged<CopyProgress>.fromOpaque(context).takeUnretainedValue()
        if Task.isCancelled {
            progress.cancelled = true
            return COPYFILE_QUIT
        }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                progress.report(progress.base + Int64(copied))
            }
        }
        return COPYFILE_CONTINUE
    }

    private final class CopyProgress {
        let base: Int64
        let report: (Int64) -> Void
        var cancelled = false

        init(base: Int64, report: @escaping (Int64) -> Void) {
            self.base = base
            self.report = report
        }
    }
}
