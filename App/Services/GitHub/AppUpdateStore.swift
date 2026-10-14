import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppUpdateStore {
    private(set) var state: AppUpdateState
    /// What the newest published release says it changed, for the About card. Present
    /// whether or not that release is newer than the running build.
    private(set) var releaseNotes: ReleaseNotes?
    /// When the last check was refused by GitHub's anonymous rate limit, the time it lifts.
    /// Checks before then fail locally, so retries can't keep the shared quota exhausted.
    private(set) var rateLimitedUntil: Date?
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let client: any AppUpdateClient
    @ObservationIgnored private let installer: any AppUpdateInstalling
    @ObservationIgnored private let workspace: AppUpdateWorkspace
    @ObservationIgnored private let scheduleInstall: (@escaping () -> Void) -> Void
    @ObservationIgnored private let terminate: () -> Void
    @ObservationIgnored private let installTimeout: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var checkTask: Task<AppUpdateState, Never>?
    @ObservationIgnored private var downloadTask: Task<AppUpdateState, Never>?
    @ObservationIgnored private var available: GitHubRelease?
    @ObservationIgnored private var downloadedArchive: URL?
    @ObservationIgnored private var extractedApp: URL?
    @ObservationIgnored private var activeOperation: AppUpdateOperation?
    @ObservationIgnored private var installScheduled = false
    @ObservationIgnored private var installWatchdog: Task<Void, Never>?
    @ObservationIgnored private var preparationTask: Task<URL, Error>?
    @ObservationIgnored private var installationTask: (any AppUpdateInstallationTask)?
    @ObservationIgnored private var installAttempt: UInt64 = 0
    @ObservationIgnored private var retryCancellationInProgress = false
    @ObservationIgnored private var installCancellationInProgress = false

    /// An installer has been started and is waiting for this app to quit, so a quit now
    /// is the update's. False while the update is still being prepared: a Quit chosen
    /// then cancels the preparation and is the user's.
    var isInstallPending: Bool { installScheduled && installationTask != nil }

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         client: any AppUpdateClient = GitHubReleaseClient(),
         installer: any AppUpdateInstalling = AppUpdateInstaller(),
         workspace: AppUpdateWorkspace = .live,
         scheduleInstall: ((@escaping () -> Void) -> Void)? = nil,
         terminate: (() -> Void)? = nil,
         installTimeout: Duration = .seconds(45),
         now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.client = client
        self.installer = installer
        self.workspace = workspace
        self.scheduleInstall = scheduleInstall ?? Self.performOnMainRunLoop
        self.terminate = terminate ?? { NSApp.terminate(nil) }
        self.installTimeout = installTimeout
        self.now = now
        state = .idle(currentVersion: currentVersion)
    }

    /// Runs `work` from the main run loop rather than as a main-queue job. AppKit waits out
    /// `.terminateLater` and `NSAlert.runModal()` in a nested run loop, and a nested run loop
    /// entered from inside a main-queue job (`DispatchQueue.main.async` or any `@MainActor`
    /// task) never drains the main queue: quitting would hang because the shutdown task never
    /// runs, and every main-actor task would stall while an alert is open.
    nonisolated static func performOnMainRunLoop(_ work: @escaping () -> Void) {
        RunLoop.main.perform(work)
    }

    func checkForUpdates() async -> AppUpdateState {
        if case .preparing = state { return state }
        if case .downloading = state { return state }
        if case .ready = state { return state }
        if let checkTask { return await checkTask.value }
        let task = Task { await performCheck() }
        checkTask = task
        return await task.value
    }

    /// Discovery never spends bandwidth on the archive or opens Finder. Download
    /// and restart remain separate choices in About.
    func checkInBackground() async -> AppUpdateState {
        await checkForUpdates()
    }

    func downloadUpdate() async -> AppUpdateState {
        if let downloadTask { return await downloadTask.value }
        guard case .available(_, let version) = state, let release = available, release.version.display == version else {
            fail(.download, AppUpdateIssue(code: .configuration, detail: String(localized: "No update is available to download.")))
            return state
        }
        let task = Task { await performDownload(release) }
        downloadTask = task
        return await task.value
    }

    func installUpdate() async {
        let canRetryInstall: Bool = {
            if case .error(_, let operation, _, let version) = state {
                return operation == .install && version != nil
            }
            return false
        }()
        if installScheduled {
            guard canRetryInstall, !retryCancellationInProgress, let installationTask else { return }
            retryCancellationInProgress = true
            let ended = await installationTask.cancel()
            retryCancellationInProgress = false
            guard ended else { return }
            self.installationTask = nil
            installScheduled = false
        }
        let isReady: Bool
        if case .ready = state { isReady = true } else { isReady = false }
        guard isReady || canRetryInstall else {
            fail(.install, AppUpdateIssue(code: .configuration, detail: String(localized: "No downloaded update is ready to install.")))
            return
        }
        guard installer.canInstallInPlace else {
            fail(.install, AppUpdateIssue(code: .permission, detail: String(localized: "The updater doesn't have permission to install this update.")))
            return
        }
        installScheduled = true
        installAttempt &+= 1
        let attempt = installAttempt
        let version = state.availableVersion ?? available?.version.display ?? ""
        state = .preparing(currentVersion: currentVersion, availableVersion: version)
        do {
            let archive = try resolvedArchive()
            let extracted: URL
            if let extractedApp { extracted = extractedApp }
            else {
                let installer = installer
                let task = Task {
                    let app = try await installer.prepareInstallation(archive: archive)
                    do { try Task.checkCancellation() } catch {
                        await installer.discardPreparation(app)
                        throw error
                    }
                    return app
                }
                preparationTask = task
                extracted = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
            }
            guard attempt == installAttempt else {
                await installer.discardPreparation(extracted)
                return
            }
            preparationTask = nil
            extractedApp = extracted
            state = .ready(currentVersion: currentVersion, availableVersion: version)
            scheduleInstall { [weak self] in
                guard let self, self.installScheduled, self.installAttempt == attempt else { return }
                do {
                    self.installationTask = try self.installer.install(extractedApp: extracted, replacing: Bundle.main.bundleURL)
                    self.armInstallWatchdog()
                    self.terminate()
                } catch {
                    self.installScheduled = false
                    self.fail(.install, error)
                }
            }
        } catch {
            guard attempt == installAttempt else { return }
            preparationTask = nil
            installScheduled = false
            if error is CancellationError {
                state = .ready(currentVersion: currentVersion, availableVersion: version)
            } else { fail(.install, error) }
        }
    }

    func revealDownloadedUpdate() {
        guard let downloadedArchive else { return }
        workspace.reveal(downloadedArchive)
    }

    func openReleases() {
        workspace.open(available?.htmlURL ?? AppUpdateConfiguration.releasesURL)
    }

    func cancel() {
        checkTask?.cancel()
        downloadTask?.cancel()
        // A scheduled replacement must survive the app's ordinary shutdown.
        // Only preparation is cancelled here; the watchdog owns helper cancellation.
        preparationTask?.cancel()
    }

    private func performCheck() async -> AppUpdateState {
        defer { checkTask = nil }
        if let rateLimitedUntil, rateLimitedUntil > now() {
            return fail(.check, AppUpdateIssue(code: .rateLimited, detail: "", retryAfter: rateLimitedUntil))
        }
        rateLimitedUntil = nil
        available = nil
        releaseNotes = nil
        activeOperation = .check
        state = .checking(currentVersion: currentVersion)
        defer {
            if activeOperation == .check { activeOperation = nil }
        }
        do {
            let release = try await client.fetchLatestRelease()
            if Task.isCancelled { return state }
            guard let current = SemanticVersion(currentVersion) else {
                return fail(.check, AppUpdateIssue(code: .configuration, detail: String(localized: "The GitHub Release update metadata is unavailable.")))
            }
            guard let release else {
                state = .noRelease(currentVersion: currentVersion)
                return state
            }
            releaseNotes = ReleaseNotes(version: release.version.display, body: release.notes)
            if release.version <= current {
                state = .upToDate(currentVersion: currentVersion)
                return state
            }
            available = release
            if GitHubReleaseParser.selectAsset(from: release) == nil {
                state = .manual(currentVersion: currentVersion, availableVersion: release.version.display)
            } else {
                state = .available(currentVersion: currentVersion, availableVersion: release.version.display)
            }
            return state
        } catch {
            return fail(.check, error)
        }
    }

    private func performDownload(_ release: GitHubRelease) async -> AppUpdateState {
        guard let asset = GitHubReleaseParser.selectAsset(from: release) else {
            state = .manual(currentVersion: currentVersion, availableVersion: release.version.display)
            downloadTask = nil
            return state
        }
        activeOperation = .download
        state = .downloading(currentVersion: currentVersion, availableVersion: release.version.display,
                             percent: 0, transferred: 0, total: max(0, asset.size), bytesPerSecond: 0)
        defer {
            if activeOperation == .download { activeOperation = nil }
            downloadTask = nil
        }
        let destination = workspace.archiveURL(release.version.display, asset.name)
        do {
            try await client.download(asset, to: destination) { [weak self] transferred, total, rate in
                guard let self else { return }
                let version = release.version.display
                let apply = {
                    MainActor.assumeIsolated {
                        self.markProgress(version: version, transferred: transferred, total: total, rate: rate)
                    }
                }
                if Thread.isMainThread {
                    apply()
                } else {
                    DispatchQueue.main.sync(execute: apply)
                }
            }
            if Task.isCancelled { return state }
            downloadedArchive = destination
            if !installer.canInstallInPlace {
                // Finder mounts the disk image and shows its drag-to-Applications window.
                workspace.open(destination)
            }
            state = .ready(currentVersion: currentVersion, availableVersion: release.version.display)
            return state
        } catch is CancellationError {
            if case .downloading = state {
                state = .available(currentVersion: currentVersion, availableVersion: release.version.display)
            }
            return state
        } catch {
            return fail(.download, error)
        }
    }

    private func markProgress(version: String, transferred: Int64, total: Int64, rate: Int64) {
        guard case .downloading(_, let current, let existing, _, _, _) = state, current == version else { return }
        let progress = AppUpdateProgress.clamped(transferred: transferred, total: total, rate: rate)
        if floor(existing) == floor(progress.percent), progress.percent < 100 {
            return
        }
        state = .downloading(currentVersion: currentVersion, availableVersion: version, percent: progress.percent,
                             transferred: progress.transferred, total: progress.total, bytesPerSecond: progress.rate)
    }

    @discardableResult
    private func fail(_ operation: AppUpdateOperation, _ error: Error) -> AppUpdateState {
        if error is CancellationError { return state }
        let code = AppUpdateErrorClassifier.classify(error)
        if code == .rateLimited { rateLimitedUntil = (error as? AppUpdateIssue)?.retryAfter }
        if case .error(_, let existingOperation, let existingCode, _) = state,
           existingOperation == operation, existingCode == code {
            return state
        }
        let version = available?.version.display
        state = .error(currentVersion: currentVersion, operation: operation, code: code,
                       availableVersion: operation == .install ? version : nil)
        return state
    }

    private func resolvedArchive() throws -> URL {
        if let downloadedArchive, FileManager.default.fileExists(atPath: downloadedArchive.path) {
            return downloadedArchive
        }
        throw AppUpdateIssue(code: .configuration, detail: String(localized: "No downloaded update is ready to install."))
    }

    /// Stops the installer helper that is waiting for this app to quit, at once. For a quit
    /// that was refused: the helper would otherwise replace the app whenever it did quit,
    /// possibly much later. The update stays downloaded and About offers the install again.
    /// A no-op when no helper is waiting or one is already being stopped, so it can be
    /// called more than once.
    func cancelPendingInstall() async {
        guard installScheduled, installationTask != nil, !installCancellationInProgress else { return }
        installWatchdog?.cancel()
        installWatchdog = nil
        await stopInstallationHelper()
    }

    /// The watchdog must not cancel itself on the way here: the helper's own wait for it
    /// to end runs on the calling task and stops sleeping once that task is cancelled.
    private func stopInstallationHelper() async {
        guard installScheduled, !installCancellationInProgress, let installation = installationTask else { return }
        installCancellationInProgress = true
        defer { installCancellationInProgress = false }
        let ended = await installation.cancel()
        if ended {
            installationTask = nil
            installScheduled = false
        }
        fail(.install, AppUpdateIssue(code: .unknown, detail: String(localized: "Install timed out: the app did not quit and relaunch.")))
    }

    private func armInstallWatchdog() {
        installWatchdog?.cancel()
        let timeout = installTimeout
        installWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            await self.stopInstallationHelper()
        }
    }
}

struct AppUpdateWorkspace: Sendable {
    let archiveURL: @Sendable (String, String) -> URL
    let reveal: @Sendable (URL) -> Void
    let open: @Sendable (URL) -> Void

    static var live: AppUpdateWorkspace {
        AppUpdateWorkspace(
            archiveURL: { version, name in
                let folder = ClientPaths.supportURL.appendingPathComponent("Updates", isDirectory: true)
                let sanitized = name.isEmpty ? "WallpaperMachine-\(version).dmg" : name
                return folder.appendingPathComponent(sanitized)
            },
            reveal: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            open: { url in
                NSWorkspace.shared.open(url)
            }
        )
    }
}
