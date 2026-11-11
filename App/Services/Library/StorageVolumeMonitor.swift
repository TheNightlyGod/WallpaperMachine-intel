import AppKit
import Observation

/// Follows the drive that holds the wallpaper library (`StorageLocation`) while the app runs, so
/// ejecting it stops the wallpapers that play from it and connecting it again brings them back.
///
/// It watches only a library kept on another disk than the startup disk, and only that disk: the
/// workspace's mount notifications for any other volume are ignored without reading anything.
///
/// - Ejected (`willUnmountNotification`) or unplugged (`didUnmountNotification`): every wallpaper
///   is in the one library on that drive, so `presentationActions` asks the presentation policy to
///   stop them all, as a **Stop (free memory)** rule does. That closes the scene runtimes, the web
///   pages and the video players with the files they hold, so the eject can go ahead, and keeps
///   every display's assignment. An eject that another app refused posts nothing more: once
///   `ejectGrace` has passed with the library still readable, its wallpapers play again.
/// - Connected again (`didMountNotification`, the library's marker found): the library is
///   rescanned first, then the stop is lifted and the displays load what they were assigned.
/// - Missing at launch: the app started without its library. Connecting the drive calls
///   `onDriveConnectedAfterLaunch` so the app can open it in place, unless a backup restore waits
///   for it: a restore is applied only at a launch, so that one still needs a reopen. A drive that
///   finished mounting after the launch looked for it but before `start()` is found by one look
///   once the launch is over, since its mount is not announced again.
@MainActor
final class StorageVolumeMonitor {
    enum State: Equatable, Sendable {
        /// Nothing to follow: the library is on the startup disk, or where it is cannot be read.
        case idle
        /// The library is open and its drive is connected.
        case connected
        /// The library's drive went away while the library was open.
        case disconnected
        /// The app launched without its library because the drive was not connected.
        case awaitingDriveAfterLaunch
    }

    /// The disk a path is on, as far as this monitor needs to know.
    struct Volume: Equatable, Sendable {
        /// Where the disk is mounted.
        var url: URL
        var isStartupDisk: Bool
    }

    private(set) var state: State
    /// From the moment the drive goes away until the library has been rescanned after it returns.
    private(set) var stopsWallpapers = false
    /// Runs when `stopsWallpapers` changes, for the presentation policy to evaluate again.
    var onChange: (@MainActor () -> Void)?
    /// Runs once the drive the app launched without is connected with this library on it.
    var onDriveConnectedAfterLaunch: (@MainActor () -> Void)?

    /// What the drive asks of the presentation policy, beside the app rules: stop everything.
    var presentationActions: Set<AppRuleAction> { stopsWallpapers ? [.stop] : [] }

    private let root: URL?
    private let support: URL
    private let center: NotificationCenter
    private let volume: @MainActor (URL) -> Volume?
    private let restoreWaits: @MainActor () -> Bool
    private let rescan: @MainActor () async -> Void
    private let status: LibraryDriveStatus
    private let ejectGrace: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The disk the library was last read from, for an unmount that names its mount point.
    private var rootVolume: URL?
    private var observers: [NSObjectProtocol] = []
    private var launchCheck: Task<Void, Never>?
    private var ejectCheck: Task<Void, Never>?
    private var returning: Task<Void, Never>?
    /// Counts the drive's returns, so a rescan overtaken by a newer one lifts nothing.
    private var returnGeneration: UInt64 = 0

    /// Closures are optional so their `@MainActor` defaults are built inside this initializer.
    init(
        resolution: StorageLocation.Resolution = ClientPaths.storageResolution,
        support: URL = ClientPaths.supportURL,
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        volume: (@MainActor (URL) -> Volume?)? = nil,
        restoreWaits: (@MainActor () -> Bool)? = nil,
        status: LibraryDriveStatus? = nil,
        ejectGrace: Duration = .seconds(20),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        rescan: @escaping @MainActor () async -> Void
    ) {
        self.support = support
        self.center = center
        let volume = volume ?? { Self.systemVolume(of: $0) }
        self.volume = volume
        self.restoreWaits = restoreWaits ?? { Self.restoreIsPending(support: support) }
        self.status = status ?? .shared
        self.ejectGrace = ejectGrace
        self.sleep = sleep
        self.rescan = rescan
        switch resolution {
        case .support, .unavailable(nil):
            root = nil
            state = .idle
        case .chosen(let url):
            let found = volume(url)
            root = url.standardizedFileURL
            rootVolume = found?.url
            state = found?.isStartupDisk == true ? .idle : .connected
        case .unavailable(let location?):
            root = location.url.standardizedFileURL
            state = .awaitingDriveAfterLaunch
        }
    }

    /// Starts observing mounts, unless there is nothing to follow. A second call does nothing.
    ///
    /// Without its library at launch, it also looks once whether the drive mounted before these
    /// observers were added: on a later main-actor turn, so a library found then opens after the
    /// launch that called this has finished starting, never in the middle of it.
    func start() {
        guard observers.isEmpty, state != .idle else { return }
        for name in [
            NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didMountNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let url = Self.volumeURL(of: note) else { return }
                let name = note.name
                MainActor.assumeIsolated { self?.handle(name, volume: url) }
            })
        }
        if state == .awaitingDriveAfterLaunch {
            launchCheck = Task { [weak self] in
                guard !Task.isCancelled else { return }
                self?.driveMayHaveMountedBeforeStart()
            }
        }
    }

    /// Ends the observation and leaves the wallpapers as they are: when the app quits, and when a
    /// library found after the launch is on the startup disk after all.
    func stop() {
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        launchCheck?.cancel()
        launchCheck = nil
        ejectCheck?.cancel()
        ejectCheck = nil
        returning?.cancel()
        returning = nil
    }

    /// Waits for the launch's look, the rescan and the eject check that are under way: for tests.
    func settle() async {
        await launchCheck?.value
        await ejectCheck?.value
        await returning?.value
    }

    // MARK: Events

    private func handle(_ name: Notification.Name, volume: URL) {
        switch name {
        case NSWorkspace.willUnmountNotification: volumeWillUnmount(volume)
        case NSWorkspace.didUnmountNotification: volumeDidUnmount(volume)
        case NSWorkspace.didMountNotification: volumeDidMount(volume)
        default: return
        }
    }

    private func volumeWillUnmount(_ volume: URL) {
        guard holdsLibrary(volume) else { return }
        switch state {
        case .connected:
            AppLog.info("storage: the library's drive \(volume.path) is being ejected; its wallpapers stop")
            disconnect()
        case .disconnected where ejectCheck != nil:
            // Ejected again after a refusal: the grace counts from this attempt.
            ejectCheck?.cancel()
        case .disconnected, .idle, .awaitingDriveAfterLaunch:
            return
        }
        let grace = ejectGrace
        ejectCheck = Task { [weak self, sleep] in
            do { try await sleep(grace) } catch { return }
            // A later attempt or the unmount cancelled this check after its time was up.
            guard !Task.isCancelled else { return }
            self?.ejectMayHaveBeenRefused()
        }
    }

    private func volumeDidUnmount(_ volume: URL) {
        guard holdsLibrary(volume) else { return }
        ejectCheck?.cancel()
        ejectCheck = nil
        guard state == .connected else { return }
        AppLog.info("storage: the library's drive \(volume.path) was disconnected; its wallpapers stop")
        disconnect()
    }

    private func volumeDidMount(_ volume: URL) {
        guard holdsLibrary(volume) else { return }
        switch state {
        case .disconnected:
            guard libraryIsReadable() else {
                AppLog.info("storage: \(volume.path) was connected without this library on it")
                return
            }
            AppLog.info("storage: the library's drive \(volume.path) is connected again; its wallpapers play again")
            ejectCheck?.cancel()
            ejectCheck = nil
            reconnect(on: volume)
        case .awaitingDriveAfterLaunch:
            guard libraryIsReadable() else {
                AppLog.info("storage: \(volume.path) was connected without this library on it")
                return
            }
            AppLog.info("storage: the library's drive \(volume.path) is connected")
            openAfterLaunch(on: Volume(url: volume, isStartupDisk: false))
        case .idle, .connected:
            return
        }
    }

    /// The drive finished mounting between the launch's look for the library and `start()`: its
    /// mount was announced before anything listened.
    private func driveMayHaveMountedBeforeStart() {
        launchCheck = nil
        guard state == .awaitingDriveAfterLaunch, let root, libraryIsReadable() else { return }
        AppLog.info("storage: the library's drive was connected before it was watched")
        openAfterLaunch(on: volume(root))
    }

    /// No unmount followed the eject: another app kept the drive busy, or the eject was cancelled.
    private func ejectMayHaveBeenRefused() {
        ejectCheck = nil
        guard state == .disconnected, libraryIsReadable() else { return }
        AppLog.info("storage: the library's drive was not ejected; its wallpapers play again")
        reconnect(on: rootVolume)
    }

    // MARK: Transitions

    /// The library the app launched without is readable: it opens, unless a backup restore waits
    /// for a reopen. From then on its drive is followed as for a library that opened at launch.
    private func openAfterLaunch(on found: Volume?) {
        guard !restoreWaits() else {
            AppLog.info("storage: the library's drive is connected; a backup restore waits for WallpaperMachine to be reopened")
            return
        }
        AppLog.info("storage: the library opens")
        rootVolume = found?.url
        if found?.isStartupDisk == true {
            // Nothing to follow on the startup disk, as for a library found there at launch.
            stop()
            state = .idle
        } else {
            state = .connected
        }
        onDriveConnectedAfterLaunch?()
    }

    private func disconnect() {
        state = .disconnected
        returnGeneration &+= 1
        returning?.cancel()
        returning = nil
        status.set(disconnectedRoot: root)
        setStopsWallpapers(true)
    }

    /// The library is back: rescanned first, so the displays load from a library that lists it
    /// again, then played.
    private func reconnect(on volume: URL?) {
        if let volume { rootVolume = volume }
        state = .connected
        returnGeneration &+= 1
        let generation = returnGeneration
        returning = Task { [weak self, rescan] in
            await rescan()
            guard let self, self.returnGeneration == generation, self.state == .connected else { return }
            self.returning = nil
            self.status.set(disconnectedRoot: nil)
            self.setStopsWallpapers(false)
        }
    }

    private func setStopsWallpapers(_ stops: Bool) {
        guard stops != stopsWallpapers else { return }
        stopsWallpapers = stops
        onChange?()
    }

    // MARK: Reading

    /// Whether `volume` is the disk the library is on: its mount point, or a folder above the
    /// library. The startup disk's `/` never is, so no other volume can pass for it.
    private func holdsLibrary(_ volume: URL) -> Bool {
        guard let root else { return false }
        let mount = volume.standardizedFileURL.pathComponents
        guard mount.count > 1 else { return false }
        if let rootVolume, rootVolume.standardizedFileURL.pathComponents == mount { return true }
        return root.pathComponents.starts(with: mount)
    }

    /// The library's folder is there with this library's marker in it.
    private func libraryIsReadable() -> Bool {
        guard let root, case .chosen(let url) = StorageLocation.resolve(support: support) else { return false }
        return url.standardizedFileURL.path == root.path
    }

    private nonisolated static func volumeURL(of note: Notification) -> URL? {
        if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { return url }
        return (note.userInfo?["NSDevicePath"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func systemVolume(of url: URL) -> Volume? {
        // A fresh URL value: resource values are cached on the value that read them.
        guard let values = try? URL(fileURLWithPath: url.path).resourceValues(
            forKeys: [.volumeURLKey, .volumeIsRootFileSystemKey]),
            let mount = values.volume
        else { return nil }
        return Volume(url: mount, isStartupDisk: values.volumeIsRootFileSystem == true || mount.path == "/")
    }

    /// A restore that waits for the next launch, or one a quit cut short: both are put right only
    /// before anything opens the library (`WallpaperBackupService.applyPendingRestore`).
    static func restoreIsPending(support: URL) -> Bool {
        let manager = FileManager.default
        return WallpaperBackupService(supportRoot: support).pendingRestore
            || manager.fileExists(atPath: support.appendingPathComponent(WallpaperBackupService.transactionDirectoryName).path)
    }
}

/// The library's drive as `StorageVolumeMonitor` last found it, for readers that do not own the
/// monitor: the control panel's banner. Holds nothing of its own and is never persisted.
@MainActor
@Observable
final class LibraryDriveStatus {
    static let shared = LibraryDriveStatus()

    /// The folder of the library whose drive went away while it was open; nil while it is
    /// connected, and for a library on this Mac.
    private(set) var disconnectedRoot: URL?

    func set(disconnectedRoot: URL?) {
        guard disconnectedRoot != self.disconnectedRoot else { return }
        self.disconnectedRoot = disconnectedRoot
    }
}
