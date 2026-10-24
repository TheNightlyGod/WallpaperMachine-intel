import Darwin
import XCTest

@testable import WallpaperMachine

/// Moving the library and the downloads to another folder (an external drive) and back: the copy
/// made while the app runs, the switch at the next launch, and every way that must leave the
/// library where it was.
final class StorageMoveServiceTests: XCTestCase {
    private var root: URL!
    private var support: URL { root.appendingPathComponent("support", isDirectory: true) }
    /// The folder the user picks, standing in for an external drive.
    private var drive: URL { root.appendingPathComponent("Drive", isDirectory: true) }
    private var target: URL { drive.appendingPathComponent(StorageLocation.folderName, isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-move-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try put("project-101", "Library/101/project.json")
        try put("movie-102", "Library/102/movie.mp4")
        try put("partial", "Downloads/Workshop/123/steamapps/part.bin")
        try put("[]", "Downloads/workshop-requests.json")
        try put("settings", "config.toml")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: Moving

    func testCopiedMoveFinishesAtLaunchWithWhatChangedSinceTheCopy() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        let plan = try service.plan(moveTo: drive)
        XCTAssertTrue(plan.copies)
        XCTAssertEqual(plan.targetRoot, target)
        try service.prepare(plan)

        // Nothing the app uses changes until the next launch.
        XCTAssertEqual(StorageLocation.resolve(support: support), .support)
        XCTAssertEqual(try read("Library/101/project.json"), "project-101")
        XCTAssertNotNil(service.pending)

        // The app keeps running meanwhile: a download arrives, a wallpaper is deleted, one updated.
        try put("new", "Library/103/project.json")
        try FileManager.default.removeItem(at: support.appendingPathComponent("Library/102"))
        try put("project-101 updated", "Library/101/project.json")

        let result = try XCTUnwrap(StorageMoveService.applyPending(support: support))
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(StorageLocation.resolve(support: support), .chosen(target))
        XCTAssertEqual(try read("Library/101/project.json", in: target), "project-101 updated")
        XCTAssertEqual(try read("Library/103/project.json", in: target), "new")
        XCTAssertFalse(exists("Library/102", in: target))
        XCTAssertEqual(try read("Downloads/Workshop/123/steamapps/part.bin", in: target), "partial")
        XCTAssertFalse(exists(StorageMoveService.stagingName, in: target))
        // Settings and the download queue stay; the old copy is out of the way and then deleted.
        XCTAssertEqual(try read("config.toml"), "settings")
        XCTAssertEqual(try read("Downloads/workshop-requests.json"), "[]")
        XCTAssertFalse(exists("Library"))
        XCTAssertFalse(exists("Downloads/Workshop"))
        XCTAssertNil(service.pending)
        StorageMoveService.removeRetiredCopies(support: support)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: support.path)
            .contains { $0.hasPrefix(StorageMoveService.retiredPrefix) })
    }

    func testMoveOnOneVolumeRenamesWithoutCopyingAndMovesBack() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive, sameVolume: true))
        let before = try inode("Library/102/movie.mp4")
        let plan = try service.plan(moveTo: drive)
        XCTAssertFalse(plan.copies)
        try service.prepare(plan)
        XCTAssertFalse(exists(StorageMoveService.stagingName, in: target), "nothing is copied on one volume")

        XCTAssertNoThrow(try XCTUnwrap(StorageMoveService.applyPending(support: support)).get())
        XCTAssertEqual(StorageLocation.resolve(support: support), .chosen(target))
        XCTAssertEqual(try inode("Library/102/movie.mp4", in: target), before, "the same file, renamed")
        XCTAssertFalse(exists("Library"))

        let back = try service.plan(moveTo: nil)
        XCTAssertEqual(back.targetRoot, support)
        try service.prepare(back)
        XCTAssertNoThrow(try XCTUnwrap(StorageMoveService.applyPending(support: support)).get())
        XCTAssertEqual(StorageLocation.resolve(support: support), .support)
        XCTAssertEqual(try read("Library/101/project.json"), "project-101")
        XCTAssertEqual(try read("Downloads/Workshop/123/steamapps/part.bin"), "partial")
        XCTAssertFalse(exists("Library", in: target))
    }

    func testCopiedMoveBackToThisMacUsesTheAppSupportFolderAgain() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        try service.prepare(try service.plan(moveTo: drive))
        XCTAssertNoThrow(try XCTUnwrap(StorageMoveService.applyPending(support: support)).get())

        try service.prepare(try service.plan(moveTo: nil))
        XCTAssertNoThrow(try XCTUnwrap(StorageMoveService.applyPending(support: support)).get())
        XCTAssertEqual(StorageLocation.resolve(support: support), .support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: StorageLocation.recordURL(support: support).path))
        XCTAssertEqual(try read("Library/101/project.json"), "project-101")
        XCTAssertFalse(exists("Library", in: target))
        StorageMoveService.removeRetiredCopies(support: support)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.path)
            .contains { $0.hasPrefix(StorageMoveService.retiredPrefix) }, "the copy on the drive is deleted")
    }

    // MARK: Failures leave the library where it was

    func testLaunchWithoutTheDriveKeepsTheLibraryAndSaysWhy() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        try service.prepare(try service.plan(moveTo: drive))
        // The drive is unplugged before the next launch.
        try FileManager.default.removeItem(at: drive)

        let result = try XCTUnwrap(StorageMoveService.applyPending(support: support))
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(StorageLocation.resolve(support: support), .support)
        XCTAssertEqual(try read("Library/101/project.json"), "project-101")
        XCTAssertNil(service.pending, "a failed move is not retried behind the user's back")
        XCTAssertNotNil(service.lastFailure)
        XCTAssertNil(StorageMoveService.applyPending(support: support))
    }

    func testAnotherDriveAtTheSamePathIsNotTakenForTheLibrary() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        try service.prepare(try service.plan(moveTo: drive))
        try StorageLocation.writeMarker(UUID().uuidString, at: target)

        XCTAssertThrowsError(try XCTUnwrap(StorageMoveService.applyPending(support: support)).get())
        XCTAssertEqual(StorageLocation.resolve(support: support), .support)
        XCTAssertEqual(try read("Library/102/movie.mp4"), "movie-102")
    }

    func testPlanRefusesFoldersThatCannotHoldTheLibrary() throws {
        var volume = FakeVolumes.external
        volume.supportsExclusiveRenaming = false
        XCTAssertThrowsError(try StorageMoveService(support: support, volumes: FakeVolumes(drive: drive, volume: volume)).plan(moveTo: drive))
        volume = FakeVolumes.external
        volume.supportsHardLinks = false
        XCTAssertThrowsError(try StorageMoveService(support: support, volumes: FakeVolumes(drive: drive, volume: volume)).plan(moveTo: drive))
        volume = FakeVolumes.external
        volume.isLocal = false
        XCTAssertThrowsError(try StorageMoveService(support: support, volumes: FakeVolumes(drive: drive, volume: volume)).plan(moveTo: drive))
        volume = FakeVolumes.external
        volume.availableBytes = 10
        XCTAssertThrowsError(try StorageMoveService(support: support, volumes: FakeVolumes(drive: drive, volume: volume)).plan(moveTo: drive))

        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        XCTAssertThrowsError(try service.plan(moveTo: support.appendingPathComponent("Library")), "inside the library")
        XCTAssertThrowsError(try service.plan(moveTo: drive.appendingPathComponent("missing")))
        XCTAssertThrowsError(try service.plan(moveTo: nil), "already on this Mac")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Something"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.plan(moveTo: drive), "a WallpaperMachine folder that is not empty")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drive.path), [StorageLocation.folderName])
        XCTAssertNil(service.pending)
    }

    func testNoMoveWhileAnInterruptedRestoreIsStillToBePutRight() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        try service.prepare(try service.plan(moveTo: drive))
        // The backup restore staged afterwards stopped part-way before this launch.
        let transaction = support.appendingPathComponent(WallpaperBackupService.transactionDirectoryName)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)

        XCTAssertThrowsError(try XCTUnwrap(StorageMoveService.applyPending(support: support)).get())
        XCTAssertEqual(StorageLocation.resolve(support: support), .support)
        XCTAssertEqual(try read("Library/101/project.json"), "project-101")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "the copy is removed")
        XCTAssertThrowsError(try service.plan(moveTo: drive))
    }

    func testOnlyOneMoveWaitsAtATime() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        let plan = try service.plan(moveTo: drive)
        try service.prepare(plan)
        XCTAssertThrowsError(try service.plan(moveTo: drive))
        XCTAssertThrowsError(try service.prepare(plan))
    }

    // MARK: Cancelling

    func testCancellingAWaitingMoveRemovesTheCopyAndTheFolder() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        try service.prepare(try service.plan(moveTo: drive))
        XCTAssertTrue(exists("\(StorageMoveService.stagingName)/Library/101/project.json", in: target))

        try service.cancelPending()
        XCTAssertNil(service.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNil(StorageMoveService.applyPending(support: support))
        XCTAssertEqual(StorageLocation.resolve(support: support), .support)
    }

    func testCancellingTheCopyRemovesWhatItCopied() async throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        let plan = try service.plan(moveTo: drive)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try service.prepare(plan)
        }
        do {
            try await task.value
            XCTFail("a cancelled copy must not record a move")
        } catch is CancellationError {}
        XCTAssertNil(service.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNoThrow(try service.plan(moveTo: drive), "the folder can be chosen again")
    }

    func testCopyThatWasCutShortIsStartedOver() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        // The app quit while copying: a marker and part of a copy, and no move recorded.
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("\(StorageMoveService.stagingName)/Library/999"), withIntermediateDirectories: true)
        try StorageLocation.writeMarker(UUID().uuidString, at: target)

        try service.prepare(try service.plan(moveTo: drive))
        XCTAssertFalse(exists("\(StorageMoveService.stagingName)/Library/999", in: target))
        XCTAssertNoThrow(try XCTUnwrap(StorageMoveService.applyPending(support: support)).get())
        XCTAssertEqual(StorageLocation.resolve(support: support), .chosen(target))
    }

    // MARK: Interrupted launches

    func testLaunchThatStoppedAfterTheSwitchFinishesWithoutTouchingTheNewLibrary() throws {
        let service = StorageMoveService(support: support, volumes: FakeVolumes(drive: drive))
        try service.prepare(try service.plan(moveTo: drive))
        let record = try Data(contentsOf: support.appendingPathComponent(StorageMoveService.pendingFileName))
        XCTAssertNoThrow(try XCTUnwrap(StorageMoveService.applyPending(support: support)).get())

        // As if that launch had stopped after recording the new folder, before retiring the old copy.
        try put("old copy", "Library/101/project.json")
        try record.write(to: support.appendingPathComponent(StorageMoveService.pendingFileName))
        XCTAssertNoThrow(try XCTUnwrap(StorageMoveService.applyPending(support: support)).get())
        XCTAssertEqual(StorageLocation.resolve(support: support), .chosen(target))
        XCTAssertEqual(try read("Library/101/project.json", in: target), "project-101")
        XCTAssertFalse(exists("Library"))
    }

    // MARK: Helpers

    private func put(_ text: String, _ path: String, in base: URL? = nil) throws {
        let url = (base ?? support).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in base: URL? = nil) throws -> String {
        try String(contentsOf: (base ?? support).appendingPathComponent(path), encoding: .utf8)
    }

    private func exists(_ path: String, in base: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (base ?? support).appendingPathComponent(path).path)
    }

    private func inode(_ path: String, in base: URL? = nil) throws -> UInt64 {
        var info = stat()
        guard lstat((base ?? support).appendingPathComponent(path).path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return UInt64(info.st_ino)
    }
}

/// Says the chosen folder is on another disk, of a kind and with room the test picks.
private struct FakeVolumes: StorageVolumeInspecting {
    static let external = StorageVolume(
        identifier: 2, isLocal: true, isReadOnly: false, supportsExclusiveRenaming: true, supportsHardLinks: true,
        availableBytes: 1 << 40)
    let drive: URL
    var volume = FakeVolumes.external
    var sameVolume = false

    init(drive: URL, volume: StorageVolume = FakeVolumes.external, sameVolume: Bool = false) {
        self.drive = drive
        self.volume = volume
        self.sameVolume = sameVolume
    }

    func volume(of url: URL) throws -> StorageVolume {
        var thisMac = Self.external
        thisMac.identifier = 1
        guard url.resolvingSymlinksInPath().path.hasPrefix(drive.resolvingSymlinksInPath().path) else { return thisMac }
        var chosen = volume
        if sameVolume { chosen.identifier = thisMac.identifier }
        return chosen
    }
}
