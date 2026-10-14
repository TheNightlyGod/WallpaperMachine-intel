import Darwin
import Dispatch
import Foundation

/// Turns SIGTERM and SIGHUP into an ordinary quit.
///
/// `kill`, `killall`, `launchctl stop`, device management and a closing terminal end an app
/// with these signals. With no handler the process dies on the spot: the poster the app put
/// on the desktop stays installed until the next launch and the renderer never closes its
/// load journal, so a stop during a load counts a strike against the wallpaper. Relayed to
/// `NSApp.terminate`, the same signal runs the quit the user's Exit runs.
///
/// How the signal gets out of the handler: the C handler does one `write(2)` of the signal
/// number to a pipe, which is all a handler may safely do, and a dispatch source reads the
/// byte on a queue of its own. The handler is *caught*, not ignored, so every child the app
/// starts (SteamCMD, perl, the updater script) gets the default action back across `exec`.
/// Ignoring the signal and watching it with a dispatch source would hand `SIG_IGN` to all of
/// them, and a child that ignores its parent's SIGTERM turns every quit into a wait for the
/// two-second SIGKILL.
///
/// A signal that was already ignored when the relay started (`nohup` does this for SIGHUP)
/// stays ignored. Only the first signal asks for a quit. A second one, or `forceAfter`
/// elapsing, calls `forceDefault`, so an app whose quit is stuck can still be killed the
/// ordinary way. `reset` forgets the first signal after a quit that was refused.
final class TerminationSignalRelay: @unchecked Sendable {
    enum StartError: LocalizedError, Equatable {
        case pipe(errno: Int32)
        case handler(signal: Int32, errno: Int32)

        var errorDescription: String? {
            switch self {
            case .pipe(let code):
                "the signal pipe could not be created (errno \(code))"
            case .handler(let signal, let code):
                "the handler for \(TerminationSignalRelay.name(of: signal)) could not be installed (errno \(code))"
            }
        }
    }

    /// Ends the process by the signal's own default action, as if there were no handler.
    /// Returns only if the signal could not be delivered; the process then exits at once.
    static let endByDefaultAction: @Sendable (Int32) -> Void = { number in
        _ = Darwin.signal(number, SIG_DFL)
        raise(number)
        _exit(128 + number)
    }

    /// Runs `work` from the main run loop in every common mode, from any thread.
    ///
    /// A quit asked for by a signal can arrive while the main loop is not in its default mode:
    /// menu tracking runs it in the event-tracking mode, and an alert's modal session in a mode of
    /// its own (the update prompt can stay open for hours). `RunLoop.perform(_:)` is not served in
    /// every mode (the event-tracking one skips it, which the tests pin), and a signal's first
    /// request that is not served waits there until the menu or alert closes. The sender, who has
    /// asked once, would see the app end only at the deadline or the second signal, with the
    /// poster still on the desktop. Common modes include all of those. This still runs as a
    /// run-loop source and not as a main-queue job, which is what lets AppKit's `terminateLater`
    /// wait (a nested loop) go on running the quit's own tasks.
    ///
    /// A block performed from another thread does not necessarily wake a sleeping loop, hence the
    /// explicit wake-up.
    static func performOnMainRunLoopInAnyMode(_ work: @escaping () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(main)
    }

    /// The name the log and the session ledger use, such as `SIGTERM`.
    static func name(of number: Int32) -> String {
        switch number {
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        default: "signal \(number)"
        }
    }

    private struct Running {
        var readEnd: Int32
        var writeEnd: Int32
        var source: any DispatchSourceRead
        /// The disposition each relayed signal had before, for `stop`.
        var previous: [Int32: sigaction]
    }

    private let signals: [Int32]
    private let terminate: @Sendable (Int32) -> Void
    private let forceDefault: @Sendable (Int32) -> Void
    private let forceAfter: Duration
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var running: Running?
    private var firstSignal: Int32?
    private var deadline: DispatchWorkItem?

    /// `terminate` and `forceDefault` run on `queue`, not on the main thread, and must not
    /// block it. `forceAfter` counts from the first signal.
    init(
        signals: [Int32] = [SIGTERM, SIGHUP],
        terminate: @escaping @Sendable (Int32) -> Void,
        forceDefault: @escaping @Sendable (Int32) -> Void = TerminationSignalRelay.endByDefaultAction,
        forceAfter: Duration = .seconds(30),
        queue: DispatchQueue = DispatchQueue(label: "app.wallpapermachine.termination-signals", qos: .utility)
    ) {
        self.signals = signals
        self.terminate = terminate
        self.forceDefault = forceDefault
        self.forceAfter = forceAfter
        self.queue = queue
    }

    deinit {
        stop()
    }

    /// The two ends of the pipe the handler writes to, for the tests; `nil` when not started.
    var descriptors: (read: Int32, write: Int32)? {
        lock.lock()
        defer { lock.unlock() }
        return running.map { ($0.readEnd, $0.writeEnd) }
    }

    /// Installs the handlers. Starting a relay that already runs changes nothing.
    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard running == nil else { return }

        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw StartError.pipe(errno: errno) }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        // Close-on-exec because an orphaned child that kept the pipe would keep the read end
        // alive for nothing; non-blocking so a full pipe can never stall the handler or the reader.
        // There is no pipe2 on macOS, so another thread that spawns between the two calls could
        // inherit the descriptors: harmless, since nothing reads or writes them.
        for end in ends {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
        }

        var previous: [Int32: sigaction] = [:]
        for number in signals where number > 0 && number < slotCount {
            var current = sigaction()
            sigaction(number, nil, &current)
            if Self.isIgnored(current) { continue }
            // The table entry first, so a signal that arrives right after the install has somewhere to go.
            writeEnds[Int(number)] = writeEnd
            var action = sigaction()
            action.__sigaction_u.__sa_handler = relayHandler
            sigemptyset(&action.sa_mask)
            // Restart interrupted system calls: the rest of the app was written without a handler.
            action.sa_flags = SA_RESTART
            var replaced = sigaction()
            guard sigaction(number, &action, &replaced) == 0 else {
                let code = errno
                restore(previous)
                for installed in previous.keys + [number] { writeEnds[Int(installed)] = -1 }
                close(readEnd)
                close(writeEnd)
                throw StartError.handler(signal: number, errno: code)
            }
            previous[number] = replaced
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: readEnd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(readEnd) }
        source.setCancelHandler { close(readEnd) }
        source.resume()
        running = Running(readEnd: readEnd, writeEnd: writeEnd, source: source, previous: previous)
    }

    /// Puts back what was there before and drops the pipe.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        deadline?.cancel()
        deadline = nil
        firstSignal = nil
        guard let running else { return }
        self.running = nil
        restore(running.previous)
        // After the dispositions are back no new signal reaches the table, and the entry is
        // cleared before the descriptor is closed so a late one cannot write to a reused number.
        for number in running.previous.keys { writeEnds[Int(number)] = -1 }
        running.source.cancel()
        close(running.writeEnd)
    }

    /// For a quit that was refused: forget the first signal and its deadline, so the next
    /// signal asks for a quit again instead of forcing the end.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        deadline?.cancel()
        deadline = nil
        firstSignal = nil
    }

    // MARK: Delivery

    private func drain(_ readEnd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16)
        while true {
            let count = read(readEnd, &buffer, buffer.count)
            if count > 0 {
                for byte in buffer[..<count] { handle(signal: Int32(byte)) }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func handle(signal number: Int32) {
        lock.lock()
        let isFirst = firstSignal == nil
        if isFirst {
            firstSignal = number
            let work = DispatchWorkItem { [weak self] in self?.deadlineReached() }
            deadline = work
            queue.asyncAfter(deadline: .now() + forceAfter.timeInterval, execute: work)
        }
        lock.unlock()
        if isFirst { terminate(number) } else { forceDefault(number) }
    }

    private func deadlineReached() {
        lock.lock()
        let number = firstSignal
        lock.unlock()
        // `reset` may have run between the timer firing and this point.
        if let number { forceDefault(number) }
    }

    private func restore(_ dispositions: [Int32: sigaction]) {
        for (number, var action) in dispositions { sigaction(number, &action, nil) }
    }

    private static func isIgnored(_ action: sigaction) -> Bool {
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }
}

// MARK: The handler

/// Signal numbers are below this on Darwin (`NSIG`).
private let slotCount: Int32 = 32

/// The pipe each relayed signal writes to, indexed by signal number; `-1` for none.
///
/// A fixed block of memory behind a `let`, because the handler runs on whatever thread the
/// signal lands on, possibly in the middle of `malloc`: it cannot take a lock, allocate,
/// or touch a Swift global `var`, whose exclusivity checks allocate. The block is created
/// by the first `start()`, before any handler is installed, and lives for the process.
private let writeEnds: UnsafeMutablePointer<Int32> = {
    let table = UnsafeMutablePointer<Int32>.allocate(capacity: Int(slotCount))
    table.initialize(repeating: -1, count: Int(slotCount))
    return table
}()

/// The only code that runs in signal context: one `write(2)`, which is async-signal-safe.
private let relayHandler: @convention(c) (Int32) -> Void = { number in
    let savedErrno = errno
    if number > 0 && number < slotCount {
        let end = writeEnds[Int(number)]
        if end >= 0 {
            var byte = UInt8(truncatingIfNeeded: number)
            _ = write(end, &byte, 1)
        }
    }
    errno = savedErrno
}
