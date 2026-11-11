import Darwin
import Foundation

/// The PTY downloader needs interactive input; the installer runner intentionally does not.
/// Both use spawn-time process-group ownership, never a racy setpgid after launch.
@MainActor
final class SteamCMDTerminalProcess {
    private let pid: pid_t
    private var exitStatus: Int32?
    private var leaderExited = false
    private var cleaned = false

    var processIdentifier: pid_t { pid }

    var isRunning: Bool {
        guard !cleaned, !leaderExited else { return false }
        // Keep the zombie leader until every group signal has been sent; its PID cannot be reused.
        var information = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
        if result == 0, information.si_pid == pid { leaderExited = true }
        if result == -1, errno == ECHILD {
            // Ownership was lost; never signal a potentially recycled process-group ID.
            cleaned = true
            exitStatus = 255
        }
        return !cleaned && !leaderExited
    }

    var terminationStatus: Int32 {
        _ = isRunning
        return exitStatus ?? -1
    }

    func stop() async {
        guard !cleaned else { return }
        let exited = !isRunning
        guard !cleaned else { return }
        cleaned = true
        let processID = pid
        let status = await Task.detached(priority: .utility) {
            Darwin.kill(-processID, SIGTERM)
            if !exited {
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while Darwin.kill(-processID, 0) == 0, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            Darwin.kill(-processID, SIGKILL)
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(processID, &status, 0) } while result < 0 && errno == EINTR
            return result == processID ? status : Int32(255 << 8)
        }.value
        exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
         master: Int32, slave: Int32, claim: Int32, contentClaim: Int32 = -1) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ result: Int32) throws {
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        // SteamCMD never falls back to Rosetta; nettop, the other child, is native as well.
        try check(SteamCMDArchitecture.requireNative(&attributes))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path))
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_adddup2(&actions, slave, descriptor))
        }
        try check(posix_spawn_file_actions_addclose(&actions, master))
        try check(posix_spawn_file_actions_addclose(&actions, slave))
        // SteamCMD keeps the staging claim alive if it outlives this process, which is what stops a
        // later launch from reclaiming a download still being written. The duplicate has to be a
        // different descriptor than the one it lands on, because dup2 onto itself does nothing and
        // would leave the claim closing on exec; it also has to survive the closes above. A download
        // kept beside a library on another disk has a second claim, on its content folder.
        var inherited: [Int32] = []
        defer { inherited.forEach { close($0) } }
        for (descriptor, slot) in [(claim, Int32(3)), (contentClaim, Int32(4))] where descriptor >= 0 {
            let copy = fcntl(descriptor, F_DUPFD, 20)
            guard copy >= 0 else { continue }
            inherited.append(copy)
            try check(posix_spawn_file_actions_adddup2(&actions, copy, slot))
        }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw POSIXError(.ENOMEM)
        }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { environment in
                posix_spawn(&child, executable.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: arguments.baseAddress!),
                            UnsafeMutablePointer(mutating: environment.baseAddress!))
            }
        }
        try check(result)
        pid = child
    }
}
