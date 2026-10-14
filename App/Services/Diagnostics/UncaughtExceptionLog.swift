import Foundation
import os

/// Writes the name, reason and call stack of an Objective-C exception that nothing
/// caught, then lets the process die the way it would have.
///
/// A crash report names the faulting frame but not always the exception, and the
/// reason string is what says which key or index was wrong. The handler is
/// chained, so any handler installed before it still runs. The exception's name
/// is also written to the session ledger, so the next launch can tell this run
/// ended by an exception.
enum UncaughtExceptionLog {
    /// Frames of the call stack that go into the log. The throw site is at the top.
    static let frameLimit = 12

    private static let state = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var installed = false
        var previous: NSUncaughtExceptionHandler?
    }

    /// Installs the handler once; later calls do nothing, so it can never chain to itself.
    static func install() {
        state.withLock { state in
            guard !state.installed else { return }
            state.installed = true
            state.previous = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { exception in
                UncaughtExceptionLog.handle(exception)
                UncaughtExceptionLog.state.withLock { $0.previous }?(exception)
            }
        }
    }

    /// What the installed handler does for one exception. Apart from the arguments
    /// it takes no part in the process, so a test can call it directly.
    static func handle(
        _ exception: NSException,
        router: AppLogRouter = AppLog.router,
        ledger: SessionLedger? = SessionLedger.shared,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let name = exception.name.rawValue
        // The ledger first: it is what the next launch reads, and it is bounded.
        ledger?.noteException(named: name)
        func emit(_ message: String) {
            router.emit(AppLogRouter.Entry(level: .error, file: "\(file)", line: UInt32(clamping: line),
                                           message: message, load: nil, unixMillis: AppLogRouter.now()))
        }
        emit("uncaught exception \(name): \(oneLine(exception.reason ?? "no reason"))")
        let frames = exception.callStackSymbols.prefix(frameLimit).map(oneLine)
        if !frames.isEmpty {
            emit("uncaught exception call stack: " + frames.joined(separator: " | "))
        }
    }

    /// Log lines hold one record each, so line breaks and column padding go.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
