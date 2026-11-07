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
    /// Every release newer than this build up to the available one, newest first, for the update
    /// window. From the manifest's changelog in every translation; without one, the latest
    /// release's own notes stand alone.
    private(set) var pendingReleases: [AppReleaseHistory.Entry] = []
    var mode: AppUpdateMode {
        didSet { defaults.set(mode.rawValue, forKey: AppUpdateMode.key) }
    }
    var automaticallyInstallsUpdates: Bool {
        get { mode == .automatic }
        set { mode = newValue ? .automatic : .notify }
    }
    private(set) var lastCheckedAt: Date?
    private(set) var recentlyInstalledVersion: String?
    private(set) var isVerifyingDownload = false
    private var automaticInstallation = false
    var isAutomaticInstallation: Bool { installScheduled && automaticInstallation }
    private(set) var deferredUntil: Date?
    private(set) var deferredVersion: String?
    private(set) var blockedAutomaticVersion: String?
    var notesReleases: [AppReleaseHistory.Entry] {
        if !pendingReleases.isEmpty { return pendingReleases }
        guard let available else { return [] }
        return Self.releases(in: available, after: SemanticVersion("0.0.0")!).prefix(1).map { $0 }
    }
    var isDeferred: Bool { deferredVersion == state.availableVersion && (deferredUntil ?? .distantPast) > now() }
    var hasDownloadedUpdate: Bool { downloadedArchive != nil }
    private(set) var isChecking = false
    var installIsScheduled: Bool { installScheduled }
    var mayDownloadAutomatically: Bool {
        mode != .notify && canInstallInPlace && state.availableVersion != skippedVersion
            && !isDeferred && state.availableVersion != blockedAutomaticVersion
    }
    var automaticCheckIsDue: Bool {
        guard let lastCheckAttempt else { return true }
        let elapsed = now().timeIntervalSince(lastCheckAttempt)
        return elapsed < 0 || elapsed >= AppUpdatePolicy.checkInterval
    }
    var nextAutomaticCheckDelay: TimeInterval {
        if state.isBusy || restoring || installScheduled { return AppUpdatePolicy.checkInterval }
        return min(AppUpdatePolicy.checkInterval,
                   max(1, AppUpdatePolicy.checkInterval - now().timeIntervalSince(lastCheckAttempt ?? .distantPast)))
    }
    /// The version the person chose **Skip This Version** for; unattended checks keep quiet about
    /// it, and a newer release is offered as usual.
    var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedKey) }
        set {
            defaults.set(newValue, forKey: Self.skippedKey)
            if newValue != nil { postponeUpdate() }
        }
    }
    /// When the last check was refused by GitHub's anonymous rate limit, the time it lifts.
    /// Checks before then fail locally, so retries can't keep the shared quota exhausted.
    private(set) var rateLimitedUntil: Date?
    static let automaticKey = "WallpaperMachine.updates.automatic"
    static let skippedKey = "WallpaperMachine.updates.skippedVersion"
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: any AppUpdateClient
    @ObservationIgnored private let installer: any AppUpdateInstalling
    @ObservationIgnored private let workspace: AppUpdateWorkspace
    @ObservationIgnored private let scheduleInstall: (@escaping () -> Void) -> Void
    @ObservationIgnored private let terminate: () -> Void
    @ObservationIgnored private let installTimeout: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastCheckAttempt: Date?
    private var restoring = false
    var isRestoring: Bool { restoring }
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var persistenceRecord = AppUpdatePersistence.Record()
    @ObservationIgnored private var checkTask: Task<AppUpdateState, Never>?
    @ObservationIgnored private var downloadTask: Task<AppUpdateState, Never>?
    @ObservationIgnored private var available: GitHubRelease?
    @ObservationIgnored private var downloadedArchive: URL?
    @ObservationIgnored private var downloadedApplication: URL?
    @ObservationIgnored private var extractedApp: URL?
    @ObservationIgnored private var activeOperation: AppUpdateOperation?
    private var installScheduled = false
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

    /// Whether the installed copy can be replaced where it is; otherwise a download opens in
    /// Finder for a manual install.
    var canInstallInPlace: Bool { installer.canInstallInPlace }

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         client: any AppUpdateClient = GitHubReleaseClient(),
         installer: any AppUpdateInstalling = AppUpdateInstaller(),
         workspace: AppUpdateWorkspace = .live,
         scheduleInstall: ((@escaping () -> Void) -> Void)? = nil,
         terminate: (() -> Void)? = nil,
         installTimeout: Duration = .seconds(45),
         defaults: UserDefaults = ClientPreferences.defaults,
         now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        let initialMode = AppUpdateMode.migrate(saved: defaults.string(forKey: AppUpdateMode.key),
                                                legacy: defaults.object(forKey: Self.automaticKey) as? Bool, freshInstall: false)
        mode = initialMode
        defaults.set(initialMode.rawValue, forKey: AppUpdateMode.key)
        deferredUntil = defaults.object(forKey: "WallpaperMachine.updates.deferredUntil") as? Date
        deferredVersion = defaults.string(forKey: "WallpaperMachine.updates.deferredVersion")
        blockedAutomaticVersion = defaults.string(forKey: "WallpaperMachine.updates.blockedVersion")
        lastCheckAttempt = defaults.object(forKey: "WallpaperMachine.updates.lastAttempt") as? Date
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
        if restoring || installScheduled { return state }
        if case .preparing = state { return state }
        if case .downloading = state { return state }
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

    func downloadUpdate(automatically: Bool = false) async -> AppUpdateState {
        if restoring || checkTask != nil || installScheduled { return state }
        if !automatically { clearDeferral() }
        if let downloadTask { return await downloadTask.value }
        guard case .available(_, let version) = state, let release = available, release.version.display == version else {
            fail(.download, AppUpdateIssue(code: .configuration, detail: String(localized: "No update is available to download.")))
            return state
        }
        let task = Task { await performDownload(release) }
        downloadTask = task
        return await task.value
    }

    func installUpdate(automatically: Bool = false, allowed: @escaping @MainActor () -> Bool = { true }) async {
        guard !restoring, checkTask == nil, allowed() else { return }
        if !automatically { clearDeferral() }
        automaticInstallation = automatically
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
        guard isReady || canRetryInstall || downloadedArchive != nil else {
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
            if let previous = extractedApp {
                await installer.discardPreparation(previous)
                extractedApp = nil
            }
            do {
                let installer = installer
                guard let release = available else { throw AppUpdateIssue(code: .configuration, detail: "Missing release") }
                let task = Task {
                    let app = try await installer.prepareInstallation(archive: archive, release: release)
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
            if let previous = downloadedApplication, previous != extracted {
                await installer.discardPreparation(previous)
            }
            downloadedApplication = extracted
            extractedApp = extracted
            state = .ready(currentVersion: currentVersion, availableVersion: version)
            guard allowed() else { installScheduled = false; return }
            persistenceRecord.installingVersion = version
            try await persist()
            scheduleInstall { [weak self] in
                guard let self, self.installScheduled, self.installAttempt == attempt else { return }
                guard allowed() else {
                    self.installScheduled = false
                    self.persistenceRecord.installingVersion = nil
                    Task { try? await self.persist() }
                    return
                }
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

    /// Restores only a complete, reverified package and removes abandoned downloads. File work
    /// is owned by the cache actor; custom workspaces without persistence retain their cleanup seam.
    func discardStaleDownloads() async {
        guard downloadTask == nil, !restoring else { return }
        if let cache = workspace.persistence, !restored {
            restoring = true
            defer { restoring = false; restored = true }
            do {
                persistenceRecord = try await cache.load()
                lastCheckedAt = persistenceRecord.lastCheckedAt
                rateLimitedUntil = persistenceRecord.rateLimitedUntil
                recentlyInstalledVersion = persistenceRecord.recentlyInstalledVersion
                available = persistenceRecord.release
                if let release = available {
                    releaseNotes = ReleaseNotes(version: release.version.display, body: release.notes)
                    pendingReleases = Self.releases(in: release, after: SemanticVersion(currentVersion) ?? release.version)
                    if let installing = persistenceRecord.installingVersion,
                       let target = SemanticVersion(installing), let current = SemanticVersion(currentVersion) {
                        if current >= target {
                            recentlyInstalledVersion = installing
                            persistenceRecord.recentlyInstalledVersion = installing
                        } else { blockAutomatic(installing) }
                        persistenceRecord.installingVersion = nil
                    }
                    if let current = SemanticVersion(currentVersion), release.version > current,
                       release.version.display != skippedVersion, AppUpdatePolicy.supports(release) {
                        state = .available(currentVersion: currentVersion, availableVersion: release.version.display)
                        if let archive = try await cache.verifiedArchive(in: persistenceRecord) {
                            isVerifyingDownload = true
                            defer { isVerifyingDownload = false }
                            let verified = try await installer.prepareInstallation(archive: archive, release: release)
                            downloadedArchive = archive
                            downloadedApplication = verified
                            state = .ready(currentVersion: currentVersion, availableVersion: release.version.display)
                        }
                    } else {
                        persistenceRecord.archiveName = nil
                        state = .idle(currentVersion: currentVersion)
                    }
                }
                try await persist()
            } catch {
                persistenceRecord.archiveName = nil
                AppLog.warn("update cache could not be restored: \(error.localizedDescription)")
                try? await persist()
            }
            await cache.discardArchives(keeping: downloadedArchive)
        } else if let cache = workspace.persistence {
            await cache.discardArchives(keeping: downloadedArchive)
        } else {
            let workspace = workspace, keeping = downloadedArchive
            await Task.detached { workspace.discardArchives(keeping) }.value
        }
    }

    func skipCurrentVersion() async {
        guard !restoring, !state.isBusy, !installScheduled, checkTask == nil, let release = available else { return }
        skippedVersion = release.version.display
        downloadedArchive = nil
        persistenceRecord.archiveName = nil
        if let app = downloadedApplication { await installer.discardPreparation(app) }
        downloadedApplication = nil
        if let app = extractedApp { await installer.discardPreparation(app) }
        extractedApp = nil
        if let cache = workspace.persistence { await cache.discardArchives(keeping: nil) }
        state = GitHubReleaseParser.selectAsset(from: release) == nil
            ? .manual(currentVersion: currentVersion, availableVersion: release.version.display)
            : .available(currentVersion: currentVersion, availableVersion: release.version.display)
        do { try await persist() } catch { AppLog.warn("skipped update could not be saved: \(error)") }
    }

    func postponeUpdate() {
        guard let version = state.availableVersion, !isInstallPending else { return }
        deferredVersion = version
        deferredUntil = now().addingTimeInterval(AppUpdatePolicy.postponement)
        defaults.set(version, forKey: "WallpaperMachine.updates.deferredVersion")
        defaults.set(deferredUntil, forKey: "WallpaperMachine.updates.deferredUntil")
    }

    func dismissRecentUpdate() async {
        recentlyInstalledVersion = nil
        persistenceRecord.recentlyInstalledVersion = nil
        do { try await persist() } catch { AppLog.warn("update result could not be saved: \(error)") }
    }

    func retryUpdate() async -> AppUpdateState {
        clearDeferral()
        if case .error(_, .install, _, _) = state {
            await installUpdate()
        } else if case .error(_, .download, _, _) = state, let release = available {
            state = .available(currentVersion: currentVersion, availableVersion: release.version.display)
            return await downloadUpdate()
        } else { return await checkForUpdates() }
        return state
    }

    private func clearDeferral() {
        deferredUntil = nil
        deferredVersion = nil
        blockedAutomaticVersion = nil
        for key in ["deferredUntil", "deferredVersion", "blockedVersion"] {
            defaults.removeObject(forKey: "WallpaperMachine.updates." + key)
        }
    }

    private func blockAutomatic(_ version: String) {
        blockedAutomaticVersion = version
        defaults.set(version, forKey: "WallpaperMachine.updates.blockedVersion")
    }

    private func persist() async throws {
        persistenceRecord.release = available
        persistenceRecord.lastCheckedAt = lastCheckedAt
        persistenceRecord.rateLimitedUntil = rateLimitedUntil
        try await workspace.persistence?.save(persistenceRecord)
    }

    func revealDownloadedUpdate() {
        guard let downloadedApplication else { return }
        workspace.reveal(downloadedApplication)
    }

    func openReleases() {
        workspace.open(available?.htmlURL ?? AppUpdateConfiguration.releasesURL)
    }

    func cancel() {
        if downloadTask != nil || preparationTask != nil { postponeUpdate() }
        checkTask?.cancel()
        downloadTask?.cancel()
        // A scheduled replacement must survive the app's ordinary shutdown.
        // Only preparation is cancelled here; the watchdog owns helper cancellation.
        preparationTask?.cancel()
    }

    private func performCheck() async -> AppUpdateState {
        isChecking = true
        defer { checkTask = nil; isChecking = false }
        lastCheckAttempt = now()
        defaults.set(lastCheckAttempt, forKey: "WallpaperMachine.updates.lastAttempt")
        if let rateLimitedUntil, rateLimitedUntil > now() {
            return fail(.check, AppUpdateIssue(code: .rateLimited, detail: "", retryAfter: rateLimitedUntil))
        }
        rateLimitedUntil = nil
        let previousState = state
        activeOperation = .check
        if downloadedArchive == nil { state = .checking(currentVersion: currentVersion) }
        defer {
            if activeOperation == .check { activeOperation = nil }
        }
        do {
            let release = try await client.fetchLatestRelease()
            try Task.checkCancellation()
            lastCheckedAt = now()
            guard let current = SemanticVersion(currentVersion) else {
                return fail(.check, AppUpdateIssue(code: .configuration, detail: String(localized: "The GitHub Release update metadata is unavailable.")))
            }
            guard let release else {
                if downloadedArchive != nil { try await persist(); return state }
                available = nil
                releaseNotes = nil
                pendingReleases = []
                state = .noRelease(currentVersion: currentVersion)
                try await persist()
                return state
            }
            if downloadedArchive != nil, let previous = available, release.version <= previous.version {
                state = .ready(currentVersion: currentVersion, availableVersion: previous.version.display)
                try await persist()
                return state
            }
            if downloadedArchive != nil, !AppUpdatePolicy.supports(release) {
                try await persist()
                return state
            }
            if downloadedArchive != nil {
                downloadedArchive = nil
                persistenceRecord.archiveName = nil
                if let app = downloadedApplication { await installer.discardPreparation(app) }
                downloadedApplication = nil
                if let app = extractedApp { await installer.discardPreparation(app) }
                extractedApp = nil
                await workspace.persistence?.discardArchives(keeping: nil)
            }
            available = release
            releaseNotes = ReleaseNotes(version: release.version.display, body: release.notes)
            pendingReleases = release.version > current ? Self.releases(in: release, after: current) : []
            if release.version <= current {
                state = .upToDate(currentVersion: currentVersion)
                try await persist()
                return state
            }
            if !AppUpdatePolicy.supports(release) {
                _ = fail(.check, AppUpdateIssue(code: .incompatible, detail: "Incompatible update"))
            } else if GitHubReleaseParser.selectAsset(from: release) == nil {
                state = .manual(currentVersion: currentVersion, availableVersion: release.version.display)
            } else {
                state = .available(currentVersion: currentVersion, availableVersion: release.version.display)
            }
            try await persist()
            return state
        } catch is CancellationError {
            state = previousState
            return state
        } catch {
            _ = fail(.check, error)
            do { try await persist() } catch { AppLog.warn("update state could not be saved: \(error)") }
            return state
        }
    }

    /// The changelog's releases above `current` up to `release`, or `release`'s own notes (in
    /// English, the only language a release body has) when the changelog is missing or unreadable.
    static func releases(in release: GitHubRelease, after current: SemanticVersion) -> [AppReleaseHistory.Entry] {
        if !release.changelog.isEmpty {
            do {
                let entries = try AppReleaseHistory(markdown: release.changelog).entries.filter {
                    $0.version > current && $0.version <= release.version
                }
                if entries.first?.version == release.version { return entries }
            } catch {
                AppLog.warn("update changelog could not be read: \(error)")
            }
        }
        guard let notes = ReleaseNotes(version: release.version.display, body: release.notes) else { return [] }
        return [AppReleaseHistory.Entry(version: release.version, english: notes, chinese: notes,
                                        url: release.htmlURL)]
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
        // An image downloaded earlier, ready or not, is superseded by this one.
        downloadedArchive = nil
        let workspace = workspace
        persistenceRecord.archiveName = nil
        if let cache = workspace.persistence { await cache.discardArchives(keeping: nil) }
        else { await Task.detached { workspace.discardArchives(nil) }.value }
        do {
            try await persist()
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
            try Task.checkCancellation()
            // A mirror controls the DMG and its digest. Finder gets only the verified app,
            // never the original image, which could contain unsigned sibling installers.
            isVerifyingDownload = true
            defer { isVerifyingDownload = false }
            let verified = try await installer.prepareInstallation(archive: destination, release: release)
            if let previous = downloadedApplication { await installer.discardPreparation(previous) }
            do { try Task.checkCancellation() } catch {
                await installer.discardPreparation(verified)
                throw error
            }
            downloadedApplication = verified
            downloadedArchive = destination
            persistenceRecord.archiveName = destination.lastPathComponent
            try await persist()
            if !installer.canInstallInPlace { workspace.reveal(verified) }
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
        let version = available.flatMap { release in
            SemanticVersion(currentVersion).map { release.version > $0 } == true ? release.version.display : nil
        }
        if let version, operation == .install || code == .verification || code == .incompatible || code == .permission {
            blockAutomatic(version)
        }
        state = .error(currentVersion: currentVersion, operation: operation, code: code,
                       availableVersion: version)
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
    /// Deletes every downloaded image except the one given.
    var discardArchives: @Sendable (_ keeping: URL?) -> Void = { _ in }
    var persistence: AppUpdatePersistence? = nil

    static var updatesFolder: URL {
        ClientPaths.supportURL.appendingPathComponent("Updates", isDirectory: true)
    }

    /// Legacy nonpersistent workspace cleanup. The live cache actor also protects its state record.
    static func discardArchives(in folder: URL, keeping: URL?, fileManager: FileManager = .default) {
        guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let kept = keeping?.standardizedFileURL.path
        for item in items where item.standardizedFileURL.path != kept {
            do { try fileManager.removeItem(at: item) } catch {
                AppLog.warn("could not remove old update download \(item.lastPathComponent): \(error)")
            }
        }
    }

    static var live: AppUpdateWorkspace {
        AppUpdateWorkspace(
            archiveURL: { version, name in
                let folder = updatesFolder
                // A mirror relays the manifest, so the name is untrusted: keep only its last component.
                let last = (name as NSString).lastPathComponent
                let sanitized = ["", ".", "..", "/"].contains(last) ? "WallpaperMachine-\(version).dmg" : last
                return folder.appendingPathComponent(sanitized)
            },
            // The store calls these on the main actor; `DesktopActions` is where tests stop them.
            reveal: { url in
                MainActor.assumeIsolated { DesktopActions.current.reveal([url]) }
            },
            open: { url in
                MainActor.assumeIsolated { _ = DesktopActions.current.open(url) }
            },
            discardArchives: { keeping in discardArchives(in: updatesFolder, keeping: keeping) },
            persistence: AppUpdatePersistence(directory: updatesFolder)
        )
    }
}
