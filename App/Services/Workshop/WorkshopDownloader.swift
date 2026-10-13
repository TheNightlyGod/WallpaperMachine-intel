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
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private var receivesNetwork = false
    @ObservationIgnored private var networkStarted = false
    @ObservationIgnored private var expectedBytes: Int64?
    @ObservationIgnored private var diskSampleTask: Task<Void, Never>?
    @ObservationIgnored private var lastDiskSample = Date.distantPast
    private(set) var isAuthenticating = true
    private static let failurePattern = try! NSRegularExpression(pattern: #"(?:failed|error!?)\s*\(([^)\r\n]+)\)"#)
    private static let appProgressPattern = try! NSRegularExpression(pattern: #"progress:\s*(\d+(?:\.\d+)?)\s*\((\d+)\s*/\s*(\d+)\)"#)
    nonisolated private static let sessionLock = NSLock()

    init(sessionDirectory: URL = ClientPaths.supportURL.appendingPathComponent("SteamSession", isDirectory: true),
         runtimeProvider: any SteamCMDRuntimeProviding = SteamCMDRuntimeService(),
         networkMonitor: (any ProcessNetworkMonitoring)? = nil, checkpointDirectory: URL? = nil,
         inactivityTimeout: TimeInterval = 300, passTimeout: TimeInterval = 1800,
         now: @escaping () -> Date = Date.init) {
        self.sessionDirectory = sessionDirectory
        self.checkpointDirectory = checkpointDirectory
        self.inactivityTimeout = inactivityTimeout
        self.passTimeout = passTimeout
        self.now = now
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
        if !rememberSession {
            forgetSavedAccount()
            guard errorMessage == nil else { return }
        }
        failure = nil
        wasCancelled = false
        completedSuccessfully = false
        pauseRequested = false
        discardPartialRequested = false
        errorMessage = nil
        sessionWarning = nil
        cachedCredentialsRejected = false
        isAuthenticating = true
        wallpaperEngineOwnership = .unknown
        assetsDownloadCompleted = false
        workshopDownloadCompleted = false
        fetchingPresetBase = false
        authenticationFailed = false
        steamGuardChallenge = nil
        if itemID != nil { downloadedID = nil }
        progress = nil
        bytesReceived = nil
        bytesExpected = nil
        bytesPerSecond = nil
        receivesNetwork = false
        networkStarted = false
        self.expectedBytes = expectedBytes
        lastDiskSample = .distantPast
        endedBySessionConflict = false
        signInHandedOff = false
        prompt = nil
        recentOutput = ""
        isRunning = true
        isSigningInOnly = signInOnly
        isInstallingAssets = itemID == nil && !signInOnly
        phase = .preparing
        status = signInOnly ? String(localized: "Preparing a private SteamCMD sign-in…") : String(localized: "Preparing a private SteamCMD download…")
        let label = itemID ?? (signInOnly ? "sign-in" : "shared assets")
        loggedStatus = ""
        task = Task {
            let staging = root.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
            var claim: Int32 = -1
            defer {
                // Releasing the claim is what lets a later launch reclaim this directory.
                if claim >= 0 { close(claim) }
                try? terminal?.close()
                terminal = nil
                process = nil
                prompt = nil
                recentOutput = ""
                receivesNetwork = false
                bytesPerSecond = nil
                bytesReceived = nil
                bytesExpected = nil
                progress = nil
                if completedSuccessfully { wasCancelled = false }
                isRunning = false
                task = nil
                onFinished?()
            }
            var restoredSessionRevision: UInt64?
            do {
                let prepared = try await runtimeProvider.prepare(executable: executable, staging: staging)
                claim = Self.claimStaging(staging)
                if let checkpointDirectory, !signInOnly {
                    try await Task.detached(priority: .utility) {
                        try WorkshopDownloadCheckpoint.restore(from: checkpointDirectory, to: staging)
                    }.value
                }
                if rememberSession {
                    let directory = sessionDirectory
                    restoredSessionRevision = try await Task.detached(priority: .utility) {
                        try Self.restoreSession(from: directory, account: account, to: staging)
                    }.value
                }
                AppLog.info("SteamCMD \(label): runtime prepared; saved sign-in restored: \(restoredSessionRevision != nil)")
                try Task.checkCancellation()
                var passItemID = itemID
                while true {
                    let started = now()
                    var restarts = 0
                    repeat {
                        try Task.checkCancellation()
                        try await runtimeProvider.validate(at: staging)
                        try Task.checkCancellation()
                        try launch(executable: prepared, staging: staging, account: account, itemID: passItemID, claim: claim)
                        while let process, process.isRunning {
                            try Task.checkCancellation()
                            try readTerminalOutput()
                            if status != loggedStatus {
                                loggedStatus = status
                                AppLog.info("SteamCMD \(label): \(status)")
                            }
                            if !isAuthenticating && !signInHandedOff && failure == nil {
                                signInHandedOff = true
                                var savedEarly = false
                                if rememberSession { savedEarly = await saveAcceptedSession(from: staging, account: account) }
                                AppLog.info("SteamCMD \(label): sign-in accepted; session saved for siblings: \(savedEarly)")
                                onAuthenticated?()
                            }
                            if receivesNetwork {
                                if !networkStarted {
                                    networkMonitor.start(processID: process.processIdentifier)
                                    networkStarted = true
                                }
                                bytesPerSecond = networkMonitor.rate(at: ProcessInfo.processInfo.systemUptime)
                                noteTransfer(networkMonitor.bytesReceived(), on: .network)
                                sampleWorkshopDisk(in: staging)
                            } else {
                                bytesPerSecond = nil
                            }
                            let checked = now()
                            let stalled = checked.timeIntervalSince(lastActivity) > inactivityTimeout
                            // A long pass is cut short only once its bytes have stopped arriving too.
                            let overlong = checked.timeIntervalSince(started) > passTimeout
                                && checked.timeIntervalSince(lastTransferProgress ?? started) > inactivityTimeout
                            if failure != nil || stalled || overlong {
                                if failure == nil {
                                    authenticationFailed = isAuthenticating
                                    failure = isAuthenticating
                                        ? String(localized: "SteamCMD timed out. If Steam Guard was not completed, retry signing in and approve the new request or enter a fresh code. Otherwise check your connection and available disk space.")
                                        : String(localized: "SteamCMD stopped receiving the download. Check your connection and available disk space, then try again.")
                                }
                                await stopProcess()
                                break
                            }
                            try await Task.sleep(for: .milliseconds(200))
                        }
                        // Reap our child and stop any descendants before a restart or staging cleanup.
                        await stopProcess()
                        // Drain the last output before closing, even when SteamCMD has already exited.
                        try readTerminalOutput()
                        consumeOwnershipLine(recentOutput)
                        try? terminal?.close()
                        terminal = nil
                        restarts += 1
                    } while process?.terminationStatus == 42 && restarts < 4 && failure == nil
                    AppLog.info("SteamCMD \(label): exited with status \(process.map { String($0.terminationStatus) } ?? "unknown")\(failure.map { "; failure: \($0)" } ?? "")")
                    try Task.checkCancellation()
                    if let failure { throw WorkshopFailure(message: failure) }
                    guard process?.terminationStatus == 0 else {
                        authenticationFailed = isAuthenticating
                        if isSigningInOnly {
                            throw WorkshopFailure(message: String(localized: "SteamCMD exited before confirming the sign-in. Check the account name and password, approve Steam Guard, and retry."))
                        }
                        throw WorkshopFailure(message: String(localized: "SteamCMD exited before completing the download. Confirm this account owns Wallpaper Engine, approve Steam Guard, and retry."))
                    }
                    progress = nil
                    receivesNetwork = false
                    bytesPerSecond = nil
                    if isSigningInOnly && isAuthenticating {
                        authenticationFailed = true
                        throw WorkshopFailure(message: String(localized: "Steam closed the session without confirming the sign-in. Check the account name and password, then retry."))
                    }
                    if isInstallingAssets && !assetsDownloadCompleted {
                        throw WorkshopFailure(message: String(localized: "Steam exited without confirming a complete Wallpaper Engine installation. Retry installing scene assets; existing assets have not been changed."))
                    }
                    if !isInstallingAssets && !isSigningInOnly && !workshopDownloadCompleted {
                        throw WorkshopFailure(message: String(localized: "Steam exited without confirming a complete Workshop download. Retry; no partial wallpaper has been added to your library."))
                    }
                    // At most one follow-up: a preset's base is never itself fetched for another.
                    guard !fetchingPresetBase, let followUp, let next = try await followUp(staging) else { break }
                    AppLog.info("SteamCMD \(label): preset is based on Workshop item \(next); downloading it in the same session")
                    passItemID = next
                    fetchingPresetBase = true
                    workshopDownloadCompleted = false
                    self.expectedBytes = nil
                    phase = .requesting
                    status = String(localized: "Downloading the wallpaper this preset is based on…")
                }
                try await onDownloaded(staging)
                completedSuccessfully = true
            } catch is CancellationError {
                wasCancelled = !pauseRequested
                await stopProcess()
                try? readTerminalOutput()
                authenticationFailed = false
                steamGuardChallenge = nil
                status = pauseRequested ? String(localized: "Download paused") : String(localized: "Download cancelled")
            } catch {
                await stopProcess()
                try? readTerminalOutput()
                errorMessage = error.localizedDescription
                status = isSigningInOnly ? String(localized: "Sign-in could not finish") : String(localized: "Download could not finish")
            }
            if rememberSession {
                do {
                    if !isAuthenticating && !authenticationFailed {
                        let directory = sessionDirectory
                        let stored = try await Task.detached(priority: .utility) {
                            try Self.saveSession(from: staging, account: account, to: directory)
                        }.value
                        if stored {
                            savedAccount = account
                        } else {
                            sessionWarning = String(localized: "Steam did not provide reusable sign-in files. You may need to sign in again next time.")
                        }
                    } else if let revision = restoredSessionRevision, cachedCredentialsRejected {
                        try Self.invalidateSession(at: sessionDirectory, account: account, revision: revision)
                    }
                } catch {
                    sessionWarning = String(localized: "Could not update the saved Steam sign-in: \(error.localizedDescription). You may need to sign in again next time.")
                }
            }
            savedAccount = Self.readSavedAccount(at: sessionDirectory)
            // Retain only content and Steam's download manifests. Programs, authentication,
            // terminal state and the private runtime always leave with staging.
            let keepPartial = !completedSuccessfully && !signInOnly && (pauseRequested || errorMessage != nil)
            let checkpoint = checkpointDirectory
            do {
                try await Task.detached(priority: .utility) {
                    defer { try? FileManager.default.removeItem(at: staging) }
                    if let checkpoint {
                        if keepPartial { try WorkshopDownloadCheckpoint.save(from: staging, to: checkpoint) }
                        else { try WorkshopDownloadCheckpoint.remove(at: checkpoint) }
                    }
                }.value
            } catch {
                errorMessage = String(localized: "Could not save partial download data: \(error.localizedDescription)")
            }
            // Cancel can arrive while the detached checkpoint move is finishing a pause.
            if discardPartialRequested, let checkpoint {
                await Task.detached(priority: .utility) {
                    try? WorkshopDownloadCheckpoint.remove(at: checkpoint)
                }.value
            }
        }
    }

    func submitSecret(_ value: String) {
        guard isRunning, prompt != nil, !value.isEmpty,
              !value.contains(where: { $0.isNewline || $0 == "\0" }), let terminal else { return }
        do {
            // Only the terminal receives the secret. No arguments, scripts, defaults, or log output.
            try terminal.write(contentsOf: Data((value + "\n").utf8))
            prompt = nil
            recentOutput = ""
            phase = .signingIn
            status = String(localized: "Waiting for Steam authentication…")
            lastActivity = now()
        } catch {
            authenticationFailed = true
            failure = String(localized: "SteamCMD closed its login prompt. Retry signing in to start a new session.")
        }
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
        // The task stops the child before staging cleanup; the importer checks cancellation before its atomic move.
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

    private func launch(executable: URL, staging: URL, account: String, itemID: String?, claim: Int32) throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw WorkshopFailure(message: String(localized: "Could not create a private terminal for SteamCMD. Restart WallpaperMachine and retry."))
        }
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            settings.c_lflag &= ~tcflag_t(ECHO | ECHONL)
            tcsetattr(slave, TCSANOW, &settings)
        }
        let input = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let child = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw WorkshopFailure(message: String(localized: "Could not read SteamCMD’s private terminal without blocking. Restart WallpaperMachine and retry."))
        }
        terminal = input
        let installDirectory = isInstallingAssets ? staging.appendingPathComponent("wallpaper-engine") : staging
        let platform = isInstallingAssets ? ["+@sSteamCmdForcePlatformType", "windows"] : []
        // Query licenses in the authenticated session without downloading any game files.
        let command = isSigningInOnly ? ["+licenses_for_app", "431960"] : itemID.map { ["+workshop_download_item", "431960", $0] } ?? ["+app_update", "431960", "validate"]
        let arguments = ["-inhibitbootstrap", "+@ShutdownOnFailedCommand", "1"] + platform
            + ["+force_install_dir", installDirectory.path, "+login", account] + command + ["+quit"]
        let temporary = staging.appendingPathComponent("tmp", isDirectory: true)
        try Self.privateDirectory(temporary)
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": staging.path,
                           "TMPDIR": temporary.path, "TERM": "dumb", "LANG": "en_US.UTF-8",
                           "DYLD_LIBRARY_PATH": staging.path,
                           "DYLD_FRAMEWORK_PATH": staging.appendingPathComponent("Frameworks").path]
        recentOutput = ""
        wallpaperEngineOwnership = .unknown
        readingLicense = false
        licenseIsActive = false
        prompt = nil
        steamGuardChallenge = nil
        isAuthenticating = true
        receivesNetwork = false
        networkStarted = false
        lastActivity = now()
        lastTransferProgress = nil
        transferMarks = [:]
        do {
            process = try SteamCMDTerminalProcess(executable: executable, arguments: arguments,
                                                  workingDirectory: staging, environment: environment,
                                                  master: master, slave: slave, claim: claim)
        }
        catch {
            try? child.close()
            throw WorkshopFailure(message: String(localized: "Cannot launch SteamCMD: \(error.localizedDescription). Reinstall SteamCMD in Settings → Library & Steam to get Valve’s Apple silicon version."))
        }
        try? child.close()
        phase = .connecting
        status = String(localized: "Starting SteamCMD and contacting Steam…")
    }

    private func readTerminalOutput() throws {
        guard let terminal else { return }
        // FileHandle.read(upToCount:) waits to fill its buffer on a PTY. A short
        // password prompt would deadlock both sides, so read only available bytes.
        while true {
            let count = outputBuffer.withUnsafeMutableBytes {
                Darwin.read(terminal.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                consume(String(decoding: outputBuffer[..<count], as: UTF8.self))
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK || errno == EIO {
                return
            } else if errno != EINTR {
                throw WorkshopFailure(message: String(localized: "Lost the connection to SteamCMD’s login terminal. Retry signing in."))
            }
        }
    }

    private func consume(_ text: String) {
        guard isRunning else { return }
        lastActivity = now()
        recentOutput += text.lowercased()
        // Keep only the incomplete line, not old prompts that can mask later failures.
        while let newline = recentOutput.firstIndex(where: { $0.isNewline }) {
            let line = String(recentOutput[..<newline])
            recentOutput.removeSubrange(...newline)
            consumeOwnershipLine(line)
            consumeLine(line)
        }
        recentOutput = String(recentOutput.suffix(4096))
        // Interactive prompts have no newline and can span multiple reads.
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

    private func consumeLine(_ line: String) {
        let output = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, failure == nil else { return }
        if output.contains("cached credential") && (output.contains("invalid") || output.contains("expired") || output.contains("revoked")) {
            cachedCredentialsRejected = true
            // SteamCMD can fall back to its password prompt in the same process.
            if output.contains("warning") {
                phase = .signingIn
                status = String(localized: "Saved Steam sign-in expired; waiting for fresh authentication…")
                if output.hasSuffix("password:") { consumeLine("password:") }
                return
            }
        }
        if output.contains("logged in elsewhere") || output.contains("logged in from another") || output.contains("loggedinelsewhere") {
            endedBySessionConflict = true
            authenticationFailed = isAuthenticating
            failure = String(localized: "Steam ended this session because the account signed in somewhere else. Retry once the other sign-in is done.")
        } else if output.contains("no subscription") || (output.contains("access denied") && !isAuthenticating) || output.contains("does not own") {
            failure = String(localized: "Steam denied this download. Sign in with an account that owns Wallpaper Engine and has access to this Workshop item.")
        } else if output.contains("error! download item") || output.contains("failed to download") || output.contains("error! failed to start downloading item") {
            failure = String(localized: "Steam could not download this wallpaper. Downloads require a Steam account that has purchased Wallpaper Engine. Buy it on Steam or sign in with an account that already owns it, then retry. If this account already owns it, the wallpaper may be private or removed; check its Workshop page.")
        } else if isInstallingAssets && (output.contains("error! app") || output.contains("failed to install app")) {
            failure = String(localized: "Steam could not install Wallpaper Engine’s shared assets. Confirm ownership and check available disk space, then retry.")
        } else if let match = Self.failurePattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output) {
            let reported = SteamCMDReportedFailure(
                reason: String(output[range]), cachedCredentialsRejected: cachedCredentialsRejected,
                awaitingSteamGuard: steamGuardChallenge != nil)
            authenticationFailed = isAuthenticating
            AppLog.warn("SteamCMD reported failure: \(reported.rawValue); authenticating: \(isAuthenticating)")
            failure = reported.message
        } else if output.contains("invalid password") || output.contains("invalid login") || output.contains("account logon denied") {
            authenticationFailed = true
            failure = String(localized: "Steam rejected the sign-in. Check your account login name and password, then retry.")
        } else if output.hasSuffix("password:") {
            prompt = .password
            steamGuardChallenge = nil
            progress = nil
            receivesNetwork = false
            bytesPerSecond = nil
            phase = .signingIn
            status = String(localized: "Enter your Steam password below")
        } else if output.hasSuffix("auth code:") || output.hasSuffix("steam guard code:") || output.hasSuffix("two-factor code:") || output.hasSuffix("enter the code:") || output.hasSuffix("enter code:") {
            prompt = .guardCode
            steamGuardChallenge = output.hasSuffix("steam guard code:") ? .emailCode : .authenticatorCode
            progress = nil
            receivesNetwork = false
            bytesPerSecond = nil
            phase = .signingIn
            status = String(localized: "Enter the code from Steam Guard or your email")
        } else if isInstallingAssets && (output.contains("update state") || output.contains("success! app")) {
            prompt = nil
            steamGuardChallenge = nil
            isAuthenticating = false
            receivesNetwork = output.contains("update state") && output.contains("downloading")
            if !receivesNetwork { bytesPerSecond = nil }
            if output.contains("success! app '431960' fully installed") {
                assetsDownloadCompleted = true
                receivesNetwork = false
                bytesPerSecond = nil
                bytesReceived = nil
                bytesExpected = nil
                progress = 1
                phase = .finishing
                status = String(localized: "Download finished; validating scene assets…")
            } else {
                phase = .transferring
                status = receivesNetwork ? String(localized: "Downloading Wallpaper Engine files…") : String(localized: "Processing Wallpaper Engine files…")
            }
        } else if output.contains("success. downloaded item") {
            workshopDownloadCompleted = true
            prompt = nil
            steamGuardChallenge = nil
            isAuthenticating = false
            receivesNetwork = false
            bytesPerSecond = nil
            bytesReceived = nil
            bytesExpected = nil
            phase = .finishing
            status = String(localized: "Download finished; waiting for SteamCMD to close…")
            progress = 1
        } else if output.contains("downloading item") {
            prompt = nil
            steamGuardChallenge = nil
            isAuthenticating = false
            receivesNetwork = true
            bytesReceived = nil
            bytesExpected = nil
            progress = nil
            phase = .transferring
            status = fetchingPresetBase ? String(localized: "Downloading the wallpaper this preset is based on…")
                : String(localized: "Downloading Workshop files…")
        } else if output.contains("logged in ok") || output.contains("waiting for user info...ok") {
            prompt = nil
            steamGuardChallenge = nil
            isAuthenticating = false
            progress = nil
            receivesNetwork = false
            bytesPerSecond = nil
            phase = .requesting
            status = isSigningInOnly ? String(localized: "Signed in; checking Wallpaper Engine ownership…") : isInstallingAssets ? String(localized: "Signed in; requesting Wallpaper Engine’s shared assets…") : String(localized: "Signed in; requesting your Workshop download…")
        } else if output.contains("confirm") && (output.contains("mobile") || output.contains("steam guard")) {
            prompt = nil
            steamGuardChallenge = .mobileApproval
            progress = nil
            receivesNetwork = false
            bytesPerSecond = nil
            phase = .signingIn
            status = String(localized: "Approve the sign-in in the Steam mobile app")
        } else if output.contains("logging in using cached credentials") {
            prompt = nil
            progress = nil
            receivesNetwork = false
            bytesPerSecond = nil
            phase = .signingIn
            status = String(localized: "Using your saved Steam sign-in…")
        } else if output.contains("logging in") || output.contains("waiting for client config") || output.contains("waiting for user info") {
            prompt = nil
            progress = nil
            receivesNetwork = false
            bytesPerSecond = nil
            phase = .signingIn
            status = String(localized: "Waiting for Steam authentication…")
        } else if output.contains("update") || output.contains("verifying installation") {
            phase = .updating
            status = String(localized: "Updating the private SteamCMD runtime…")
        }
        if failure != nil {
            prompt = nil
            progress = nil
            receivesNetwork = false
            bytesPerSecond = nil
            bytesReceived = nil
            bytesExpected = nil
            return
        }
        if isInstallingAssets && output.hasPrefix("update state") {
            progress = nil
            bytesReceived = nil
            bytesExpected = nil
            if let match = Self.appProgressPattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let receivedRange = Range(match.range(at: 2), in: output),
               let totalRange = Range(match.range(at: 3), in: output),
               let received = Int64(output[receivedRange]), let total = Int64(output[totalRange]),
               total > 0, received >= 0, received <= total {
                progress = Double(received) / Double(total)
                noteTransfer(received, on: .steam)
                if receivesNetwork {
                    bytesReceived = received
                    bytesExpected = total
                }
            }
        }
    }

    /// SteamCMD prints no counters while it fetches a Workshop item, so transfer progress is
    /// measured against the size Steam's Workshop listing reports for the item: the content that
    /// has landed under steamapps/workshop, capped by the bytes the process has received over the
    /// network since the transfer began. Steam can allocate a file's full length before its chunks
    /// arrive, which the network figure cannot overstate; compressed chunks make the network figure
    /// run a little behind, which the tree cannot overstate. The tree is walked off the UI actor at
    /// most twice a second; a sample is applied only while the transfer it measured is still on.
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
            // Without a working network meter the tree alone is still better than nothing.
            let arrived = networkMonitor.bytesReceived().map { min($0, onDisk) } ?? onDisk
            let received = min(arrived, expected)
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
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !account.isEmpty, account != "anonymous",
              account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return account
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
        let files = FileManager.default
        let identity = directory.appendingPathComponent("account")
        guard (try? files.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? files.attributesOfItem(atPath: identity.path)[.type]) as? FileAttributeType == .typeRegular,
              let account = try? String(contentsOf: identity, encoding: .utf8) else { return nil }
        return normalizedAccount(account)
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
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw WorkshopFailure(message: String(localized: "Steam sign-in storage must be a private directory, not a symbolic link."))
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    nonisolated private static func copySessionFiles(from source: URL, to destination: URL) throws -> Bool {
        let files = FileManager.default
        try privateDirectory(source)
        try privateDirectory(destination)
        var copied = false
        // Preserve Steam's opaque token + machine-auth state, not logs, programs,
        // downloaded content, or submitted passwords/codes. macOS uses both roots.
        layouts: for base in ["", "Library/Application Support/Steam"] {
            var sourceBase = source
            var destinationBase = destination
            for component in base.split(separator: "/") {
                sourceBase.appendPathComponent(String(component))
                destinationBase.appendPathComponent(String(component))
                guard files.fileExists(atPath: sourceBase.path) else { continue layouts }
                guard try files.attributesOfItem(atPath: sourceBase.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw WorkshopFailure(message: String(localized: "Steam sign-in files cannot be read through symbolic links."))
                }
                try privateDirectory(destinationBase)
            }
            for subdirectory in ["", "config"] {
                let folder = subdirectory.isEmpty ? sourceBase : sourceBase.appendingPathComponent(subdirectory)
                guard files.fileExists(atPath: folder.path) else { continue }
                guard try files.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw WorkshopFailure(message: String(localized: "Steam sign-in files cannot be read through symbolic links."))
                }
                for file in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    let name = file.lastPathComponent
                    let isSessionFile = subdirectory.isEmpty
                        ? name == "registry.vdf" || name.hasPrefix("ssfn")
                        : name == "config.vdf" || name == "loginusers.vdf" || name == "local.vdf" || (name.hasPrefix("local_") && name.hasSuffix(".vdf"))
                    guard isSessionFile else { continue }
                    guard try files.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
                        throw WorkshopFailure(message: String(localized: "Steam sign-in storage contains an unsafe file."))
                    }
                    let targetFolder = subdirectory.isEmpty ? destinationBase : destinationBase.appendingPathComponent(subdirectory)
                    try privateDirectory(targetFolder)
                    let target = targetFolder.appendingPathComponent(name)
                    try files.copyItem(at: file, to: target)
                    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
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
        let pending = directory.deletingLastPathComponent().appendingPathComponent(".steam-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: pending) }
        guard try copySessionFiles(from: staging, to: pending) else { return false }
        let identity = pending.appendingPathComponent("account")
        try Data(account.utf8).write(to: identity, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)
        if files.fileExists(atPath: directory.path) {
            try privateDirectory(directory)
            _ = try files.replaceItemAt(directory, withItemAt: pending)
        } else {
            try files.moveItem(at: pending, to: directory)
        }
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
         master: Int32, slave: Int32, claim: Int32) throws {
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
        // would leave the claim closing on exec; it also has to survive the closes above.
        var inherited: Int32 = -1
        if claim >= 0 { inherited = fcntl(claim, F_DUPFD, 20) }
        defer { if inherited >= 0 { close(inherited) } }
        if inherited >= 0 { try check(posix_spawn_file_actions_adddup2(&actions, inherited, 3)) }
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
        defer { close(master); if slave >= 0 { close(slave) } }
        var settings = termios()
        guard tcgetattr(slave, &settings) == 0 else { throw POSIXError(.EIO) }
        settings.c_lflag &= ~tcflag_t(ECHO | ECHONL)
        guard tcsetattr(slave, TCSANOW, &settings) == 0 else { throw POSIXError(.EIO) }
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let process = try SteamCMDTerminalProcess(executable: executable, arguments: arguments,
            workingDirectory: workingDirectory, environment: environment, master: master, slave: slave, claim: -1)
        close(slave)
        slave = -1
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() throws {
            for _ in 0..<32 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
                if count > 0 {
                    onOutput(Data(buffer.prefix(count)))
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK || errno == EIO {
                    return
                } else if errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
