import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// The playable copies of video files the app keeps instead of changing the files themselves, in
/// `Cache/DerivedVideos`. One kind exists: an HEVC clip tagged `hev1` whose sample entries are
/// retagged `hvc1` (`HevcSampleEntryRetag`), which the desktop, the preview, a library poster and
/// the black-bar check read in its place.
///
/// The file in the library is never written: a Workshop update would undo the change, and the
/// file's hash, its backup and the update check would all see a different file. Where the cache
/// and the clip share an APFS volume the copy is a clone, which costs the one block that differs,
/// and is made at once. Elsewhere (a library on another drive, a volume that cannot clone) it is a
/// full copy, made in the background so that no metadata deadline and no reconcile pass waits for
/// it, and only while the full copies stay within `copyBudget` together and the cache's volume
/// (this Mac's startup disk, not the library's drive) keeps `freeSpaceReserve` free.
///
/// A copy is named after the file's path and `VideoFileStamp`, so a replaced file gets a new copy,
/// and is kept only once AVFoundation has said it plays. What it stands for is written on the copy
/// itself (an extended attribute), so a copy and its record appear together, in one move.
///
/// A copy is held (`Lease`) for as long as something reads it: a desktop surface, the preview, a
/// poster or a black-bar check. The cache never removes a copy that is held. Any other goes when
/// its file is replaced or gone, when the wallpaper is deleted (`removeCopies(under:)`), with
/// **Clear unused caches** (`removeUnused()`), and, least recently used first, beyond `capacity` or
/// to make room for a full copy. A file that played from a copy is never handed out without one:
/// once its copy has gone (its wallpaper's deletion included, should the folder come back from the
/// Trash), `playableFile(for:)` answers `.gone` and the copy is made again.
///
/// `copiesChanged` is posted when a full copy is finished (or has failed) and when copies were let
/// go, which is when a clip waiting for its copy, or for room for one, may now have it.
/// `progress(ofCopyOf:)` tells a caller that was answered `.copying` which it was: a full copy that
/// failed is not started again until it is asked for again.
final class DerivedVideoCache: @unchecked Sendable {
    static let shared = DerivedVideoCache()

    /// Posted on the default center, with the cache as the object, when a full copy was finished or
    /// failed and when held copies were let go or unused ones removed. Posted from whatever thread
    /// did it.
    static let copiesChanged = Notification.Name("WallpaperMachine.DerivedVideoCache.copiesChanged")

    enum Failure: Error, Equatable, LocalizedError {
        /// The file or the cache could not be read or written. Says nothing about the format.
        case unreadable(String)
        /// A full copy is being made in the background; `copiesChanged` says when it is done.
        case copying
        /// The copy has to be a full one, and it does not fit.
        case noRoomForCopy(NoRoom)
        /// The retagged copy does not play either.
        case notPlayable

        var errorDescription: String? {
            switch self {
            case let .unreadable(detail): return detail
            case .copying: return "its corrected copy is still being made"
            case .noRoomForCopy(.tooLarge): return "it is too large for a full corrected copy"
            case .noRoomForCopy(.notNow): return "there is no room for a full corrected copy now"
            case .notPlayable: return "its corrected copy does not play either"
            }
        }
    }

    /// Why a full copy does not fit.
    enum NoRoom: Error, Equatable, Sendable {
        /// The clip alone is larger than the budget for full copies: nothing that is cleared helps.
        case tooLarge
        /// The budget is taken by copies in use, or the startup disk would keep less than the
        /// reserve. Another moment may have room.
        case notNow
    }

    /// What a player reads for a file.
    enum PlayableFile {
        /// The file itself: nothing in this session made it a copy.
        case original
        /// Its copy, held until the lease is released.
        case copy(Lease)
        /// It plays only from a copy, and that copy has gone (cleared, made room for, removed with
        /// its wallpaper, or the file changed since): it is to be prepared again, never played as
        /// it is.
        case gone
    }

    /// Where the full copy of a file stands, for a caller that was answered `.copying`.
    enum CopyProgress: Equatable {
        /// Being made.
        case making
        /// This session has a copy for the file.
        case made
        /// The last full copy of the file failed (a read error, the file changed while it was
        /// copied), and none was started since. The next request for it starts another.
        case failed(Failure)
        /// None was asked for.
        case unknown
    }

    /// A hold on one copy, released by `release()` or when the lease goes. While any lease on a
    /// copy is open, the cache does not remove it.
    final class Lease: @unchecked Sendable {
        let url: URL
        private let lock = NSLock()
        private var onRelease: (@Sendable () -> Void)?

        fileprivate init(url: URL, onRelease: @escaping @Sendable () -> Void) {
            self.url = url
            self.onRelease = onRelease
        }

        func release() {
            let release = lock.withLock { () -> (@Sendable () -> Void)? in
                defer { onRelease = nil }
                return onRelease
            }
            release?()
        }

        deinit { release() }
    }

    /// What a copy stands for.
    private struct Record: Codable, Equatable {
        var source: String
        var size: Int
        /// A full copy rather than a clone: it holds its bytes on its own.
        var copied: Bool
    }

    private struct Entry {
        var file: String
        var name: String
        var record: Record
        var lastUsed: Date
    }

    /// A full copy being made in the background. Its fields change under the cache's lock.
    private final class Job: @unchecked Sendable {
        let source: String
        let size: Int64
        var task: Task<Void, Never>?
        var result: Result<URL, Failure>?
        var waiters: [UUID: CheckedContinuation<Result<URL, Failure>, Never>] = [:]

        init(source: String, size: Int64) {
            self.source = source
            self.size = size
        }
    }

    private static let recordAttribute = "com.wallpapermachine.derived-video"

    private let folder: @Sendable () -> URL
    private let capacity: Int
    private let copyBudget: Int64
    private let freeSpaceReserve: Int64
    private let clone: @Sendable (URL, URL) -> Int32
    private let availableCapacity: @Sendable (URL) -> Int64?
    private let verify: @Sendable (URL) async throws -> Bool
    /// Whether AVFoundation plays a file as it is, for `reading`: a macOS that decodes `hev1`
    /// needs no copy.
    private let playsAsItIs: @Sendable (URL) async -> Bool

    private let lock = NSLock()
    /// The copy each file plays from in this session (its name), by the file's path: what
    /// `playableFile(for:)` hands out. Not a hold.
    private var prepared: [String: String] = [:]
    /// How many leases are open on each copy, by its name.
    private var holds: [String: Int] = [:]
    /// The names of the clones being made (and by how many requests), whose unfinished files no
    /// sweep may take.
    private var building: [String: Int] = [:]
    /// The full copies being made in the background, by name.
    private var jobs: [String: Job] = [:]
    /// Copies that were made and did not play, by name: a verdict on that version of the file, so
    /// it is not copied again to find the same.
    private var unplayable: Set<String> = []
    /// Why the last full copy of each file failed, by the file's path, until another is started or
    /// one is made: what `progress(ofCopyOf:)` answers once its job has ended.
    private var copyFailures: [String: Failure] = [:]

    init(
        folder: @escaping @Sendable () -> URL = {
            ClientPaths.cacheURL.appendingPathComponent("DerivedVideos", isDirectory: true)
        },
        capacity: Int = 8,
        copyBudget: Int64 = 2 << 30,
        freeSpaceReserve: Int64 = 5 << 30,
        clone: @escaping @Sendable (URL, URL) -> Int32 = DerivedVideoCache.cloneFile,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = DerivedVideoCache.availableCapacity,
        verify: @escaping @Sendable (URL) async throws -> Bool = DerivedVideoCache.playsInAVFoundation,
        playsAsItIs: @escaping @Sendable (URL) async -> Bool = {
            (try? await DerivedVideoCache.playsInAVFoundation($0)) == true
        }
    ) {
        self.folder = folder
        self.capacity = capacity
        self.copyBudget = copyBudget
        self.freeSpaceReserve = freeSpaceReserve
        self.clone = clone
        self.availableCapacity = availableCapacity
        self.verify = verify
        self.playsAsItIs = playsAsItIs
    }

    // MARK: - Asking for a copy

    /// The retagged copy of `source`, unless one for this version of the file exists. A clone is
    /// made on the caller's task. A full copy is made in the background: with `waiting` the caller
    /// waits for it (giving up when its task is cancelled, while the copy goes on), and without, the
    /// answer is `.copying` at once and `copiesChanged` follows when the copy is done.
    func prepare(
        source: URL, plan: HevcSampleEntryRetag.Plan, waiting: Bool = true
    ) async -> Result<URL, Failure> {
        let source = source.standardizedFileURL
        let stamp: VideoFileStamp
        do { stamp = try VideoFileStamp(url: source) } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        let folder = self.folder()
        let manager = FileManager.default
        do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        let name = Self.name(path: source.path, stamp: stamp)
        let suffix = "." + Self.fileExtension(of: source)
        let copy = folder.appendingPathComponent(name + suffix)
        if manager.fileExists(atPath: copy.path) {
            lock.withLock { remember(source.path, as: name) }
            try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)
            return .success(copy)
        }

        enum Next { case refused, job(Job), made, make }
        let next = lock.withLock { () -> Next in
            if unplayable.contains(name) { return .refused }
            if let job = jobs[name] { return .job(job) }
            // A full copy is in place before its job ends: one that ended since the look above left it.
            if manager.fileExists(atPath: copy.path) {
                remember(source.path, as: name)
                return .made
            }
            building[name, default: 0] += 1
            return .make
        }
        switch next {
        case .refused: return .failure(.notPlayable)
        case .made: return .success(copy)
        case let .job(job): return waiting ? await wait(for: job) : .failure(.copying)
        case .make: break
        }
        let temporary = folder.appendingPathComponent(".\(name)-\(UUID().uuidString)\(suffix)")
        defer {
            try? manager.removeItem(at: temporary)
            lock.withLock {
                building[name, default: 1] -= 1
                if building[name] == 0 { building.removeValue(forKey: name) }
            }
        }
        let kept = sweep(folder, making: true).kept
        let cloneError = clone(source, temporary)
        if cloneError == 0 {
            return await finish(
                source: source, stamp: stamp, plan: plan, temporary: temporary, copy: copy, name: name,
                copied: false)
        }
        guard [EXDEV, ENOTSUP, EOPNOTSUPP].contains(cloneError) else {
            return .failure(.unreadable(String(cString: strerror(cloneError))))
        }
        switch startFullCopy(
            source: source, stamp: stamp, plan: plan, copy: copy, name: name, among: kept, in: folder)
        {
        case let .failure(noRoom):
            let message = "native video: \(source.lastPathComponent) is HEVC tagged hev1 and cannot be "
                + "cloned here; a full copy retagged hvc1 would not fit"
            // A clip with no room now is asked again whenever copies change; the host says it once.
            if noRoom == .tooLarge { AppLog.warn(message + " at all") } else { AppLog.debug(message + " now") }
            return .failure(.noRoomForCopy(noRoom))
        case let .success(job):
            return waiting ? await wait(for: job) : .failure(.copying)
        }
    }

    /// What a player reads for `source`: its copy, held for the caller, when this session made the
    /// file one; `.gone` when that copy is no longer there for this version of the file; the file
    /// itself otherwise. Reads nothing for a file that never needed a copy.
    func playableFile(for source: URL) -> PlayableFile {
        let source = source.standardizedFileURL
        guard let name = lock.withLock({ prepared[source.path] }) else { return .original }
        guard let stamp = try? VideoFileStamp(url: source), Self.name(path: source.path, stamp: stamp) == name
        else { return .gone }
        let copy = folder().appendingPathComponent(name + "." + Self.fileExtension(of: source))
        // Looked for and held in one step: nothing in the cache removes a copy while it holds the lock.
        let held = lock.withLock { () -> Bool in
            guard prepared[source.path] == name, FileManager.default.fileExists(atPath: copy.path) else {
                return false
            }
            holds[name, default: 0] += 1
            return true
        }
        guard held else { return .gone }
        return .copy(Lease(url: copy) { [weak self] in self?.release(name) })
    }

    /// Where the full copy of `source` stands: being made, made, failed with none started since, or
    /// never asked for. Reads nothing from the disk, so it may be asked on the main actor about a
    /// file on a volume that does not answer.
    func progress(ofCopyOf source: URL) -> CopyProgress {
        let path = source.standardizedFileURL.path
        return lock.withLock {
            if jobs.values.contains(where: { $0.source == path }) { return .making }
            if let failure = copyFailures[path] { return .failed(failure) }
            return prepared[path] != nil ? .made : .unknown
        }
    }

    /// Runs `read` on a file AVFoundation can open for `source`: the file itself, or, for an HEVC
    /// clip tagged `hev1` that AVFoundation refuses as it is and a retag makes playable, its copy,
    /// held while `read` runs (a full copy is waited for). With `keepingCopy` false, a copy made
    /// only for this read is removed after it, as for a file that is about to move (an import's
    /// staging copy).
    func reading<T>(
        _ source: URL, keepingCopy: Bool = true, _ read: (URL) async throws -> T
    ) async throws -> T {
        guard case let .retag(plan)? = try? HevcSampleEntryRetag.inspect(url: source) else {
            return try await read(source)
        }
        // The format check's rule: only a file AVFoundation refuses is read from a copy.
        if await playsAsItIs(source) { return try await read(source) }
        let path = source.standardizedFileURL.path
        let known = lock.withLock { prepared[path] != nil }
        if case let .failure(failure) = await prepare(source: source, plan: plan, waiting: true) {
            try Task.checkCancellation()
            throw failure
        }
        guard case let .copy(lease) = playableFile(for: source) else {
            throw Failure.unreadable("the corrected copy was removed as it was opened")
        }
        defer {
            lease.release()
            if !keepingCopy, !known { discard(path) }
        }
        return try await read(lease.url)
    }

    /// Forgets that `source` plays from a copy, for a file that was judged again and needs none
    /// (one replaced by a file that plays as it is).
    func forget(_ source: URL) {
        let path = source.standardizedFileURL.path
        lock.withLock { _ = prepared.removeValue(forKey: path) }
    }

    // MARK: - Removing copies

    /// Removes the copies of files inside `directory`, a wallpaper that was deleted, and stops the
    /// full copies of them being made. A file there that played from a copy still plays only from
    /// one: should the folder come back from the Trash, its copy is `.gone` and made again.
    func removeCopies(under directory: URL) {
        // The folder as named and with its links resolved (`/var` is `/private/var`).
        let prefixes = Set([directory.standardizedFileURL, directory.resolvingSymlinksInPath()].map { $0.path + "/" })
        let inside = { (path: String) in prefixes.contains { path.hasPrefix($0) } }
        let stopped = lock.withLock { () -> [Task<Void, Never>] in
            jobs.values.filter { inside($0.source) }.compactMap(\.task)
        }
        stopped.forEach { $0.cancel() }
        let folder = self.folder()
        for entry in entries(in: folder) where inside(entry.record.source) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.file))
        }
    }

    /// Removes every copy nothing holds now, and every copy whose file was replaced or deleted that
    /// nothing holds either. Returns the bytes that freed: a clone's are shared with its file, so
    /// only full copies count.
    @discardableResult
    func removeUnused() -> Int64 {
        let folder = self.folder()
        let (kept, stale) = sweep(folder, making: false)
        var removed = stale
        for entry in kept where remove(entry, in: folder) { removed.append(entry) }
        if !removed.isEmpty { NotificationCenter.default.post(name: Self.copiesChanged, object: self) }
        return removed.filter(\.record.copied).reduce(Int64(0)) { $0 + Int64($1.record.size) }
    }

    // MARK: - Full copies

    /// Takes room for a full copy of `source` and starts it in the background: within the budget
    /// for full copies (those being made count), once the least recently used ones nothing holds
    /// are removed, and with the reserve left free on the cache's volume. Both are checked before
    /// anything is removed, so a copy that would not fit takes no other copy with it. The job of
    /// the same copy, when another request started it meanwhile.
    private func startFullCopy(
        source: URL, stamp: VideoFileStamp, plan: HevcSampleEntryRetag.Plan, copy: URL, name: String,
        among kept: [Entry], in folder: URL
    ) -> Result<Job, NoRoom> {
        let size = Int64(stamp.size)
        guard size <= copyBudget else { return .failure(.tooLarge) }
        let copies = kept.filter(\.record.copied).sorted { $0.lastUsed < $1.lastUsed }
        var used = copies.reduce(Int64(0)) { $0 + Int64($1.record.size) }
        let (reserved, held) = lock.withLock {
            (jobs.values.reduce(Int64(0)) { $0 + $1.size }, Set(holds.keys))
        }
        // What would go, and what that frees on the startup disk, decided before anything goes.
        var evicting: [Entry] = []
        var freeing: Int64 = 0
        for entry in copies where !held.contains(entry.name) && used - freeing + reserved + size > copyBudget {
            evicting.append(entry)
            freeing += Int64(entry.record.size)
        }
        guard let measured = availableCapacity(folder),
            used - freeing + reserved + size <= copyBudget,
            measured + freeing - reserved - size >= freeSpaceReserve
        else { return .failure(.notNow) }
        var freed: Int64 = 0
        for entry in evicting where remove(entry, in: folder) {
            used -= Int64(entry.record.size)
            freed += Int64(entry.record.size)
        }
        let available = measured + freed
        let started = lock.withLock { () -> Result<Job, NoRoom> in
            if let job = jobs[name] { return .success(job) }
            let reserved = jobs.values.reduce(Int64(0)) { $0 + $1.size }
            guard used + reserved + size <= copyBudget, available - reserved - size >= freeSpaceReserve
            else { return .failure(.notNow) }
            let job = Job(source: source.path, size: size)
            jobs[name] = job
            copyFailures.removeValue(forKey: source.path)
            job.task = Task.detached(priority: .utility) { [self] in
                let temporary = folder.appendingPathComponent(".\(name)-\(UUID().uuidString)." + copy.pathExtension)
                let result: Result<URL, Failure>
                do {
                    try Self.copyBytes(from: source, to: temporary)
                    result = await finish(
                        source: source, stamp: stamp, plan: plan, temporary: temporary, copy: copy, name: name,
                        copied: true)
                } catch is CancellationError {
                    result = .failure(.unreadable("the copy was stopped"))
                } catch {
                    result = .failure(.unreadable(error.localizedDescription))
                }
                // Gone before the copy is said to be done, so nothing it left is seen then.
                try? FileManager.default.removeItem(at: temporary)
                complete(job, name: name, with: result)
            }
            return .success(job)
        }
        return started
    }

    /// Ends `job`: its waiters are answered, and a failure is kept for `progress(ofCopyOf:)`, so a
    /// caller told `.copying` learns of it instead of starting the same copy again. A copy that
    /// does not play is not kept there: it is a verdict on the file, which the next request is
    /// given (`unplayable`).
    private func complete(_ job: Job, name: String, with result: Result<URL, Failure>) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Result<URL, Failure>, Never>] in
            job.result = result
            if jobs[name] === job {
                jobs.removeValue(forKey: name)
                switch result {
                case let .failure(failure) where failure != .notPlayable: copyFailures[job.source] = failure
                default: copyFailures.removeValue(forKey: job.source)
                }
            }
            defer { job.waiters.removeAll() }
            return Array(job.waiters.values)
        }
        if case let .failure(failure) = result, failure != .notPlayable {
            AppLog.warn(
                "native video: the full copy of \(URL(fileURLWithPath: job.source).lastPathComponent) "
                    + "retagged hvc1 was not made: \(failure.localizedDescription)")
        }
        waiters.forEach { $0.resume(returning: result) }
        NotificationCenter.default.post(name: Self.copiesChanged, object: self)
    }

    /// The result of `job`, or an unreadable failure as soon as the caller's task is cancelled.
    private func wait(for job: Job) async -> Result<URL, Failure> {
        let id = UUID()
        let cancelled = Result<URL, Failure>.failure(.unreadable("the wait for the copy was cancelled"))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, Failure>, Never>) in
                let ready = lock.withLock { () -> Result<URL, Failure>? in
                    if let result = job.result { return result }
                    if Task.isCancelled { return cancelled }
                    job.waiters[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            lock.withLock { job.waiters.removeValue(forKey: id) }?.resume(returning: cancelled)
        }
    }

    /// Retags, checks and puts in place a clone or a full copy of `source` at `temporary`.
    private func finish(
        source: URL, stamp: VideoFileStamp, plan: HevcSampleEntryRetag.Plan, temporary: URL, copy: URL,
        name: String, copied: Bool
    ) async -> Result<URL, Failure> {
        let manager = FileManager.default
        guard (try? VideoFileStamp(url: source)) == stamp else {
            return .failure(.unreadable("the file changed while it was copied"))
        }
        do { try HevcSampleEntryRetag.apply(plan, to: temporary) } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        do {
            guard try await verify(temporary) else {
                lock.withLock { _ = unplayable.insert(name) }
                return .failure(.notPlayable)
            }
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        do {
            try Self.write(Record(source: source.path, size: stamp.size, copied: copied), on: temporary)
            if !manager.fileExists(atPath: copy.path) { try manager.moveItem(at: temporary, to: copy) }
        } catch {
            // A copy made at the same moment by another request is as good as this one.
            guard manager.fileExists(atPath: copy.path) else {
                return .failure(.unreadable(error.localizedDescription))
            }
        }
        lock.withLock { remember(source.path, as: name) }
        AppLog.info(
            "native video: \(source.lastPathComponent) is HEVC tagged hev1; it plays from "
                + (copied ? "a full copy (\(stamp.size) bytes)" : "a clone") + " retagged hvc1")
        return .success(copy)
    }

    // MARK: - Housekeeping

    /// Records that the file at `path` plays from the copy `name`. Called under the lock.
    private func remember(_ path: String, as name: String) {
        prepared[path] = name
        copyFailures.removeValue(forKey: path)
    }

    private func release(_ name: String) {
        let freed = lock.withLock { () -> Bool in
            guard let count = holds[name] else { return false }
            if count > 1 {
                holds[name] = count - 1
                return false
            }
            holds.removeValue(forKey: name)
            return true
        }
        if freed { NotificationCenter.default.post(name: Self.copiesChanged, object: self) }
    }

    /// Removes the copy of `entry` unless it is held, deciding and removing in one step. True when
    /// it went.
    @discardableResult
    private func remove(_ entry: Entry, in folder: URL) -> Bool {
        lock.withLock {
            guard holds[entry.name] == nil else { return false }
            return (try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.file))) != nil
        }
    }

    /// Removes the copy a read made for `path` alone, unless something holds it.
    private func discard(_ path: String) {
        let folder = self.folder()
        let suffix = "." + Self.fileExtension(of: URL(fileURLWithPath: path))
        lock.withLock {
            guard let name = prepared[path], holds[name] == nil else { return }
            prepared.removeValue(forKey: path)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + suffix))
        }
    }

    /// The finished copy `file` in the folder, with what it stands for; nil for anything else.
    private func entry(_ file: String, in folder: URL) -> Entry? {
        guard !file.hasPrefix(".") else { return nil }
        let url = folder.appendingPathComponent(file)
        guard let record = Self.record(on: url) else { return nil }
        let used = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            ?? .distantPast
        return Entry(file: file, name: (file as NSString).deletingPathExtension, record: record, lastUsed: used)
    }

    /// The finished copies in the folder.
    private func entries(in folder: URL) -> [Entry] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap {
            entry($0, in: folder)
        }
    }

    /// Removes what no longer stands for a file, from one listing of the folder: copies nothing
    /// holds whose file was replaced or deleted, files with no record and what an interrupted copy
    /// left. A file that appears after the listing (a copy just moved into place) is not looked at.
    /// When a copy is about to be made, the others are then kept under `capacity`, the least
    /// recently used one nothing holds going first. Returns what is left and the copies it removed.
    private func sweep(_ folder: URL, making: Bool) -> (kept: [Entry], removed: [Entry]) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        // Read after the listing: whatever is unfinished in it was already being made.
        let busy = lock.withLock { Set(building.keys).union(jobs.keys) }
        var kept: [Entry] = []
        var removed: [Entry] = []
        for file in files {
            if file.hasPrefix(".") {
                if !busy.contains(where: { file.hasPrefix(".\($0)-") }) {
                    try? manager.removeItem(at: folder.appendingPathComponent(file))
                }
                continue
            }
            guard let entry = entry(file, in: folder) else {
                try? manager.removeItem(at: folder.appendingPathComponent(file))
                continue
            }
            let source = URL(fileURLWithPath: entry.record.source)
            let current = (try? VideoFileStamp(url: source)).map { Self.name(path: source.path, stamp: $0) }
            // A copy of a file that is unreachable or replaced goes, unless something still reads it.
            if current != entry.name, remove(entry, in: folder) {
                removed.append(entry)
            } else {
                kept.append(entry)
            }
        }
        guard making else { return (kept, removed) }
        kept.sort { $0.lastUsed < $1.lastUsed }
        var index = 0
        while kept.count >= capacity, index < kept.count {
            if remove(kept[index], in: folder) { removed.append(kept.remove(at: index)) } else { index += 1 }
        }
        return (kept, removed)
    }

    private static func write(_ record: Record, on url: URL) throws {
        let data = try JSONEncoder().encode(record)
        let status = data.withUnsafeBytes { bytes in
            setxattr(url.path, recordAttribute, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func record(on url: URL) -> Record? {
        let length = getxattr(url.path, recordAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0, length <= 64 << 10 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, recordAttribute, bytes.baseAddress, length, 0, XATTR_NOFOLLOW)
        }
        guard read == length else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    // MARK: - Defaults

    /// The name of the copy of the file at `path` as `stamp` describes it.
    static func name(path: String, stamp: VideoFileStamp) -> String {
        let modified = stamp.modified.map { String($0.timeIntervalSince1970) } ?? ""
        let key = [path, String(stamp.size), modified, stamp.identity].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The source's extension, so AVFoundation reads the copy as the same kind of file.
    static func fileExtension(of url: URL) -> String {
        let candidate = url.pathExtension.lowercased()
        guard !candidate.isEmpty, candidate.count <= 8,
            candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return "mp4" }
        return candidate
    }

    /// `clonefile`, answering the error number it failed with, or 0.
    @Sendable static func cloneFile(_ source: URL, _ destination: URL) -> Int32 {
        clonefile(source.path, destination.path, 0) == 0 ? 0 : errno
    }

    @Sendable static func availableCapacity(_ folder: URL) -> Int64? {
        try? URL(fileURLWithPath: folder.path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Whether AVFoundation calls the file playable, with a video track it can decode. Metadata only.
    @Sendable static func playsInAVFoundation(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable),
            let track = try await asset.loadTracks(withMediaType: .video).first
        else { return false }
        return try await track.load(.isDecodable)
    }

    private static func copyBytes(from source: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
        }
    }
}
