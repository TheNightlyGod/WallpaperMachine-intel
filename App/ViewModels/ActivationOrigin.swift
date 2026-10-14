/// Who asked for a wallpaper to be loaded on a display.
///
/// Only the user's own request is a choice. Everything else (a playlist's timer, an
/// automatic rule, a restored layout, an update reloading files) is the app acting on its
/// own, so it gives way to a choice the user is waiting on and is never counted as one.
enum ActivationOrigin: String, Sendable {
    /// The panel, the menu bar, a hotkey, a Shortcuts action or a link.
    case user
    case playlist
    case automation
    /// Applying a saved display layout, or copying, swapping or applying one wallpaper to every
    /// display. Each is one user command that reports the choices it made itself, so its
    /// individual activations are not choices. Applying one wallpaper to every display also
    /// asks the activation to lift a crash hold on it (`releasesHold`), as naming it does.
    case layout
    /// Files loaded afresh: an update replacing them, or the user's Retry for a scene that
    /// stopped drawing. Neither is a new choice of wallpaper, so both give way to one.
    case updateReload

    /// Whether the person chose this. A user choice is never replaced by an automatic
    /// change, and only it reports a manual choice and counts toward the support prompt.
    var isUserChoice: Bool { self == .user }
}

/// What a finished activation did.
enum ActivationResult: String, Sendable {
    /// The display now shows the wallpaper through a fresh apply.
    case applied
    /// The display already showed it with nothing pending, so the renderer was not touched.
    case noOp
}

/// The log line each activation or reload leaves, so "why did my wallpaper change?" is
/// answered by one line: which wallpaper, on which display, asked for by whom, and how it
/// ended.
///
/// A line names the wallpaper by id and never by title, and a failure by category and never
/// by message: the panel already shows the person the message, and the message may carry
/// paths the diagnostics report would then have to redact.
enum ActivationLog {
    /// `activation` is one `activateWallpaperAsync` call. `reload` is an update (or any other
    /// change of files) loading the wallpaper afresh on a display, and `reapply` is the user
    /// restarting the wallpaper the display already shows; both also log the `activation`
    /// their re-apply performed.
    enum Kind: String, Sendable {
        case activation, reload, reapply
    }

    enum Failure: String, Sendable {
        case cancelled
        /// The app declined with a reason it can state (`WallpaperActionError`).
        case refused
        /// Anything else, such as the bridge or the file system failing.
        case error
    }

    enum Outcome: Equatable, Sendable {
        case applied, noOp
        /// A reload that did not run because another command took its slot: usually a choice
        /// the user was waiting on, otherwise a newer automatic command.
        case skipped
        case failed(Failure)

        init(_ result: ActivationResult) {
            switch result {
            case .applied: self = .applied
            case .noOp: self = .noOp
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    static func failure(of error: Error) -> Failure {
        if error is CancellationError { return .cancelled }
        if error is WallpaperActionError { return .refused }
        return .error
    }

    static func milliseconds(_ elapsed: Duration) -> Int {
        let parts = elapsed.components
        return Int(clamping: parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    /// `activation: wallpaper 123 display 1 origin user applied in 42 ms`. A skipped reload
    /// has no duration because nothing ran.
    static func line(_ kind: Kind, wallpaper: String, display: String, origin: ActivationOrigin,
                     outcome: Outcome, milliseconds: Int?) -> String {
        let verdict: String
        switch outcome {
        case .applied: verdict = "applied"
        case .noOp: verdict = "noOp"
        case .skipped: verdict = "skipped (another command took its place)"
        case let .failed(failure): verdict = "failed (\(failure.rawValue))"
        }
        return "\(kind.rawValue): wallpaper \(wallpaper) display \(display) origin \(origin.rawValue) \(verdict)"
            + (milliseconds.map { " in \($0) ms" } ?? "")
    }

    /// Failures are warnings; everything else, a skipped reload included, is plain news.
    static func write(_ line: String, isFailure: Bool) {
        if isFailure { AppLog.warn(line) } else { AppLog.info(line) }
    }
}
