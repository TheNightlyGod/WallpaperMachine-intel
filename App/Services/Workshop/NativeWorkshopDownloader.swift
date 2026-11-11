import Darwin
import Foundation
import Observation

/// Runs one queued Workshop job with the app's own Steam client, signed in with a QR code.
///
/// It lays the download out exactly as SteamCMD does
/// (`<staging>/steamapps/workshop/content/431960/<id>`), so importing, preset bases and the
/// shared scene resources go through the same code as a SteamCMD download. There is nothing
/// to answer: no password, no Steam Guard prompt.
@MainActor
@Observable
final class NativeWorkshopDownloader: WorkshopDownloadWorker {
    static let wallpaperEngineApp: UInt32 = 431_960
    static let sceneAssetsDepot: UInt32 = 431_961

    private(set) var isRunning = false
    private(set) var status = String(localized: "Ready to download")
    private(set) var phase = WorkshopDownloader.Phase.preparing
    private(set) var progress: Double?
    private(set) var bytesReceived: Int64?
    private(set) var bytesExpected: Int64?
    private(set) var bytesPerSecond: Double?
    private(set) var errorMessage: String?
    private(set) var wasCancelled = false
    private(set) var completedSuccessfully = false
    private(set) var isAuthenticating = true
    private(set) var wallpaperEngineOwnership = WorkshopDownloader.WallpaperEngineOwnership.unknown
    let prompt: WorkshopDownloader.Prompt? = nil
    let steamGuardChallenge: WorkshopDownloader.SteamGuardChallenge? = nil
    let sessionWarning: String? = nil
    let endedBySessionConflict = false
    let endedBeforeSignInUnexplained = false
    @ObservationIgnored private(set) var failureOutput: String?
    @ObservationIgnored var onAuthenticated: (@MainActor () -> Void)?
    @ObservationIgnored var onFinished: (@MainActor () -> Void)?

    var secondsRemaining: Int? {
        guard isRunning, let received = bytesReceived, let expected = bytesExpected,
              let rate = bytesPerSecond, rate > 0, expected > received else { return nil }
        return Int((Double(expected - received) / rate).rounded(.up))
    }

    @ObservationIgnored private let session: SteamNativeSession
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var transferStarted: ContinuousClock.Instant?
    /// Counts transfers within a run (an item, then its preset base), to drop late reports.
    @ObservationIgnored private var transfer = 0

    init(session: SteamNativeSession, supportDirectory: URL) {
        self.session = session
        self.supportDirectory = supportDirectory
    }

    func start(item: WorkshopItem, library: URL, onImported: @escaping @MainActor () async throws -> Void) {
        guard let id = UInt64(item.id), id > 0, item.id.allSatisfy({ $0.isASCII && $0.isNumber }), item.kind != .application else {
            errorMessage = String(localized: "Choose a valid Workshop wallpaper. Application wallpapers execute Windows programs and cannot be used on macOS.")
            return
        }
        run(root: library.deletingLastPathComponent(), requesting: String(localized: "Signed in; requesting your Workshop download…")) { client, staging in
            try await self.fetch(id, with: client, into: staging)
            // A Workshop preset is only property values; the wallpaper it is based on comes too.
            if let base = try await WallpaperImportService().presetBaseToDownload(item.id, in: staging, library: library),
               let baseID = UInt64(base) {
                try await self.fetch(baseID, with: client, into: staging)
            }
            self.phase = .finishing
            self.status = String(localized: "Validating and adding to your library…")
            // A download of a wallpaper already in the library is its update, and replaces it.
            try await WallpaperImportService().importDownloadedItem(item.id, from: staging, into: library, replacing: true)
            self.clearTransferFigures()
            self.status = String(localized: "Downloaded to your library")
            do { try await onImported() }
            catch { self.errorMessage = String(localized: "Downloaded, but the library could not refresh: \(error.localizedDescription). Refresh the library before applying it.") }
        }
    }

    func installAssets(destination: URL, onInstalled: @escaping @MainActor () throws -> Void) {
        run(root: destination.deletingLastPathComponent(),
            requesting: String(localized: "Signed in; requesting Wallpaper Engine’s shared assets…")) { client, staging in
            let depot = staging.appending(path: "depot_\(Self.sceneAssetsDepot)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: depot, withIntermediateDirectories: false)
            self.beginTransfer()
            _ = try await client.downloadDepot(app: Self.wallpaperEngineApp, depot: Self.sceneAssetsDepot, into: depot,
                                               progress: self.progressHandler())
            self.phase = .finishing
            self.status = String(localized: "Validating and installing scene assets…")
            try ClientPaths.installSceneAssets(from: depot.appending(path: "assets", directoryHint: .isDirectory), to: destination)
            self.clearTransferFigures()
            try onInstalled()
            self.status = String(localized: "Scene assets installed")
        }
    }

    // MARK: - Running

    private func run(root: URL, requesting: String,
                     body: @escaping @MainActor (SteamContentClient, URL) async throws -> Void) {
        guard !isRunning else { return }
        isRunning = true
        wasCancelled = false
        completedSuccessfully = false
        errorMessage = nil
        failureOutput = nil
        isAuthenticating = true
        phase = .connecting
        status = String(localized: "Connecting to Steam")
        task = Task { [weak self] in
            guard let self else { return }
            var claim: Int32 = -1
            var staging: URL?
            var holdsClient = false
            do {
                let parent = FileLocation.isSame(self.supportDirectory, root) ? self.supportDirectory : root
                let folder = parent.appending(path: WorkshopDownloader.stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                staging = folder
                ClientPaths.excludeFromBackup(folder)
                claim = WorkshopDownloader.claimStaging(folder)
                self.phase = .signingIn
                let client = try await self.session.contentClient()
                holdsClient = true
                self.isAuthenticating = false
                self.onAuthenticated?()
                self.phase = .requesting
                self.status = requesting
                try await body(client, folder)
                self.completedSuccessfully = true
                self.wallpaperEngineOwnership = .owned
            } catch {
                self.fail(with: error)
            }
            if holdsClient { self.session.release() }
            if claim >= 0 { close(claim) }
            if let staging {
                await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staging) }.value
            }
            self.isAuthenticating = false
            self.isRunning = false
            self.task = nil
            self.onFinished?()
        }
    }

    private func fetch(_ id: UInt64, with client: SteamContentClient, into staging: URL) async throws {
        let folder = staging.appending(path: "steamapps/workshop/content/\(Self.wallpaperEngineApp)/\(id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        beginTransfer()
        _ = try await client.downloadWorkshopItem(id, of: Self.wallpaperEngineApp, into: folder, progress: progressHandler())
    }

    private func beginTransfer() {
        clearTransferFigures()
        transfer += 1
        phase = .transferring
        status = String(localized: "Downloading Workshop files…")
        transferStarted = .now
    }

    /// Reports reach the main actor one task each, in no guaranteed order: a report of an
    /// earlier transfer (an item before its preset base) or an older figure is dropped, so the
    /// count never steps back.
    private func progressHandler() -> @Sendable (UInt64, UInt64) -> Void {
        let transfer = transfer
        return { [weak self] done, total in
            Task { @MainActor in self?.report(done: done, total: total, transfer: transfer) }
        }
    }

    private func report(done: UInt64, total: UInt64, transfer: Int) {
        guard isRunning, phase == .transferring, transfer == self.transfer,
              Int64(clamping: done) >= bytesReceived ?? 0 else { return }
        bytesReceived = Int64(clamping: done)
        bytesExpected = total > 0 ? Int64(clamping: total) : nil
        progress = total > 0 ? min(Double(done) / Double(total), 1) : nil
        if let transferStarted {
            let seconds = Double((ContinuousClock.now - transferStarted).components.seconds)
            bytesPerSecond = seconds >= 1 ? Double(done) / seconds : nil
        }
    }

    private func clearTransferFigures() {
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        bytesPerSecond = nil
        transferStarted = nil
    }

    private func fail(with error: any Error) {
        clearTransferFigures()
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
            status = wasCancelled ? String(localized: "Download cancelled") : String(localized: "Download paused")
            return
        }
        AppLog.warn("Steam download failed (\(error.localizedDescription))")
        failureOutput = "native Steam client: \(error.localizedDescription)"
        if Self.meansNotOwned(error) { wallpaperEngineOwnership = .notOwned }
        errorMessage = Self.message(for: error)
        status = errorMessage ?? status
    }

    /// Steam hands a depot key only to an account that owns the app, and the key is asked for
    /// before anything else of the depot, so a refusal that names access is the ownership
    /// answer: AccessDenied, InsufficientPrivilege or Blocked. A plain Fail (also what a reply
    /// without a result reads as) proves nothing and stays a failed download.
    static func meansNotOwned(_ error: any Error) -> Bool {
        guard case SteamCMConnection.Failure.requestFailed(SteamContentClient.depotKeyRequest, let eresult)? =
                error as? SteamCMConnection.Failure else { return false }
        return [15, 24, 40].contains(eresult)
    }

    /// What the person reads about a failed native download: a few phrases in their language, the
    /// technical detail staying in the log. Errors of the import and install steps that follow the
    /// download are the app's own and already read well.
    static func message(for error: any Error) -> String {
        if meansNotOwned(error) {
            return String(localized: "This Steam account does not own Wallpaper Engine. Please purchase it on Steam to download Wallpaper Engine wallpapers. You can still download from Pixiv, browse the Workshop, and view Wallpaper Engine wallpapers you already have.")
        }
        switch error {
        case let failure as SteamNativeSession.Failure:
            return failure.localizedDescription
        case SteamContentClient.Failure.insufficientSpace(let needed, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let neededText = formatter.string(fromByteCount: needed)
            let availableText = formatter.string(fromByteCount: available)
            return String(localized: "Not enough free disk space: this download needs about \(neededText) and only \(availableText) is available on the disk that holds your library. Free up space, then try again.")
        case SteamContentClient.Failure.itemUnavailable, SteamContentClient.Failure.notDepotContent,
             SteamContentClient.Failure.wrongApp:
            return String(localized: "Steam does not offer this Workshop item for download. It may be private, removed, or not a Wallpaper Engine item.")
        case SteamContentClient.Failure.http, SteamContentClient.Failure.noContentServers:
            return String(localized: "Steam’s download servers did not deliver this wallpaper. Try again later.")
        case is SteamContentClient.Failure, is SteamDepotCrypto.Failure, is SteamProto.DecodingError, is BridgeError:
            return String(localized: "A downloaded file did not match what Steam listed, so nothing was installed. Try again.")
        case SteamCMConnection.Failure.logOnRefused(84):
            return String(localized: "Steam has temporarily limited sign-in attempts. Wait before retrying.")
        case SteamCMConnection.Failure.logOnRefused:
            return String(localized: "Steam sign-in failed. Try again.")
        case SteamCMConnection.Failure.loggedOff:
            return String(localized: "Steam ended the session, for example because this account signed in elsewhere. Try again.")
        case SteamCMConnection.Failure.requestFailed(SteamContentClient.itemDetailsMethod, _):
            return String(localized: "Steam does not offer this Workshop item for download. It may be private, removed, or not a Wallpaper Engine item.")
        case SteamCMConnection.Failure.requestFailed:
            // Steam answered but declined a manifest code, the product info or a depot key.
            return String(localized: "Steam’s download servers did not deliver this wallpaper. Try again later.")
        case is URLError, is SteamCMConnection.Failure, is SteamWebAPIError:
            return String(localized: "Could not reach Steam. Check your internet connection and try again.")
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Control

    func submitSecret(_ value: String) {}

    /// Native transfers keep no connection that a sleep could leave hanging: a dropped request fails and is retried.
    func noteSystemResume() {}

    /// Stops the transfer. Nothing partial is kept: a resumed job fetches the item again.
    func pause() {
        task?.cancel()
    }

    func cancel() {
        wasCancelled = true
        task?.cancel()
    }

    func discardCheckpoint() {}

    func shutdown() async {
        guard let task else { return }
        task.cancel()
        await task.value
    }
}
