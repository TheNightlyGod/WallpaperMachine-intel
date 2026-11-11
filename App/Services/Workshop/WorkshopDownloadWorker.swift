import Foundation

/// What runs one queued Workshop job: SteamCMD signed in with a password
/// (`WorkshopDownloader`), or the app's own Steam client signed in with a QR code
/// (`NativeWorkshopDownloader`). The queue and the panel read a job only through this.
@MainActor
protocol WorkshopDownloadWorker: AnyObject {
    var isRunning: Bool { get }
    var status: String { get }
    var phase: WorkshopDownloader.Phase { get }
    var progress: Double? { get }
    var bytesReceived: Int64? { get }
    var bytesExpected: Int64? { get }
    var bytesPerSecond: Double? { get }
    var secondsRemaining: Int? { get }
    var errorMessage: String? { get }
    var wasCancelled: Bool { get }
    var completedSuccessfully: Bool { get }

    /// Still establishing the session, before any content moves.
    var isAuthenticating: Bool { get }
    /// What Steam is waiting for the person to type; only SteamCMD ever asks.
    var prompt: WorkshopDownloader.Prompt? { get }
    var steamGuardChallenge: WorkshopDownloader.SteamGuardChallenge? { get }
    var sessionWarning: String? { get }
    var wallpaperEngineOwnership: WorkshopDownloader.WallpaperEngineOwnership { get }

    /// Steam ended the session because the same account signed in elsewhere.
    var endedBySessionConflict: Bool { get }
    /// The sign-in ended before Steam accepted it and Steam gave no reason.
    var endedBeforeSignInUnexplained: Bool { get }
    /// What to keep in the failure log when a run fails.
    var failureOutput: String? { get }

    var onAuthenticated: (@MainActor () -> Void)? { get set }
    var onFinished: (@MainActor () -> Void)? { get set }

    func submitSecret(_ value: String)
    func noteSystemResume()
    func pause()
    func cancel()
    func discardCheckpoint()
    func shutdown() async
}

extension WorkshopDownloader: WorkshopDownloadWorker {}
