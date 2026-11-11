import AppKit
import XCTest

@testable import WallpaperMachine

/// The library kept on another drive while the app runs: ejecting the drive stops its wallpapers,
/// connecting it again plays them, a drive missing at launch opens the library once it is connected,
/// and every other volume is left alone. No real volume is touched: the drive is a folder under a
/// temporary `WALLPAPER_MACHINE_HOME`, its mount notifications are posted to a private center, and
/// unplugging it moves the folder away.
@MainActor
final class StorageVolumeMonitorTests: XCTestCase {
    private var home: URL!
    private var savedHome: String?
    private let center = ObserverCountingCenter()
    private let status = LibraryDriveStatus()
    /// What the monitor and the presentation policy did, in order.
    private var events: [String] = []

    private var support: URL { home.appendingPathComponent("Support", isDirectory: true) }
    private var drive: URL { home.appendingPathComponent("Volumes/Library Drive", isDirectory: true) }
    private var unplugged: URL { home.appendingPathComponent("Unplugged", isDirectory: true) }
    private var root: URL { drive.appendingPathComponent(StorageLocation.folderName, isDirectory: true) }
    private var location: StorageLocation { StorageLocation(path: root.path, id: "library-id") }

    override func setUpWithError() throws {
        savedHome = getenv("WALLPAPER_MACHINE_HOME").map { String(cString: $0) }
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-volume-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        setenv("WALLPAPER_MACHINE_HOME", support.path, 1)
        ClientPaths.reloadStorageLocation()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try StorageLocation.writeMarker(location.id, at: root)
        try StorageLocation.write(location, support: support)
    }

    override func tearDownWithError() throws {
        if let savedHome { setenv("WALLPAPER_MACHINE_HOME", savedHome, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
        ClientPaths.reloadStorageLocation()
        try FileManager.default.removeItem(at: home)
    }

    // MARK: Fixtures

    private func makeMonitor(
        resolution: StorageLocation.Resolution? = nil, startupDisk: Bool = false, ejectGrace: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> StorageVolumeMonitor {
        let drive = drive
        let monitor = StorageVolumeMonitor(
            resolution: resolution ?? .chosen(location.url), support: support, center: center,
            volume: { _ in .init(url: drive, isStartupDisk: startupDisk) },
            status: status, ejectGrace: ejectGrace, sleep: sleep,
            rescan: { [weak self] in self?.events.append("rescan") })
        monitor.onDriveConnectedAfterLaunch = { [weak self] in self?.events.append("library opens") }
        return monitor
    }

    /// The app's presentation policy over one visible display, with the drive as its only rule.
    private func makePolicy(following monitor: StorageVolumeMonitor) -> WallpaperPresentationPolicy {
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: NotificationCenter(), lockCenter: NotificationCenter(), windowCenter: NotificationCenter(),
            surfaces: { [WallpaperSurfaceVisibility(displayID: 1, isVisible: true)] },
            sessionState: { .init(locked: false) },
            appRuleActions: { monitor.presentationActions },
            occlusionSettleDelay: .zero,
            applyGlobal: { [weak self] presentation, completion in
                self?.events.append("wallpapers \(presentation.logLabel)")
                completion(.success(()))
            },
            applyDisplay: { [weak self] display, suspended, completion in
                self?.events.append("display \(display) \(suspended ? "suspended" : "resumed")")
                completion(.success(()))
            })
        monitor.onChange = { [weak policy] in policy?.evaluate() }
        return policy
    }

    private func post(_ name: Notification.Name, _ volume: URL) {
        center.post(name: name, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
    }

    private func unplug() throws {
        try FileManager.default.moveItem(at: drive, to: unplugged)
    }

    private func plugIn() throws {
        try FileManager.default.moveItem(at: unplugged, to: drive)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Tests

    func testEjectingTheLibrarysDriveStopsItsWallpapersAndConnectingItPlaysThemAfterARescan() async throws {
        let monitor = makeMonitor()
        let policy = makePolicy(following: monitor)
        policy.start()
        monitor.start()
        defer { monitor.stop(); policy.stop() }
        XCTAssertEqual(monitor.state, .connected)
        XCTAssertTrue(events.isEmpty, "nothing changes while the drive stays")

        post(NSWorkspace.willUnmountNotification, drive)
        XCTAssertEqual(events, ["wallpapers unloaded"], "the eject frees what plays from the drive at once")
        XCTAssertEqual(status.disconnectedRoot?.path, root.path)
        try unplug()
        post(NSWorkspace.didUnmountNotification, drive)
        XCTAssertEqual(events, ["wallpapers unloaded"])

        try plugIn()
        post(NSWorkspace.didMountNotification, drive)
        await monitor.settle()
        XCTAssertEqual(events, ["wallpapers unloaded", "rescan", "wallpapers resumed"],
                       "the library is read again before its wallpapers load")
        XCTAssertEqual(monitor.state, .connected)
        XCTAssertNil(status.disconnectedRoot)
        XCTAssertEqual(policy.globalPresentation, .running)
    }

    func testADriveUnpluggedWithoutAnEjectStopsItsWallpapersToo() throws {
        let monitor = makeMonitor()
        let policy = makePolicy(following: monitor)
        policy.start()
        monitor.start()
        defer { monitor.stop(); policy.stop() }

        try unplug()
        post(NSWorkspace.didUnmountNotification, drive)
        XCTAssertEqual(events, ["wallpapers unloaded"])
        XCTAssertEqual(monitor.state, .disconnected)
    }

    func testOtherVolumesChangeNothing() throws {
        let monitor = makeMonitor()
        let policy = makePolicy(following: monitor)
        policy.start()
        monitor.start()
        defer { monitor.stop(); policy.stop() }
        let other = home.appendingPathComponent("Volumes/Camera Card", isDirectory: true)
        // Its name starts like the library's drive, and the startup disk holds every path.
        let lookalike = home.appendingPathComponent("Volumes/Library", isDirectory: true)
        for volume in [other, lookalike, URL(fileURLWithPath: "/", isDirectory: true)] {
            post(NSWorkspace.willUnmountNotification, volume)
            post(NSWorkspace.didUnmountNotification, volume)
            post(NSWorkspace.didMountNotification, volume)
        }
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(monitor.state, .connected)
        XCTAssertFalse(monitor.stopsWallpapers)
        XCTAssertNil(status.disconnectedRoot)
    }

    func testALibraryOnTheStartupDiskIsNotFollowed() {
        let monitor = makeMonitor(startupDisk: true)
        let policy = makePolicy(following: monitor)
        policy.start()
        monitor.start()
        defer { monitor.stop(); policy.stop() }
        XCTAssertEqual(monitor.state, .idle)
        post(NSWorkspace.willUnmountNotification, drive)
        post(NSWorkspace.didUnmountNotification, drive)
        XCTAssertTrue(events.isEmpty)

        let onThisMac = makeMonitor(resolution: .support)
        onThisMac.start()
        defer { onThisMac.stop() }
        XCTAssertEqual(onThisMac.state, .idle)
        post(NSWorkspace.didUnmountNotification, drive)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(center.added, 0, "nothing is observed, so no volume's notification runs anything")

        let elsewhere = makeMonitor()
        elsewhere.start()
        defer { elsewhere.stop() }
        XCTAssertGreaterThan(center.added, 0, "a library on another drive is observed")
    }

    func testEjectingAgainAfterARefusalCountsTheGraceFromThatAttempt() async throws {
        let sleeper = ManualSleep()
        let monitor = makeMonitor(sleep: { await sleeper.sleep(for: $0) })
        let policy = makePolicy(following: monitor)
        policy.start()
        monitor.start()
        defer { monitor.stop(); policy.stop(); sleeper.releaseAll() }

        // The first eject is refused while a video still holds its file; the user ejects again.
        post(NSWorkspace.willUnmountNotification, drive)
        try await waitUntil { sleeper.waiting == 1 }
        post(NSWorkspace.willUnmountNotification, drive)
        try await waitUntil { sleeper.waiting == 2 }

        // The first attempt's grace runs out, as a sleep that missed its cancel would; the
        // second's has not.
        sleeper.releaseOldest()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(events, ["wallpapers unloaded"], "the wallpapers stay stopped for the second attempt")
        XCTAssertEqual(monitor.state, .disconnected)

        sleeper.releaseOldest()
        await monitor.settle()
        XCTAssertEqual(events, ["wallpapers unloaded", "rescan", "wallpapers resumed"])
        XCTAssertEqual(monitor.state, .connected)
    }

    func testAnEjectThatDidNotHappenPlaysTheWallpapersAgain() async {
        let monitor = makeMonitor(ejectGrace: .milliseconds(20))
        let policy = makePolicy(following: monitor)
        policy.start()
        monitor.start()
        defer { monitor.stop(); policy.stop() }

        // Another app kept the drive busy: no unmount follows, and the library is still there.
        post(NSWorkspace.willUnmountNotification, drive)
        await monitor.settle()
        XCTAssertEqual(events, ["wallpapers unloaded", "rescan", "wallpapers resumed"])
        XCTAssertEqual(monitor.state, .connected)
        XCTAssertNil(status.disconnectedRoot)
    }

    func testADriveWithoutThisLibraryOnItIsNotTakenForIt() async throws {
        let monitor = makeMonitor()
        let policy = makePolicy(following: monitor)
        policy.start()
        monitor.start()
        defer { monitor.stop(); policy.stop() }
        post(NSWorkspace.willUnmountNotification, drive)
        try unplug()
        post(NSWorkspace.didUnmountNotification, drive)

        // Another drive mounted under the same name holds another library.
        let other = drive.appendingPathComponent(StorageLocation.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try StorageLocation.writeMarker("another-library", at: other)
        post(NSWorkspace.didMountNotification, drive)
        await monitor.settle()
        XCTAssertEqual(events, ["wallpapers unloaded"])
        XCTAssertEqual(monitor.state, .disconnected)
        XCTAssertEqual(status.disconnectedRoot?.path, root.path)
    }

    func testALibraryMissingAtLaunchOpensWhenItsDriveIsConnected() async throws {
        try unplug()
        let monitor = makeMonitor(resolution: .unavailable(location))
        monitor.start()
        defer { monitor.stop() }
        await monitor.settle()
        XCTAssertEqual(monitor.state, .awaitingDriveAfterLaunch)
        XCTAssertTrue(events.isEmpty, "the drive is not there yet")

        // Something else mounted at that path first, without the library.
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        post(NSWorkspace.didMountNotification, drive)
        XCTAssertTrue(events.isEmpty)
        try FileManager.default.removeItem(at: drive)

        try plugIn()
        post(NSWorkspace.didMountNotification, home.appendingPathComponent("Volumes/Camera Card", isDirectory: true))
        XCTAssertTrue(events.isEmpty, "another volume opens nothing")
        post(NSWorkspace.didMountNotification, drive)
        XCTAssertEqual(events, ["library opens"])
        XCTAssertEqual(monitor.state, .connected)
        XCTAssertFalse(monitor.stopsWallpapers)

        // From then on the drive is followed as for a library that opened at launch.
        post(NSWorkspace.didUnmountNotification, drive)
        XCTAssertEqual(monitor.state, .disconnected)
        XCTAssertTrue(monitor.stopsWallpapers)
    }

    func testALibraryWhoseDriveMountedBeforeItWasWatchedOpensOnceTheLaunchIsOver() async {
        // The launch found no library, then the drive finished mounting before the monitor
        // started: its mount is not announced again.
        let monitor = makeMonitor(resolution: .unavailable(location))
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(events.isEmpty, "nothing opens in the middle of the launch that started the monitor")

        await monitor.settle()
        XCTAssertEqual(events, ["library opens"])
        XCTAssertEqual(monitor.state, .connected)
        post(NSWorkspace.didMountNotification, drive)
        XCTAssertEqual(events, ["library opens"], "it opens once")
    }

    func testALibraryFoundOnTheStartupDiskAfterTheLaunchOpensAndIsNotFollowed() async {
        // The launch found no library, then it was found on this Mac's own disk before the
        // monitor started.
        let monitor = makeMonitor(resolution: .unavailable(location), startupDisk: true)
        let policy = makePolicy(following: monitor)
        policy.start()
        monitor.start()
        defer { monitor.stop(); policy.stop() }
        XCTAssertGreaterThan(center.observing, 0, "the drive is awaited until the launch's look")

        await monitor.settle()
        XCTAssertEqual(events, ["library opens"])
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertEqual(center.observing, 0, "nothing is followed on the startup disk")

        post(NSWorkspace.willUnmountNotification, drive)
        post(NSWorkspace.didUnmountNotification, drive)
        XCTAssertEqual(events, ["library opens"], "no volume's notification stops its wallpapers")
        XCTAssertEqual(monitor.state, .idle)
        XCTAssertFalse(monitor.stopsWallpapers)
        XCTAssertNil(status.disconnectedRoot)
    }

    func testAPendingBackupRestoreStillWaitsForAReopen() async throws {
        try unplug()
        let pending = support.appendingPathComponent(WallpaperBackupService.pendingDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let monitor = makeMonitor(resolution: .unavailable(location))
        monitor.start()
        defer { monitor.stop() }
        await monitor.settle()

        try plugIn()
        post(NSWorkspace.didMountNotification, drive)
        XCTAssertTrue(events.isEmpty, "a restore is applied only before anything opens the library")
        XCTAssertEqual(monitor.state, .awaitingDriveAfterLaunch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path), "the restore is kept for the next launch")

        // Nor does a drive already connected when the monitor started open it.
        let late = makeMonitor(resolution: .unavailable(location))
        late.start()
        defer { late.stop() }
        await late.settle()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(late.state, .awaitingDriveAfterLaunch)
    }
}

/// Counts the observers a notification center is given and the ones taken back.
private final class ObserverCountingCenter: NotificationCenter, @unchecked Sendable {
    private(set) var added = 0
    private(set) var removed = 0
    /// The observers added and not removed yet.
    var observing: Int { added - removed }

    override func addObserver(
        forName name: NSNotification.Name?, object: Any?, queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        added += 1
        return super.addObserver(forName: name, object: object, queue: queue, using: block)
    }

    override func removeObserver(_ observer: Any) {
        removed += 1
        super.removeObserver(observer)
    }
}
