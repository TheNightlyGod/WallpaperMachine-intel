import Darwin
import Foundation

/// Asks a child process what it sees for a signal, the way the app's own children see it.
enum ChildSignalProbe {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// What perl reports for each signal in a child started with `posix_spawn`, as SteamCMD and
    /// the Workshop downloader are: `IGNORE`, or `DEFAULT` when it is neither ignored nor
    /// handled. Comma-separated, in order, with names as perl spells them (`USR1`, `PIPE`).
    /// Foundation's `Process` is no probe, because it resets every signal to its default in
    /// the child whatever the parent did.
    static func perlDispositions(of names: [String]) throws -> String {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw Failure(description: "pipe failed (errno \(errno))") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, ends[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, ends[0])
        posix_spawn_file_actions_addclose(&actions, ends[1])

        let script = #"print join(",", map { $SIG{$_} // "DEFAULT" } @ARGV)"#
        let arguments = ["perl", "-e", script] + names
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for argument in argv { free(argument) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { for entry in environment { free(entry) } }

        var child: pid_t = 0
        let status = posix_spawn(&child, "/usr/bin/perl", &actions, nil, &argv, &environment)
        close(ends[1])
        defer { close(ends[0]) }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = read(ends[0], &buffer, buffer.count)
            if count <= 0 { break }
            output.append(contentsOf: buffer[..<count])
        }
        var waitStatus: Int32 = 0
        waitpid(child, &waitStatus, 0)
        guard waitStatus == 0 else { throw Failure(description: "perl ended with status \(waitStatus)") }
        return String(decoding: output, as: UTF8.self)
    }
}
