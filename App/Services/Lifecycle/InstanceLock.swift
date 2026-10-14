import Darwin
import Foundation

/// Lets one copy of the app run per library folder.
///
/// The claim is an advisory `flock` on an open file description, so the kernel drops it on any
/// exit, including a crash or `kill -9`, and no lock can be stale because its owner is gone. The
/// descriptor is `O_CLOEXEC`, so a child the app spawns can never keep the claim after the app
/// itself has exited. The file also records `<pid> <phase>` so a second copy can tell a running
/// holder from one that is quitting and find out which program it is. The file is never
/// unlinked: a second inode would let two copies each hold a lock on "the" file.
final class InstanceLock {
    static let fileName = ".instance.lock"

    enum Phase: String, Equatable {
        case running
        case quitting
    }

    struct Holder: Equatable {
        var pid: pid_t
        var phase: Phase
    }

    /// How long a second copy waits for the lock to come free before deciding what to do.
    struct Patience: Equatable {
        /// A running holder normally keeps the lock for good; this only covers a quit-and-reopen
        /// race and an updater relaunch whose old process is still tearing down.
        var running: TimeInterval = 2
        /// A holder that announced it is quitting is waiting on wallpaper restoration and the
        /// teardown after it, which can take a while on a slow disk or display. It is waited for as
        /// long as an interactive quit may take within its budgets, plus `quitMargin`, so a
        /// relaunch right after a slow but successful quit is not given up on and lost.
        var quitting: TimeInterval = QuitMode.interactive.budgets.longestQuit.timeInterval + Patience.quitMargin
        var poll: TimeInterval = 0.125

        /// What a second copy waits beyond the longest quit: for the holder's process to be torn
        /// down after its exit fuse and for the kernel to drop the lock.
        static let quitMargin: TimeInterval = 3
        static let standard = Patience()
    }

    enum Unlocked: Equatable {
        /// The lock file could not be opened or locked at all, for example on a read-only volume.
        case unusable(errno: Int32)
        /// The recorded holder no longer exists, so a descriptor outlived it in some other process.
        case deadHolder(pid: pid_t)
        /// Something holds the lock but never recorded who.
        case unreadableHolder
    }

    enum Outcome {
        case acquired(InstanceLock)
        /// A live copy owns the library.
        case heldBy(Holder)
        /// Launch continues without a lock. A lock that cannot be trusted must never keep the app
        /// from starting.
        case proceedUnlocked(Unlocked)
    }

    /// The lock this process holds for the rest of its life.
    nonisolated(unsafe) static var current: InstanceLock?

    let pid: pid_t
    private var descriptor: Int32

    private init(descriptor: Int32, pid: pid_t) {
        self.descriptor = descriptor
        self.pid = pid
    }

    deinit { release() }

    /// Takes the lock at `url`, waiting while its holder is expected to let go.
    ///
    /// `sleep` and `isAlive` are injected so tests can pass time without waiting for it.
    static func acquire(
        at url: URL,
        patience: Patience = .standard,
        isAlive: (pid_t) -> Bool = processExists,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Outcome {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .proceedUnlocked(.unusable(errno: Int32(truncatingIfNeeded: (error as NSError).code)))
        }
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return .proceedUnlocked(.unusable(errno: errno)) }

        var waited: TimeInterval = 0
        while true {
            let acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            let failure = errno
            if !acquired, failure != EWOULDBLOCK {
                close(descriptor)
                return .proceedUnlocked(.unusable(errno: failure))
            }
            let holder = acquired ? nil : readHolder(descriptor: descriptor)
            switch InstanceDecision.decide(
                acquired: acquired, holder: holder, holderAlive: holder.map { isAlive($0.pid) } ?? false,
                waited: waited, patience: patience)
            {
            case .proceed:
                let lock = InstanceLock(descriptor: descriptor, pid: getpid())
                lock.setPhase(.running)
                return .acquired(lock)
            case .wait:
                sleep(patience.poll)
                waited += patience.poll
            case .handOff:
                close(descriptor)
                return holder.map(Outcome.heldBy) ?? .proceedUnlocked(.unreadableHolder)
            case .proceedUnlocked:
                close(descriptor)
                return .proceedUnlocked(holder.map { .deadHolder(pid: $0.pid) } ?? .unreadableHolder)
            }
        }
    }

    /// Who the file at `url` says holds the lock, without taking part in the claim.
    static func readHolder(at url: URL) -> Holder? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        return readHolder(descriptor: descriptor)
    }

    /// Announces that this process is quitting (or, if the quit was cancelled, running again).
    /// The record is written over the old one before the file is trimmed, so a reader never sees
    /// an empty file.
    @discardableResult
    func setPhase(_ phase: Phase) -> Bool {
        guard descriptor >= 0 else { return false }
        let record = Array("\(pid) \(phase.rawValue)\n".utf8)
        guard pwrite(descriptor, record, record.count, 0) == record.count else { return false }
        return ftruncate(descriptor, off_t(record.count)) == 0
    }

    /// Gives the library up. Closing the only descriptor is what releases the kernel lock.
    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    static func processExists(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private static func readHolder(descriptor: Int32) -> Holder? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0, let text = String(bytes: buffer[0..<count], encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard let first = fields.first, let pid = pid_t(first), pid > 0 else { return nil }
        // An unfamiliar phase is a newer build's word for "still here".
        let phase = fields.dropFirst().first.flatMap { Phase(rawValue: String($0)) } ?? .running
        return Holder(pid: pid, phase: phase)
    }
}

/// The decisions a second launch makes, kept apart from the descriptors so they can be exercised
/// as a table.
enum InstanceDecision: Equatable {
    case proceed
    case wait
    case handOff
    case proceedUnlocked

    /// What to do after one attempt at the lock.
    ///
    /// A holder that looks dead is waited for one more poll before it is believed: the lock file
    /// keeps the previous owner's record until a new owner has written its own, so the first look
    /// can catch the gap between taking the lock and recording who took it.
    static func decide(
        acquired: Bool, holder: InstanceLock.Holder?, holderAlive: Bool,
        waited: TimeInterval, patience: InstanceLock.Patience
    ) -> InstanceDecision {
        if acquired { return .proceed }
        guard let holder else { return waited < patience.running ? .wait : .proceedUnlocked }
        guard holderAlive else { return waited > 0 ? .proceedUnlocked : .wait }
        let limit = holder.phase == .quitting ? patience.quitting : patience.running
        return waited < limit ? .wait : .handOff
    }
}

/// What a second launch does about the copy that owns the library.
enum InstanceHandOff: Equatable {
    /// The owner is this very bundle: bring it forward and let it show its panel.
    case reopenRunningCopy
    /// The owner is the app run from somewhere else: the user has to choose which copy to keep.
    case warnAboutOtherCopy
    /// The recorded pid belongs to some other program, so the lock is not an app copy's.
    case proceedUnlocked

    /// `holderExecutable` and `ownExecutable` are the kernel's paths for the two processes.
    static func action(holderExecutable: String?, ownExecutable: String?) -> InstanceHandOff {
        guard let holderExecutable, let ownExecutable else { return .proceedUnlocked }
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        if canonical(holderExecutable) == canonical(ownExecutable) { return .reopenRunningCopy }
        let holderURL = URL(fileURLWithPath: holderExecutable)
        let sameProgram = holderURL.lastPathComponent == URL(fileURLWithPath: ownExecutable).lastPathComponent
        let insideBundle = holderURL.deletingLastPathComponent().lastPathComponent == "MacOS"
            && holderURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents"
        return sameProgram && insideBundle ? .warnAboutOtherCopy : .proceedUnlocked
    }

    /// The path of the program running as `pid`, or nil when the process is gone or not ours to see.
    static func executablePath(ofProcess pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
