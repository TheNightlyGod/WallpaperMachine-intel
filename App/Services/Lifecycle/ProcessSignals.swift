import Darwin

/// Signal dispositions the whole process depends on, set once before anything else runs.
enum ProcessSignals {
    /// Makes a write to a pipe or socket whose other end is gone fail with `EPIPE` instead of
    /// ending the app.
    ///
    /// By default the first such write raises SIGPIPE and the process dies on the spot, with
    /// no quit, no log line and the poster still on the desktop. Rust turns that default off
    /// for its own executables, but this app is a Swift executable that only links the
    /// renderer, so nothing did. The import picker's handshake writes to its helper's pipe
    /// with a throwing write that handles the error; it only never got the chance.
    ///
    /// The handler does nothing and is *caught*, not `SIG_IGN`. An ignore is inherited
    /// across `exec` by everything the app starts with `posix_spawn` (SteamCMD), while a
    /// caught handler goes back to the default there, so a child still dies when its own
    /// pipe breaks, as it would under a shell. `SA_RESTART` matches the rest of the app,
    /// which was written without any handler.
    ///
    /// Only a SIGPIPE that still has the default action is replaced. One that was ignored
    /// or handled before (by whatever launched the app, or by an earlier call) already
    /// cannot end the process and is left as it is, so calling this twice is the same as
    /// calling it once.
    static func ignoreBrokenPipes() {
        var current = sigaction()
        guard sigaction(SIGPIPE, nil, &current) == 0, hasDefaultAction(current) else { return }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = brokenPipeHandler
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        sigaction(SIGPIPE, &action, nil)
    }

    private static func hasDefaultAction(_ action: sigaction) -> Bool {
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_DFL, to: Int.self)
    }
}

/// Runs in signal context, where nothing but async-signal-safe calls is allowed: it does
/// nothing at all. The failed `write` reports the broken pipe.
private let brokenPipeHandler: @convention(c) (Int32) -> Void = { _ in }
