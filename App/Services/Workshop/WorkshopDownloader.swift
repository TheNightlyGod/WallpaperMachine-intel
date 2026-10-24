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
    @ObservationIgnored private var readingLicense = false
    @ObservationIgnored private var licenseIsActive = false
    /// Coarse step of a run for compact surfaces such as the tile ring; `status` carries the
    /// full sentence. Bytes only move during `transferring`; `finishing` covers SteamCMD's
    /// close and the validation/import that follows it.
    enum Phase: String { case preparing, connecting, updating, signingIn, requesting, transferring, finishing }
    /// The byte counters that show a transfer is alive: the process's network total, the content
    /// landed on disk, and the counts SteamCMD prints for an asset installation.
    private enum TransferMeter { case network, disk, steam }
    private(set) var isRunning = false
    private(set) var phase = Phase.preparing
    private(set) var wasCancelled = false
    private(set) var completedSuccessfully = false
    @ObservationIgnored private var pauseRequested = false
    @ObservationIgnored private var discardPartialRequested = false
    @ObservationIgnored private let checkpointDirectory: URL?
    private(set) var status = String(localized: "Ready to download")
    private(set) var progress: Double?
    private(set) var bytesReceived: Int64?
    private(set) var bytesExpected: Int64?
    private(set) var bytesPerSecond: Double?
    /// Seconds until the transfer in progress finishes at its recent pace, or nil while there is
    /// no trustworthy pace (the first seconds, a crawl, the last bytes, nothing measurable).
    var secondsRemaining: Int? {
        guard isRunning, receivesNetwork, let received = bytesReceived, let expected = bytesExpected else { return nil }
        return estimator.secondsRemaining(remaining: expected - received)
    }
    private(set) var prompt: Prompt?
    private(set) var steamGuardChallenge: SteamGuardChallenge?
    var canRetryAuthentication: Bool { authenticationFailed && !isRunning }
    private var authenticationFailed = false
    private(set) var errorMessage: String?
    private(set) var downloadedID: String?
    private(set) var isInstallingAssets = false
    /// A session that signs in, checks ownership, and downloads nothing. The welcome guide
    /// and Settings use it to verify an account and save its sign-in ahead of any download.
    private(set) var isSigningInOnly = false
    private(set) var savedAccount: String?
    private(set) var sessionWarning: String?
    @ObservationIgnored private let sessionDirectory: URL
    @ObservationIgnored private let runtimeProvider: any SteamCMDRuntimeProviding
    @ObservationIgnored private let networkMonitor: any ProcessNetworkMonitoring
    @ObservationIgnored private var cachedCredentialsRejected = false
    @ObservationIgnored private var assetsDownloadCompleted = false
    @ObservationIgnored private var workshopDownloadCompleted = false
    /// The run's second pass, which fetches the wallpaper a downloaded preset is based on.
    @ObservationIgnored private var fetchingPresetBase = false
    @ObservationIgnored private var process: SteamCMDTerminalProcess?
    @ObservationIgnored private var terminal: FileHandle?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onFinished: (@MainActor () -> Void)?
    /// Called once per run when Steam accepts the sign-in, after the session was saved (when
    /// remembered), so another session can restore it while this download is still running.
    @ObservationIgnored var onAuthenticated: (@MainActor () -> Void)?
    /// Steam ended this session because the same account signed in from somewhere else.
    private(set) var endedBySessionConflict = false
    @ObservationIgnored private var signInHandedOff = false
    @ObservationIgnored private var loggedStatus = ""
    @ObservationIgnored private var recentOutput = ""
    @ObservationIgnored private var outputBuffer = [UInt8](repeating: 0, count: 8192)
    nonisolated static let stagingPrefix = ".WallpaperMachine-workshop-"
    nonisolated private static let ownerName = "owner"
    @ObservationIgnored private var lastActivity = Date()
    /// When a byte counter last grew in this run. SteamCMD prints nothing while it fetches a
    /// Workshop item, so arriving bytes, not terminal output, are what show a transfer is alive.
    @ObservationIgnored private var lastTransferProgress: Date?
    @ObservationIgnored private var transferMarks: [TransferMeter: Int64] = [:]
    /// How long a run may go without output or transfer progress before it is stopped.
    @ObservationIgnored private let inactivityTimeout: TimeInterval
    /// How long one pass may run before it is stopped, once it has also stopped transferring.
    @ObservationIgnored private let passTimeout: TimeInterval
    /// The clock both limits are measured on.
    @ObservationIgnored private let now: () -> Date
    /// Free bytes on the volume that holds a folder, as the system would hand them to this app.
    @ObservationIgnored private let freeSpace: @Sendable (URL) -> Int64?
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private var receivesNetwork = false
    @ObservationIgnored private var networkStarted = false
    @ObservationIgnored private var expectedBytes: Int64?
    @ObservationIgnored private var diskSampleTask: Task<Void, Never>?
    @ObservationIgnored private var lastDiskSample = Date.distantPast
    @ObservationIgnored private var estimator = TransferEstimator()
    /// The most bytes this run has shown. Each SteamCMD launch starts its own network meter and the
    /// tree can shrink as Steam moves chunks about, so what is shown never drops below it.
    @ObservationIgnored private var receivedFloor: Int64 = 0
    /// What the run had shown when the current network meter started. A relaunched SteamCMD
    /// resumes from Steam's partial manifests and its meter counts only the bytes still to come,
    /// so the figure shown is this baseline plus the meter, never the meter alone.
    @ObservationIgnored private var receivedBaseline: Int64 = 0
    /// How long to wait before each automatic retry of a dropped connection; one entry per retry
    /// the pass may use.
    @ObservationIgnored private let retryDelays: [TimeInterval]
    /// Set together with `failure` when the inactivity limit, not a message from Steam or the
    /// watch after a wake, ended the pass.
    @ObservationIgnored private var endedBySilence = false
    /// Passes already repeated after such a silence. Each one costs the whole inactivity limit,
    /// so only `maximumSilentRetries` of them are repeated.
    @ObservationIgnored private var silentRetries = 0
    nonisolated static let maximumSilentRetries = 1
    /// Set together with `failure` when the attempt ended in a way another launch can fix: the
    /// connection dropped after Steam accepted the sign-in. Never set for anything the user decides.
    @ObservationIgnored private var transientFailure = false
    /// Retries the pass in progress has used; a preset's base wallpaper starts its own count.
    private(set) var retryAttempt = 0
    /// When the Mac last woke while a transfer was running, until bytes arrive again or SteamCMD is
    /// relaunched. Sleep usually kills the connection without a word from SteamCMD, so the wait
    /// for the inactivity limit is replaced by a short watch for bytes.
    @ObservationIgnored private(set) var resumedAt: Date?
    /// How long after a wake a transfer may stay silent before it is restarted.
    @ObservationIgnored private let resumeGrace: TimeInterval
    /// What the log calls this run, for lines written outside the run itself.
    @ObservationIgnored private var runLabel = ""
    private(set) var isAuthenticating = true
    /// Whether Steam accepted the sign-in at any point in this run, including one an earlier
    /// launch of SteamCMD made: what separates a dropped connection from a refused sign-in.
    @ObservationIgnored private var signInAccepted = false
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

    private static let appProgressPattern = try! NSRegularExpression(pattern: #"progress:\s*(\d+(?:\.\d+)?)\s*\((\d+)\s*/\s*(\d+)\)"#)
    nonisolated private static let sessionLock = NSLock()

    init(sessionDirectory: URL = ClientPaths.steamSessionURL(),
         runtimeProvider: any SteamCMDRuntimeProviding = SteamCMDRuntimeService(),
         networkMonitor: (any ProcessNetworkMonitoring)? = nil, checkpointDirectory: URL? = nil,
         inactivityTimeout: TimeInterval = 300, passTimeout: TimeInterval = 1800,
         now: @escaping () -> Date = Date.init,
         freeSpace: @escaping @Sendable (URL) -> Int64? = WorkshopDownloader.systemFreeSpace,
         retryDelays: [TimeInterval] = [2, 8, 30], resumeGrace: TimeInterval = 45) {
        self.sessionDirectory = sessionDirectory
        self.checkpointDirectory = checkpointDirectory
        self.inactivityTimeout = inactivityTimeout
        self.passTimeout = passTimeout
        self.now = now
        self.freeSpace = freeSpace
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
        download(itemID: item.id, username: username, executable: executable, root: library.deletingLastPathComponent(),
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
        download(itemID: nil, username: username, executable: executable, root: destination.deletingLastPathComponent(), rememberSession: rememberSession) { staging in
            self.phase = .finishing
            self.status = String(localized: "Validating and installing scene assets…")
            try ClientPaths.installSceneAssets(from: staging.appendingPathComponent("wallpaper-engine/assets"), to: destination)
            self.clearTransferFigures()
            try onInstalled()
            self.status = String(localized: "Scene assets installed")
        }
    }

    /// Signs in, checks ownership, and quits using the same password and Steam Guard prompts
    /// as a download; with `rememberSession` the accepted sign-in is saved for later downloads.
    func signIn(username: String, executable: URL, root: URL, rememberSession: Bool = true, onSignedIn: @escaping @MainActor () -> Void = {}) {
        download(itemID: nil, signInOnly: true, username: username, executable: executable, root: root, rememberSession: rememberSession) { _ in
            self.phase = .finishing
            self.status = String(localized: "Signed in to Steam")
            onSignedIn()
        }
    }

    /// `followUp` may name one more Workshop item to fetch into the same staging, in the same
    /// session, once the first has arrived.
    private func download(itemID: String?, signInOnly: Bool = false, username: String, executable: URL, root: URL, rememberSession: Bool,
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
        resetRunState(itemID: itemID, signInOnly: signInOnly, expectedBytes: expectedBytes)
        let label = itemID ?? (signInOnly ? "sign-in" : "scene assets")
        runLabel = label
        task = Task {
            await self.performRun(
                itemID: itemID, account: account, executable: executable, root: root,
                rememberSession: rememberSession, label: label, followUp: followUp, onDownloaded: onDownloaded)
        }
    }

    /// Puts every observable and private per-run value back to where a new run begins.
    private func resetRunState(itemID: String?, signInOnly: Bool, expectedBytes: Int64?) {
        isRunning = true
        phase = .preparing
        wasCancelled = false
        completedSuccessfully = false
        pauseRequested = false
        discardPartialRequested = false
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        bytesPerSecond = nil
        prompt = nil
        steamGuardChallenge = nil
        authenticationFailed = false
        errorMessage = nil
        downloadedID = nil
        isSigningInOnly = signInOnly
        isInstallingAssets = itemID == nil && !signInOnly
        sessionWarning = nil
        wallpaperEngineOwnership = .unknown
        readingLicense = false
        licenseIsActive = false
        cachedCredentialsRejected = false
        assetsDownloadCompleted = false
        workshopDownloadCompleted = false
        fetchingPresetBase = false
        endedBySessionConflict = false
        signInHandedOff = false
        signInAccepted = false
        loggedStatus = ""
        recentOutput = ""
        failure = nil
        receivesNetwork = false
        networkStarted = false
        self.expectedBytes = expectedBytes
        diskSampleTask?.cancel()
        diskSampleTask = nil
        lastDiskSample = .distantPast
        estimator = TransferEstimator()
        receivedFloor = 0
        receivedBaseline = 0
        endedBySilence = false
        silentRetries = 0
        transientFailure = false
        retryAttempt = 0
        resumedAt = nil
        lastTransferProgress = nil
        transferMarks = [:]
        lastActivity = now()
        isAuthenticating = true
        status = signInOnly
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
        let content = Self.sameFolder(runRoot, root) ? staging : root.appendingPathComponent(name, isDirectory: true)
        var claim: Int32 = -1
        var contentClaim: Int32 = -1
        var restoredRevision: UInt64?
        var finishedItem = false
        var failedRun = false
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
            if let checkpoint = checkpointDirectory, !isSigningInOnly {
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
            try Task.checkCancellation()
            try await ensureFreeSpace(under: root, staging: content, label: label)

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
                if let reason = failure {
                    if let delay = nextRetryDelay() {
                        prepareRetry(label: label, delay: delay)
                        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                        try await ensureFreeSpace(under: root, staging: content, label: label)
                        continue
                    }
                    throw passFailure(reason, itemID: currentItem)
                }
                if exitStatus == Self.restartStatus, restarts < Self.maximumRestarts {
                    restarts += 1
                    try await ensureFreeSpace(under: root, staging: content, label: label)
                    continue
                }
                try judgeExit(exitStatus, itemID: currentItem)
                if let followUp, !followedUp, !fetchingPresetBase, itemID != nil,
                   let base = try await followUp(content) {
                    // One more item in the same session, never a chain of them.
                    followedUp = true
                    fetchingPresetBase = true
                    currentItem = base
                    workshopDownloadCompleted = false
                    self.expectedBytes = nil
                    receivedFloor = 0
                    receivedBaseline = 0
                    retryAttempt = 0
                    silentRetries = 0
                    status = String(localized: "Downloading the wallpaper this preset is based on…")
                    continue
                }
                break
            }
            try Task.checkCancellation()
            try await onDownloaded(content)
            finishedItem = true
            completedSuccessfully = true
        } catch is CancellationError {
            if pauseRequested {
                status = String(localized: "Download paused")
            } else {
                wasCancelled = true
                status = String(localized: "Download cancelled")
            }
            failedRun = false
        } catch {
            failedRun = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        if failedRun || wasCancelled || pauseRequested {
            progress = nil
            bytesReceived = nil
            bytesExpected = nil
        }
        bytesPerSecond = nil
        receivesNetwork = false
        resumedAt = nil

        if rememberSession {
            await settleSession(staging: staging, account: account, restoredRevision: restoredRevision)
        }
        let keepForLater = !finishedItem && !isSigningInOnly && (failedRun || (pauseRequested && !wasCancelled))
        await retireStaging(staging, content: content, keepingPartialData: keepForLater && !discardPartialRequested)
        if claim >= 0 { close(claim) }
        if contentClaim >= 0 { close(contentClaim) }

        isRunning = false
        task = nil
        pauseRequested = false
        onFinished?()
    }

    /// What SteamCMD's exit says about a pass that reported no failure of its own.
    private func judgeExit(_ exitStatus: Int32, itemID: String?) throws {
        let confirmed = isSigningInOnly ? !isAuthenticating
            : isInstallingAssets ? assetsDownloadCompleted : workshopDownloadCompleted
        if exitStatus != 0 {
            authenticationFailed = isAuthenticating && !signInAccepted
            throw passFailure(isSigningInOnly
                ? String(localized: "SteamCMD exited before confirming the sign-in. Check the account name and password, approve Steam Guard, and retry.")
                : String(localized: "SteamCMD exited before completing the download. Confirm this account owns Wallpaper Engine, approve Steam Guard, and retry."),
                itemID: itemID)
        }
        guard confirmed else {
            if isSigningInOnly {
                authenticationFailed = true
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
                if status != loggedStatus {
                    loggedStatus = status
                    AppLog.info("SteamCMD \(runLabel): \(status)")
                }
                if signInAccepted, !signInHandedOff {
                    signInHandedOff = true
                    if rememberSession { await saveAcceptedSession(from: staging, account: account) }
                    onAuthenticated?()
                }
                if receivesNetwork, !networkStarted, let pid = process?.processIdentifier {
                    networkStarted = true
                    receivedBaseline = receivedFloor
                    networkMonitor.start(processID: pid)
                }
                if receivesNetwork, networkStarted {
                    noteTransfer(networkMonitor.bytesReceived(), on: .network)
                    bytesPerSecond = networkMonitor.rate(at: ProcessInfo.processInfo.systemUptime)
                    sampleWorkshopDisk(in: content)
                }
                if failure == nil { checkLimits(passStarted: passStarted) }
                if failure != nil {
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
            if let moved = lastTransferProgress, moved >= woke {
                resumedAt = nil
            } else if current.timeIntervalSince(woke) >= resumeGrace {
                resumedAt = nil
                setFailure(String(localized: "The connection to Steam stopped responding after the Mac woke from sleep. Check your connection and try again; what was already downloaded is kept."),
                           transient: true)
                return
            }
        }
        let silent = current.timeIntervalSince(lastActivity) > inactivityTimeout
        let bytesStopped = current.timeIntervalSince(lastTransferProgress ?? passStarted) > inactivityTimeout
        let overlong = current.timeIntervalSince(passStarted) > passTimeout && bytesStopped
        guard silent || overlong else { return }
        // Steam Guard help only fits where the user may still be answering a sign-in.
        let awaitingUser = !signInAccepted || prompt != nil || steamGuardChallenge != nil
        setFailure(awaitingUser
            ? String(localized: "SteamCMD timed out. If Steam Guard was not completed, retry signing in and approve the new request or enter a fresh code. Otherwise check your connection and available disk space.")
            : String(localized: "SteamCMD stopped receiving the download. Check your connection and available disk space, then try again."),
                   transient: !awaitingUser, silence: true)
    }

    /// Records how the pass failed, once. Everything the user has to decide is non-transient.
    private func setFailure(_ message: String, transient: Bool = false, silence: Bool = false, conflict: Bool = false) {
        guard failure == nil else { return }
        failure = message
        transientFailure = transient && signInAccepted && !isSigningInOnly
        endedBySilence = silence && transientFailure
        authenticationFailed = conflict ? isAuthenticating : (isAuthenticating && !signInAccepted)
        prompt = nil
        steamGuardChallenge = nil
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        bytesPerSecond = nil
        receivesNetwork = false
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
            } else if cachedCredentialsRejected, let restoredRevision {
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
        if discardPartialRequested, let checkpoint {
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
        guard fetchingPresetBase, let itemID else { return WorkshopFailure(message: reason) }
        return WorkshopFailure(message: String(localized: "The preset downloaded, but the wallpaper it is based on (Workshop item \(itemID)) did not, so nothing was added to your library. \(reason)"))
    }

    /// Stops a download that cannot fit before SteamCMD starts, instead of letting it stall for
    /// the inactivity limit and blame the connection. It runs on every start (first, resume,
    /// Try again) after any checkpoint is restored, and again before each automatic relaunch
    /// of SteamCMD (a retry after a dropped connection or a wake, or Steam asking to be
    /// started again), so a retry only needs the space still missing. A preset's base is
    /// fetched in a second pass of unknown size, which is not checked; concurrent jobs are
    /// checked one by one, not summed.
    private func ensureFreeSpace(under root: URL, staging: URL, label: String) async throws {
        let installingAssets = isInstallingAssets
        let expected = expectedBytes
        guard !isSigningInOnly,
              Self.requiredFreeBytes(expected: expected, alreadyStaged: 0, installingAssets: installingAssets) != nil
        else { return }
        // Where this kind of run keeps what it has fetched: an item under the Workshop tree, the
        // shared assets in the app's own install directory.
        let content = staging.appendingPathComponent(installingAssets ? "wallpaper-engine" : "steamapps/workshop", isDirectory: true)
        let measure = freeSpace
        let (staged, available) = await Task.detached(priority: .utility) { () -> (Int64, Int64?) in
            (Self.bytesOnDisk(under: content), measure(root))
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
    /// can reclaim on demand (purgeable caches, local snapshots); nil when it cannot be read.
    nonisolated static func availableCapacity(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// What a download reads by default; tests pass their own disk instead.
    nonisolated static let systemFreeSpace: @Sendable (URL) -> Int64? = { availableCapacity(at: $0) }

    /// Room kept beyond the content itself for Steam's manifests and the private runtime.
    nonisolated static let freeSpaceMargin: Int64 = 64 * 1024 * 1024
    /// What a Workshop item needs on top of its listed size while Steam stages and assembles it.
    nonisolated static let freeSpaceHeadroom = 1.15
    /// Wallpaper Engine's shared assets have no size to read, so a fixed floor stands in. It is
    /// a lower bound, meant to block only when the disk is clearly short; tune it after one
    /// measured real installation. What an earlier attempt already staged counts against it.
    nonisolated static let sceneAssetsFreeBytes: Int64 = 3 * 1024 * 1024 * 1024

    /// The free space a download needs before it starts, or nil when nothing can be said and the
    /// download is never blocked: a sign-in-only run, or an item whose listing gives no size.
    /// Bytes an earlier attempt already staged are on the disk and are not needed again, for the
    /// shared assets as much as for an item.
    nonisolated static func requiredFreeBytes(expected: Int64?, alreadyStaged: Int64, installingAssets: Bool) -> Int64? {
        if installingAssets { return max(freeSpaceMargin, sceneAssetsFreeBytes - max(0, alreadyStaged)) }
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
        guard transientFailure, retryAttempt < retryDelays.count, !cachedCredentialsRejected,
              !endedBySessionConflict, !isSigningInOnly, prompt == nil, steamGuardChallenge == nil,
              !endedBySilence || silentRetries < Self.maximumSilentRetries
        else { return nil }
        let delay = retryDelays[retryAttempt]
        return delay > 0 ? delay * Double.random(in: 0.8...1.2) : 0
    }

    private func prepareRetry(label: String, delay: TimeInterval) {
        retryAttempt += 1
        if endedBySilence { silentRetries += 1 }
        endedBySilence = false
        failure = nil
        transientFailure = false
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
        guard isRunning, !isSigningInOnly, receivesNetwork, phase == .transferring, failure == nil else { return }
        resumedAt = now()
        AppLog.info("SteamCMD \(runLabel): Mac woke; watching for bytes")
    }

    func submitSecret(_ value: String) {
        guard isRunning, prompt != nil, !value.isEmpty,
              !value.contains(where: { $0.isNewline }), !value.utf8.contains(0),
              let terminal else { return }
        do {
            // The only place a secret goes: the terminal's input, never an argument or a file.
            try terminal.write(contentsOf: Data((value + "\n").utf8))
        } catch {
            setFailure(String(localized: "SteamCMD closed its login prompt. Retry signing in to start a new session."))
            authenticationFailed = true
            return
        }
        prompt = nil
        recentOutput = ""
        phase = .signingIn
        status = String(localized: "Waiting for Steam authentication…")
        lastActivity = now()
    }

    func pause() {
        guard isRunning, !isSigningInOnly else { return }
        pauseRequested = true
        task?.cancel()
        status = String(localized: "Pausing…")
    }

    func discardCheckpoint() {
        guard !isRunning, let checkpointDirectory else { return }
        try? WorkshopDownloadCheckpoint.remove(at: checkpointDirectory)
    }

    func cancel() {
        guard isRunning else { return }
        pauseRequested = false
        discardPartialRequested = true
        wasCancelled = true
        receivesNetwork = false
        bytesPerSecond = nil
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        task?.cancel()
        status = String(localized: "Cancelling…")
    }

    func shutdown() async {
        guard let current = task else { return }
        receivesNetwork = false
        bytesPerSecond = nil
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        current.cancel()
        await current.value
    }

    private func launch(executable: URL, staging: URL, content: URL, account: String, itemID: String?, claim: Int32,
                        contentClaim: Int32) throws {
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
        recentOutput = ""
        readingLicense = false
        licenseIsActive = false
        prompt = nil
        steamGuardChallenge = nil
        isAuthenticating = true
        receivesNetwork = false
        networkStarted = false
        lastActivity = now()
        lastTransferProgress = nil
        resumedAt = nil
        transferMarks = [:]

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
            arguments += ["+app_update", "431960", "validate"]
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
        status = String(localized: "Starting SteamCMD and contacting Steam…")
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
        lastActivity = now()
        recentOutput += text.lowercased()
        while let newline = recentOutput.firstIndex(where: { $0.isNewline }) {
            let line = String(recentOutput[..<newline])
            recentOutput.removeSubrange(...newline)
            consumeOwnershipLine(line)
            consumeLine(line)
        }
        // An old prompt must not mask a later failure, and a prompt has no newline to wait for.
        if recentOutput.count > 4096 { recentOutput = String(recentOutput.suffix(4096)) }
        consumeLine(recentOutput, complete: false)
    }

    /// Output the process left without a final newline is a whole line once nothing more can
    /// arrive, so a failure reported that way is judged like any other.
    private func consumeUnterminatedOutput() {
        guard !recentOutput.isEmpty else { return }
        consumeOwnershipLine(recentOutput)
        consumeLine(recentOutput)
    }

    /// Only complete lines establish ownership; a truncated app ID must never match 431960.
    private func consumeOwnershipLine(_ line: String) {
        guard isSigningInOnly, !isAuthenticating, failure == nil else { return }
        let output = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.range(of: #"^no active license found for appid 431960\.?$"#, options: .regularExpression) != nil {
            wallpaperEngineOwnership = .notOwned
            readingLicense = false
        } else if output.range(of: #"^license packageid [0-9]+:$"#, options: .regularExpression) != nil {
            readingLicense = true
            licenseIsActive = false
        } else if readingLicense && output.hasPrefix("- state") {
            licenseIsActive = output.range(of: #"^- state\s*:\s*active\s*\("#, options: .regularExpression) != nil
        } else if readingLicense && licenseIsActive && output.hasPrefix("- apps") {
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
        guard !text.isEmpty, failure == nil else { return }
        let cachedLine = text.contains("cached credential")
            && ["invalid", "expired", "revoked"].contains { text.contains($0) }
        let reason = Self.failureReason(in: text)

        // Failures come first. A reason is judged only once its closing bracket is there.
        if cachedLine { cachedCredentialsRejected = true }
        if text.contains("logged in elsewhere") || text.contains("logged in from another")
            || text.contains("loggedinelsewhere") {
            endedBySessionConflict = true
            setFailure(String(localized: "Steam ended this session because the account signed in somewhere else. Retry once the other sign-in is done."), conflict: true)
            return
        }
        if let reason {
            let kind = SteamCMDReportedFailure(
                reason: reason, cachedCredentialsRejected: cachedCredentialsRejected,
                awaitingSteamGuard: steamGuardChallenge != nil || prompt == .guardCode)
            AppLog.warn("SteamCMD \(runLabel): reported failure (\(kind.rawValue))")
            let transfer = text.contains("download item") || text.contains("app '431960'") || text.contains("app 431960")
                || text.contains("start downloading item") || text.contains("install app")
            if !transfer {
                setFailure(kind.message, transient: kind.isTransient)
            } else {
                setFailure(transferFailureMessage(kind: kind, reason: reason), transient: kind == .connection)
            }
            return
        }
        if complete {
            if text.contains("no subscription") || text.contains("does not own")
                || (text.contains("access denied") && !isAuthenticating) {
                setFailure(Self.deniedMessage)
                return
            }
            if text.contains("error! download item") || text.contains("failed to download")
                || text.contains("error! failed to start downloading item") {
                setFailure(Self.genericDownloadMessage)
                return
            }
            if isInstallingAssets, text.contains("error! app") || text.contains("failed to install app") {
                setFailure(Self.assetInstallMessage)
                return
            }
            if text.contains("invalid password") || text.contains("invalid login") || text.contains("account logon denied") {
                let kind = SteamCMDReportedFailure(
                    reason: text, cachedCredentialsRejected: cachedCredentialsRejected,
                    awaitingSteamGuard: steamGuardChallenge != nil || prompt == .guardCode)
                setFailure(kind.message)
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
            steamGuardChallenge = text.hasSuffix("steam guard code:") ? .emailCode : .authenticatorCode
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
            workshopDownloadCompleted = true
            markAuthenticated()
            phase = .finishing
            progress = 1
            prompt = nil
            bytesReceived = nil
            bytesExpected = nil
            bytesPerSecond = nil
            receivesNetwork = false
            status = String(localized: "Download finished; waiting for SteamCMD to close…")
            return
        }
        if text.contains("success! app '431960' fully installed") {
            assetsDownloadCompleted = true
            markAuthenticated()
            phase = .finishing
            progress = 1
            bytesReceived = nil
            bytesExpected = nil
            bytesPerSecond = nil
            status = String(localized: "Download finished; validating scene assets…")
            return
        }
        if text.contains("downloading item") {
            markAuthenticated()
            prompt = nil
            steamGuardChallenge = nil
            phase = .transferring
            receivesNetwork = true
            estimator = TransferEstimator()
            status = String(localized: "Downloading Workshop files…")
            if let expected = expectedBytes, expected > 0, receivedFloor > 0 {
                progress = min(0.99, Double(receivedFloor) / Double(expected))
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
        if isInstallingAssets, text.contains("update state") {
            let counters = Self.appProgressPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            func number<T: LosslessStringConvertible>(_ group: Int) -> T? {
                counters.flatMap { Range($0.range(at: group), in: text) }.flatMap { T(String(text[$0])) }
            }
            if text.contains("downloading") {
                phase = .transferring
                receivesNetwork = true
                status = String(localized: "Downloading Wallpaper Engine files…")
                // Byte counts only mean something while Steam is downloading and names a total.
                if let done: Int64 = number(2), let total: Int64 = number(3), total > 0 {
                    bytesReceived = done
                    bytesExpected = total
                    progress = min(1, Double(done) / Double(total))
                    noteTransfer(done, on: .steam)
                } else {
                    bytesReceived = nil
                    bytesExpected = nil
                    progress = nil
                }
            } else {
                phase = .updating
                receivesNetwork = false
                bytesPerSecond = nil
                bytesReceived = nil
                bytesExpected = nil
                status = String(localized: "Updating the private SteamCMD runtime…")
                if let percent: Double = number(1) { progress = min(1, max(0, percent / 100)) }
            }
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

    /// Steam has taken the sign-in: nothing from here on is a sign-in failure.
    private func markAuthenticated() {
        isAuthenticating = false
        signInAccepted = true
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
    private func sampleWorkshopDisk(in staging: URL) {
        guard !isInstallingAssets, let expected = expectedBytes, expected > 0, diskSampleTask == nil,
              Date().timeIntervalSince(lastDiskSample) >= 0.5 else { return }
        lastDiskSample = Date()
        let root = staging.appendingPathComponent("steamapps/workshop", isDirectory: true)
        diskSampleTask = Task {
            let onDisk = await Task.detached(priority: .utility) { Self.bytesOnDisk(under: root) }.value
            diskSampleTask = nil
            guard isRunning, receivesNetwork, failure == nil else { return }
            noteTransfer(onDisk, on: .disk)
            // Without a working network meter the tree alone is still better than nothing. The
            // meter counts from its own start, so a relaunch adds what was shown before it.
            let arrived = networkMonitor.bytesReceived().map { min($0 + receivedBaseline, onDisk) } ?? onDisk
            let received = max(receivedFloor, min(arrived, expected))
            receivedFloor = received
            estimator.add(bytes: received, at: now().timeIntervalSinceReferenceDate)
            bytesReceived = received
            bytesExpected = expected
            // Only Steam's own success line claims completion; bytes alone stop at 99%.
            progress = min(0.99, Double(received) / Double(expected))
        }
    }

    /// Counts a byte counter that grew as activity, each counter against its own last reading.
    private func noteTransfer(_ bytes: Int64?, on meter: TransferMeter) {
        guard let bytes, bytes > (transferMarks[meter] ?? 0) else { return }
        transferMarks[meter] = bytes
        lastActivity = now()
        lastTransferProgress = lastActivity
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
        receivesNetwork = false
        bytesPerSecond = nil
        networkStarted = false
        await networkMonitor.stop()
        await process?.stop()
    }

    nonisolated static func normalizedAccount(_ username: String) -> String? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name != "anonymous",
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") })
        else { return nil }
        return name
    }

    /// Staging is removed when a download ends, so a leftover means the owning process died with a
    /// download inside it. The claim is a held lock rather than a recorded process identifier, and
    /// SteamCMD inherits it, so it stays held for as long as anything can still write here —
    /// including a child that outlived the app that started it.
    /// Whether two paths name one folder, as a run decides if its download is kept apart.
    nonisolated static func sameFolder(_ first: URL, _ second: URL) -> Bool {
        first.resolvingSymlinksInPath().standardizedFileURL.path == second.resolvingSymlinksInPath().standardizedFileURL.path
    }

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
    nonisolated private static func bytesOnDisk(under root: URL) -> Int64 {
        var total: Int64 = 0
        var visited = 0
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: []) else { return 0 }
        for case let url as URL in walker {
            visited += 1
            guard visited <= 200_000 else { break }
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

/// The PTY downloader needs interactive input; the installer runner intentionally does not.
/// Both use spawn-time process-group ownership, never a racy setpgid after launch.
@MainActor
private final class SteamCMDTerminalProcess {
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

@MainActor
protocol ProcessNetworkMonitoring: AnyObject {
    func start(processID: Int32)
    func rate(at time: TimeInterval) -> Double?
    /// Bytes the process has received since monitoring began, or nil while no meter is running.
    func bytesReceived() -> Int64?
    func stop() async
}

/// Reads nettop's per-process CSV deltas. nettop's first row for a process carries every byte it
/// received since it launched, not since the sample began, so that row only anchors the timeline:
/// the rate and the running total are built from the rows that follow.
struct NetworkReceiveMeter {
    let processID: Int32
    /// Bytes received since the first sample; the transfer's own traffic, not the sign-in before it.
    private(set) var bytesReceived: Int64 = 0
    private var pending = ""
    private var byteColumn: Int?
    private var lastSample: TimeInterval?
    private var anchored = false
    private var intervals: [(bytes: Double, duration: TimeInterval)] = []
    private var currentRate: Double?

    init(processID: Int32) {
        self.processID = processID
    }

    mutating func append(_ data: Data, at time: TimeInterval) {
        guard time.isFinite else { return }
        pending += String(decoding: data, as: UTF8.self)
        guard pending.utf8.count <= 65_536 else {
            // Runaway output loses the rate window, never the bytes already counted.
            let total = bytesReceived
            let anchored = anchored
            self = NetworkReceiveMeter(processID: processID)
            bytesReceived = total
            self.anchored = anchored
            return
        }
        while let newline = pending.firstIndex(where: { $0.isNewline }) {
            let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.first == "" {
                byteColumn = fields.firstIndex(of: "bytes_in")
                continue
            }
            guard let column = byteColumn, fields.indices.contains(column),
                  fields.first?.hasSuffix(".\(processID)") == true,
                  !fields[column].isEmpty,
                  fields[column].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let bytes = Int64(fields[column]) else { continue }
            let previous = lastSample
            lastSample = time
            guard anchored else {
                anchored = true
                continue
            }
            bytesReceived += bytes
            guard let previous, (0.5...2.5).contains(time - previous) else {
                intervals = []
                currentRate = nil
                continue
            }
            intervals.append((Double(bytes), time - previous))
            if intervals.count > 3 { intervals.removeFirst(intervals.count - 3) }
            currentRate = intervals.reduce(0) { $0 + $1.bytes } / intervals.reduce(0) { $0 + $1.duration }
        }
    }

    func rate(at time: TimeInterval) -> Double? {
        guard let lastSample, time.isFinite, (0...3).contains(time - lastSample) else { return nil }
        return currentRate
    }
}

private final class NetworkReceiveCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var meter: NetworkReceiveMeter
    private var finished = false

    init(processID: Int32) { meter = NetworkReceiveMeter(processID: processID) }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        meter.append(data, at: ProcessInfo.processInfo.systemUptime)
    }

    func rate(at time: TimeInterval) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return finished ? nil : meter.rate(at: time)
    }

    func bytesReceived() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return finished ? nil : meter.bytesReceived
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
    }
}

private struct NetworkTerminalRunner: SteamCMDProcessRunning {
    @MainActor
    func run(executable: URL, arguments: [String], workingDirectory: URL,
             environment: [String: String], onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        try Task.checkCancellation()
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw POSIXError(.EIO) }
        defer { close(master) }
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            settings.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(slave, TCSANOW, &settings)
        }
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) != -1 else {
            close(slave)
            throw POSIXError(.EIO)
        }
        let process: SteamCMDTerminalProcess
        do {
            process = try SteamCMDTerminalProcess(
                executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                environment: environment, master: master, slave: slave, claim: -1)
        } catch {
            close(slave)
            throw error
        }
        close(slave)

        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() throws {
            for _ in 0..<32 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
                if count > 0 {
                    onOutput(Data(buffer[0..<count]))
                    continue
                }
                if count == 0 { return }
                switch errno {
                case EINTR: continue
                case EAGAIN, EIO: return
                default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try drain()
                try await Task.sleep(for: .milliseconds(40))
            }
            await process.stop()
            try drain()
            try Task.checkCancellation()
            return process.terminationStatus
        } catch {
            await process.stop()
            throw error
        }
    }
}

@MainActor
final class ProcessNetworkMonitor: ProcessNetworkMonitoring {
    private let runner: any SteamCMDProcessRunning
    private var capture: NetworkReceiveCapture?
    private var task: Task<Void, Never>?

    init(runner: any SteamCMDProcessRunning = NetworkTerminalRunner()) { self.runner = runner }

    func start(processID: Int32) {
        guard processID > 0, task == nil else { return }
        let capture = NetworkReceiveCapture(processID: processID)
        self.capture = capture
        let runner = runner
        task = Task {
            defer { capture.finish() }
            _ = try? await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/nettop"),
                arguments: ["-P", "-L", "0", "-p", String(processID), "-n", "-x", "-d", "-s", "1", "-J", "bytes_in"],
                workingDirectory: URL(fileURLWithPath: "/"),
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
                onOutput: { capture.append($0) })
        }
    }

    func rate(at time: TimeInterval) -> Double? { capture?.rate(at: time) }

    func bytesReceived() -> Int64? { capture?.bytesReceived() }

    func stop() async {
        capture?.finish()
        capture = nil
        let current = task
        current?.cancel()
        await current?.value
        task = nil
    }
}
