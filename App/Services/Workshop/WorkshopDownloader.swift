import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class WorkshopDownloader: SteamCMDDownloadActivity {
    enum Prompt: String { case password = "Steam password", guardCode = "Steam Guard code" }
    enum SteamGuardChallenge { case mobileApproval, authenticatorCode, emailCode }
    enum WallpaperEngineOwnership: String { case unknown, owned, notOwned }
    private(set) var wallpaperEngineOwnership = WallpaperEngineOwnership.unknown
    /// Coarse step of a run for compact surfaces such as the tile ring; `status` carries the
    /// full sentence. Bytes only move during `transferring`; `finishing` covers SteamCMD's
    /// close and the validation/import that follows it.
    enum Phase: String { case preparing, connecting, updating, signingIn, requesting, transferring, finishing }
    /// The byte counters that show a transfer is alive: the process's network total, the content
    /// landed on disk, and the counts SteamCMD prints for an asset installation.
    private enum TransferMeter { case network, disk, steam }
    /// How a pass failed, recorded once with the message the user is shown.
    private enum PassFailure {
        /// Nothing another launch can fix: whatever the user has to decide, and any failure before
        /// Steam accepted the sign-in.
        case final(String)
        /// Another launch can fix it: the connection dropped after Steam accepted the sign-in.
        case transient(String)
        /// A transient failure the inactivity limit ended, not a message from Steam or the watch
        /// after a wake. Each repeat costs the whole limit, so only `maximumSilentRetries` are made.
        case silence(String)
        /// Steam ended the session because the same account signed in somewhere else.
        case sessionConflict(String)

        var message: String {
            switch self {
            case .final(let message), .transient(let message), .silence(let message), .sessionConflict(let message):
                return message
            }
        }

        var isTransient: Bool {
            switch self {
            case .transient, .silence: return true
            case .final, .sessionConflict: return false
            }
        }

        var endedBySilence: Bool {
            if case .silence = self { return true }
            return false
        }
    }
    /// The private bookkeeping of one run, which `resetRunState` puts back in one step. What
    /// observers read stays in the observed properties, which it resets one by one.
    private struct RunState {
        var pauseRequested = false
        var discardPartialRequested = false
        var readingLicense = false
        var licenseIsActive = false
        /// The method this pass's output has named for Steam Guard so far (the email wording, or the
        /// mobile app's), which a later code prompt is read by: the prompt's own words do not say.
        var steamGuardMethod: SteamGuardChallenge?
        /// A Steam Guard code was submitted in this pass and Steam has not answered yet.
        var steamGuardAnswered = false
        var cachedCredentialsRejected = false
        var assetsDownloadCompleted = false
        /// The folder SteamCMD named when it finished the shared assets' depot, as it printed it.
        var reportedDepotPath: String?
        /// This run's private SteamCMD home, where a depot download may land.
        var staging: URL?
        var workshopDownloadCompleted = false
        /// The run's second pass, which fetches the wallpaper a downloaded preset is based on.
        var fetchingPresetBase = false
        /// What the base pass says while it starts and transfers, naming the base when Steam lists it.
        var presetBaseStatus: String?
        /// The item the current pass fetches; transfer progress counts only its files.
        var transferItem: String?
        var signInHandedOff = false
        /// Whether Steam accepted the sign-in at any point in this run, including one an earlier
        /// launch of SteamCMD made: what separates a dropped connection from a refused sign-in.
        var signInAccepted = false
        var loggedStatus = ""
        var recentOutput = ""
        /// The run's last lines of output, redacted as they arrive, for `failureOutput`.
        var outputTail: [String] = []
        var outputTailPartial = ""
        var account = ""
        /// What the log calls this run, for lines written outside the run itself.
        var label = ""
        var lastActivity = Date()
        /// When a byte counter last grew in this run. SteamCMD prints nothing while it fetches a
        /// Workshop item, so arriving bytes, not terminal output, are what show a transfer is alive.
        var lastTransferProgress: Date?
        var transferMarks: [TransferMeter: Int64] = [:]
        /// How the pass in progress failed; nil while it has not.
        var failure: PassFailure?
        var receivesNetwork = false
        var networkStarted = false
        var expectedBytes: Int64?
        var lastDiskSample = Date.distantPast
        var estimator = TransferEstimator()
        /// The most bytes this run has shown. Each SteamCMD launch starts its own network meter and the
        /// tree can shrink as Steam moves chunks about, so what is shown never drops below it.
        var receivedFloor: Int64 = 0
        /// What the run had shown when the current network meter started. A relaunched SteamCMD
        /// resumes from Steam's partial manifests and its meter counts only the bytes still to come,
        /// so the figure shown is this baseline plus the meter, never the meter alone.
        var receivedBaseline: Int64 = 0
        /// Passes already repeated after a `PassFailure.silence`. Each one costs the whole inactivity
        /// limit, so only `maximumSilentRetries` of them are repeated.
        var silentRetries = 0
    }
    @ObservationIgnored private var run = RunState()
    private(set) var isRunning = false
    private(set) var phase = Phase.preparing
    private(set) var wasCancelled = false
    private(set) var completedSuccessfully = false
    @ObservationIgnored private let checkpointDirectory: URL?
    private(set) var status = String(localized: "Ready to download")
    private(set) var progress: Double?
    private(set) var bytesReceived: Int64?
    private(set) var bytesExpected: Int64?
    private(set) var bytesPerSecond: Double?
    /// Seconds until the transfer in progress finishes at its recent pace, or nil while there is
    /// no trustworthy pace (the first seconds, a crawl, the last bytes, nothing measurable).
    var secondsRemaining: Int? {
        guard isRunning, run.receivesNetwork, let received = bytesReceived, let expected = bytesExpected else { return nil }
        return run.estimator.secondsRemaining(remaining: expected - received)
    }
    private(set) var prompt: Prompt?
    private(set) var steamGuardChallenge: SteamGuardChallenge?
    var canRetryAuthentication: Bool { authenticationFailed && !isRunning }
    private var authenticationFailed = false
    private(set) var errorMessage: String?
    private(set) var downloadedID: String?
    /// What a run fetches: one Workshop item (a preset's base wallpaper comes along in a second
    /// pass), the shared scene assets, or nothing. A sign-in-only run signs in, checks ownership,
    /// and downloads nothing; the welcome guide and Settings use it to verify an account and save
    /// its sign-in ahead of any download.
    enum RunKind: Equatable {
        case item(String)
        case assets
        case signInOnly

        var itemID: String? {
            if case .item(let id) = self { return id }
            return nil
        }
    }
    /// The kind of the current or last run; nil before the first.
    private(set) var runKind: RunKind?
    var isInstallingAssets: Bool { runKind == .assets }
    var isSigningInOnly: Bool { runKind == .signInOnly }
    private(set) var savedAccount: String?
    private(set) var sessionWarning: String?
    @ObservationIgnored private let sessionDirectory: URL
    @ObservationIgnored private let runtimeProvider: any SteamCMDRuntimeProviding
    /// The download region each run's SteamCMD config starts from, read as the run starts.
    @ObservationIgnored private let downloadRegion: @Sendable () -> SteamCMDDownloadRegion
    @ObservationIgnored private let networkMonitor: any ProcessNetworkMonitoring
    @ObservationIgnored private var process: SteamCMDTerminalProcess?
    @ObservationIgnored private var terminal: FileHandle?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onFinished: (@MainActor () -> Void)?
    /// Called once per run when Steam accepts the sign-in, after the session was saved (when
    /// remembered), so another session can restore it while this download is still running.
    @ObservationIgnored var onAuthenticated: (@MainActor () -> Void)?
    /// Steam ended this session because the same account signed in from somewhere else.
    private(set) var endedBySessionConflict = false
    /// SteamCMD ended before Steam accepted the sign-in, without a word from Steam about why:
    /// no rejected password or code, no failure reason. An outdated SteamCMD ends this way.
    private(set) var endedBeforeSignInUnexplained = false
    /// What SteamCMD printed before the last run failed, redacted (`SteamCMDFailureLog`); nil after
    /// a run that did not fail.
    @ObservationIgnored private(set) var failureOutput: String?
    @ObservationIgnored private var outputBuffer = [UInt8](repeating: 0, count: 8192)
    nonisolated static let stagingPrefix = ".WallpaperMachine-workshop-"
    nonisolated private static let ownerName = "owner"
    /// How long a run may go without output or transfer progress before it is stopped.
    @ObservationIgnored private let inactivityTimeout: TimeInterval
    /// How long one pass may run before it is stopped, once it has also stopped transferring.
    @ObservationIgnored private let passTimeout: TimeInterval
    /// The clock both limits are measured on.
    @ObservationIgnored private let now: () -> Date
    /// Free bytes on the volume that holds a folder, as the system would hand them to this app.
    @ObservationIgnored private let freeSpace: @Sendable (URL) -> Int64?
    /// Steam's listing of one Workshop item (title and size), for a preset's base; nil when it
    /// cannot be read. Tests pass their own.
    typealias ItemDetails = @Sendable (String) async -> WorkshopItem?
    @ObservationIgnored private let itemDetails: ItemDetails
    @ObservationIgnored private var diskSampleTask: Task<Void, Never>?
    /// How long to wait before each automatic retry of a dropped connection; one entry per retry
    /// the pass may use.
    @ObservationIgnored private let retryDelays: [TimeInterval]
    nonisolated static let maximumSilentRetries = 1
    /// Retries the pass in progress has used; a preset's base wallpaper starts its own count.
    private(set) var retryAttempt = 0
    /// When the Mac last woke while a transfer was running, until bytes arrive again or SteamCMD is
    /// relaunched. Sleep usually kills the connection without a word from SteamCMD, so the wait
    /// for the inactivity limit is replaced by a short watch for bytes.
    @ObservationIgnored private(set) var resumedAt: Date?
    /// How long after a wake a transfer may stay silent before it is restarted.
    @ObservationIgnored private let resumeGrace: TimeInterval
    private(set) var isAuthenticating = true
    /// SteamCMD exits with this status when it wants to be started again after updating itself.
    nonisolated private static let restartStatus: Int32 = 42
    nonisolated private static let maximumRestarts = 4
    private static let failurePattern = try! NSRegularExpression(pattern: #"(?:failed|error!?)\s*\(([^)\r\n]+)\)"#)

    /// The parenthesised reason SteamCMD gives a failure, such as `Timeout` in `failed (Timeout)`.
    private static func failureReason(in output: String) -> String? {
        guard let match = failurePattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }

    /// Wallpaper Engine's content depot: the Windows application with its `assets` folder (about
    /// 800 MB on disk). The shared assets come from this depot alone. `app_update` on the whole
    /// app also brought whatever Steam ties to the account (DLC, and in one report tens of
    /// gigabytes it would not name), only to keep the `assets` folder.
    nonisolated static let sceneAssetsDepotID = "431961"
    /// "Downloading depot 431961 (788 MB) ..." or "(241 files, 788 MB)": the size Steam gives it.
    nonisolated private static let depotSizePattern = try! NSRegularExpression(pattern: #"downloading depot \d+ \((?:[^)]*,\s*)?(\d+(?:\.\d+)?)\s*(kb|mb|gb)\)"#)
    /// "Depot download complete : "<folder>" (…)": the folder, as SteamCMD prints it.
    private static let depotFolderPattern = try! NSRegularExpression(pattern: #""([^"]+)""#)
    nonisolated private static let sessionLock = NSLock()

    init(sessionDirectory: URL = ClientPaths.steamSessionURL(),
         runtimeProvider: any SteamCMDRuntimeProviding = SteamCMDRuntimeService(),
         networkMonitor: (any ProcessNetworkMonitoring)? = nil, checkpointDirectory: URL? = nil,
         inactivityTimeout: TimeInterval = 300, passTimeout: TimeInterval = 1800,
         now: @escaping () -> Date = Date.init,
         freeSpace: @escaping @Sendable (URL) -> Int64? = WorkshopDownloader.systemFreeSpace,
         retryDelays: [TimeInterval] = [2, 8, 30], resumeGrace: TimeInterval = 45,
         itemDetails: @escaping ItemDetails = WorkshopDownloader.publicItemDetails,
         downloadRegion: @escaping @Sendable () -> SteamCMDDownloadRegion = { .steamsChoice }) {
        self.sessionDirectory = sessionDirectory
        self.downloadRegion = downloadRegion
        self.checkpointDirectory = checkpointDirectory
        self.inactivityTimeout = inactivityTimeout
        self.passTimeout = passTimeout
        self.now = now
        self.freeSpace = freeSpace
        self.itemDetails = itemDetails
        self.retryDelays = retryDelays
        self.resumeGrace = resumeGrace
        self.runtimeProvider = runtimeProvider
        self.networkMonitor = networkMonitor ?? ProcessNetworkMonitor()
        savedAccount = Self.readSavedAccount(at: sessionDirectory)
    }

    func forgetSavedAccount() {
        guard !isRunning else { return }
        do {
            try Self.removeSession(at: sessionDirectory)
            savedAccount = nil
            sessionWarning = nil
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Could not log out of Steam: \(error.localizedDescription)")
        }
    }

    func start(item: WorkshopItem, username: String, executable: URL, library: URL, rememberSession: Bool = true, onImported: @escaping @MainActor () async throws -> Void) {
        guard !isRunning else { return }
        guard let id = UInt64(item.id), id > 0, item.id.allSatisfy({ $0.isASCII && $0.isNumber }), item.kind != .application else {
            errorMessage = String(localized: "Choose a valid Workshop wallpaper. Application wallpapers execute Windows programs and cannot be used on macOS.")
            return
        }
        download(kind: .item(item.id), username: username, executable: executable, root: library.deletingLastPathComponent(),
                 rememberSession: rememberSession, expectedBytes: item.size > 0 ? item.size : nil,
                 followUp: { staging in
                     // A Workshop preset is only property values; the wallpaper it is based on comes too.
                     try await WallpaperImportService().presetBaseToDownload(item.id, in: staging, library: library)
                 }) { staging in
            self.phase = .finishing
            self.status = String(localized: "Validating and adding to your library…")
            // A download of a wallpaper already in the library is its update, and replaces it.
            try await WallpaperImportService().importDownloadedItem(item.id, from: staging, into: library, replacing: true)
            self.clearTransferFigures()
            self.downloadedID = item.id
            self.status = String(localized: "Downloaded to your library")
            do { try await onImported() }
            catch { self.errorMessage = String(localized: "Downloaded, but the library could not refresh: \(error.localizedDescription). Refresh the library before applying it.") }
        }
    }

    func installAssets(username: String, executable: URL, destination: URL, rememberSession: Bool = true, onInstalled: @escaping @MainActor () throws -> Void) {
        download(kind: .assets, username: username, executable: executable, root: destination.deletingLastPathComponent(), rememberSession: rememberSession) { content in
            self.phase = .finishing
            self.status = String(localized: "Validating and installing scene assets…")
            let staging = self.run.staging ?? content
            let candidates = Self.depotFolders(reported: self.run.reportedDepotPath, staging: staging, content: content)
            let depot = candidates.first { ClientPaths.hasSceneAssets(at: $0.appendingPathComponent("assets")) }
                ?? candidates[0]
            try ClientPaths.installSceneAssets(from: depot.appendingPathComponent("assets"), to: destination)
            self.clearTransferFigures()
            try onInstalled()
            self.status = String(localized: "Scene assets installed")
        }
    }

    /// Signs in, checks ownership, and quits using the same password and Steam Guard prompts
    /// as a download; with `rememberSession` the accepted sign-in is saved for later downloads.
    func signIn(username: String, executable: URL, root: URL, rememberSession: Bool = true, onSignedIn: @escaping @MainActor () -> Void = {}) {
        download(kind: .signInOnly, username: username, executable: executable, root: root, rememberSession: rememberSession) { _ in
            self.phase = .finishing
            self.status = String(localized: "Signed in to Steam")
            onSignedIn()
        }
    }

    /// `followUp` may name one more Workshop item to fetch into the same staging, in the same
    /// session, once the first has arrived.
    private func download(kind: RunKind, username: String, executable: URL, root: URL, rememberSession: Bool,
                          expectedBytes: Int64? = nil, followUp: (@MainActor (URL) async throws -> String?)? = nil,
                          onDownloaded: @escaping @MainActor (URL) async throws -> Void) {
        guard !isRunning else { return }
        guard let account = Self.normalizedAccount(username) else {
            errorMessage = String(localized: "Enter your Steam account login name (not your display name). An account that owns Wallpaper Engine is required.")
            return
        }
        // Opting out of a remembered sign-in also forgets the one already on disk, so the run
        // neither reuses nor leaves behind a login the user chose not to keep.
        if !rememberSession {
            do {
                try Self.removeSession(at: sessionDirectory)
                savedAccount = nil
            } catch {
                errorMessage = String(localized: "Could not log out of Steam: \(error.localizedDescription)")
                return
            }
        }
        resetRunState(kind: kind, expectedBytes: expectedBytes)
        run.account = account
        let label: String
        switch kind {
        case .item(let id): label = id
        case .assets: label = "scene assets"
        case .signInOnly: label = "sign-in"
        }
        run.label = label
        task = Task {
            await self.performRun(
                itemID: kind.itemID, account: account, executable: executable, root: root,
                rememberSession: rememberSession, label: label, followUp: followUp, onDownloaded: onDownloaded)
        }
    }

    /// Puts every observable and private per-run value back to where a new run begins.
    private func resetRunState(kind: RunKind, expectedBytes: Int64?) {
        isRunning = true
        phase = .preparing
        wasCancelled = false
        completedSuccessfully = false
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        bytesPerSecond = nil
        prompt = nil
        steamGuardChallenge = nil
        authenticationFailed = false
        errorMessage = nil
        downloadedID = nil
        runKind = kind
        sessionWarning = nil
        wallpaperEngineOwnership = .unknown
        endedBySessionConflict = false
        endedBeforeSignInUnexplained = false
        failureOutput = nil
        diskSampleTask?.cancel()
        diskSampleTask = nil
        retryAttempt = 0
        resumedAt = nil
        isAuthenticating = true
        run = RunState()
        run.expectedBytes = expectedBytes
        run.lastActivity = now()
        status = kind == .signInOnly
            ? String(localized: "Preparing a private SteamCMD sign-in…")
            : String(localized: "Preparing a private SteamCMD download…")
    }

    /// The whole life of one run: staging, passes of SteamCMD, hand-over of what arrived, and the
    /// clean-up that always follows, whatever ended it.
    private func performRun(
        itemID: String?, account: String, executable: URL, root: URL, rememberSession: Bool, label: String,
        followUp: (@MainActor (URL) async throws -> String?)?,
        onDownloaded: @escaping @MainActor (URL) async throws -> Void
    ) async {
        // SteamCMD's home (the restored sign-in), its private copy and its temporary files stay
        // beside the saved sign-in, on this Mac. What it fetches goes to `root`, the disk that
        // holds the library, so publishing it is a rename there. Usually both are one folder.
        let name = Self.stagingPrefix + UUID().uuidString
        let runRoot = sessionDirectory.deletingLastPathComponent()
        let staging = runRoot.appendingPathComponent(name, isDirectory: true)
        let content = FileLocation.isSame(runRoot, root) ? staging : root.appendingPathComponent(name, isDirectory: true)
        var claim: Int32 = -1
        var contentClaim: Int32 = -1
        var restoredRevision: UInt64?
        var finishedItem = false
        var failedRun = false
        run.staging = staging
        do {
            let binary = try await runtimeProvider.prepare(executable: executable, staging: staging)
            // Out of backups before anything is downloaded into it.
            ClientPaths.excludeFromBackup(staging)
            claim = Self.claimStaging(staging)
            if content != staging {
                try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                ClientPaths.excludeFromBackup(content)
                contentClaim = Self.claimStaging(content)
            }
            if let checkpoint = checkpointDirectory, isInstallingAssets {
                // A depot download starts over, so nothing an earlier attempt kept is of use: that
                // includes an interrupted `app_update` of the whole app, which could be gigabytes.
                await Task.detached(priority: .utility) {
                    try? WorkshopDownloadCheckpoint.remove(at: checkpoint)
                }.value
            } else if let checkpoint = checkpointDirectory, !isSigningInOnly {
                try await Task.detached(priority: .utility) {
                    try WorkshopDownloadCheckpoint.restore(from: checkpoint, to: content)
                }.value
            }
            if rememberSession {
                let directory = sessionDirectory
                restoredRevision = try await Task.detached(priority: .utility) {
                    try Self.restoreSession(from: directory, account: account, to: staging)
                }.value
            }
            // After the restore, so a saved sign-in's config keeps everything but a far region.
            let region = downloadRegion()
            await Task.detached(priority: .utility) { region.seed(home: staging) }.value
            try Task.checkCancellation()
            try await ensureFreeSpace(under: root, staging: content, item: itemID, label: label)

            var currentItem = itemID
            var followedUp = false
            var restarts = 0
            while true {
                try Task.checkCancellation()
                // Checked again before every launch: a relaunch must not run what has changed.
                try await runtimeProvider.validate(at: staging)
                try launch(executable: binary, staging: staging, content: content, account: account, itemID: currentItem,
                           claim: claim, contentClaim: contentClaim)
                let exitStatus = try await supervise(staging: staging, content: content, account: account, rememberSession: rememberSession)
                if let reason = run.failure?.message {
                    if let delay = nextRetryDelay() {
                        prepareRetry(label: label, delay: delay)
                        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                        try await ensureFreeSpace(under: root, staging: content, item: currentItem, label: label)
                        continue
                    }
                    throw passFailure(reason, itemID: currentItem)
                }
                if exitStatus == Self.restartStatus, restarts < Self.maximumRestarts {
                    restarts += 1
                    try await ensureFreeSpace(under: root, staging: content, item: currentItem, label: label)
                    continue
                }
                try judgeExit(exitStatus, itemID: currentItem)
                if let followUp, !followedUp, !run.fetchingPresetBase, itemID != nil,
                   let base = try await followUp(content) {
                    // One more item in the same session, never a chain of them.
                    followedUp = true
                    run.fetchingPresetBase = true
                    currentItem = base
                    run.workshopDownloadCompleted = false
                    run.receivedFloor = 0
                    run.receivedBaseline = 0
                    retryAttempt = 0
                    run.silentRetries = 0
                    // Steam's listing names the base and gives its size, so its progress has a
                    // total and the disk is checked for it as for any item.
                    let listing = await itemDetails(base)
                    self.run.expectedBytes = listing.flatMap { $0.size > 0 ? $0.size : nil }
                    if let listing, !listing.title.isEmpty {
                        let size = listing.size > 0
                            ? ByteCountFormatter.string(fromByteCount: listing.size, countStyle: .file) : nil
                        run.presetBaseStatus = size.map { String(localized: "Downloading “\(listing.title)” (\($0)), the wallpaper this preset is based on…") }
                            ?? String(localized: "Downloading “\(listing.title)”, the wallpaper this preset is based on…")
                    } else {
                        run.presetBaseStatus = String(localized: "Downloading the wallpaper this preset is based on…")
                    }
                    status = run.presetBaseStatus ?? status
                    try await ensureFreeSpace(under: root, staging: content, item: currentItem, label: label)
                    continue
                }
                break
            }
            try Task.checkCancellation()
            try await onDownloaded(content)
            finishedItem = true
            completedSuccessfully = true
        } catch is CancellationError {
            if run.pauseRequested {
                status = String(localized: "Download paused")
            } else {
                wasCancelled = true
                status = String(localized: "Download cancelled")
            }
            failedRun = false
        } catch {
            failedRun = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            failureOutput = failureTranscript(label: label)
            status = isSigningInOnly
                ? String(localized: "Sign-in could not finish")
                : String(localized: "Download could not finish")
        }

        // From here on nothing may depend on the task still being live.
        await stopProcess()
        terminal = nil
        diskSampleTask?.cancel()
        diskSampleTask = nil
        prompt = nil
        steamGuardChallenge = nil
        if failedRun || wasCancelled || run.pauseRequested {
            progress = nil
            bytesReceived = nil
            bytesExpected = nil
        }
        bytesPerSecond = nil
        run.receivesNetwork = false
        resumedAt = nil

        if rememberSession {
            await settleSession(staging: staging, account: account, restoredRevision: restoredRevision)
        }
        // SteamCMD cannot resume a depot download, so the shared assets keep nothing for later.
        let keepForLater = !finishedItem && !isSigningInOnly && !isInstallingAssets
            && (failedRun || (run.pauseRequested && !wasCancelled))
        await retireStaging(staging, content: content, keepingPartialData: keepForLater && !run.discardPartialRequested)
        if claim >= 0 { close(claim) }
        if contentClaim >= 0 { close(contentClaim) }

        isRunning = false
        task = nil
        run.pauseRequested = false
        onFinished?()
    }

    /// What SteamCMD's exit says about a pass that reported no failure of its own.
    private func judgeExit(_ exitStatus: Int32, itemID: String?) throws {
        let confirmed = isSigningInOnly ? !isAuthenticating
            : isInstallingAssets ? run.assetsDownloadCompleted : run.workshopDownloadCompleted
        if exitStatus != 0 {
            authenticationFailed = isAuthenticating && !run.signInAccepted
            // Only the step it ended in is logged, never what SteamCMD printed.
            AppLog.warn("SteamCMD \(run.label): exited with status \(exitStatus) while \(phase.rawValue) (sign-in accepted: \(run.signInAccepted), Steam Guard answered: \(run.steamGuardAnswered))")
            endedBeforeSignInUnexplained = authenticationFailed
            // Before Steam accepts the sign-in, ownership has not been asked about yet.
            throw passFailure(isSigningInOnly || authenticationFailed
                ? String(localized: "SteamCMD exited before confirming the sign-in. Check the account name and password, approve Steam Guard, and retry.")
                : String(localized: "SteamCMD exited before completing the download. Confirm this account owns Wallpaper Engine, approve Steam Guard, and retry."),
                itemID: itemID)
        }
        guard confirmed else {
            if isSigningInOnly {
                authenticationFailed = true
                endedBeforeSignInUnexplained = isAuthenticating && !run.signInAccepted
                throw WorkshopFailure(message: String(localized: "Steam closed the session without confirming the sign-in. Check the account name and password, then retry."))
            }
            throw passFailure(isInstallingAssets
                ? String(localized: "Steam exited without confirming a complete Wallpaper Engine installation. Retry installing scene assets; existing assets have not been changed.")
                : String(localized: "Steam exited without confirming a complete Workshop download. Retry; no partial wallpaper has been added to your library."),
                itemID: itemID)
        }
    }

    /// Watches one SteamCMD pass every 200 ms until it ends or has to be stopped, and returns its
    /// exit status once the rest of its output has been read.
    private func supervise(staging: URL, content: URL, account: String, rememberSession: Bool) async throws -> Int32 {
        let passStarted = now()
        do {
            while true {
                try Task.checkCancellation()
                try readTerminalOutput()
                if status != run.loggedStatus {
                    run.loggedStatus = status
                    AppLog.info("SteamCMD \(run.label): \(status)")
                }
                if run.signInAccepted, !run.signInHandedOff {
                    run.signInHandedOff = true
                    if rememberSession { await saveAcceptedSession(from: staging, account: account) }
                    onAuthenticated?()
                }
                if run.receivesNetwork, !run.networkStarted, let pid = process?.processIdentifier {
                    run.networkStarted = true
                    run.receivedBaseline = run.receivedFloor
                    networkMonitor.start(processID: pid)
                }
                if run.receivesNetwork, run.networkStarted {
                    noteTransfer(networkMonitor.bytesReceived(), on: .network)
                    bytesPerSecond = networkMonitor.rate(at: ProcessInfo.processInfo.systemUptime)
                    sampleTransferDisk(staging: staging, content: content)
                }
                if run.failure == nil { checkLimits(passStarted: passStarted) }
                if run.failure != nil {
                    await stopProcess()
                    break
                }
                if process?.isRunning != true {
                    // Output can still be in flight through the terminal just after the exit: one
                    // more interval, then it is read below and the pass is judged.
                    try await Task.sleep(for: .milliseconds(200))
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            await stopProcess()
            try readTerminalOutput()
            consumeUnterminatedOutput()
            let exitStatus = process?.terminationStatus ?? -1
            terminal = nil
            return exitStatus
        } catch {
            await stopProcess()
            throw error
        }
    }

    /// Ends a pass that has stopped being alive: a transfer that stayed silent after a wake, a run
    /// that has said and moved nothing for the inactivity limit, or one that outlived its pass limit
    /// and also stopped receiving bytes.
    private func checkLimits(passStarted: Date) {
        let current = now()
        if let woke = resumedAt {
            if let moved = run.lastTransferProgress, moved >= woke {
                resumedAt = nil
            } else if current.timeIntervalSince(woke) >= resumeGrace {
                resumedAt = nil
                setFailure(.transient(String(localized: "The connection to Steam stopped responding after the Mac woke from sleep. Check your connection and try again; what was already downloaded is kept.")))
                return
            }
        }
        let silent = current.timeIntervalSince(run.lastActivity) > inactivityTimeout
        let bytesStopped = current.timeIntervalSince(run.lastTransferProgress ?? passStarted) > inactivityTimeout
        let overlong = current.timeIntervalSince(passStarted) > passTimeout && bytesStopped
        guard silent || overlong else { return }
        // Steam Guard help only fits where the user may still be answering a sign-in.
        let awaitingUser = !run.signInAccepted || prompt != nil || steamGuardChallenge != nil
        if awaitingUser {
            setFailure(.final(String(localized: "SteamCMD timed out. If Steam Guard was not completed, retry signing in and approve the new request or enter a fresh code. Otherwise check your connection and available disk space.")))
        } else {
            setFailure(.silence(String(localized: "SteamCMD stopped receiving the download. Check your connection and available disk space, then try again.")))
        }
    }

    /// Records how the pass failed, once. A failure is transient only once Steam has accepted the
    /// sign-in and the run downloads something; everything the user has to decide is final.
    private func setFailure(_ failure: PassFailure) {
        guard run.failure == nil else { return }
        switch failure {
        case .transient(let message), .silence(let message):
            run.failure = run.signInAccepted && !isSigningInOnly ? failure : PassFailure.final(message)
        case .final, .sessionConflict:
            run.failure = failure
        }
        if case .sessionConflict = failure {
            authenticationFailed = isAuthenticating
        } else {
            authenticationFailed = isAuthenticating && !run.signInAccepted
        }
        prompt = nil
        steamGuardChallenge = nil
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        bytesPerSecond = nil
        run.receivesNetwork = false
    }

    /// Keeps, after a run, the sign-in Steam accepted and drops one it rejected.
    private func settleSession(staging: URL, account: String, restoredRevision: UInt64?) async {
        let directory = sessionDirectory
        let authenticated = !isAuthenticating && !authenticationFailed
        do {
            if authenticated {
                let stored = try await Task.detached(priority: .utility) {
                    try Self.saveSession(from: staging, account: account, to: directory)
                }.value
                if !stored {
                    sessionWarning = String(localized: "This Steam sign-in did not provide reusable authentication information, so you may be asked to sign in again later.")
                }
            } else if run.cachedCredentialsRejected, let restoredRevision {
                try await Task.detached(priority: .utility) {
                    try Self.invalidateSession(at: directory, account: account, revision: restoredRevision)
                }.value
            }
        } catch {
            sessionWarning = String(localized: "Steam authentication information retained on this device could not be updated (\(error.localizedDescription)); you may need to sign in again later.")
        }
        savedAccount = Self.readSavedAccount(at: directory)
    }

    /// Removes the staging folders, or first moves what a later resume needs into the checkpoint.
    private func retireStaging(_ staging: URL, content: URL, keepingPartialData: Bool) async {
        let checkpoint = checkpointDirectory
        let keep = keepingPartialData ? checkpoint : nil
        let saveFailure = await Task.detached(priority: .utility) { () -> Error? in
            var failure: Error?
            if let keep {
                do { try WorkshopDownloadCheckpoint.save(from: content, to: keep) } catch { failure = error }
            }
            try? FileManager.default.removeItem(at: staging)
            if content != staging { try? FileManager.default.removeItem(at: content) }
            return failure
        }.value
        if let saveFailure {
            errorMessage = errorMessage ?? String(localized: "Could not save partial download data: \(saveFailure.localizedDescription)")
        }
        // A cancel that arrived while the data was being moved still discards it.
        if run.discardPartialRequested, let checkpoint {
            try? WorkshopDownloadCheckpoint.remove(at: checkpoint)
        }
    }

    /// The ring stays full while the finished download is validated; once that is done nothing of
    /// the transfer is left to show.
    private func clearTransferFigures() {
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        bytesPerSecond = nil
    }

    /// What a failed pass is reported as. The second pass of a preset fetches its base wallpaper: the
    /// preset has already arrived, but without its base nothing is added, and the user should hear
    /// that rather than a bare "could not download this wallpaper" about an item they never chose.
    private func passFailure(_ reason: String, itemID: String?) -> WorkshopFailure {
        guard run.fetchingPresetBase, let itemID else { return WorkshopFailure(message: reason) }
        return WorkshopFailure(message: String(localized: "The preset downloaded, but the wallpaper it is based on (Workshop item \(itemID)) did not, so nothing was added to your library. \(reason)"))
    }

    /// Stops a download that cannot fit before SteamCMD starts, instead of letting it stall for
    /// the inactivity limit and blame the connection. It runs on every start (first, resume,
    /// Try again) after any checkpoint is restored, and again before each automatic relaunch
    /// of SteamCMD (a retry after a dropped connection or a wake, or Steam asking to be
    /// started again), so a retry only needs the space still missing. A preset's base is
    /// checked before its pass at the size Steam lists for it (not at all when it lists none);
    /// concurrent jobs are checked one by one, not summed. Only `item`'s own files count as
    /// already staged, so a preset on the disk is not taken for part of its base.
    private func ensureFreeSpace(under root: URL, staging: URL, item: String?, label: String) async throws {
        let installingAssets = isInstallingAssets
        let expected = run.expectedBytes
        guard !isSigningInOnly,
              Self.requiredFreeBytes(expected: expected, alreadyStaged: 0, installingAssets: installingAssets) != nil
        else { return }
        // What an item already has under the Workshop tree counts; the shared assets' depot
        // download starts over every time, so nothing of theirs does.
        let content = staging.appendingPathComponent("steamapps/workshop", isDirectory: true)
        let measure = freeSpace
        let (staged, available) = await Task.detached(priority: .utility) { () -> (Int64, Int64?) in
            (installingAssets ? 0 : Self.bytesOnDisk(under: content, item: item), measure(root))
        }.value
        guard let needed = Self.requiredFreeBytes(expected: expected, alreadyStaged: staged, installingAssets: installingAssets),
              let available, available < needed else { return }
        AppLog.warn("SteamCMD \(label): not enough free space (need \(needed), have \(available))")
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let neededText = formatter.string(fromByteCount: needed)
        let availableText = formatter.string(fromByteCount: available)
        throw WorkshopFailure(message: String(localized: "Not enough free disk space: this download needs about \(neededText) and only \(availableText) is available on the disk that holds your library. Free up space, then try again."))
    }

    /// Free bytes the system would give this app on the volume holding `url`, counting space it
    /// can reclaim on demand (purgeable caches, local snapshots), or the plain free space when that
    /// is higher; nil when it cannot be read.
    nonisolated static func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        return usableCapacity(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            plain: values.volumeAvailableCapacity.map(Int64.init))
    }

    /// The larger of the two figures macOS gives for a volume. The important-usage figure counts
    /// reclaimable space and so is normally the larger, but on some Macs it reads 0 for every
    /// volume while the plain free space is right; a 0 would look like a full disk and block every
    /// download, so the plain figure is used when it is higher. Nil only when neither can be read.
    nonisolated static func usableCapacity(importantUsage: Int64?, plain: Int64?) -> Int64? {
        switch (importantUsage, plain) {
        case let (important?, plain?): max(important, plain)
        case let (important?, nil): important
        case let (nil, plain?): plain
        case (nil, nil): nil
        }
    }

    /// What a download asks Steam's public details endpoint by default; tests pass their own.
    nonisolated static let publicItemDetails: ItemDetails = { id in
        try? await WorkshopService().details(ids: [id]).first
    }

    /// What a download reads by default; tests pass their own disk instead.
    nonisolated static let systemFreeSpace: @Sendable (URL) -> Int64? = { availableCapacity(at: $0) }

    /// Room kept beyond the content itself for Steam's manifests and the private runtime.
    nonisolated static let freeSpaceMargin: Int64 = 64 * 1024 * 1024
    /// What a Workshop item needs on top of its listed size while Steam stages and assembles it.
    nonisolated static let freeSpaceHeadroom = 1.15
    /// The shared assets' depot has no size to read before SteamCMD names it, so a fixed floor
    /// stands in: the depot (about 800 MB on disk) and the assets copied out of it, with room
    /// to spare. It is meant to block only when the disk is clearly short.
    nonisolated static let sceneAssetsFreeBytes: Int64 = 3 * 1024 * 1024 * 1024

    /// The free space a download needs before it starts, or nil when nothing can be said and the
    /// download is never blocked: a sign-in-only run, or an item whose listing gives no size.
    /// Bytes an earlier attempt already staged for an item are on the disk and are not needed
    /// again; the shared assets always need the whole floor, since their download starts over.
    nonisolated static func requiredFreeBytes(expected: Int64?, alreadyStaged: Int64, installingAssets: Bool) -> Int64? {
        if installingAssets { return sceneAssetsFreeBytes }
        guard let expected, expected > 0 else { return nil }
        // A listed size beyond a pebibyte is a bad listing, not a disk that needs it.
        let remaining = max(0, min(expected, 1 << 50) - max(0, alreadyStaged))
        return Int64((Double(remaining) * freeSpaceHeadroom).rounded(.up)) + freeSpaceMargin
    }

    /// How long to wait before trying the pass again, or nil when this failure is the user's to
    /// handle: only a connection lost after Steam accepted the sign-in is retried, and never once
    /// the budget is spent, Steam asked for a password or Guard, rejected the saved sign-in, or
    /// ended the session for a sign-in elsewhere. A pass that went silent for the whole inactivity
    /// limit is repeated once at most, since each repeat can cost that long again. Waits vary a
    /// little so parallel jobs that lost the same connection do not all come back in the same second.
    private func nextRetryDelay() -> TimeInterval? {
        guard let failure = run.failure, failure.isTransient, retryAttempt < retryDelays.count,
              !run.cachedCredentialsRejected, !endedBySessionConflict, !isSigningInOnly, prompt == nil,
              steamGuardChallenge == nil, !failure.endedBySilence || run.silentRetries < Self.maximumSilentRetries
        else { return nil }
        let delay = retryDelays[retryAttempt]
        return delay > 0 ? delay * Double.random(in: 0.8...1.2) : 0
    }

    private func prepareRetry(label: String, delay: TimeInterval) {
        retryAttempt += 1
        if run.failure?.endedBySilence == true { run.silentRetries += 1 }
        run.failure = nil
        authenticationFailed = false
        phase = .connecting
        status = String(localized: "Connection lost; retrying (\(retryAttempt) of \(retryDelays.count))…")
        AppLog.warn("SteamCMD \(label): connection lost after sign-in; retry \(retryAttempt) of \(retryDelays.count) in \(Int(delay.rounded())) s")
    }

    /// The Mac woke from sleep. A transfer that was running is watched rather than trusted: if no
    /// byte arrives within `resumeGrace`, SteamCMD is relaunched through the retry path, and one
    /// that keeps receiving is left alone. A run that was signing in or requesting has nothing to
    /// restart (Steam Guard may be waiting for the user), so only a transfer in progress counts.
    func noteSystemResume() {
        guard isRunning, !isSigningInOnly, run.receivesNetwork, phase == .transferring, run.failure == nil else { return }
        resumedAt = now()
        AppLog.info("SteamCMD \(run.label): Mac woke; watching for bytes")
    }

    func submitSecret(_ value: String) {
        guard isRunning, prompt != nil, !value.isEmpty,
              !value.contains(where: { $0.isNewline }), !value.utf8.contains(0),
              let terminal else { return }
        do {
            // The only place a secret goes: the terminal's input, never an argument or a file.
            try terminal.write(contentsOf: Data((value + "\n").utf8))
        } catch {
            setFailure(.final(String(localized: "SteamCMD closed its login prompt. Retry signing in to start a new session.")))
            authenticationFailed = true
            return
        }
        if prompt == .guardCode {
            // The code is Steam's to judge now; a card that still asks for it has no field to fill.
            run.steamGuardAnswered = true
            steamGuardChallenge = nil
        }
        prompt = nil
        run.recentOutput = ""
        phase = .signingIn
        status = String(localized: "Waiting for Steam authentication…")
        run.lastActivity = now()
    }

    func pause() {
        guard isRunning, !isSigningInOnly else { return }
        run.pauseRequested = true
        task?.cancel()
        status = String(localized: "Pausing…")
    }

    func discardCheckpoint() {
        guard !isRunning, let checkpointDirectory else { return }
        try? WorkshopDownloadCheckpoint.remove(at: checkpointDirectory)
    }

    func cancel() {
        guard isRunning else { return }
        run.pauseRequested = false
        run.discardPartialRequested = true
        wasCancelled = true
        run.receivesNetwork = false
        bytesPerSecond = nil
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        task?.cancel()
        status = String(localized: "Cancelling…")
    }

    func shutdown() async {
        guard let current = task else { return }
        run.receivesNetwork = false
        bytesPerSecond = nil
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        current.cancel()
        await current.value
    }

    private func launch(executable: URL, staging: URL, content: URL, account: String, itemID: String?, claim: Int32,
                        contentClaim: Int32) throws {
        run.transferItem = itemID
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw WorkshopFailure(message: String(localized: "Could not create a private terminal for SteamCMD. Restart WallpaperMachine and retry."))
        }
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            settings.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(slave, TCSANOW, &settings)
        }
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) != -1 else {
            close(master)
            close(slave)
            throw WorkshopFailure(message: String(localized: "Could not read SteamCMD’s private terminal without blocking. Restart WallpaperMachine and retry."))
        }

        // The state of one pass starts from nothing.
        run.recentOutput = ""
        keepOutputLine("--- SteamCMD started ---")
        run.readingLicense = false
        run.licenseIsActive = false
        prompt = nil
        steamGuardChallenge = nil
        run.steamGuardMethod = nil
        run.steamGuardAnswered = false
        isAuthenticating = true
        run.receivesNetwork = false
        run.networkStarted = false
        run.lastActivity = now()
        run.lastTransferProgress = nil
        resumedAt = nil
        run.transferMarks = [:]

        let tmp = staging.appendingPathComponent("tmp", isDirectory: true)
        let installDirectory = isInstallingAssets ? content.appendingPathComponent("wallpaper-engine", isDirectory: true) : content
        var arguments = ["-inhibitbootstrap", "+@ShutdownOnFailedCommand", "1"]
        if isInstallingAssets { arguments += ["+@sSteamCmdForcePlatformType", "windows"] }
        arguments += ["+force_install_dir", installDirectory.path, "+login", account]
        if isSigningInOnly {
            arguments += ["+licenses_for_app", "431960"]
        } else if let itemID {
            arguments += ["+workshop_download_item", "431960", itemID]
        } else {
            arguments += ["+download_depot", "431960", Self.sceneAssetsDepotID]
        }
        arguments.append("+quit")
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": staging.path,
            "TMPDIR": tmp.path,
            "DYLD_LIBRARY_PATH": staging.path,
            "DYLD_FRAMEWORK_PATH": staging.path,
            "TERM": "dumb",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        do {
            try Self.privateDirectory(tmp)
            process = try SteamCMDTerminalProcess(
                executable: executable, arguments: arguments, workingDirectory: staging,
                environment: environment, master: master, slave: slave, claim: claim, contentClaim: contentClaim)
        } catch {
            close(master)
            close(slave)
            throw WorkshopFailure(message: String(localized: "Cannot launch SteamCMD: \(error.localizedDescription). Reinstall SteamCMD in Settings → Library & Steam to get Valve’s Apple silicon version."))
        }
        // The child holds its own copy; keeping ours would stop the terminal from ever closing.
        close(slave)
        terminal = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        phase = .connecting
        status = run.presetBaseStatus ?? String(localized: "Starting SteamCMD and contacting Steam…")
    }

    private func readTerminalOutput() throws {
        guard let terminal else { return }
        // At most this many reads per call, so a flood of output cannot hold the main actor.
        for _ in 0..<64 {
            let count = Darwin.read(terminal.fileDescriptor, &outputBuffer, outputBuffer.count)
            if count > 0 {
                consume(String(decoding: outputBuffer[0..<count], as: UTF8.self))
                continue
            }
            if count == 0 { return }
            switch errno {
            case EINTR: continue
            // Nothing more yet, or the other end is gone: both just end this read.
            case EAGAIN, EIO: return
            default:
                throw WorkshopFailure(message: String(localized: "Lost the connection to SteamCMD’s login terminal. Retry signing in."))
            }
        }
    }

    private func consume(_ text: String) {
        guard isRunning else { return }
        run.lastActivity = now()
        keepOutput(text)
        run.recentOutput += text.lowercased()
        while let newline = run.recentOutput.firstIndex(where: { $0.isNewline }) {
            let line = String(run.recentOutput[..<newline])
            run.recentOutput.removeSubrange(...newline)
            consumeOwnershipLine(line)
            consumeLine(line)
        }
        // An old prompt must not mask a later failure, and a prompt has no newline to wait for.
        if run.recentOutput.count > 4096 { run.recentOutput = String(run.recentOutput.suffix(4096)) }
        consumeLine(run.recentOutput, complete: false)
    }

    /// Adds output to the run's tail, a line at a time once its end has arrived.
    private func keepOutput(_ text: String) {
        run.outputTailPartial += text
        while let end = run.outputTailPartial.firstIndex(where: { $0.isNewline }) {
            let line = String(run.outputTailPartial[..<end])
            run.outputTailPartial.removeSubrange(...end)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { keepOutputLine(line) }
        }
        if run.outputTailPartial.count > SteamCMDFailureLog.maximumLineLength * 4 {
            keepOutputLine(run.outputTailPartial)
            run.outputTailPartial = ""
        }
    }

    private func keepOutputLine(_ line: String) {
        run.outputTail.append(SteamCMDFailureLog.redacted(line, account: run.account))
        if run.outputTail.count > SteamCMDFailureLog.maximumLines { run.outputTail.removeFirst(run.outputTail.count - SteamCMDFailureLog.maximumLines) }
    }

    /// The failed run's tail with what the app made of it, for `SteamCMDFailureLog`.
    private func failureTranscript(label: String) -> String {
        var lines = run.outputTail
        let partial = run.outputTailPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { lines.append(SteamCMDFailureLog.redacted(partial, account: run.account)) }
        let stamp = ISO8601DateFormatter().string(from: now())
        let header = "== \(stamp) SteamCMD \(label): failed while \(phase.rawValue) (sign-in accepted: \(run.signInAccepted), "
            + "Steam Guard answered: \(run.steamGuardAnswered), no reason from Steam: \(endedBeforeSignInUnexplained))"
        let message = SteamCMDFailureLog.redacted(errorMessage ?? "", account: run.account)
        return ([header, "app said: \(message)"] + (lines.isEmpty ? ["(SteamCMD printed nothing)"] : lines))
            .joined(separator: "\n")
    }

    /// Output the process left without a final newline is a whole line once nothing more can
    /// arrive, so a failure reported that way is judged like any other.
    private func consumeUnterminatedOutput() {
        guard !run.recentOutput.isEmpty else { return }
        consumeOwnershipLine(run.recentOutput)
        consumeLine(run.recentOutput)
    }

    /// Only complete lines establish ownership; a truncated app ID must never match 431960.
    private func consumeOwnershipLine(_ line: String) {
        guard isSigningInOnly, !isAuthenticating, run.failure == nil else { return }
        let output = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.range(of: #"^no active license found for appid 431960\.?$"#, options: .regularExpression) != nil {
            wallpaperEngineOwnership = .notOwned
            run.readingLicense = false
        } else if output.range(of: #"^license packageid [0-9]+:$"#, options: .regularExpression) != nil {
            run.readingLicense = true
            run.licenseIsActive = false
        } else if run.readingLicense && output.hasPrefix("- state") {
            run.licenseIsActive = output.range(of: #"^- state\s*:\s*active\s*\("#, options: .regularExpression) != nil
        } else if run.readingLicense && run.licenseIsActive && output.hasPrefix("- apps") {
            let apps = output.split(separator: ":", maxSplits: 1).last?.split(separator: ",") ?? []
            if apps.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "431960" }) {
                wallpaperEngineOwnership = .owned
            }
        }
    }

    /// `complete` is false for the unfinished end of the output so far. Prompts have to be
    /// recognised before their newline arrives, but a failure line is judged only once it is
    /// whole: what follows `failed` decides whether the connection or the purchase is to blame.
    private func consumeLine(_ line: String, complete: Bool = true) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, run.failure == nil else { return }
        let cachedLine = text.contains("cached credential")
            && ["invalid", "expired", "revoked"].contains { text.contains($0) }
        let reason = Self.failureReason(in: text)

        if complete, isAuthenticating { noteSteamGuardMethod(text) }

        // Failures come first. A reason is judged only once its closing bracket is there.
        if cachedLine { run.cachedCredentialsRejected = true }
        if text.contains("logged in elsewhere") || text.contains("logged in from another")
            || text.contains("loggedinelsewhere") {
            endedBySessionConflict = true
            setFailure(.sessionConflict(String(localized: "Steam ended this session because the account signed in somewhere else. Retry once the other sign-in is done.")))
            return
        }
        if let reason {
            let kind = SteamCMDReportedFailure(
                reason: reason, cachedCredentialsRejected: run.cachedCredentialsRejected,
                awaitingSteamGuard: awaitingSteamGuard)
            AppLog.warn("SteamCMD \(run.label): reported failure (\(kind.rawValue))")
            let transfer = text.contains("download item") || text.contains("app '431960'") || text.contains("app 431960")
                || text.contains("depot")
                || text.contains("start downloading item") || text.contains("install app")
            if !transfer {
                setFailure(kind.isTransient ? .transient(kind.message) : .final(kind.message))
            } else {
                let message = transferFailureMessage(kind: kind, reason: reason)
                setFailure(kind == .connection ? .transient(message) : .final(message))
            }
            return
        }
        if complete {
            if text.contains("no subscription") || text.contains("does not own")
                || (text.contains("access denied") && !isAuthenticating) {
                setFailure(.final(Self.deniedMessage))
                return
            }
            if text.contains("error! download item") || text.contains("failed to download")
                || text.contains("error! failed to start downloading item") {
                setFailure(.final(Self.genericDownloadMessage))
                return
            }
            if isInstallingAssets, text.contains("depot download failed") || text.contains("error! app")
                || text.contains("failed to install app") {
                setFailure(.final(Self.assetInstallMessage))
                return
            }
            if text.contains("invalid password") || text.contains("invalid login") || text.contains("account logon denied") {
                let kind = SteamCMDReportedFailure(
                    reason: text, cachedCredentialsRejected: run.cachedCredentialsRejected,
                    awaitingSteamGuard: awaitingSteamGuard)
                setFailure(.final(kind.message))
                return
            }
        }

        // A saved sign-in Steam no longer takes is only a warning: the same process goes on to
        // ask for the password itself.
        if cachedLine {
            phase = .signingIn
            status = String(localized: "Saved Steam sign-in expired; waiting for fresh authentication…")
            guard text.hasSuffix("password:") else { return }
        }

        // Prompts.
        if text.hasSuffix("password:") {
            prompt = .password
            steamGuardChallenge = nil
            progress = nil
            phase = .signingIn
            status = String(localized: "Enter your Steam password below")
            return
        }
        if text.hasSuffix("code:") {
            prompt = .guardCode
            // A bare "Steam Guard code:" is used for more than one method, so only what Steam said
            // before it names one; with neither, the general guide is shown.
            steamGuardChallenge = text.hasSuffix("two-factor code:") ? .authenticatorCode : run.steamGuardMethod
            run.steamGuardAnswered = false
            progress = nil
            phase = .signingIn
            status = String(localized: "Enter the code from Steam Guard or your email")
            return
        }
        if text.contains("confirm"), text.contains("mobile") || text.contains("steam guard") {
            prompt = nil
            steamGuardChallenge = .mobileApproval
            phase = .signingIn
            status = String(localized: "Approve the sign-in in the Steam mobile app")
            return
        }

        // Progress and milestones.
        if text.contains("success. downloaded item") {
            run.workshopDownloadCompleted = true
            markAuthenticated()
            phase = .finishing
            progress = 1
            prompt = nil
            bytesReceived = nil
            bytesExpected = nil
            bytesPerSecond = nil
            run.receivesNetwork = false
            status = String(localized: "Download finished; waiting for SteamCMD to close…")
            return
        }
        if isInstallingAssets, complete, text.hasPrefix("depot download complete") {
            run.assetsDownloadCompleted = true
            run.reportedDepotPath = Self.depotFolderPattern
                .firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
                .flatMap { Range($0.range(at: 1), in: line) }
                .map { String(line[$0]) }
            markAuthenticated()
            phase = .finishing
            progress = 1
            prompt = nil
            bytesReceived = nil
            bytesExpected = nil
            bytesPerSecond = nil
            run.receivesNetwork = false
            status = String(localized: "Download finished; validating scene assets…")
            return
        }
        if isInstallingAssets, text.hasPrefix("downloading depot") {
            markAuthenticated()
            prompt = nil
            steamGuardChallenge = nil
            phase = .transferring
            run.receivesNetwork = true
            run.estimator = TransferEstimator()
            status = String(localized: "Downloading Wallpaper Engine files…")
            // SteamCMD prints nothing more until the depot is complete: what has landed on the
            // disk, against the size it gives here, is the progress.
            if let size = Self.depotSize(in: text) { run.expectedBytes = size }
            progress = nil
            return
        }
        if text.contains("downloading item") {
            markAuthenticated()
            prompt = nil
            steamGuardChallenge = nil
            phase = .transferring
            run.receivesNetwork = true
            run.estimator = TransferEstimator()
            status = run.presetBaseStatus ?? String(localized: "Downloading Workshop files…")
            if let expected = run.expectedBytes, expected > 0, run.receivedFloor > 0 {
                progress = min(0.99, Double(run.receivedFloor) / Double(expected))
            } else {
                progress = nil
            }
            return
        }
        if text.contains("logged in ok") || text.contains("waiting for user info...ok") {
            markAuthenticated()
            prompt = nil
            steamGuardChallenge = nil
            phase = .requesting
            status = isSigningInOnly
                ? String(localized: "Signed in; closing SteamCMD…")
                : isInstallingAssets
                    ? String(localized: "Signed in; requesting Wallpaper Engine’s shared assets…")
                    : String(localized: "Signed in; requesting your Workshop download…")
            return
        }
        if text.contains("logging in using cached credentials") {
            phase = .signingIn
            status = String(localized: "Using your saved Steam sign-in…")
            return
        }
        if text.contains("logging in") || text.contains("waiting for client config") || text.contains("waiting for user info") {
            guard isAuthenticating else { return }
            phase = .signingIn
            status = String(localized: "Waiting for Steam authentication…")
            return
        }
        if text.contains("update") || text.contains("verifying installation") {
            guard isAuthenticating, phase != .transferring, phase != .finishing else { return }
            phase = .updating
            status = String(localized: "Updating the private SteamCMD runtime…")
        }
    }

    /// Whether a failure Steam reports now answers a Steam Guard request: one still open, or a code
    /// that was just submitted.
    private var awaitingSteamGuard: Bool {
        steamGuardChallenge != nil || prompt == .guardCode || run.steamGuardAnswered
    }

    /// Remembers which Steam Guard method a whole line of sign-in output names.
    private func noteSteamGuardMethod(_ text: String) {
        if text.contains("email") {
            run.steamGuardMethod = .emailCode
        } else if text.contains("mobile") || text.contains("two-factor") || text.contains("authenticator") {
            run.steamGuardMethod = .authenticatorCode
        }
    }

    /// Steam has taken the sign-in: nothing from here on is a sign-in failure.
    private func markAuthenticated() {
        isAuthenticating = false
        run.signInAccepted = true
        run.steamGuardAnswered = false
    }

    private static var deniedMessage: String {
        String(localized: "Steam denied this download. Sign in with an account that owns Wallpaper Engine and has access to this Workshop item.")
    }
    private static var genericDownloadMessage: String {
        String(localized: "Steam could not download this wallpaper. Downloads require a Steam account that has purchased Wallpaper Engine. Buy it on Steam or sign in with an account that already owns it, then retry. If this account already owns it, the wallpaper may be private or removed; check its Workshop page.")
    }
    private static var assetInstallMessage: String {
        String(localized: "Steam could not install Wallpaper Engine’s shared assets. Confirm ownership and check available disk space, then retry.")
    }

    /// What a failed transfer is called to the user, by Steam's own reason.
    private func transferFailureMessage(kind: SteamCMDReportedFailure, reason: String) -> String {
        switch kind {
        case .connection:
            return String(localized: "The connection to Steam dropped while downloading. Check your connection and try again; what was already downloaded is kept.")
        case .rateLimited, .steamGuard, .credentials, .cachedCredentials:
            return kind.message
        case .unknown:
            let letters = reason.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            if letters.contains("accessdenied") || letters.contains("nosubscription") || letters.contains("notowned") {
                return Self.deniedMessage
            }
            return isInstallingAssets ? Self.assetInstallMessage : Self.genericDownloadMessage
        }
    }

    /// SteamCMD prints no counters while it fetches a Workshop item, so transfer progress is
    /// measured against the size Steam's Workshop listing reports for the item: the content that
    /// has landed under steamapps/workshop, capped by the bytes the process has received over the
    /// network since the transfer began. Steam can allocate a file's full length before its chunks
    /// arrive, which the network figure cannot overstate; compressed chunks make the network figure
    /// run a little behind, which the tree cannot overstate. The tree is walked off the UI actor at
    /// most twice a second; a sample is applied only while the transfer it measured is still on.
    /// What is shown never falls below the most this run has shown, however either measure moves,
    /// and a relaunch carries on from there instead of waiting for the new meter to catch up.
    /// The shared assets' depot is measured against the size SteamCMD gives it, which is what
    /// crosses the network (compressed chunks), not what lands: about a third of the folder's
    /// final weight. So the network figure is its measure, and its folder only stands in when
    /// there is no network meter.
    private func sampleTransferDisk(staging: URL, content: URL) {
        guard let expected = run.expectedBytes, expected > 0, diskSampleTask == nil,
              Date().timeIntervalSince(run.lastDiskSample) >= 0.5 else { return }
        run.lastDiskSample = Date()
        let installingAssets = isInstallingAssets
        let roots = installingAssets
            ? Self.depotFolders(reported: nil, staging: staging, content: content)
            : [content.appendingPathComponent("steamapps/workshop", isDirectory: true)]
        diskSampleTask = Task {
            let item = installingAssets ? nil : run.transferItem
            let onDisk = await Task.detached(priority: .utility) {
                roots.reduce(Int64(0)) { $0 + Self.bytesOnDisk(under: $1, item: item) }
            }.value
            diskSampleTask = nil
            guard isRunning, run.receivesNetwork, run.failure == nil else { return }
            noteTransfer(onDisk, on: .disk)
            // Without a working network meter the tree alone is still better than nothing. The
            // meter counts from its own start, so a relaunch adds what was shown before it.
            let network = networkMonitor.bytesReceived().map { $0 + run.receivedBaseline }
            let arrived = installingAssets ? network ?? onDisk : network.map { min($0, onDisk) } ?? onDisk
            let received = max(run.receivedFloor, min(arrived, expected))
            run.receivedFloor = received
            run.estimator.add(bytes: received, at: now().timeIntervalSinceReferenceDate)
            bytesReceived = received
            bytesExpected = expected
            // Only Steam's own success line claims completion; bytes alone stop at 99%.
            progress = min(0.99, Double(received) / Double(expected))
        }
    }

    /// Counts a byte counter that grew as activity, each counter against its own last reading.
    private func noteTransfer(_ bytes: Int64?, on meter: TransferMeter) {
        guard let bytes, bytes > (run.transferMarks[meter] ?? 0) else { return }
        run.transferMarks[meter] = bytes
        run.lastActivity = now()
        run.lastTransferProgress = run.lastActivity
    }

    /// Saves the sign-in Steam just accepted while the download goes on. Whatever Steam has not
    /// written yet is picked up by the save at the end of the run; a sibling that restores an
    /// incomplete copy falls back to Steam's own password prompt.
    @discardableResult
    private func saveAcceptedSession(from staging: URL, account: String) async -> Bool {
        let directory = sessionDirectory
        do {
            let stored = try await Task.detached(priority: .utility) {
                try Self.saveSession(from: staging, account: account, to: directory)
            }.value
            if stored { savedAccount = account }
            return stored
        } catch {
            AppLog.warn("Could not save the accepted Steam sign-in early: \(error.localizedDescription)")
            return false
        }
    }

    private func stopProcess() async {
        run.receivesNetwork = false
        bytesPerSecond = nil
        run.networkStarted = false
        await networkMonitor.stop()
        await process?.stop()
    }

    /// A Steam login name: ASCII letters, digits and underscores, plus the `@`, `.` and `-` of the
    /// email addresses Steam once accepted as account names. It starts with a letter, digit or
    /// underscore, so SteamCMD never reads it as one of its own `+command` or `-option` arguments.
    nonisolated static func normalizedAccount(_ username: String) -> String? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool { scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) }
        guard let first = name.unicodeScalars.first, isAlphanumeric(first) || first == "_", name != "anonymous",
              name.unicodeScalars.allSatisfy({ isAlphanumeric($0) || "_@.-".unicodeScalars.contains($0) })
        else { return nil }
        return name
    }

    /// Staging is removed when a download ends, so a leftover means the owning process died with a
    /// download inside it. The claim is a held lock rather than a recorded process identifier, and
    /// SteamCMD inherits it, so it stays held for as long as anything can still write here —
    /// including a child that outlived the app that started it.
    nonisolated private static func claimStaging(_ staging: URL) -> Int32 {
        let descriptor = open(staging.appendingPathComponent(ownerName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return -1 }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return -1 }
        return descriptor
    }

    /// Reclaims downloads stranded by a crash. Deletion needs positive evidence that nothing can
    /// still write here, so anything that cannot be inspected is left alone.
    nonisolated static func removeAbandonedStaging(in root: URL, quietFor quiet: TimeInterval = 600) {
        let files = FileManager.default
        let candidates = ((try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(stagingPrefix) }
        let deadline = Date().addingTimeInterval(-quiet)
        for entry in candidates {
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  isUnclaimed(entry), isQuiet(entry, since: deadline) else { continue }
            try? files.removeItem(at: entry)
        }
    }

    nonisolated private static func isUnclaimed(_ staging: URL) -> Bool {
        let descriptor = open(staging.appendingPathComponent(ownerName).path, O_RDWR | O_CLOEXEC)
        // Staging from before claims existed; the quiet window is all that stands behind it. Any
        // other failure means the claim could not be read, which is not permission to delete.
        guard descriptor >= 0 else { return errno == ENOENT }
        defer { close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    /// A directory's own timestamp does not move when a download writes deeper in the tree, so the
    /// whole tree decides, and a tree that cannot be walked completely counts as busy. The window
    /// outlasts the downloader's own limit on silence, so a download worth keeping is never idle
    /// for this long.
    nonisolated private static func isQuiet(_ staging: URL, since deadline: Date) -> Bool {
        var metadata = stat()
        guard lstat(staging.path, &metadata) == 0,
              Double(metadata.st_mtimespec.tv_sec) <= deadline.timeIntervalSince1970 else { return false }
        var readable = true
        guard let walker = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil,
                                                          options: [], errorHandler: { _, _ in
            readable = false
            return false
        }) else { return false }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            var entry = stat()
            guard visited <= 200_000, lstat(url.path, &entry) == 0,
                  Double(entry.st_mtimespec.tv_sec) <= deadline.timeIntervalSince1970 else { return false }
        }
        return readable
    }

    /// Steam moves a download between workshop/downloads, workshop/temp, and workshop/content, so
    /// the whole steamapps/workshop tree is summed; the min keeps sparse pre-allocated files from
    /// reporting their full logical size before the blocks exist.
    /// With `item`, only files inside a folder named for it count (Steam keeps an item under
    /// `content/431960/<id>` and `downloads/431960/<id>`).
    /// The depot size in a lowercased "downloading depot" line, in bytes; nil when it names none.
    nonisolated static func depotSize(in text: String) -> Int64? {
        guard let match = depotSizePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
              let number = Double(text[numberRange]), number > 0 else { return nil }
        let scale: Double = switch text[unitRange] { case "kb": 1024; case "mb": 1024 * 1024; default: 1024 * 1024 * 1024 }
        // A size beyond a pebibyte is a bad line, not a depot.
        return Int64(min(number * scale, Double(1 << 50)))
    }

    /// Where the shared assets' depot may have landed, most likely first: the folder SteamCMD
    /// reported, when it lies inside this run's own folders, then where SteamCMD puts depots
    /// (under its own folder or its Steam home, whatever `force_install_dir` says).
    nonisolated static func depotFolders(reported: String?, staging: URL, content: URL) -> [URL] {
        let relative = "steamapps/content/app_431960/depot_\(sceneAssetsDepotID)"
        var folders = [staging, staging.appendingPathComponent("Library/Application Support/Steam", isDirectory: true),
                       content, content.appendingPathComponent("wallpaper-engine", isDirectory: true)]
            .map { $0.appendingPathComponent(relative, isDirectory: true).standardizedFileURL }
        if let reported, !reported.isEmpty {
            let folder = URL(fileURLWithPath: reported.replacingOccurrences(of: "\\", with: "/"), isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            let inside = [staging, content].contains { root in
                let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                return folder.pathComponents.count > base.count && folder.pathComponents.starts(with: base)
            }
            if inside { folders.insert(folder, at: 0) }
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    nonisolated private static func bytesOnDisk(under root: URL, item: String? = nil) -> Int64 {
        var total: Int64 = 0
        var visited = 0
        let depth = root.standardizedFileURL.pathComponents.count
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: []) else { return 0 }
        for case let url as URL in walker {
            visited += 1
            guard visited <= 200_000 else { break }
            if let item, !url.standardizedFileURL.pathComponents.dropFirst(depth).contains(item) { continue }
            var entry = stat()
            guard lstat(url.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG else { continue }
            total += min(entry.st_size, entry.st_blocks * 512)
        }
        return total
    }

    nonisolated static func readSavedAccount(at directory: URL) -> String? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return readSavedAccountUnlocked(at: directory)
    }

    nonisolated private static func readSavedAccountUnlocked(at directory: URL) -> String? {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let file = directory.appendingPathComponent("account")
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return nil }
        return normalizedAccount(text)
    }

    nonisolated static func removeSession(at directory: URL) throws {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }

    nonisolated private static func restoreSession(from directory: URL, account: String, to staging: URL) throws -> UInt64? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard readSavedAccountUnlocked(at: directory) == account else { return nil }
        let revision = try FileManager.default.attributesOfItem(atPath: directory.path)[.systemFileNumber] as? NSNumber
        return try copySessionFiles(from: directory, to: staging) ? revision?.uint64Value : nil
    }

    nonisolated private static func invalidateSession(at directory: URL, account: String, revision: UInt64) throws {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard readSavedAccountUnlocked(at: directory) == account,
              let current = try FileManager.default.attributesOfItem(atPath: directory.path)[.systemFileNumber] as? NSNumber,
              current.uint64Value == revision else { return }
        // A late rejection must not delete a newer sign-in saved by another download.
        try FileManager.default.removeItem(at: directory)
    }

    nonisolated private static func privateDirectory(_ directory: URL) throws {
        let files = FileManager.default
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw WorkshopFailure(message: String(localized: "Steam sign-in storage must be a private directory, not a symbolic link."))
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    nonisolated private static func copySessionFiles(from source: URL, to destination: URL) throws -> Bool {
        try privateDirectory(source)
        try privateDirectory(destination)
        let files = FileManager.default
        let symlinkFailure = WorkshopFailure(message: String(localized: "Steam sign-in files cannot be read through symbolic links."))
        var copied = false
        // Steam keeps its state either directly under a root or under the user's Steam folder.
        for depth in [[String](), ["Library", "Application Support", "Steam"]] {
            var from = source
            var to = destination
            var present = true
            for component in depth {
                from.appendPathComponent(component, isDirectory: true)
                var info = stat()
                guard lstat(from.path, &info) == 0 else { present = false; break }
                guard info.st_mode & S_IFMT == S_IFDIR else { throw symlinkFailure }
                to.appendPathComponent(component, isDirectory: true)
                try privateDirectory(to)
            }
            guard present else { continue }
            for (subfolder, accepts) in [
                (nil as String?, { (name: String) in name == "registry.vdf" || name.hasPrefix("ssfn") }),
                ("config", { (name: String) in
                    ["config.vdf", "loginusers.vdf", "local.vdf"].contains(name)
                        || (name.hasPrefix("local_") && name.hasSuffix(".vdf")) }),
            ] as [(String?, (String) -> Bool)] {
                var folder = from
                var target = to
                if let subfolder {
                    folder.appendPathComponent(subfolder, isDirectory: true)
                    var info = stat()
                    guard lstat(folder.path, &info) == 0 else { continue }
                    guard info.st_mode & S_IFMT == S_IFDIR else { throw symlinkFailure }
                    target.appendPathComponent(subfolder, isDirectory: true)
                    try privateDirectory(target)
                }
                for name in try files.contentsOfDirectory(atPath: folder.path).sorted() where accepts(name) {
                    let file = folder.appendingPathComponent(name)
                    var info = stat()
                    guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                        throw WorkshopFailure(message: String(localized: "Steam sign-in storage contains an unsafe file."))
                    }
                    let copy = target.appendingPathComponent(name)
                    if files.fileExists(atPath: copy.path) { try files.removeItem(at: copy) }
                    try files.copyItem(at: file, to: copy)
                    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                    copied = true
                }
            }
        }
        return copied
    }

    nonisolated private static func saveSession(from staging: URL, account: String, to directory: URL) throws -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let files = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let pending = parent.appendingPathComponent(".\(directory.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: pending) }
        // Private and out of backups before it holds a single token.
        try privateDirectory(pending)
        ClientPaths.excludeFromBackup(pending)
        guard try copySessionFiles(from: staging, to: pending) else { return false }
        let accountFile = pending.appendingPathComponent("account")
        try Data(account.utf8).write(to: accountFile, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountFile.path)
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            try privateDirectory(directory)
            _ = try files.replaceItemAt(directory, withItemAt: pending)
        } else {
            try files.moveItem(at: pending, to: directory)
        }
        ClientPaths.excludeFromBackup(directory)
        return true
    }


}
