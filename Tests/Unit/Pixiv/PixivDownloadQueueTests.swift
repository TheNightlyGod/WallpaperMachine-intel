import Foundation
import XCTest

@testable import WallpaperMachine

@MainActor
final class PixivDownloadQueueTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pixiv-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func work(_ id: Int, pages: Int = 1) -> PixivWork {
        PixivWork(
            id: String(id), title: "Work \(id)", authorID: "1", authorName: "Artist", thumbnailURL: nil,
            width: 1360, height: 1920, pageCount: pages, rating: .everyone, aiGenerated: nil, tags: [], rank: nil)
    }

    private func queue(_ transport: any PixivTransport) -> PixivDownloadQueue {
        let packager = PixivWallpaperPackager(library: library) { _, pixels in Data("scaled \(pixels)".utf8) }
        return PixivDownloadQueue(service: PixivService(transport: transport, minimumInterval: .zero), packager: packager)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testADownloadedPageBecomesALibraryWallpaper() async throws {
        let image = PixivFixtures.imageBytes("png", size: 200_000)
        let transport = PixivFixtureTransport { url in
            url.host == "www.pixiv.net" ? PixivFixtures.pages(workID: 7, count: 3) : image
        }
        let queue = queue(transport)
        var installed: [String] = []
        queue.onInstalled = { installed.append($0) }

        let job = queue.enqueue(work(7, pages: 3), page: 2)
        XCTAssertEqual(job.id, "pixiv-7-p2")
        XCTAssertTrue(job.isPending)
        try await waitUntil { !job.isPending }

        XCTAssertEqual(job.status, .finished)
        XCTAssertEqual(installed, ["pixiv-7-p2"])
        XCTAssertEqual(job.progress, 1)
        XCTAssertEqual(job.bytesReceived, Int64(image.count))
        XCTAssertEqual(
            try Data(contentsOf: library.appendingPathComponent("pixiv-7-p2/illustration.png")), image)
        XCTAssertEqual(transport.requests.last?.lastPathComponent, "7_p2.png", "the chosen page's original")
        XCTAssertFalse(queue.isRunning)
    }

    func testPagesTheStoreAlreadyKnowsAreNotFetchedAgain() async throws {
        let transport = PixivFixtureTransport { _ in PixivFixtures.imageBytes("jpg") }
        let queue = queue(transport)
        let pages = try PixivService.decodePages(PixivFixtures.pages(workID: 8, count: 1))

        let job = queue.enqueue(work(8), page: 0, knownPages: pages)
        try await waitUntil { !job.isPending }

        XCTAssertEqual(job.status, .finished)
        XCTAssertEqual(transport.requests.map(\.host), ["i.pximg.net"])
    }

    func testAFailureStaysOnTheJobUntilItIsRetried() async throws {
        let allowed = LockedFlag()
        let transport = PixivFixtureTransport { url in
            if url.host == "www.pixiv.net" { return PixivFixtures.pages(workID: 9, count: 1) }
            guard allowed.value else { throw PixivFailure(code: .status(503)) }
            return PixivFixtures.imageBytes("jpg")
        }
        let queue = queue(transport)

        let job = queue.enqueue(work(9), page: 0)
        try await waitUntil { !job.isPending }
        XCTAssertEqual(job.status, .failed(PixivFailure(code: .status(503)).localizedDescription))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("pixiv-9-p0").path))

        allowed.value = true
        XCTAssertTrue(queue.retry("pixiv-9-p0"))
        let again = try XCTUnwrap(queue.download(for: "pixiv-9-p0"))
        XCTAssertFalse(again === job)
        try await waitUntil { !again.isPending }
        XCTAssertEqual(again.status, .finished)
        XCTAssertFalse(queue.retry("pixiv-9-p0"), "a finished download has nothing to retry")
        XCTAssertEqual(queue.downloads.count, 1)
    }

    func testMembersOnlyWorksFailWithTheirReason() async throws {
        let queue = queue(PixivFixtureTransport { _ in PixivFixtures.membersOnlyPages() })

        let job = queue.enqueue(work(10), page: 0)
        try await waitUntil { !job.isPending }

        XCTAssertEqual(job.status, .failed(PixivFailure(code: .membersOnly).localizedDescription))
    }

    func testTwoDownloadsRunAtOnceAndTheRestWaitInOrder() async throws {
        let gate = PixivGate()
        let transport = PixivGatedTransport(gate: gate)
        let queue = queue(transport)

        let jobs = [11, 12, 13].map { queue.enqueue(work($0), page: 0) }
        try await waitUntil { gate.waiting == 2 }

        XCTAssertEqual(jobs.map(\.status), [.downloading, .downloading, .waiting])
        XCTAssertTrue(queue.enqueue(work(11), page: 0) === jobs[0], "a pending page is not queued twice")
        queue.cancel(jobs[2].id)
        XCTAssertEqual(jobs[2].status, .cancelled)
        queue.cancel(jobs[1].id)
        try await waitUntil { jobs[1].status == .cancelled }

        gate.open()
        try await waitUntil { !jobs[0].isPending }
        XCTAssertEqual(jobs[0].status, .finished)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: library.path), ["pixiv-11-p0"])
        queue.clearFinished()
        XCTAssertTrue(queue.downloads.isEmpty)
    }

    func testPersistenceFailureDoesNotStartATransferAndCanBeRetried() async throws {
        let queueFile = root.appendingPathComponent("Downloads/Pixiv/queue.json")
        try FileManager.default.createDirectory(at: queueFile, withIntermediateDirectories: true)
        let transport = PixivFixtureTransport { url in
            url.host == "www.pixiv.net" ? PixivFixtures.pages(workID: 24, count: 1) : PixivFixtures.imageBytes("jpg")
        }
        let queue = queue(transport)
        let job = queue.enqueue(work(24), page: 0)
        XCTAssertFalse(job.isPending)
        XCTAssertNotNil(job.errorMessage)
        XCTAssertNotNil(queue.persistenceError)
        XCTAssertTrue(transport.requests.isEmpty)
        try FileManager.default.removeItem(at: queueFile)
        XCTAssertTrue(queue.retry(job.id))
        try await waitUntil { queue.download(for: job.id)?.status == .finished }
        XCTAssertNil(queue.persistenceError)
    }

    func testCancellationIsDurableWhileCleanupStillOwnsItsTransferSlot() async throws {
        let gate = PixivGate(finishesOnCancellation: false)
        defer { gate.open() }
        let queue = queue(PixivGatedTransport(gate: gate))
        let jobs = [25, 26, 27].map { queue.enqueue(work($0), page: 0) }
        try await waitUntil { gate.waiting == 2 }
        let cancelledCheckpoint = root.appendingPathComponent("Downloads/Pixiv/\(jobs[0].id)")
        let pausedCheckpoint = root.appendingPathComponent("Downloads/Pixiv/\(jobs[1].id)")
        for checkpoint in [cancelledCheckpoint, pausedCheckpoint] {
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
            try Data("partial image".utf8).write(to: checkpoint.appendingPathComponent("image.partial"))
        }

        queue.cancel(jobs[0].id)
        queue.pause(jobs[0].id)
        queue.pause(jobs[1].id)
        queue.clearFinished()

        XCTAssertTrue(queue.enqueue(work(25), page: 0) === jobs[0], "cleanup still owns this page")
        XCTAssertFalse(queue.retry(jobs[0].id))
        XCTAssertEqual(jobs.map(\.status), [.downloading, .downloading, .waiting])
        XCTAssertEqual(gate.waiting, 2, "a cancelled transfer retains its slot until it stops")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cancelledCheckpoint.path))
        let restored = self.queue(PixivFixtureTransport { _ in PixivFixtures.imageBytes("jpg") })
        XCTAssertEqual(restored.downloads.map(\.id), [jobs[1].id, jobs[2].id])
        XCTAssertEqual(restored.downloads.map(\.status), [.paused, .paused])

        var shutdownFinished = false
        let shutdown = Task { await queue.shutdown(); shutdownFinished = true }
        try await waitUntil { jobs[2].status == .paused }
        XCTAssertFalse(shutdownFinished)
        let restoredDuringShutdown = self.queue(PixivFixtureTransport { _ in PixivFixtures.imageBytes("jpg") })
        XCTAssertEqual(restoredDuringShutdown.downloads.map(\.id), [jobs[1].id, jobs[2].id])

        gate.open()
        await shutdown.value
        XCTAssertEqual(jobs.map(\.status), [.cancelled, .paused, .paused])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledCheckpoint.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pausedCheckpoint.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testStartingAForgottenDownloadDiscardsItsOrphanedCheckpoint() async throws {
        let checkpoint = root.appendingPathComponent("Downloads/Pixiv/pixiv-28-p0")
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        try Data("partial image".utf8).write(to: checkpoint.appendingPathComponent("image.partial"))
        try Data("[]".utf8).write(to: root.appendingPathComponent("Downloads/Pixiv/queue.json"))
        let gate = PixivGate()
        defer { gate.open() }
        let queue = queue(PixivGatedTransport(gate: gate))
        XCTAssertTrue(queue.downloads.isEmpty)

        let job = queue.enqueue(work(28), page: 0)
        try await waitUntil { gate.waiting == 1 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path), "a new request cannot resume a cancelled job's bytes")

        gate.open()
        try await waitUntil { job.status == .finished }
    }

    func testShutdownPausesEveryDownloadAndRestoresQueueOrder() async throws {
        let gate = PixivGate()
        let queue = queue(PixivGatedTransport(gate: gate))
        let jobs = [21, 22, 23].map { queue.enqueue(work($0), page: 0) }
        try await waitUntil { gate.waiting == 2 }

        await queue.shutdown()

        XCTAssertEqual(jobs.map(\.status), [.paused, .paused, .paused])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        let restored = self.queue(PixivFixtureTransport { _ in PixivFixtures.imageBytes("jpg") })
        XCTAssertEqual(restored.downloads.map(\.id), jobs.map(\.id))
        XCTAssertEqual(restored.downloads.map(\.status), [.paused, .paused, .paused])
        XCTAssertFalse(restored.isRunning)
        restored.clearFinished()
        XCTAssertEqual(restored.downloads.count, 3, "clearing history keeps paused work")
        XCTAssertTrue(restored.resume(jobs[0].id))
        try await waitUntil { restored.downloads[0].status == .finished }
        XCTAssertEqual(restored.downloads[1].status, .paused)
        restored.cancel(jobs[1].id)
        let afterCancel = self.queue(PixivFixtureTransport { _ in PixivFixtures.imageBytes("jpg") })
        XCTAssertEqual(afterCancel.downloads.map(\.id), [jobs[2].id])
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct PixivGatedTransport: PixivTransport {
    let gate: PixivGate

    func data(from url: URL, session: String?) async throws -> Data {
        PixivFixtures.pages(workID: Int(url.pathComponents.dropLast().last ?? "") ?? 0, count: 1)
    }

    func image(
        from url: URL, limit: Int, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Data {
        try await gate.pass()
        return PixivFixtures.imageBytes("jpg")
    }
}
