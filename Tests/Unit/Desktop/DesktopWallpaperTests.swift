import AppKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import XCTest
@testable import WallpaperMachine

@MainActor
private final class MemoryDesktopWorkspace: DesktopPictureWorkspace {
    var pictures: [DesktopPictureTarget: DesktopPicture] = [:]
    /// Public NSWorkspace results, which may resolve an empty per-Space selection.
    var visiblePictures: [String: DesktopPicture] = [:]
    /// A reload can lag behind the persisted native selection.
    var persistedPictures: Set<URL> = []
    var writes: [DesktopPictureTarget] = []
    /// The picture of each write, in order.
    var written: [URL] = []
    var failures: Set<DesktopPictureTarget> = []
    /// Writes to a desktop in `failures`, each one refused.
    var refused: [DesktopPictureTarget] = []
    /// Listed by `targets()`, but their current picture cannot be read.
    var unreadable: Set<DesktopPictureTarget> = []
    /// Desktops whose writes read back only after `land()`, as WallpaperAgent
    /// applies them asynchronously.
    var lagging: Set<DesktopPictureTarget> = []
    private var inFlight: [DesktopPictureTarget: DesktopPicture] = [:]
    var didWrite: (() throws -> Void)?
    var didEnumerate: (() -> Void)?

    func targets() -> [DesktopPictureTarget] {
        didEnumerate?()
        return Set(pictures.keys).union(unreadable)
            .sorted { ($0.display + ($0.space ?? "")) < ($1.display + ($1.space ?? "")) }
    }
    func currentPicture(target: DesktopPictureTarget) -> DesktopPicture? {
        if target.space == nil, let visible = visiblePictures[target.display] { return visible }
        return unreadable.contains(target) ? nil : pictures[target]
    }
    func setPicture(_ picture: DesktopPicture, target: DesktopPictureTarget) throws {
        // macOS refuses a picture whose file does not exist, as `NSWorkspace` does.
        if picture.url.isFileURL, access(picture.url.path, F_OK) != 0, errno == ENOENT {
            throw CocoaError(.fileNoSuchFile)
        }
        if failures.contains(target) {
            refused.append(target)
            throw CocoaError(.fileWriteNoPermission)
        }
        writes.append(target)
        written.append(picture.url)
        if lagging.contains(target) {
            inFlight[target] = picture
            try didWrite?()
            throw DesktopPictureUnconfirmed()
        }
        pictures[target] = picture
        try didWrite?()
    }
    func land() {
        pictures.merge(inFlight) { $1 }
        inFlight.removeAll()
    }
    func referencedPictureURLs(targets: [DesktopPictureTarget]) -> Set<URL> { persistedPictures }

    /// macOS's wallpaper store, which a per-Space write changes along with the picture.
    var store: Data?
    var storeReplacements = 0
    var storeReloads = 0
    /// Reloads that fail before one succeeds, as when WallpaperAgent is between a restart and its relaunch.
    var failingReloads = 0
    func storeContents() -> Data? { store }
    func replaceStore(_ data: Data, expected: Data) throws {
        guard store == expected else { throw DesktopPictureUnconfirmed() }
        store = data
        storeReplacements += 1
    }
    func reloadStore() throws {
        if failingReloads > 0 {
            failingReloads -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        storeReloads += 1
    }
}

private actor ControlledPosterEncoder {
    private var requests: [Data: CheckedContinuation<Data, Never>] = [:]
    func encode(_ frame: DesktopPosterFrame) async -> Data {
        await withCheckedContinuation { requests[frame.pixels] = $0 }
    }
    func has(_ data: Data) -> Bool { requests[data] != nil }
    func finish(_ data: Data) { requests.removeValue(forKey: data)?.resume(returning: data) }
}

private actor CountingPosterEncoder {
    private(set) var count = 0
    func encode(_ frame: DesktopPosterFrame) -> Data {
        count += 1
        return frame.pixels
    }
}

private actor FailingPosterEncoder {
    private(set) var count = 0
    func encode(_ frame: DesktopPosterFrame) throws -> Data {
        count += 1
        throw CocoaError(.fileWriteUnknown)
    }
}

/// The sync's notion of when a frame arrived, moved by the test and not by waiting.
@MainActor
private final class ManualClock {
    private(set) var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}

final class DesktopWallpaperTests: XCTestCase {
    private var root: URL!
    private let one = DesktopPictureTarget(display: "1", space: "one")
    private let two = DesktopPictureTarget(display: "1", space: "two")
    private let external = DesktopPictureTarget(display: "2", space: "external")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-poster-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    /// A user wallpaper whose file exists; never inside the ledger's own poster folder.
    private func original(_ name: String) -> DesktopPicture {
        let url = root.appendingPathComponent("User Pictures/" + name + ".heic")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data([0]).write(to: url)
        }
        return DesktopPicture(url: url, scaling: Int(NSImageScaling.scaleProportionallyDown.rawValue),
                              allowClipping: true, fill: [0.1, 0.2, 0.3, 1])
    }

    @MainActor
    func testNewWallpaperUpdatesEverySpaceImmediatelyWithoutVisitingThem() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("first"), two: original("second")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        workspace.writes.removeAll()
        // Apply another wallpaper in place: no active-space event exists in this fake.
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        XCTAssertEqual(Set(workspace.writes), [one, two])
        for target in [one, two] {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[target]?.url)), Data([2]))
        }
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("first"))
        XCTAssertEqual(workspace.pictures[two], original("second"))
    }

    @MainActor
    func testMultipleDisplaysKeepTheirOwnRenderedFramesAndDisabledDisplayRestores() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("primary"), two: original("primary"), external: original("external")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1]), "2": Data([2])], liveDisplays: ["1", "2"])
        for target in [one, two] {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[target]?.url)), Data([1]))
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[external]?.url)), Data([2]))
        try ledger.synchronize(posters: ["1": Data([3])], liveDisplays: ["1"])
        XCTAssertEqual(workspace.pictures[external], original("external"))
        XCTAssertNotEqual(workspace.pictures[one], original("primary"))
    }

    @MainActor
    func testFrameURLsAreImmutableAndPrunedOnlyAfterAllSpacesUpdate() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("same"), two: original("same")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        var urls: Set<URL> = []
        for value in UInt8(0)..<20 {
            try ledger.synchronize(posters: ["1": Data([value])], liveDisplays: ["1"])
            urls.insert(try XCTUnwrap(workspace.pictures[one]?.url))
        }
        XCTAssertEqual(urls.count, 20, "Never alternate stale WallpaperAgent cache keys")
        XCTAssertEqual(workspace.pictures[one]?.url, workspace.pictures[two]?.url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == DesktopPosterEncoder.fileExtension }.count, 1)
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("same"))
    }

    @MainActor
    func testIdenticalFramesSkipWritesButNewSpacesStillSynchronize() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertEqual(workspace.writes.count, 1)
        workspace.pictures[two] = original("new-space")
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertEqual(workspace.writes.count, 2)
        XCTAssertEqual(workspace.writes.last, two)
    }

    @MainActor
    func testSharedPosterJournalsOnceAndStillRestoresAfterRelaunch() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("same"), two: original("same")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        let journal = root.appendingPathComponent("originals.json")
        let marker = Date(timeIntervalSince1970: 1_000)
        var writes = 0
        workspace.didWrite = {
            writes += 1
            if writes == 1 {
                try! FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: journal.path)
            }
        }
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.path)[.modificationDate] as? Date, marker)
        workspace.didWrite = nil
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("same"))
        XCTAssertEqual(workspace.pictures[two], original("same"))
    }

    @MainActor
    func testFailedJournalSaveCannotBeSkippedOnRetry() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        let journal = root.appendingPathComponent("originals.json")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"]))
        XCTAssertTrue(workspace.writes.isEmpty)
        try FileManager.default.removeItem(at: journal)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertEqual(Set(workspace.writes), [one, two])
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("before"))
        XCTAssertEqual(workspace.pictures[two], original("before"))
    }

    @MainActor
    func testRelaunchRestoresInactiveSpacesAndNativeConfiguration() throws {
        let workspace = MemoryDesktopWorkspace()
        var before = original("before")
        before.nativeOptions = try PropertyListSerialization.data(fromPropertyList: [
            "ImageFilePath": before.url.path, "DynamicStyle": 2,
            "Placement": "SizeToFit", "Change": "TimeInterval", "ChangeDuration": 900
        ], format: .binary, options: 0)
        workspace.pictures = [one: before, two: before]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], before)
        XCTAssertEqual(workspace.pictures[two], before)
    }

    @MainActor
    func testInheritedNativeSelectionCapturesEffectiveWallpaperBeforeAnyWrite() throws {
        let workspace = MemoryDesktopWorkspace()
        let inherited = try DesktopSpaceWallpaperAPI.decodePicture([:])
        workspace.pictures = [one: inherited, two: inherited, external: inherited]
        workspace.visiblePictures = ["1": original("primary"), "2": original("external")]
        // macOS's fallback changes with the first poster, including defaults
        // that another Space/display might inherit. Capture both beforehand.
        workspace.didWrite = {
            workspace.visiblePictures = ["1": workspace.pictures[self.one]!, "2": workspace.pictures[self.one]!]
        }
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1]), "2": Data([2])], liveDisplays: ["1", "2"])
        XCTAssertTrue(try XCTUnwrap(workspace.pictures[one]).url.isFileURL)
        XCTAssertEqual(workspace.pictures[one], workspace.pictures[two])
        workspace.didWrite = nil
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("primary"))
        XCTAssertEqual(workspace.pictures[two], original("primary"))
        XCTAssertEqual(workspace.pictures[external], original("external"))
    }

    @MainActor
    func testUnresolvedInheritedWallpaperIsNeverReplacedByAPoster() throws {
        let workspace = MemoryDesktopWorkspace()
        let inherited = try DesktopSpaceWallpaperAPI.decodePicture([:])
        workspace.pictures = [one: inherited, two: inherited]
        // An already stranded frame is not an original either.
        workspace.visiblePictures = ["1": .poster(root.appendingPathComponent("old-poster.png"))]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        XCTAssertThrowsError(try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"]))
        XCTAssertTrue(workspace.writes.isEmpty)
        XCTAssertEqual(workspace.pictures[one], inherited)
        XCTAssertEqual(workspace.pictures[two], inherited)
        XCTAssertTrue(try posterNames().isEmpty)

        // Once a real original is available, playback can synchronize again.
        workspace.visiblePictures["1"] = original("chosen-again")
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("chosen-again"))
        XCTAssertEqual(workspace.pictures[two], original("chosen-again"))
    }

    @MainActor
    func testInheritedSpaceGetsTheUsersWallpaperBackInsteadOfAPoster() throws {
        let workspace = MemoryDesktopWorkspace()
        let inherited = try DesktopSpaceWallpaperAPI.decodePicture([:])
        workspace.pictures = [one: original("before"), two: inherited, external: inherited]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1]), "2": Data([2])], liveDisplays: ["1", "2"])
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("before"))
        XCTAssertEqual(workspace.pictures[two], original("before"))
        // A display with no wallpaper of its own gets another display's.
        XCTAssertEqual(workspace.pictures[external], original("before"))
    }

    @MainActor
    func testPostersJournaledAsInheritedOrUnjournaledRestoreTheDisplaysWallpaper() throws {
        let encode = { (picture: DesktopPicture) in
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(picture)) as? [String: Any])
        }
        // Written by a build that journaled pathless originals verbatim.
        try JSONSerialization.data(withJSONObject: [
            "poster-real.png": ["original": try encode(original("before")), "display": "1"],
            "poster-inherited.png": ["original": try encode(DesktopSpaceWallpaperAPI.decodePicture([:])), "display": "1"]
        ]).write(to: root.appendingPathComponent("originals.json"))
        for name in ["poster-real.png", "poster-inherited.png", "poster-orphan.png"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        let three = DesktopPictureTarget(display: "1", space: "three")
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [
            one: .poster(root.appendingPathComponent("poster-real.png")),
            two: .poster(root.appendingPathComponent("poster-inherited.png")),
            three: .poster(root.appendingPathComponent("poster-orphan.png")),
            external: original("user-choice")
        ]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("before"))
        XCTAssertEqual(workspace.pictures[two], original("before"))
        XCTAssertEqual(workspace.pictures[three], original("before"))
        XCTAssertEqual(workspace.pictures[external], original("user-choice"))
        XCTAssertFalse(workspace.writes.contains(external))
    }

    @MainActor
    func testLegacyInheritedJournalIsRepairedEvenWhenFrameHasNotChanged() throws {
        let inherited = try DesktopSpaceWallpaperAPI.decodePicture([:])
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(inherited)) as? [String: Any])
        try JSONSerialization.data(withJSONObject: [
            "old.png": ["original": encoded, "display": "1"]
        ]).write(to: root.appendingPathComponent("originals.json"))
        let old = root.appendingPathComponent("old.png")
        try Data([1]).write(to: old)
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: .poster(old)]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        XCTAssertThrowsError(try ledger.restoreAll(), "An empty original is not a successful restoration")
        XCTAssertTrue(workspace.writes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))

        workspace.visiblePictures["1"] = original("recovered")
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertNotEqual(workspace.pictures[one]?.url, old)
        workspace.visiblePictures = [:]
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try reloaded.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("recovered"))
    }

    @MainActor
    func testEffectiveWallpaperDoesNotReplaceIndependentSpaceOriginals() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        workspace.visiblePictures["1"] = original("visible")
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("one"))
        XCTAssertEqual(workspace.pictures[two], original("two"))
    }

    @MainActor
    func testTerminationWaitsForNativeReloadAndPersistedPosterRestoration() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(image: Data([1]), target: one)
        let poster = try XCTUnwrap(workspace.pictures[one])
        // The native journal has put the PNG back in the store, but the old
        // WallpaperAgent still reports the extension's pathless selection.
        workspace.pictures[one] = try DesktopSpaceWallpaperAPI.decodePicture([:])
        workspace.persistedPictures = [poster.url]
        XCTAssertThrowsError(try ledger.restoreAll())
        XCTAssertTrue(FileManager.default.fileExists(atPath: poster.url.path))

        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [] }, frameCenter: NotificationCenter())
        var reloaded = false
        var persisted = false
        try await sync.restoreForTermination {
            XCTAssertTrue(FileManager.default.fileExists(atPath: poster.url.path),
                          "Do not delete the frame or its original while macOS still references it")
            if !reloaded {
                workspace.pictures[self.one] = poster
                reloaded = true
            } else {
                XCTAssertEqual(workspace.pictures[self.one], self.original("before"))
                workspace.persistedPictures = []
                persisted = true
            }
        }
        XCTAssertTrue(reloaded)
        XCTAssertTrue(persisted)
        XCTAssertEqual(workspace.pictures[one], original("before"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: poster.url.path))
    }

    @MainActor
    func testTerminationReportsPersistentFailureAndRetainsOriginalForRetry() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        let poster = try XCTUnwrap(workspace.pictures[one])
        workspace.failures = [one]
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [] }, frameCenter: NotificationCenter())
        do {
            try await sync.restoreForTermination(wait: {})
            XCTFail("Quit must not succeed while an original could not be restored")
        } catch {
            XCTAssertEqual(workspace.pictures[one], poster)
            XCTAssertTrue(FileManager.default.fileExists(atPath: poster.url.path))
            XCTAssertEqual(workspace.pictures[two], original("two"))
        }
        workspace.failures = []
        try await sync.restoreForTermination(wait: {})
        XCTAssertEqual(workspace.pictures[one], original("one"))
    }

    /// The probe behind the startup repair: a poster is only worth looking for while the journal
    /// still names an original.
    @MainActor
    func testRecordedOriginalsAreReportedUntilTheyAreRestored() throws {
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root), "no journal yet")
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root.appendingPathComponent("absent")))
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root), "a ledger with nothing written leaves no journal")

        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertTrue(DesktopWallpaperLedger.hasRecordedOriginals(in: root))
        try ledger.restoreAll()
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root), "restoring prunes what it put back")

        try Data("not json".utf8).write(to: root.appendingPathComponent("originals.json"))
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root), "a damaged journal names nothing to restore")
    }

    /// Turning writes off: the running sync puts every original back with the quit's verified
    /// restore, and nothing it is told afterwards writes again.
    @MainActor
    func testTurningWritesOffRestoresTheOriginalsAndLaterFramesWriteNothing() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        let center = NotificationCenter(), layer = CAMetalLayer()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: center, encode: { $0.pixels })
        sync.start()
        let installed = expectation(description: "Both desktops show the poster")
        installed.expectedFulfillmentCount = 2
        workspace.didWrite = { installed.fulfill() }
        post(Data([1]), layer: layer, center: center)
        await fulfillment(of: [installed], timeout: 2)
        workspace.didWrite = nil
        XCTAssertNotEqual(workspace.pictures[one], original("one"))

        try await sync.restoreForTermination(wait: {})
        XCTAssertEqual(workspace.pictures[one], original("one"))
        XCTAssertEqual(workspace.pictures[two], original("two"))
        XCTAssertTrue(sync.isSuspended, "a restored sync must not start writing again by itself")
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root))

        let written = workspace.writes.count
        post(Data([2]), layer: layer, center: center)
        sync.refresh()
        sync.presentationResumed()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(workspace.writes.count, written, "no frame after the restore may reach a desktop")
        XCTAssertEqual(workspace.pictures[one], original("one"))
    }

    /// The repair at launch: a poster a crash or an earlier run left behind is found through the
    /// journal and put back by a sync that never started.
    @MainActor
    func testAJournalLeftBehindIsRestoredByAFreshSync() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        let first = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try first.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertNotEqual(workspace.pictures[one], original("one"))
        XCTAssertTrue(DesktopWallpaperLedger.hasRecordedOriginals(in: root))

        // The app is gone; nothing but the journal and the poster files remain.
        let fresh = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                             surfaces: { [] }, frameCenter: NotificationCenter())
        try await fresh.restoreForTermination(wait: {})
        XCTAssertEqual(workspace.pictures[one], original("one"))
        XCTAssertEqual(workspace.pictures[two], original("two"))
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root))
        XCTAssertTrue(try posterNames().isEmpty, "the posters themselves are deleted once nothing shows them")
    }

    /// Another app can delete the picture it had set, as a wallpaper app clearing out its
    /// downloads does. A desktop whose original is gone gets another display's original that
    /// is still there, both when its display stops playing and at quit, instead of a write
    /// that fails on every attempt and so refuses every quit.
    @MainActor
    func testAnOriginalWhoseFileIsGoneGivesWayToAnotherDisplaysOriginal() throws {
        let workspace = MemoryDesktopWorkspace()
        let gone = original("deleted-by-another-app"), kept = original("kept")
        workspace.pictures = [one: gone, two: gone, external: kept]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1]), "2": Data([2])], liveDisplays: ["1", "2"])
        try FileManager.default.removeItem(at: gone.url)

        try ledger.synchronize(posters: ["2": Data([2])], liveDisplays: ["2"])
        XCTAssertEqual(workspace.pictures[one], kept)
        XCTAssertEqual(workspace.pictures[two], kept)
        XCTAssertNotEqual(workspace.pictures[external], kept, "the display still playing keeps its poster")

        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[external], kept)
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root))
    }

    /// When every recorded original is gone, the quit and the launch repair (a fresh sync over
    /// the journal) put back macOS's default picture, written as the file its link points to.
    @MainActor
    func testEveryOriginalGoneGivesWayToTheMacOSDefaultPicture() async throws {
        let workspace = MemoryDesktopWorkspace()
        let gone = original("deleted-by-another-app")
        workspace.pictures = [one: gone, two: gone, external: gone]
        let first = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try first.synchronize(posters: ["1": Data([1]), "2": Data([2])], liveDisplays: ["1", "2"])
        try FileManager.default.removeItem(at: gone.url)
        let system = root.appendingPathComponent("System", isDirectory: true)
        let link = system.appendingPathComponent("DefaultDesktop.heic")
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace, surfaces: { [] },
                                            frameCenter: NotificationCenter(), systemDefaultPicture: link)

        do {
            try await sync.restoreForTermination(wait: {})
            XCTFail("With no picture left at all there is nothing to put back")
        } catch {
            XCTAssertEqual(error as? DesktopWallpaperLedger.Failure, .originalUnavailable)
            XCTAssertTrue(DesktopWallpaperLedger.hasRecordedOriginals(in: root), "the journal stays for a later run")
        }

        let picture = system.appendingPathComponent("Default.heic")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try Data([0]).write(to: picture)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: picture)
        try await sync.restoreForTermination(wait: {})
        for target in [one, two, external] {
            XCTAssertEqual(workspace.pictures[target]?.url, picture.resolvingSymlinksInPath())
        }
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root))
        XCTAssertTrue(try posterNames().isEmpty)
    }

    /// Only a file that is certainly gone gives way. One the app may not look at, as in a
    /// folder macOS's privacy protection covers, is still put back as it was.
    @MainActor
    func testAnOriginalTheAppMayNotLookAtIsStillPutBack() throws {
        let workspace = MemoryDesktopWorkspace()
        let closed = original("closed")
        workspace.pictures = [one: closed, two: closed]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace,
                                                systemDefaultPicture: root.appendingPathComponent("no-default.heic"))
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        let folder = closed.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], closed)
        XCTAssertEqual(workspace.pictures[two], closed)
    }

    @MainActor
    func testUnreachablePosterReferenceDoesNotBlockQuitForever() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(image: Data([1]), target: one)
        let poster = try XCTUnwrap(workspace.pictures[one])
        // The display-wide selection keeps the poster; no Space write reaches it.
        workspace.persistedPictures = [poster.url]
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [] }, frameCenter: NotificationCenter())
        var waits = 0
        try await sync.restoreForTermination { waits += 1 }
        XCTAssertGreaterThan(waits, 0, "A lagging reload is still waited for first")
        XCTAssertEqual(workspace.pictures[one], original("before"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: poster.url.path),
                      "A poster macOS still names must not be deleted")
    }

    /// A store that no longer names the poster does not prove the desktop stopped
    /// showing it: quit waits for the restoration itself to read back.
    @MainActor
    func testQuitWaitsForEveryRestorationToReadBack() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(image: Data([1]), target: one)
        workspace.lagging = [one]
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [] }, frameCenter: NotificationCenter())
        var waits = 0
        try await sync.restoreForTermination {
            waits += 1
            if waits == 3 { workspace.land() }
        }
        XCTAssertEqual(waits, 3)
        XCTAssertEqual(workspace.pictures[one], original("before"))

        // One that never reads back cancels quit even with nothing left in the store.
        workspace.lagging = []
        try DesktopWallpaperLedger(folder: root, workspace: workspace).apply(image: Data([2]), target: one)
        workspace.lagging = [one]
        let next = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [] }, frameCenter: NotificationCenter())
        do {
            try await next.restoreForTermination(wait: {})
            XCTFail("An unconfirmed restoration must not let the app quit")
        } catch {
            XCTAssertEqual(error as? DesktopWallpaperLedger.Failure, .restorationUnconfirmed)
        }
    }

    /// A logout gives restoration a few seconds and then cancels it, so cancelling must stop
    /// it where it is and leave the journal as it was: the poster stays on the desktop until
    /// the app runs again, and the original it replaces is still on record to put back.
    @MainActor
    func testRestoreForTerminationStopsWhenCancelledAndKeepsTheJournal() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(image: Data([1]), target: one)
        let poster = try XCTUnwrap(workspace.pictures[one])
        workspace.lagging = [one]
        let journalURL = root.appendingPathComponent("originals.json")
        func journaledNames() throws -> Set<String> {
            let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
            return Set(try XCTUnwrap(entries).keys)
        }
        XCTAssertEqual(try journaledNames(), [poster.url.lastPathComponent])

        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [] }, frameCenter: NotificationCenter())
        let waiting = expectation(description: "restoration is waiting for the desktop to read back")
        let finished = expectation(description: "restoration returned")
        let restoration = Task { @MainActor () -> String in
            defer { finished.fulfill() }
            do {
                try await sync.restoreForTermination {
                    waiting.fulfill()
                    // Parked here until the task is cancelled, like the 200 ms wait between attempts.
                    try await Task.sleep(for: .seconds(3600))
                }
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "failed: \(error)"
            }
        }
        await fulfillment(of: [waiting], timeout: 30)
        restoration.cancel()
        await fulfillment(of: [finished], timeout: 30)

        let result = await restoration.value
        XCTAssertEqual(result, "cancelled")
        XCTAssertEqual(try journaledNames(), [poster.url.lastPathComponent],
                       "what restoration did not finish stays on record")
        XCTAssertTrue(FileManager.default.fileExists(atPath: poster.url.path),
                      "the poster is not deleted while the desktop may still show it")

        // A later run finishes what the cancelled one left.
        workspace.land()
        workspace.lagging = []
        let next = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [] }, frameCenter: NotificationCenter())
        try await next.restoreForTermination(wait: {})
        XCTAssertEqual(workspace.pictures[one], original("before"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: poster.url.path))
    }

    /// A poster write still in flight can land after quit restored its desktop, so
    /// quit waits out the confirmation window and restores it again.
    @MainActor
    func testQuitWaitsForAPosterWriteStillInFlight() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one")]
        workspace.lagging = [one]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace,
                                                confirmationWindow: .milliseconds(200))
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertThrowsError(try ledger.restoreAll()) {
            XCTAssertEqual($0 as? DesktopWallpaperLedger.Failure, .restorationUnconfirmed)
        }
        workspace.lagging = []
        workspace.land()
        XCTAssertThrowsError(try ledger.restoreAll(), "Restored, but the write is still in its window")
        XCTAssertEqual(workspace.pictures[one], original("one"))
        try await Task.sleep(for: .milliseconds(250))
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("one"))
    }

    /// WallpaperAgent copies a poster after the write. A newer frame or a desktop
    /// that stops receiving posters must not delete a file it may still copy, and a
    /// poster that lands afterwards on a stopped desktop is restored.
    @MainActor
    func testPosterFilesStayUntilTheirWritesSettle() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one")]
        workspace.lagging = [one]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace,
                                                confirmationWindow: .milliseconds(200))
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        try ledger.synchronize(posters: [:], liveDisplays: [])
        let posters = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("poster-") }
        XCTAssertEqual(posters.count, 2, "Both in-flight frames stay on disk")
        XCTAssertTrue(ledger.awaitsConfirmation)

        workspace.land()
        workspace.lagging = []
        try ledger.synchronize(posters: [:], liveDisplays: [])
        XCTAssertEqual(workspace.pictures[one], original("one"))

        try await Task.sleep(for: .milliseconds(250))
        try ledger.synchronize(posters: [:], liveDisplays: [])
        XCTAssertFalse(ledger.awaitsConfirmation)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("poster-") }.isEmpty)
    }

    @MainActor
    func testUserChoiceDuringNativeReloadSurvivesQuit() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(image: Data([1]), target: one)
        workspace.persistedPictures = [try XCTUnwrap(workspace.pictures[one]?.url)]
        workspace.pictures[one] = try DesktopSpaceWallpaperAPI.decodePicture([:])
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [] }, frameCenter: NotificationCenter())
        workspace.writes = []
        try await sync.restoreForTermination {
            workspace.pictures[self.one] = self.original("user-choice")
            workspace.persistedPictures = []
        }
        XCTAssertEqual(workspace.pictures[one], original("user-choice"))
        XCTAssertTrue(workspace.writes.isEmpty)
    }

    private func storeSelection(provider: String, configuration: [String: Any]) throws -> [String: Any] {
        ["Content": ["Choices": [[
            "Provider": provider, "Files": [String](),
            "Configuration": try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)
        ]]]]
    }
    /// `set` is the `LastSet` WallpaperAgent records when it applies a selection.
    private func storeImage(_ url: URL, set: Date? = nil) throws -> [String: Any] {
        var selection = try storeSelection(provider: "com.apple.wallpaper.choice.image",
                                           configuration: ["type": "imageFile", "url": ["relative": url.absoluteString]])
        selection["LastSet"] = set
        return selection
    }
    private func storeData(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
    private func storeRoot(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(data), format: nil) as? [String: Any])
    }

    /// An aerial shown on all Spaces reads as an empty per-Space selection, and the public API
    /// answers with a still stand-in. Writing that still back left an image choice on every
    /// desktop, which macOS showed as a different wallpaper; quitting puts the aerial back.
    @MainActor
    func testWallpaperOnAllSpacesThatThePerSpaceAPICannotWriteIsPutBackOnQuit() async throws {
        let workspace = MemoryDesktopWorkspace()
        let inherited = try DesktopSpaceWallpaperAPI.decodePicture([:])
        workspace.pictures = [one: inherited, two: inherited]
        let still = original("DefaultDesktop")
        workspace.visiblePictures = ["1": still]
        let aerial = try storeSelection(provider: "com.apple.wallpaper.choice.aerials",
                                        configuration: ["assetID": "golden-gate"])
        let idle = try storeSelection(provider: "default", configuration: [:])
        let global: [String: Any] = ["Type": "individual", "Desktop": aerial, "Idle": idle]
        let before: [String: Any] = ["AllSpacesAndDisplays": global, "SystemDefault": global,
                                     "Displays": [String: Any](), "Spaces": [String: Any]()]
        workspace.store = try storeData(before)
        // WallpaperAgent records each per-Space write in its own nodes and copies it into the
        // system default.
        workspace.didWrite = {
            var root = try self.storeRoot(workspace.store)
            var spaces = root["Spaces"] as? [String: Any] ?? [:]
            for target in [self.one, self.two] {
                guard let url = workspace.pictures[target]?.url, url.isFileURL else { continue }
                let node: [String: Any] = ["Type": "individual", "Desktop": try self.storeImage(url, set: Date()), "Idle": idle]
                spaces[target.space!] = ["Default": node, "Displays": ["display-uuid": node]]
                root["SystemDefault"] = node
                root["Displays"] = ["display-uuid": node]
            }
            root["Spaces"] = spaces
            workspace.store = try self.storeData(root)
        }
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        XCTAssertNotEqual(try storeRoot(workspace.store)["SystemDefault"] as? NSDictionary, global as NSDictionary)

        // A relaunch after a crash still has the store as it was before the first poster.
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [] }, frameCenter: NotificationCenter())
        // The retry after a failed reload finds nothing left to change and still reloads.
        workspace.failingReloads = 1
        try await sync.restoreForTermination { }
        let after = try storeRoot(workspace.store)
        XCTAssertEqual(after["AllSpacesAndDisplays"] as? NSDictionary, global as NSDictionary)
        XCTAssertEqual(after["SystemDefault"] as? NSDictionary, global as NSDictionary)
        XCTAssertEqual((after["Spaces"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual((after["Displays"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual(workspace.storeReplacements, 1)
        XCTAssertEqual(workspace.storeReloads, 1)

        // Nothing is left to put back or reload on the next quit.
        workspace.pictures = [one: inherited, two: inherited]
        workspace.didWrite = nil
        let next = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try next.restoreAll()
        XCTAssertEqual(workspace.storeReplacements, 1)
        XCTAssertEqual(workspace.storeReloads, 1)
    }

    /// A poster whose file and journal entry survive from an earlier run is written again
    /// under its old name; the store is still saved before that write.
    @MainActor
    func testStoreIsSavedBeforeAPosterJournaledInAnEarlierRun() throws {
        let workspace = MemoryDesktopWorkspace()
        let inherited = try DesktopSpaceWallpaperAPI.decodePicture([:])
        workspace.pictures = [one: inherited]
        workspace.visiblePictures = ["1": original("DefaultDesktop")]
        let earlier = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try earlier.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        // That run kept no store copy; its desktop was put back but the entry stayed.
        workspace.pictures = [one: inherited]

        let aerial = try storeSelection(provider: "com.apple.wallpaper.choice.aerials",
                                        configuration: ["assetID": "golden-gate"])
        let global: [String: Any] = ["Type": "desktop", "Desktop": aerial]
        workspace.store = try storeData(["AllSpacesAndDisplays": global, "SystemDefault": global,
                                         "Displays": [String: Any](), "Spaces": [String: Any]()])
        let saved = workspace.store
        workspace.didWrite = {
            guard let url = workspace.pictures[self.one]?.url else { return }
            let node: [String: Any] = ["Type": "desktop", "Desktop": try self.storeImage(url, set: Date())]
            workspace.store = try self.storeData(["AllSpacesAndDisplays": node, "SystemDefault": node,
                                                   "Displays": [String: Any](), "Spaces": [String: Any]()])
        }
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        // A crash before quitting leaves the store copy for the launch repair.
        XCTAssertTrue(DesktopWallpaperLedger.hasRecordedOriginals(in: root))
        // A store that cannot be read keeps the copy for a later restoration.
        let written = workspace.store
        workspace.store = nil
        workspace.didWrite = nil
        try ledger.restoreAll()
        XCTAssertTrue(DesktopWallpaperLedger.hasRecordedOriginals(in: root))
        workspace.store = written
        try ledger.restoreAll()
        XCTAssertEqual(try storeRoot(workspace.store) as NSDictionary, try storeRoot(saved) as NSDictionary)
        XCTAssertFalse(DesktopWallpaperLedger.hasRecordedOriginals(in: root))
    }

    /// Only selections the app wrote are put back: a choice made in System Settings while the
    /// app ran stays, even of the picture the app wrote back, and a snapshot that already named
    /// a poster is never written back.
    @MainActor
    func testStoreRestorationKeepsTheUsersChoicesAndNeverPutsBackAPoster() throws {
        let posters = root.appendingPathComponent("posters")
        let written = original("DefaultDesktop").url
        let aerial = try storeSelection(provider: "com.apple.wallpaper.choice.aerials",
                                        configuration: ["assetID": "golden-gate"])
        let idle = try storeSelection(provider: "default", configuration: [:])
        let poster = try storeImage(posters.appendingPathComponent("poster-old.jpg"))
        let original = try storeData([
            "AllSpacesAndDisplays": ["Type": "individual", "Desktop": aerial, "Idle": idle],
            "SystemDefault": ["Type": "individual", "Desktop": poster, "Idle": idle],
            "Displays": [String: Any](), "Spaces": ["kept": ["Displays": [String: Any]()]]])
        let user = try storeImage(self.original("user-choice").url)
        let wroteAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var ourImage = try storeImage(written)
        ourImage["LastSet"] = wroteAt.addingTimeInterval(0.3)
        let ours: [String: Any] = ["Type": "individual", "Desktop": ourImage, "Idle": idle]
        // The user picked the same picture for this display long after the app wrote it.
        var sameFile = try storeImage(written)
        sameFile["LastSet"] = wroteAt.addingTimeInterval(600)
        let usersSameFile: [String: Any] = ["Type": "individual", "Desktop": sameFile, "Idle": idle]
        // A selection of that file with no time shows nothing of who set it.
        let untimed: [String: Any] = ["Type": "individual", "Desktop": try storeImage(written), "Idle": idle]
        let current = try storeData([
            "AllSpacesAndDisplays": ["Type": "individual", "Desktop": aerial, "Idle": idle],
            "SystemDefault": ours,
            "Displays": ["d": ours, "e": usersSameFile, "f": untimed],
            "Spaces": ["kept": ["Displays": [String: Any]()],
                       "user": ["Default": ["Type": "individual", "Desktop": user, "Idle": idle],
                                "Displays": ["d": ours]]]])
        let writes = [DesktopWallpaperStoreRestoration.Write(url: written, at: wroteAt)]
        let restored = try storeRoot(DesktopWallpaperStoreRestoration.restored(
            current: current, original: original, written: writes, posters: posters))
        XCTAssertEqual(restored["SystemDefault"] as? NSDictionary, ours as NSDictionary,
                       "a poster in the snapshot is not an original")
        XCTAssertEqual(restored["Displays"] as? NSDictionary, ["e": usersSameFile, "f": untimed] as NSDictionary)
        let spaces = try XCTUnwrap(restored["Spaces"] as? [String: Any])
        XCTAssertNotNil(spaces["kept"])
        let space = try XCTUnwrap(spaces["user"] as? [String: Any])
        XCTAssertEqual((space["Default"] as? [String: Any])?["Desktop"] as? NSDictionary, user as NSDictionary)
        XCTAssertEqual((space["Displays"] as? [String: Any])?.isEmpty, true)

        XCTAssertNil(try DesktopWallpaperStoreRestoration.restored(
            current: original, original: original, written: writes, posters: posters))
    }

    @MainActor
    func testPersistedWallpaperReferencesIncludeFallbacksButExcludeIdleAndOtherDisplays() throws {
        func selection(_ name: String) throws -> [String: Any] {
            let config: [String: Any] = ["type": "imageFile", "url": ["relative": original(name).url.absoluteString]]
            return ["Content": ["Choices": [[
                "Provider": "com.apple.wallpaper.choice.image",
                "Configuration": try PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
            ]]]]
        }
        let store: [String: Any] = [
            "AllSpacesAndDisplays": ["Type": "linked", "Linked": try selection("linked"),
                                     "Desktop": try selection("inactive-desktop")],
            "SystemDefault": ["Type": "individual", "Desktop": try selection("system"),
                              "Idle": try selection("idle"), "Linked": try selection("inactive-linked")],
            "Displays": ["display-one": ["Desktop": try selection("display")],
                         "disconnected": ["Desktop": try selection("disconnected")]],
            "Spaces": ["space-one": ["Default": ["Desktop": try selection("fallback")],
                                     "Displays": ["display-one": ["Desktop": try selection("space")]]],
                       "deleted-space": ["Default": ["Desktop": try selection("deleted")]]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        XCTAssertEqual(try SystemDesktopPictureWorkspace.referencedPictureURLs(
            in: data, displays: ["display-one"], spaces: ["space-one"]),
            Set(["linked", "system", "display", "fallback", "space"].map { original($0).url }))
        XCTAssertThrowsError(try SystemDesktopPictureWorkspace.referencedPictureURLs(
            in: Data("invalid".utf8), displays: ["display-one"], spaces: []))
    }

    @MainActor
    func testPathlessNativeOptionsArePreservedAndAcknowledgementIsNotFalseSuccess() throws {
        let native: [String: Any] = ["Placement": "Crop", "DynamicStyle": 2]
        let picture = try DesktopSpaceWallpaperAPI.decodePicture(native)
        XCTAssertTrue(NSDictionary(dictionary: try DesktopSpaceWallpaperAPI.configuration(picture)).isEqual(to: native))
        XCTAssertTrue(DesktopSpaceWallpaperAPI.acknowledges([:], expected: [:]))
        XCTAssertFalse(DesktopSpaceWallpaperAPI.acknowledges(["ImageFilePath": "/tmp/poster.png"], expected: [:]))
        XCTAssertFalse(DesktopSpaceWallpaperAPI.acknowledges([:], expected: native))
        XCTAssertFalse(DesktopSpaceWallpaperAPI.acknowledges([:], expected: ["ImageFilePath": "/tmp/poster.png"]))
        XCTAssertTrue(DesktopSpaceWallpaperAPI.acknowledges(["ImageFilePath": "/tmp/poster.png"], expected: ["ImageFilePath": "tmp/poster.png"]))
    }

    @MainActor
    func testUnreadableOriginalReportsFailureWithoutWriting() throws {
        let workspace = MemoryDesktopWorkspace()
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        XCTAssertThrowsError(try ledger.apply(image: Data([1]), target: one))
        XCTAssertTrue(workspace.writes.isEmpty)
    }

    @MainActor
    func testLegacyAlternatingJournalMigratesWithoutLosingOriginals() throws {
        let before = original("before")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        try JSONSerialization.data(withJSONObject: [
            "old-a.png": ["original": encoded, "alternate": "old-b.png"],
            "old-b.png": ["original": encoded, "alternate": "old-a.png"]
        ]).write(to: root.appendingPathComponent("originals.json"))
        try Data([0]).write(to: root.appendingPathComponent("old-a.png"))
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: .poster(root.appendingPathComponent("old-a.png"))]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], before)
    }

    @MainActor
    func testUserWallpaperChangeIsNotOverwrittenOnRestore() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        workspace.pictures[two] = original("user-change")
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[two], original("user-change"))
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[two], original("user-change"))
    }

    @MainActor
    func testFailedSpaceDoesNotBlockOthersOrDeleteItsPreviousPosterAndCanRetry() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        let oldURL = try XCTUnwrap(workspace.pictures[two]?.url)
        workspace.failures = [two]
        XCTAssertThrowsError(try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"]))
        XCTAssertEqual(try Data(contentsOf: oldURL), Data([1]))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([2]))
        workspace.failures = []
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(workspace.pictures[one]?.url, workspace.pictures[two]?.url)
    }

    @MainActor
    func testLoadingRendererKeepsPreviousWallpaperAndFallbackKeepsRecentPosters() throws {
        let workspace = MemoryDesktopWorkspace()
        let target = DesktopPictureTarget(display: "1", space: nil)
        workspace.pictures = [target: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"])
        let old = try XCTUnwrap(workspace.pictures[target])
        try ledger.synchronize(posters: [:], liveDisplays: ["1"])
        XCTAssertEqual(workspace.pictures[target], old)
        try ledger.synchronize(posters: ["1": Data([2])], liveDisplays: ["1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.url.path))
    }

    @MainActor
    func testFallbackDisplayKeepsOnlyItsNewestPosters() throws {
        let workspace = MemoryDesktopWorkspace()
        let target = DesktopPictureTarget(display: "1", space: nil)
        workspace.pictures = [target: original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try synchronizeDistinctPosters(7, ledger: ledger, workspace: workspace, dating: target)
        let posters = try posterNames()
        XCTAssertEqual(posters.count, DesktopWallpaperLedger.retainedPostersPerIncompleteDisplay)
        XCTAssertTrue(posters.contains(try XCTUnwrap(workspace.pictures[target]?.url.lastPathComponent)))
        // The current poster's journal entry survived with its file.
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[target], original("before"))
    }

    @MainActor
    func testUnreadableSpaceStillReportsFailureButBoundsItsDisplaysPosters() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before")]
        workspace.unreadable = [two]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try synchronizeDistinctPosters(7, ledger: ledger, workspace: workspace, dating: one,
                                       expectFailure: true)
        let posters = try posterNames()
        XCTAssertEqual(posters.count, DesktopWallpaperLedger.retainedPostersPerIncompleteDisplay)
        XCTAssertTrue(posters.contains(try XCTUnwrap(workspace.pictures[one]?.url.lastPathComponent)),
                      "a poster a readable Space shows was deleted")
    }

    /// `count` synchronizations of distinct frames. After each one the poster
    /// `dating` now shows is dated one second after the previous, so which
    /// posters are newest does not depend on the file system's timestamp
    /// resolution.
    @MainActor
    private func synchronizeDistinctPosters(_ count: UInt8, ledger: DesktopWallpaperLedger,
                                            workspace: MemoryDesktopWorkspace,
                                            dating: DesktopPictureTarget,
                                            expectFailure: Bool = false) throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        for value in UInt8(0)..<count {
            if expectFailure {
                XCTAssertThrowsError(try ledger.synchronize(posters: ["1": Data([value])], liveDisplays: ["1"]))
            } else {
                try ledger.synchronize(posters: ["1": Data([value])], liveDisplays: ["1"])
            }
            let url = try XCTUnwrap(workspace.pictures[dating]?.url)
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(Double(value))],
                                                  ofItemAtPath: url.path)
        }
    }

    private func posterNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == DesktopPosterEncoder.fileExtension }.map(\.lastPathComponent))
    }

    @MainActor
    func testMissingDisplayAndCorruptJournalNeverWriteWallpaper() throws {
        let workspace = MemoryDesktopWorkspace()
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["missing": Data([1])], liveDisplays: ["missing"])
        try ledger.restoreAll()
        XCTAssertTrue(workspace.writes.isEmpty)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("originals.json"))
        XCTAssertThrowsError(try DesktopWallpaperLedger(folder: root, workspace: workspace))
    }

    @MainActor
    func testTopologyEnumeratesInactiveDesktopSpacesExcludesFullscreenAndSupportsSharedSpaces() {
        let groups: [[String: Any]] = [["Display Identifier": "uuid-a", "Spaces": [
            ["uuid": "one", "type": 0], ["uuid": "two", "type": 0],
            ["uuid": "full", "type": 4], ["uuid": "", "type": 0], ["uuid": "unknown"]
        ]], ["Display Identifier": "uuid-b", "Spaces": [["uuid": "external", "type": 0]]]]
        XCTAssertEqual(Set(DesktopSpaceWallpaperAPI.targets(groups: groups, displays: ["1": "UUID-A", "2": "UUID-B"])), [one, two, external])
        let shared: [[String: Any]] = [["Display Identifier": "Main", "Spaces": [["uuid": "one", "type": 0]]]]
        XCTAssertEqual(Set(DesktopSpaceWallpaperAPI.targets(groups: shared, displays: ["1": "A", "2": "B"])), [one, DesktopPictureTarget(display: "2", space: "one")])
    }

    @MainActor
    func testNativeConfigurationPreservesOriginalOptionsAndNormalizesPaths() throws {
        var before = original("before")
        before.nativeOptions = try PropertyListSerialization.data(fromPropertyList: [
            "ImageFilePath": before.url.path, "Placement": "Centered", "DynamicStyle": 2,
            "ChangePath": root.path, "ChangeDuration": 100, "BackgroundColor": [0.1, 0.2, 0.3]
        ], format: .binary, options: 0)
        let config = try DesktopSpaceWallpaperAPI.configuration(before, absolutePaths: false)
        XCTAssertEqual(config["ImageFilePath"] as? String, String(before.url.path.dropFirst()))
        // macOS 27's sandboxed agent resolves relative paths in its own container.
        let absolute = try DesktopSpaceWallpaperAPI.configuration(before, absolutePaths: true)
        XCTAssertEqual(absolute["ImageFilePath"] as? String, before.url.path)
        XCTAssertEqual(absolute["ChangePath"] as? String, root.path)
        XCTAssertEqual(try DesktopSpaceWallpaperAPI.configuration(
            .poster(URL(fileURLWithPath: "/~/Pictures/poster.jpg")), absolutePaths: true)["ImageFilePath"] as? String,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/poster.jpg").path)
        XCTAssertEqual(config["Placement"] as? String, "Centered")
        XCTAssertEqual(config["DynamicStyle"] as? Int, 2)
        XCTAssertEqual(config["ChangeDuration"] as? Int, 100)
        XCTAssertEqual(try DesktopSpaceWallpaperAPI.configuration(original("legacy-fill"))["Placement"] as? String, "Crop")
        XCTAssertEqual(try DesktopSpaceWallpaperAPI.configuration(.poster(before.url))["Placement"] as? String, "FillScreen")
        XCTAssertEqual(DesktopSpaceWallpaperAPI.imageURL(String(before.url.path.dropFirst())), before.url)
        XCTAssertEqual(DesktopSpaceWallpaperAPI.imageURL(before.url.absoluteString), before.url)
        XCTAssertEqual(DesktopSpaceWallpaperAPI.imageURL("/~/Pictures/test.png"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/test.png"))
    }

    @MainActor
    func testRefreshRequestsFirstFrameSynchronouslyAndCoalescesABurst() async throws {
        let workspace = MemoryDesktopWorkspace()
        let layer = CAMetalLayer() // unattached: never creates a window or renderer
        let center = NotificationCenter()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] }, frameCenter: center)
        var requests = 0
        let observer = center.addObserver(forName: Notification.Name("WallpaperMachine.requestDesktopPoster"), object: layer, queue: nil) { _ in requests += 1 }
        defer { center.removeObserver(observer); sync.stop() }
        sync.start()
        workspace.didEnumerate = { XCTAssertGreaterThan(requests, 0, "Request pixels before native synchronization") }
        sync.refresh()
        XCTAssertEqual(requests, 1, "Apply must request a frame before refresh returns, never behind a timer")

        // Snapshot churn (menu opening, volume changes, display refreshes) must
        // not multiply GPU readbacks: the burst collapses into one trailing fire.
        for _ in 0..<5 { sync.refresh() }
        XCTAssertEqual(requests, 1, "A burst inside the throttle window must not re-read the swapchain")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(requests, 2, "The coalesced refresh must still land so the poster matches final state")
    }

    @MainActor
    func testSpaceChangeAppliesThePosterAtOnceAndCapturesAFreshFrame() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one")]
        let frames = NotificationCenter(), spaces = NotificationCenter()
        let layer = CAMetalLayer()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: frames, workspaceCenter: spaces,
                                            encode: { $0.pixels }, settleDelays: [])
        var requests = 0
        let observer = frames.addObserver(forName: Notification.Name("WallpaperMachine.requestDesktopPoster"),
                                          object: layer, queue: nil) { _ in requests += 1 }
        defer { frames.removeObserver(observer); sync.stop() }
        sync.start()
        let installed = expectation(description: "Poster installed")
        workspace.didWrite = { installed.fulfill() }
        post(Data([1]), layer: layer, center: frames)
        await fulfillment(of: [installed], timeout: 2)

        // A Space the poster is not on yet becomes current. It gets the poster
        // that exists without waiting for pixels, and a fresh frame is asked
        // for because the frame came unasked, so the poster has not settled.
        workspace.pictures[two] = original("two")
        let added = expectation(description: "New Space updated")
        workspace.didWrite = { added.fulfill() }
        spaces.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await fulfillment(of: [added], timeout: 2)
        workspace.didWrite = nil
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([1]))
        XCTAssertEqual(requests, 1)
    }

    /// A rig for the frames the sync asks for: one or two displays, a clock the test moves,
    /// and counters for the requests. With `answers`, each surface answers every request a
    /// moment later with pixels it has not drawn before, as an animated wallpaper does.
    @MainActor
    private final class PosterRig {
        let workspace = MemoryDesktopWorkspace()
        let frames = NotificationCenter(), spaces = NotificationCenter()
        let clock = ManualClock()
        let layers: [CAMetalLayer]
        let sync: DesktopWallpaperSync
        private(set) var requests: [Int] = []
        private var observers: [NSObjectProtocol] = []
        private var drawn: UInt8 = 0

        var total: Int { requests.reduce(0, +) }
        /// Every poster file a desktop was given.
        var posterFiles: Set<URL> { Set(workspace.written.filter { $0.lastPathComponent.hasPrefix("poster-") }) }

        init(root: URL, displays: Int = 1, settleDelays: [Duration] = [], answers: Bool = false,
             scope: @escaping @MainActor (String) -> DesktopPosterScope = { _ in .all },
             periodicInterval: Duration = .seconds(300),
             encode: @escaping @Sendable (DesktopPosterFrame) async throws -> Data = { $0.pixels }) throws {
            let layers = (0..<displays).map { _ in CAMetalLayer() }
            self.layers = layers
            requests = Array(repeating: 0, count: displays)
            let clock = self.clock
            sync = try DesktopWallpaperSync(
                folder: root, workspace: workspace,
                surfaces: { layers.enumerated().map { DesktopPosterSurface(layer: $1, display: String($0 + 1)) } },
                frameCenter: frames, workspaceCenter: spaces, scope: scope, encode: encode,
                settleDelays: settleDelays, periodicInterval: periodicInterval, clock: { clock.now })
            for (index, layer) in layers.enumerated() {
                observers.append(frames.addObserver(forName: DesktopPosterNotification.request,
                                                    object: layer, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.requests[index] += 1
                        guard answers else { return }
                        Task { @MainActor [weak self] in
                            self?.clock.advance(.seconds(1))
                            self?.draw(on: index)
                        }
                    }
                })
            }
            sync.start()
        }

        /// The surface draws a frame it has not drawn before, whether asked or not.
        func draw(on display: Int = 0) {
            drawn &+= 1
            frames.post(name: DesktopPosterNotification.ready, object: layers[display],
                        userInfo: ["pixels": Data([drawn]), "width": 1, "height": 1, "bgra": false, "context": ""])
        }

        func finish() {
            for observer in observers { frames.removeObserver(observer) }
            sync.stop()
        }

        func spaceChanged() { spaces.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil) }
        func woke() { spaces.post(name: NSWorkspace.didWakeNotification, object: nil) }
    }

    @MainActor
    private func postFrame(_ pixels: Data, on rig: PosterRig, display: Int = 0, context: String = "") async throws {
        let written = rig.workspace.writes.count
        post(pixels, layer: rig.layers[display], center: rig.frames, context: context)
        try await waitUntil { rig.workspace.writes.count > written }
    }

    @MainActor
    func testAnAnimatedWallpaperGetsNewPosterFilesOnlyWhenItsLookChanges() async throws {
        // Each frame of an animated wallpaper is a new image file, and macOS keeps a full-size
        // copy of every file a desktop has shown. Hours of Space changes, wakes, resumes,
        // snapshots that change no display and renderers starting again add no file.
        let rig = try PosterRig(root: root, settleDelays: [.milliseconds(20), .milliseconds(50)], answers: true)
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        rig.sync.refresh()
        try await waitUntil { rig.total == 3 && rig.posterFiles.count == 3 }
        let settled = rig.posterFiles

        for _ in 0..<5 {
            rig.clock.advance(.seconds(3600))
            rig.spaceChanged()
            rig.woke()
            rig.sync.presentationResumed()
            rig.sync.refresh(capture: .unsettled)
            rig.draw()
            try await Task.sleep(for: .milliseconds(120))
        }
        // The last coalesced refresh runs within the 500 ms refresh interval.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(rig.total, 3, "nothing was asked for")
        XCTAssertEqual(rig.posterFiles, settled, "no desktop was given a new file")

        // A new or changed wallpaper is taken again as it settles.
        rig.sync.refresh()
        try await waitUntil { rig.total == 6 && rig.posterFiles.count == settled.count + 3 }
    }

    @MainActor
    func testASettledPosterStaysThroughSpaceChangesAndWakesHoweverOld() async throws {
        let rig = try PosterRig(root: root)
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        rig.sync.refresh()
        XCTAssertEqual(rig.total, 1)
        try await postFrame(Data([1]), on: rig)

        // A new Space gets the poster that exists, and an hour on it is not taken again.
        rig.clock.advance(.seconds(3600))
        rig.workspace.pictures[two] = original("two")
        let written = rig.workspace.writes.count
        rig.spaceChanged()
        try await waitUntil { rig.workspace.writes.count > written }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(rig.workspace.pictures[two]?.url)), Data([1]))
        rig.clock.advance(.seconds(3600))
        rig.woke()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(rig.total, 1, "a settled poster shows the wallpaper as well as a new one")
    }

    @MainActor
    func testResumeOfASettledPosterTakesNothingHoweverOld() async throws {
        let rig = try PosterRig(root: root, settleDelays: [.milliseconds(20), .milliseconds(50)])
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        rig.sync.refresh()
        try await waitUntil { rig.total == 3 }   // the request itself and both settle captures
        // The frame that answers the last settle capture arrives after it.
        rig.clock.advance(.seconds(1))
        try await postFrame(Data([1]), on: rig)

        rig.sync.presentationResumed()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.total, 3, "the wallpaper settled a moment ago")

        rig.clock.advance(.seconds(3600))
        rig.sync.presentationResumed()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.total, 3, "an hour later it still shows the same wallpaper")
    }

    @MainActor
    func testAFrameAPausedSurfaceAnswersWithDoesNotSettleThePosterForTheResume() async throws {
        let rig = try PosterRig(root: root, settleDelays: [.milliseconds(20), .milliseconds(50)])
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one"), two: original("two")]
        var presenting = false
        rig.sync.canCapture = { _ in presenting }

        // A Space change asks every surface without a settled poster, paused or not, and a
        // paused one answers with the frame it kept.
        rig.spaceChanged()
        try await waitUntil { rig.total == 1 }
        try await postFrame(Data([1]), on: rig)

        // The display plays again: that frame was no reading of the wallpaper running, so the
        // resume still takes the poster as the wallpaper settles.
        presenting = true
        rig.sync.presentationResumed()
        try await waitUntil { rig.total == 3 }

        // A frame taken while it presents does settle the poster.
        try await postFrame(Data([2]), on: rig)
        rig.sync.presentationResumed()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.total, 3, "a presenting surface's frame settles the poster")
    }

    @MainActor
    func testResumeRetakesAPosterThatWasTakenBeforeSettling() async throws {
        let rig = try PosterRig(root: root, settleDelays: [.milliseconds(20), .milliseconds(50)])
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        rig.sync.refresh()
        try await waitUntil { rig.total == 3 }
        // The wallpaper was covered before its settle captures could land: this frame is
        // the first one, taken in the same instant the wallpaper started.
        try await postFrame(Data([1]), on: rig)

        rig.sync.presentationResumed()
        try await waitUntil { rig.total == 5 }
    }

    @MainActor
    func testSpaceChangesDuringSettlingLeaveTheCapturesToTheSettleSequence() async throws {
        let rig = try PosterRig(root: root, settleDelays: [.milliseconds(150), .milliseconds(300)])
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        rig.sync.refresh()
        try await postFrame(Data([1]), on: rig)

        // The frame came before the wallpaper settled, but the settle captures still to come
        // take it again, so neither a Space change nor a snapshot asks for another.
        rig.spaceChanged()
        rig.sync.refresh(capture: .unsettled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.total, 1)
        try await waitUntil { rig.total == 3 }
    }

    @MainActor
    func testSpaceScopedPostersAreNeverKept() async throws {
        let rig = try PosterRig(root: root, scope: { _ in .desktop(id: "one", context: "visit-a") })
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one"), two: original("two")]
        try await postFrame(Data([1]), on: rig, context: "visit-a")

        rig.spaceChanged()
        try await waitUntil { rig.total == 1 }
    }

    @MainActor
    func testPeriodicCapturesRetakeASettledPoster() async throws {
        let rig = try PosterRig(root: root, periodicInterval: .milliseconds(30))
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        rig.sync.refresh()
        try await postFrame(Data([1]), on: rig)
        let before = rig.total
        rig.sync.refreshesPeriodically = true
        try await waitUntil { rig.total >= before + 2 }
    }

    @MainActor
    func testDisplaysAreJudgedOnTheirOwn() async throws {
        let rig = try PosterRig(root: root, displays: 2, settleDelays: [.milliseconds(20)])
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one"), external: original("external")]
        rig.sync.refresh()
        try await waitUntil { rig.total == 4 }
        // Display 1 answers in the instant its wallpaper started, display 2 once it settled.
        try await postFrame(Data([1]), on: rig, display: 0)
        rig.clock.advance(.seconds(1))
        try await postFrame(Data([2]), on: rig, display: 1)

        rig.spaceChanged()
        try await waitUntil { rig.total == 5 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.requests, [3, 2])
    }

    @MainActor
    func testADisplayWithoutAFrameYetIsAskedAndTheOtherKeepsItsPoster() async throws {
        let rig = try PosterRig(root: root, displays: 2)
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one"), external: original("external")]
        rig.sync.refresh()
        XCTAssertEqual(rig.requests, [1, 1])
        try await postFrame(Data([1]), on: rig, display: 0)

        rig.spaceChanged()
        try await waitUntil { rig.total == 3 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.requests, [1, 2], "the display that never answered is asked, the other keeps its poster")
    }

    @MainActor
    func testAFrameNobodyAskedForNeverReplacesASettledPoster() async throws {
        let rig = try PosterRig(root: root, settleDelays: [.milliseconds(20)])
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        rig.sync.refresh()
        try await waitUntil { rig.total == 2 }
        rig.clock.advance(.seconds(1))
        try await postFrame(Data([1]), on: rig)

        // The renderer starts again on the same wallpaper, as after display sleep, and sends
        // its first frame, the start of an intro, unasked.
        let written = rig.workspace.writes.count
        post(Data([0]), layer: rig.layers[0], center: rig.frames)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(rig.workspace.writes.count, written)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(rig.workspace.pictures[one]?.url)), Data([1]))
        XCTAssertEqual(rig.total, 2, "and nothing is asked again")
    }

    @MainActor
    func testAFrameNobodyAskedForOnANewSurfaceSettlesLikeANewWallpaper() async throws {
        let rig = try PosterRig(root: root, settleDelays: [.milliseconds(20), .milliseconds(50)])
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        // A window that just opened draws its first frame before anything asks for one.
        try await postFrame(Data([1]), on: rig)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(rig.workspace.pictures[one]?.url)), Data([1]))
        try await waitUntil { rig.total == 2 }
    }

    @MainActor
    func testAFrameDroppedForItsContextStillAnswersTheRequest() async throws {
        let rig = try PosterRig(root: root, periodicInterval: .milliseconds(30))
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        rig.sync.refresh()
        rig.clock.advance(.seconds(1))
        try await postFrame(Data([1]), on: rig)

        // A periodic capture asks again, and the renderer answers the piled-up requests with
        // one frame that carries a switch hold's context: it is dropped, but it answered.
        rig.sync.refreshesPeriodically = true
        try await waitUntil { rig.total >= 2 }
        rig.sync.refreshesPeriodically = false
        post(Data([2]), layer: rig.layers[0], center: rig.frames, context: "switch-hold:A")

        // So the intro frame a restarted renderer sends next is still one nobody asked for.
        let written = rig.workspace.writes.count
        post(Data([0]), layer: rig.layers[0], center: rig.frames)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(rig.workspace.writes.count, written)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(rig.workspace.pictures[one]?.url)), Data([1]))
    }

    @MainActor
    func testASnapshotRetakesEveryPosterOnlyWhenItChangesTheLayout() async throws {
        let rig = try PosterRig(root: root)
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one")]
        // The first snapshot a sync sees takes every poster.
        rig.sync.snapshotApplied(posterLayout(wallpaper: "a"))
        XCTAssertEqual(rig.total, 1)
        try await postFrame(Data([1]), on: rig)

        // Playback, audio or quality changed: the settled poster stays.
        rig.sync.snapshotApplied(posterLayout(wallpaper: "a", fps: 60))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(rig.total, 1)

        // The display shows another wallpaper.
        rig.sync.snapshotApplied(posterLayout(wallpaper: "b"))
        try await waitUntil { rig.total == 2 }
    }

    func testThePosterLayoutFollowsWhatTheDisplaysShowAndNothingElse() {
        let base = posterLayout(wallpaper: "a")
        XCTAssertEqual(posterLayout(wallpaper: "a", fps: 60, volume: 0.2, muted: true, title: "Another title"), base,
                       "frame rates, volume, mute and titles change no picture")
        let changed: [(String, DesktopPosterLayout)] = [
            ("wallpaper", posterLayout(wallpaper: "b")),
            ("mirror target", posterLayout(wallpaper: "a", mirrorTarget: "2")),
            ("scaling", posterLayout(wallpaper: "a", scaling: .match)),
            ("scaling factor", posterLayout(wallpaper: "a", scalingFactor: 1.5)),
            ("enabled", posterLayout(wallpaper: "a", enabled: false)),
            ("mode", posterLayout(wallpaper: "a", mode: .mirror)),
            ("screen size", posterLayout(wallpaper: "a", screen: CGRect(x: 0, y: 0, width: 2560, height: 1440))),
            ("screen scale", posterLayout(wallpaper: "a", scale: 1)),
            ("files", posterLayout(wallpaper: "a", contentRevision: 1)),
        ]
        for (name, layout) in changed { XCTAssertNotEqual(layout, base, name) }
    }

    private func posterLayout(wallpaper: String, mirrorTarget: String? = nil, scaling: BridgeScalingMode = .fill,
                              scalingFactor: Double = 1, enabled: Bool = true, mode: BridgeDisplayMode = .standalone,
                              fps: UInt32 = 30, volume: Float = 1, muted: Bool = false, title: String = "Built-in",
                              screen: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982), scale: CGFloat = 2,
                              contentRevision: UInt64 = 0) -> DesktopPosterLayout {
        DesktopPosterLayout(
            monitors: [BridgeMonitorInfoRow(
                displayId: "1", title: title, wallpaperId: wallpaper, wallpaperTitle: wallpaper.uppercased(),
                mirrorTargetDisplayId: mirrorTarget, mirrorTargetTitle: nil,
                scalingMode: scaling == .fill ? "fill" : "match", targetFps: String(fps), audioResponse: false)],
            displays: [BridgeDisplaySettingsRow(
                displayId: "1", title: title, enabled: enabled, mode: mode, mirrorTargets: [],
                selectedMirrorTarget: mirrorTarget, scalingMode: scaling, scalingFactor: scalingFactor,
                targetFps: fps, maxFps: 120, muted: muted, volume: volume)],
            screens: [.init(frame: screen, scale: scale)], contentRevision: contentRevision)
    }

    @MainActor
    func testADisplayDrawingAnUnsavedLookKeepsItsPosterUntilItDrawsTheSavedLookAgain() async throws {
        let rig = try PosterRig(root: root, displays: 2, settleDelays: [.milliseconds(20)])
        defer { rig.finish() }
        rig.workspace.pictures = [one: original("one"), external: original("external")]
        rig.sync.refresh()
        try await waitUntil { rig.total == 4 }
        try await postFrame(Data([1]), on: rig, display: 0)
        try await postFrame(Data([2]), on: rig, display: 1)
        let asked = rig.requests

        // Display 1 draws an edit nobody saved. A new wallpaper elsewhere, its settle capture and
        // a Space change ask display 2 and leave display 1 alone.
        var unsaved = true
        rig.sync.showsUnsavedLook = { unsaved && $0.display == "1" }
        rig.sync.refresh()
        try await waitUntil { rig.requests[1] == asked[1] + 2 }
        rig.spaceChanged()
        try await waitUntil { rig.requests[1] == asked[1] + 3 }
        XCTAssertEqual(rig.requests[0], asked[0], "no capture reads an edit nobody saved")

        // A frame that was already on its way is dropped when it arrives.
        let written = rig.workspace.writes.count
        post(Data([9]), layer: rig.layers[0], center: rig.frames)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.workspace.writes.count, written)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(rig.workspace.pictures[one]?.url)), Data([1]), "the saved look stays")

        // The owner asks again once the display draws the saved look: the poster is retaken.
        unsaved = false
        rig.sync.refresh()
        try await waitUntil { rig.requests[0] > asked[0] }
        try await postFrame(Data([3]), on: rig, display: 0)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(rig.workspace.pictures[one]?.url)), Data([3]))
    }

    @MainActor
    func testFrameThatCouldNotBeEncodedDoesNotSettleThePoster() async throws {
        let encoder = FailingPosterEncoder()
        let rig = try PosterRig(root: root, encode: { try await encoder.encode($0) })
        defer { rig.finish() }
        rig.sync.refresh()
        post(Data([1]), layer: rig.layers[0], center: rig.frames)
        for _ in 0..<300 {
            if await encoder.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let attempts = await encoder.count
        XCTAssertEqual(attempts, 1)
        for _ in 0..<50 { await Task.yield() }

        rig.spaceChanged()
        try await waitUntil { rig.total == 2 }
    }

    @MainActor
    func testWallpaperIsCapturedAgainAsItSettlesAndAfterItResumes() async throws {
        let workspace = MemoryDesktopWorkspace()
        let layer = CAMetalLayer(), center = NotificationCenter()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: center,
                                            settleDelays: [.milliseconds(40), .milliseconds(100)])
        var requests = 0
        let observer = center.addObserver(forName: Notification.Name("WallpaperMachine.requestDesktopPoster"),
                                          object: layer, queue: nil) { _ in requests += 1 }
        defer { center.removeObserver(observer); sync.stop() }
        sync.start()
        sync.refresh()
        XCTAssertEqual(requests, 1)
        // An intro or a fading setting shows only after the first frame.
        try await waitUntil { requests == 3 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(requests, 3, "settling ends after its last capture")

        sync.presentationResumed()
        XCTAssertEqual(requests, 3, "a resumed wallpaper has not moved yet")
        try await waitUntil { requests == 5 }
    }

    @MainActor
    func testLaterCapturesSkipDisplaysThatAreNotPresenting() async throws {
        let workspace = MemoryDesktopWorkspace()
        let shown = CAMetalLayer(), covered = CAMetalLayer(), center = NotificationCenter()
        let sync = try DesktopWallpaperSync(
            folder: root, workspace: workspace,
            surfaces: { [DesktopPosterSurface(layer: shown, display: "1"), DesktopPosterSurface(layer: covered, display: "2")] },
            frameCenter: center, settleDelays: [.milliseconds(30)], periodicInterval: .milliseconds(30))
        sync.canCapture = { $0.display == "1" }
        var requests: [ObjectIdentifier: Int] = [:]
        let observer = center.addObserver(forName: Notification.Name("WallpaperMachine.requestDesktopPoster"),
                                          object: nil, queue: nil) { note in
            guard let layer = note.object as? CALayer else { return }
            requests[ObjectIdentifier(layer), default: 0] += 1
        }
        defer { center.removeObserver(observer); sync.stop() }
        sync.refreshesPeriodically = true
        sync.start()
        sync.refresh()
        // A new wallpaper needs a poster wherever it is shown, presenting or not.
        XCTAssertEqual(requests[ObjectIdentifier(covered)], 1)
        try await waitUntil { requests[ObjectIdentifier(shown), default: 0] >= 3 }
        XCTAssertEqual(requests[ObjectIdentifier(covered)], 1, "a suspended wallpaper would draw the same frame again")
    }

    @MainActor
    func testPeriodicCapturesRunOnlyWhileEnabled() async throws {
        let workspace = MemoryDesktopWorkspace()
        let layer = CAMetalLayer(), center = NotificationCenter()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: center, settleDelays: [], periodicInterval: .milliseconds(30))
        var requests = 0
        let observer = center.addObserver(forName: Notification.Name("WallpaperMachine.requestDesktopPoster"),
                                          object: layer, queue: nil) { _ in requests += 1 }
        defer { center.removeObserver(observer); sync.stop() }
        sync.start()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(requests, 0)
        sync.refreshesPeriodically = true
        try await waitUntil { requests >= 2 }
        sync.refreshesPeriodically = false
        let stopped = requests
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(requests, stopped)
    }

    @MainActor
    func testFrameIdenticalToThePosterIsNeitherEncodedNorWrittenAgain() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one")]
        let layer = CAMetalLayer(), center = NotificationCenter()
        let encoder = CountingPosterEncoder()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: center, encode: { await encoder.encode($0) })
        sync.start()
        defer { sync.stop() }
        let first = expectation(description: "Poster installed")
        workspace.didWrite = { first.fulfill() }
        post(Data([1]), layer: layer, center: center)
        await fulfillment(of: [first], timeout: 2)

        // A paused or still wallpaper answers a later capture with the same pixels.
        workspace.didWrite = nil
        post(Data([1]), layer: layer, center: center)
        try await Task.sleep(for: .milliseconds(200))
        let unchanged = await encoder.count
        XCTAssertEqual(unchanged, 1)
        XCTAssertEqual(workspace.writes, [one])

        let changed = expectation(description: "Changed poster installed")
        workspace.didWrite = { changed.fulfill() }
        post(Data([2]), layer: layer, center: center)
        await fulfillment(of: [changed], timeout: 2)
        workspace.didWrite = nil
        let encoded = await encoder.count
        XCTAssertEqual(encoded, 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([2]))
    }

    @MainActor
    func testIdenticalPixelsCanMoveToANewSpaceAfterItsFreshContextIsConfirmed() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        let layer = CAMetalLayer(), center = NotificationCenter(), encoder = CountingPosterEncoder()
        var scope = DesktopPosterScope.desktop(id: "one", context: "visit-a")
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
            surfaces: { [.init(layer: layer, display: "1")] }, frameCenter: center, scope: { _ in scope },
            encode: { await encoder.encode($0) }, settleDelays: [])
        sync.start(); defer { sync.stop() }
        post(Data([7]), layer: layer, center: center, context: "visit-a")
        try await waitUntil { workspace.writes == [self.one] }
        scope = .desktop(id: "two", context: "visit-b")
        sync.refresh(capture: .none)
        XCTAssertEqual(workspace.pictures[two], original("two"), "cached pixels need a response for the new visit")
        post(Data([7]), layer: layer, center: center, context: "visit-b")
        try await waitUntil { workspace.writes.contains(self.two) }
        let encoded = await encoder.count
        XCTAssertEqual(encoded, 1, "the accepted new context can reuse identical encoded pixels")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([7]))
    }

    @MainActor
    func testSettlingAndPeriodicCapturesUseTheCurrentSpaceContextAndHonorHold() async throws {
        for periodic in [false, true] {
            let workspace = MemoryDesktopWorkspace(), center = NotificationCenter(), layer = CAMetalLayer()
            var scope = DesktopPosterScope.hold
            let sync = try DesktopWallpaperSync(folder: root.appendingPathComponent(periodic ? "periodic" : "settling"),
                workspace: workspace, surfaces: { [.init(layer: layer, display: "1")] }, frameCenter: center,
                scope: { _ in scope }, settleDelays: periodic ? [] : [.milliseconds(40)], periodicInterval: .milliseconds(40))
            var contexts: [String] = []
            let observer = center.addObserver(forName: DesktopPosterNotification.request, object: layer, queue: .main) { note in
                contexts.append(note.userInfo?["context"] as? String ?? "missing")
            }
            sync.start()
            if periodic { sync.refreshesPeriodically = true } else { sync.presentationResumed() }
            scope = .desktop(id: "two", context: "visit-b")
            try await waitUntil { !contexts.isEmpty }
            XCTAssertTrue(contexts.allSatisfy { $0 == "visit-b" })
            scope = .hold
            if !periodic { sync.presentationResumed() }
            let count = contexts.count
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(contexts.count, count)
            center.removeObserver(observer)
            sync.stop()
        }
    }

    @MainActor
    func testFirstReadyFrameUpdatesAllSpacesWithoutRefreshEvent() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        let center = NotificationCenter(), layer = CAMetalLayer()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] }, frameCenter: center,
                                            encode: { $0.pixels })
        sync.start()
        defer { sync.stop() }
        let updated = expectation(description: "Both desktops updated")
        updated.expectedFulfillmentCount = 2
        workspace.didWrite = { updated.fulfill() }
        post(Data([1]), layer: layer, center: center)
        await fulfillment(of: [updated], timeout: 2)
        workspace.didWrite = nil
        XCTAssertEqual(Set(workspace.writes), [one, two])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([1]))
    }

    /// While one wallpaper window replaces another, a display lists both for a moment. The one
    /// without a poster yet must not take away the other's, and the newer poster then wins.
    @MainActor
    func testTwoWindowsOnADisplayInstallTheNewerPosterAndNeverNone() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one")]
        let center = NotificationCenter(), outgoing = CAMetalLayer(), incoming = CAMetalLayer()
        // The window that has no poster yet is listed last, as the window order may have it.
        let sync = try DesktopWallpaperSync(
            folder: root, workspace: workspace,
            surfaces: {
                [DesktopPosterSurface(layer: outgoing, display: "1"), DesktopPosterSurface(layer: incoming, display: "1")]
            }, frameCenter: center, encode: { $0.pixels })
        sync.start()
        defer { sync.stop() }
        let first = expectation(description: "The ready poster is installed")
        workspace.didWrite = { first.fulfill() }
        post(Data([1]), layer: outgoing, center: center)
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([1]))
        let second = expectation(description: "The newer poster replaces it")
        workspace.didWrite = { second.fulfill() }
        post(Data([2]), layer: incoming, center: center)
        await fulfillment(of: [second], timeout: 2)
        workspace.didWrite = nil
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([2]))
    }

    /// Two windows on a display both answer a poster request; the newer frame wins even when the
    /// older one takes longer to encode.
    @MainActor
    func testTheNewerFrameWinsWhateverOrderTheEncodesFinishIn() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one")]
        let center = NotificationCenter(), outgoing = CAMetalLayer(), incoming = CAMetalLayer()
        let encoder = ControlledPosterEncoder()
        let sync = try DesktopWallpaperSync(
            folder: root, workspace: workspace,
            surfaces: {
                [DesktopPosterSurface(layer: outgoing, display: "1"), DesktopPosterSurface(layer: incoming, display: "1")]
            }, frameCenter: center, encode: { await encoder.encode($0) })
        sync.start()
        defer { sync.stop() }
        let old = Data([1]), new = Data([2])
        post(old, layer: outgoing, center: center)
        try await waitFor(encoder, data: old)
        post(new, layer: incoming, center: center)
        try await waitFor(encoder, data: new)
        let installed = expectation(description: "The newer poster is installed")
        workspace.didWrite = { installed.fulfill() }
        await encoder.finish(new)
        await fulfillment(of: [installed], timeout: 2)
        workspace.didWrite = nil
        await encoder.finish(old)
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), new)
    }

    @MainActor
    func testDelayedOldLayerFrameCannotOverwriteNewWallpaper() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        let center = NotificationCenter(), oldLayer = CAMetalLayer(), newLayer = CAMetalLayer()
        var surfaces = [DesktopPosterSurface(layer: oldLayer, display: "1")]
        let encoder = ControlledPosterEncoder()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace, surfaces: { surfaces }, frameCenter: center,
                                            encode: { await encoder.encode($0) })
        sync.start()
        defer { sync.stop() }
        let old = Data([1]), new = Data([2])
        post(old, layer: oldLayer, center: center)
        try await waitFor(encoder, data: old)
        surfaces = [DesktopPosterSurface(layer: newLayer, display: "1")]
        sync.refresh()
        post(new, layer: newLayer, center: center)
        try await waitFor(encoder, data: new)
        let updated = expectation(description: "New frame updates both Spaces")
        updated.expectedFulfillmentCount = 2
        workspace.didWrite = { updated.fulfill() }
        await encoder.finish(new)
        await fulfillment(of: [updated], timeout: 2)
        workspace.didWrite = nil
        await encoder.finish(old)
        // Let the old encoding continuation run; it must fail its layer guard.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(workspace.writes.count, 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), new)
    }

    @MainActor
    func testNativeTransientFailureRetriesWithoutSpaceChange() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("before"), two: original("before")]
        workspace.failures = [two]
        let center = NotificationCenter(), layer = CAMetalLayer()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] }, frameCenter: center,
                                            encode: { $0.pixels })
        sync.start()
        defer { sync.stop() }
        let first = expectation(description: "First Space updated")
        workspace.didWrite = { first.fulfill() }
        post(Data([1]), layer: layer, center: center)
        await fulfillment(of: [first], timeout: 2)
        let retry = expectation(description: "Failed Space retried")
        workspace.didWrite = { retry.fulfill() }
        workspace.failures = []
        await fulfillment(of: [retry], timeout: 2)
        workspace.didWrite = nil
        XCTAssertEqual(Set(workspace.writes), [one, two])
    }

    /// Issue #30: two desktops macOS never accepted a poster on were rewritten, and the refusal
    /// logged, on every snapshot for hours. After its retries such a desktop is left alone until
    /// a Space change or wake, while its siblings keep getting every new frame.
    @MainActor
    func testDesktopThatKeepsRefusingPostersWaitsForTheNextSpaceChange() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        workspace.failures = [two]
        let frames = NotificationCenter(), spaces = NotificationCenter(), layer = CAMetalLayer()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: frames, workspaceCenter: spaces,
                                            encode: { $0.pixels })
        sync.start()
        defer { sync.stop() }
        post(Data([1]), layer: layer, center: frames)
        try await waitUntil { workspace.refused.count == DesktopWallpaperLedger.refusalsBeforePause }
        // Past the last retry's delay, nothing tries the refusing desktop again.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(workspace.refused.count, DesktopWallpaperLedger.refusalsBeforePause)

        // New frames, as a playing video produces, still reach the desktop that accepts them.
        for pixel in [UInt8(2), 3] {
            let updated = expectation(description: "Accepting desktop updated")
            workspace.didWrite = { updated.fulfill() }
            post(Data([pixel]), layer: layer, center: frames)
            await fulfillment(of: [updated], timeout: 2)
            workspace.didWrite = nil
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(workspace.refused.count, DesktopWallpaperLedger.refusalsBeforePause)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([3]))

        // A Space change tries it again, and it takes the current poster once macOS accepts it.
        workspace.failures = []
        let retried = expectation(description: "Refusing desktop retried")
        workspace.didWrite = { if workspace.writes.last == self.two { retried.fulfill() } }
        spaces.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await fulfillment(of: [retried], timeout: 2)
        workspace.didWrite = nil
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([3]))
    }

    /// macOS 27 applies a per-Space write about 0.3 s after the call, so its readback
    /// cannot confirm it at once. Every such write was counted as refused, logged, and
    /// after a few snapshots left alone although macOS had accepted it.
    @MainActor
    func testPosterThatReadsBackLateIsConfirmedWithoutCountingARefusal() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one")]
        workspace.lagging = [one]
        let frames = NotificationCenter(), layer = CAMetalLayer()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: frames, encode: { $0.pixels },
                                            confirmationDelay: .milliseconds(150))
        sync.start()
        defer { sync.stop() }
        post(Data([1]), layer: layer, center: frames)
        try await waitUntil { workspace.writes.count == 1 }
        workspace.land()
        // Past the confirmation pass and the quick retries: the write is not repeated.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(workspace.writes, [one])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([1]))

        // A later frame is written at once; the desktop was never paused.
        workspace.lagging = []
        let updated = expectation(description: "Next poster written")
        workspace.didWrite = { updated.fulfill() }
        post(Data([2]), layer: layer, center: frames)
        await fulfillment(of: [updated], timeout: 2)
        workspace.didWrite = nil
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([2]))
    }

    /// A write that never reads back is still a refusal, counted once per confirmation
    /// window, so a desktop macOS ignores is paused rather than rewritten forever.
    @MainActor
    func testPosterThatNeverReadsBackIsPausedAfterItsConfirmations() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one")]
        workspace.lagging = [one]
        let frames = NotificationCenter(), layer = CAMetalLayer()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: frames, encode: { $0.pixels },
                                            confirmationDelay: .milliseconds(50))
        sync.start()
        defer { sync.stop() }
        post(Data([1]), layer: layer, center: frames)
        try await waitUntil { workspace.writes.count == DesktopWallpaperLedger.refusalsBeforePause }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(workspace.writes.count, DesktopWallpaperLedger.refusalsBeforePause)
        XCTAssertEqual(workspace.pictures[one], original("one"))
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func testNativeHandoffPreservesPosterAndJournalWithoutLegacyRestore() async throws {
        let workspace = MemoryDesktopWorkspace()
        let before = original("before")
        workspace.pictures = [one: before]
        let center = NotificationCenter(), layer = CAMetalLayer()
        let encoder = ControlledPosterEncoder()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
                                            surfaces: { [DesktopPosterSurface(layer: layer, display: "1")] },
                                            frameCenter: center, encode: { await encoder.encode($0) })
        sync.start()
        let first = Data([1]), delayed = Data([2])
        post(first, layer: layer, center: center)
        try await waitFor(encoder, data: first)
        let updated = expectation(description: "Poster installed")
        workspace.didWrite = { updated.fulfill() }
        await encoder.finish(first)
        await fulfillment(of: [updated], timeout: 2)
        workspace.didWrite = nil
        let poster = try XCTUnwrap(workspace.pictures[one])
        post(delayed, layer: layer, center: center)
        try await waitFor(encoder, data: delayed)
        // Handoff must not restore through the legacy API, delete the poster,
        // or forget its original while the native provider owns the desktop.
        workspace.failures = [one]
        sync.suspendForNativeProvider()
        await encoder.finish(delayed)
        for _ in 0..<20 { await Task.yield() }
        sync.refresh()
        XCTAssertEqual(workspace.writes, [one])
        XCTAssertEqual(workspace.pictures[one], poster)
        XCTAssertEqual(try Data(contentsOf: poster.url), first)
        workspace.failures = []
        let recovered = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try recovered.restoreAll()
        XCTAssertEqual(workspace.pictures[one], before)
    }

    @MainActor
    private func post(_ pixels: Data, layer: CAMetalLayer, center: NotificationCenter, context: String = "") {
        center.post(name: Notification.Name("WallpaperMachine.desktopPosterReady"), object: layer,
                    userInfo: ["pixels": pixels, "width": 1, "height": 1, "bgra": false, "context": context])
    }

    @MainActor
    func testSpaceRestrictionNeverWritesAnotherDesktopOrThePublicFallback() throws {
        let workspace = MemoryDesktopWorkspace()
        let fallback = DesktopPictureTarget(display: "1", space: nil)
        workspace.pictures = [one: original("one"), two: original("two"), fallback: original("visible")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1"], targetSpaces: ["1": ["one"]])
        XCTAssertEqual(workspace.writes, [one])
        XCTAssertEqual(workspace.pictures[two], original("two"))
        XCTAssertEqual(workspace.pictures[fallback], original("visible"))
        let saved = workspace.pictures[one]
        workspace.writes.removeAll()
        try ledger.synchronize(posters: [:], liveDisplays: [], targetSpaces: ["1": []])
        XCTAssertTrue(workspace.writes.isEmpty)
        XCTAssertEqual(workspace.pictures[one], saved)
        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("one"))
    }

    @MainActor
    func testOtherDesktopsOfASpaceDisplayGetTheirOwnPosterAndAreRestoredAtQuit() throws {
        let workspace = MemoryDesktopWorkspace()
        let three = DesktopPictureTarget(display: "1", space: "three")
        workspace.pictures = [one: original("one"), two: original("two"), three: original("three"),
                              external: original("external")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)

        try ledger.synchronize(posters: ["1": Data([1])], liveDisplays: ["1", "2"], targetSpaces: ["1": ["one"]],
                               spacePosters: ["1": ["two": Data([2])], "2": ["external": Data([9])]])

        XCTAssertEqual(Set(workspace.writes), [one, two])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([2]))
        XCTAssertEqual(workspace.pictures[three], original("three"), "a desktop without a poster of its own is left alone")
        XCTAssertEqual(workspace.pictures[external], original("external"),
                       "a display that does not follow Spaces takes nothing scoped")

        workspace.writes.removeAll()
        try ledger.synchronize(posters: [:], liveDisplays: ["1"], targetSpaces: ["1": []],
                               spacePosters: ["1": ["two": Data([3])]])
        XCTAssertEqual(workspace.writes, [two], "a held current desktop keeps its poster while the others still update")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([3]))

        workspace.writes.removeAll()
        try ledger.synchronize(posters: [:], liveDisplays: ["1"], targetSpaces: ["1": ["one"]],
                               spacePosters: ["1": ["one": Data([4])]])
        XCTAssertEqual(workspace.writes, [one], "the current desktop has its saved picture until a fresh one is taken")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([4]))

        try ledger.restoreAll()
        XCTAssertEqual(workspace.pictures[one], original("one"))
        XCTAssertEqual(workspace.pictures[two], original("two"))
    }

    @MainActor
    func testAScopedPosterIsReportedAndOtherDesktopsAreWrittenFromTheirOwn() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        let layer = CAMetalLayer(), center = NotificationCenter(), encoder = CountingPosterEncoder()
        var scope = DesktopPosterScope.desktop(id: "one", context: "visit-a")
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
            surfaces: { [.init(layer: layer, display: "1")] }, frameCenter: center, scope: { _ in scope },
            encode: { await encoder.encode($0) }, settleDelays: [])
        var accepted: [(String, DesktopPosterScope, Data)] = []
        sync.onPosterAccepted = { accepted.append(($0, $1, $2)) }
        // The fresh poster wins on the current desktop.
        sync.desktopPosters = { _ in ["one": Data([8]), "two": Data([9])] }
        sync.start(); defer { sync.stop() }

        post(Data([7]), layer: layer, center: center, context: "visit-a")
        try await waitUntil { Set(workspace.writes) == [self.one, self.two] }

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([7]))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([9]))
        XCTAssertEqual(accepted.map(\.0), ["1"])
        XCTAssertEqual(accepted.first?.1, scope)
        XCTAssertEqual(accepted.first?.2, Data([7]))

        scope = .all
        sync.desktopPosters = { _ in ["two": Data([5])] }
        workspace.writes.removeAll()
        post(Data([6]), layer: layer, center: center)
        try await waitUntil { Set(workspace.writes) == [self.one, self.two] }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([6]),
                       "a display that leaves Space selection shows its wallpaper everywhere again")
    }

    @MainActor
    func testLateFramesAndEncodesFromAnotherSpaceAreRejected() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        let center = NotificationCenter(), layer = CAMetalLayer(), encoder = ControlledPosterEncoder()
        var scope = DesktopPosterScope.desktop(id: "one", context: "visit-a")
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
            surfaces: { [.init(layer: layer, display: "1")] }, frameCenter: center,
            scope: { _ in scope }, encode: { await encoder.encode($0) })
        sync.start(); defer { sync.stop() }
        post(Data([1]), layer: layer, center: center, context: "visit-a")
        try await waitFor(encoder, data: Data([1]))
        scope = .desktop(id: "two", context: "visit-b")
        await encoder.finish(Data([1]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(workspace.writes.isEmpty)
        post(Data([2]), layer: layer, center: center, context: "visit-a")
        for _ in 0..<20 { await Task.yield() }
        let receivedStale = await encoder.has(Data([2]))
        XCTAssertFalse(receivedStale)
        post(Data([3]), layer: layer, center: center, context: "visit-b")
        try await waitFor(encoder, data: Data([3]))
        await encoder.finish(Data([3]))
        try await waitUntil { workspace.writes == [self.two] }
        XCTAssertEqual(workspace.pictures[one], original("one"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[two]?.url)), Data([3]))
        scope = .all
        post(Data([4]), layer: layer, center: center, context: "visit-b")
        for _ in 0..<20 { await Task.yield() }
        let receivedAfterModeChange = await encoder.has(Data([4]))
        XCTAssertFalse(receivedAfterModeChange)
    }

    @MainActor
    func testScopedPostersSurviveReplacementGapsAndEjectRestoresOnlyTheCurrentSpace() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one"), two: original("two")]
        let center = NotificationCenter(), layer = CAMetalLayer()
        var surfaces = [DesktopPosterSurface(layer: layer, display: "1")]
        var retained: Set<String> = ["1"]
        var scope = DesktopPosterScope.desktop(id: "one", context: "visit-a")
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace, surfaces: { surfaces },
            frameCenter: center, scope: { _ in scope }, retainedDisplays: { retained }, encode: { $0.pixels })
        sync.start(); defer { sync.stop() }
        post(Data([1]), layer: layer, center: center, context: "visit-a")
        try await waitUntil { workspace.writes == [self.one] }
        let first = try XCTUnwrap(workspace.pictures[one])
        scope = .hold; surfaces = []; workspace.writes.removeAll()
        sync.refresh(capture: .none)
        XCTAssertTrue(workspace.writes.isEmpty)
        XCTAssertEqual(workspace.pictures[one], first)
        surfaces = [.init(layer: layer, display: "1")]
        scope = .desktop(id: "two", context: "visit-b")
        post(Data([2]), layer: layer, center: center, context: "visit-b")
        try await waitUntil { workspace.writes == [self.two] }
        XCTAssertEqual(try Data(contentsOf: first.url), Data([1]))
        surfaces = []; retained = []
        sync.refresh(capture: .none)
        try await waitUntil { workspace.pictures[self.two] == self.original("two") }
        XCTAssertEqual(workspace.pictures[one], first)
    }

    private func waitFor(_ encoder: ControlledPosterEncoder, data: Data) async throws {
        for _ in 0..<200 {
            if await encoder.has(data) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Encoder did not receive frame")
        throw CocoaError(.coderInvalidValue)
    }

    func testRendererPixelsKeepChannelsOrientationAndDimensions() throws {
        // Quadrants large enough that JPEG's chroma subsampling cannot blend
        // their centres: red, green / blue, white.
        let size = 32, half = size / 2
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]]
        for blueFirst in [false, true] {
            var pixels = Data(capacity: size * size * 4)
            for y in 0..<size {
                for x in 0..<size {
                    let rgb = colors[(y < half ? 0 : 2) + (x < half ? 0 : 1)]
                    pixels.append(contentsOf: blueFirst ? [rgb[2], rgb[1], rgb[0], 255] : rgb + [255])
                }
            }
            let jpeg = try DesktopPosterEncoder.jpeg(pixels: pixels, width: size, height: size, bgra: blueFirst)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
            let bitmap = NSBitmapImageRep(cgImage: image)
            XCTAssertEqual(bitmap.pixelsWide, size)
            XCTAssertEqual(bitmap.pixelsHigh, size)
            for (x, y, expected) in [(8, 8, colors[0]), (24, 8, colors[1]), (8, 24, colors[2]), (24, 24, colors[3])] {
                var samples = [Int](repeating: 0, count: 4)
                bitmap.getPixel(&samples, atX: x, y: y)
                for (sample, wanted) in zip(samples.prefix(3), expected) {
                    XCTAssertEqual(Double(sample), Double(wanted), accuracy: 24, "pixel \(x),\(y)")
                }
            }
        }
    }

    func testPosterFramesFromANotificationKeepByteOrderAndRejectWhatCannotBeShown() throws {
        let red: [UInt8] = [255, 0, 0, 255]
        for bgra in [false, true] {
            let frame = try XCTUnwrap(DesktopPosterFrame(userInfo: [
                "pixels": Data(red), "width": 1, "height": 1, "bgra": bgra, "context": "any"]))
            let image = try XCTUnwrap(frame.cgImage())
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
            let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            // The same four bytes: red first, or blue first.
            XCTAssertEqual(color.redComponent, bgra ? 0 : 1, accuracy: 0.05, "bgra: \(bgra)")
            XCTAssertEqual(color.blueComponent, bgra ? 1 : 0, accuracy: 0.05, "bgra: \(bgra)")
        }

        XCTAssertNil(DesktopPosterFrame(userInfo: nil))
        XCTAssertNil(DesktopPosterFrame(userInfo: ["pixels": Data(red), "width": 1, "height": 1]))
        XCTAssertNil(DesktopPosterFrame(userInfo: ["pixels": Data(red), "width": "1", "height": 1, "bgra": false]))

        for (width, height, bytes) in [(0, 2, 0), (-1, 2, 0), (2, 2, 15), (2, 2, 17), (16_385, 1, 16_385 * 4),
                                       (1, 16_385, 16_385 * 4), (Int.max, 1, 0)] {
            let frame = DesktopPosterFrame(pixels: Data(count: bytes), width: width, height: height, bgra: false)
            XCTAssertNil(frame.cgImage(), "\(width) by \(height) with \(bytes) bytes")
        }
    }

    @MainActor
    func testAHeldSwitchFrameNeverBecomesTheDesktopPoster() async throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = [one: original("one")]
        let center = NotificationCenter(), layer = CAMetalLayer(), encoder = CountingPosterEncoder()
        let sync = try DesktopWallpaperSync(folder: root, workspace: workspace,
            surfaces: { [.init(layer: layer, display: "1")] }, frameCenter: center, scope: { _ in .all },
            encode: { await encoder.encode($0) }, settleDelays: [])
        sync.start(); defer { sync.stop() }

        // The frame a switch hold asked the renderer for answers a request of its own.
        post(Data([9]), layer: layer, center: center, context: "switch-hold:3F2A9C")
        for _ in 0..<20 { await Task.yield() }
        let encodedHeld = await encoder.count
        XCTAssertEqual(encodedHeld, 0)
        XCTAssertTrue(workspace.writes.isEmpty)

        post(Data([2]), layer: layer, center: center)
        try await waitUntil { workspace.writes == [self.one] }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.pictures[one]?.url)), Data([2]))
    }

    func testEncoderRejectsInvalidSizesAndTruncatedPixels() {
        for (width, height, bytes) in [(0, 2, 0), (-1, 2, 0), (2, 2, 15), (2, 2, 17), (Int.max, 1, 0), (16_384, 16_384, 0)] {
            XCTAssertThrowsError(try DesktopPosterEncoder.jpeg(pixels: Data(count: bytes), width: width, height: height, bgra: false))
        }
    }
}
