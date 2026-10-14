import XCTest

@testable import WallpaperMachine

/// Where a file lives decides how long the native backend waits for it. The
/// classification is a pure function of the volume's flags, so every shape the
/// file system can answer with is exercised here without a slow volume.
@MainActor
final class NativeVideoStoragePolicyTests: XCTestCase {
    private typealias Facts = NativeVideoStoragePolicy.Facts

    func testClassificationOrder() {
        let classify = NativeVideoStoragePolicy.classify
        // A file that may need downloading is slow whatever its volume says.
        XCTAssertEqual(
            classify(Facts(isInternal: true, isLocal: true, isUbiquitous: false, isDataless: true)),
            .dataless)
        XCTAssertEqual(
            classify(Facts(isInternal: true, isLocal: true, isUbiquitous: true, isDataless: false)),
            .dataless)
        XCTAssertEqual(
            classify(Facts(isInternal: false, isLocal: false, isUbiquitous: nil, isDataless: true)),
            .dataless, "dataless beats a network volume")
        // Not local is a network volume, even when the volume claims to be internal.
        XCTAssertEqual(
            classify(Facts(isInternal: true, isLocal: false, isUbiquitous: false)), .networkVolume)
        // A flag that could not be read is never taken to mean "internal".
        XCTAssertEqual(classify(Facts()), .unknown)
        XCTAssertEqual(classify(Facts(isInternal: true, isLocal: nil)), .unknown)
        XCTAssertEqual(classify(Facts(isInternal: nil, isLocal: true)), .unknown)
        // What is left is a local volume, internal or not.
        XCTAssertEqual(classify(Facts(isInternal: false, isLocal: true)), .removableVolume)
        XCTAssertEqual(
            classify(Facts(isInternal: true, isLocal: true, isUbiquitous: false)), .internalVolume)
    }

    func testDeadlinesGrowWithTheSlowerStorage() {
        let probe = NativeVideoStoragePolicy.metadataProbeDeadline
        XCTAssertLessThan(probe(.internalVolume), probe(.removableVolume))
        XCTAssertLessThan(probe(.removableVolume), probe(.networkVolume))
        XCTAssertEqual(probe(.networkVolume), probe(.dataless))
        XCTAssertEqual(
            probe(.unknown), probe(.removableVolume),
            "an unreadable volume waits as long as an external drive, not as a local one")

        let firstFrame = NativeVideoStoragePolicy.firstFrameDeadline
        XCTAssertLessThan(firstFrame(.internalVolume), firstFrame(.removableVolume))
        XCTAssertLessThan(firstFrame(.removableVolume), firstFrame(.networkVolume))
        XCTAssertEqual(firstFrame(.unknown), firstFrame(.removableVolume))
        // Decoding follows the read, so a first frame is never given less time.
        for location in [
            NativeVideoStoragePolicy.Location.internalVolume, .removableVolume, .networkVolume,
            .dataless, .unknown,
        ] {
            XCTAssertGreaterThanOrEqual(firstFrame(location), probe(location), "\(location)")
        }
    }

    func testAFileThatCannotBeReadHasNoFactsAndIsTreatedAsSlow() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperMachine-missing-\(UUID().uuidString)/clip.mp4")

        let facts = NativeVideoStoragePolicy.facts(of: missing)

        XCTAssertEqual(facts, Facts())
        XCTAssertEqual(NativeVideoStoragePolicy.classify(facts), .unknown)
    }

    func testAnOrdinaryLocalFileIsNotDatalessAndHasReadableFlags() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperMachine-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("clip.mp4")
        try Data("x".utf8).write(to: file)

        let facts = NativeVideoStoragePolicy.facts(of: file)

        XCTAssertFalse(facts.isDataless)
        XCTAssertEqual(facts.isLocal, true, "the temporary directory is a local volume")
        XCTAssertNotNil(facts.isInternal)
        XCTAssertNotEqual(NativeVideoStoragePolicy.classify(facts), .unknown)
    }

    func testAClassificationThatNeverReturnsIsTreatedAsUnknown() async {
        // `stat` on a volume that stopped answering does not return. The read
        // must not hold the caller, which is the host's reconcile pass.
        let sleeper = ManualSleeper()
        let release = DispatchSemaphore(value: 0)
        let reading = AsyncGate()
        let task = Task {
            await NativeVideoStoragePolicy.location(
                of: URL(fileURLWithPath: "/Volumes/gone/clip.mp4"), within: .seconds(2),
                sleep: sleeper.closure,
                read: { _ in
                    reading.open()
                    release.wait()
                    return Facts(isInternal: true, isLocal: true)
                })
        }
        await sleeper.waitUntilPending()
        await reading.wait()
        XCTAssertEqual(sleeper.requested, [.seconds(2)])

        sleeper.fireNext()
        let location = await task.value
        release.signal()

        XCTAssertEqual(location, .unknown, "not internal, although the late answer would have been")
    }

    func testAClassificationThatReturnsInTimeIsUsed() async {
        let sleeper = ManualSleeper()
        let location = await NativeVideoStoragePolicy.location(
            of: URL(fileURLWithPath: "/Volumes/nas/clip.mp4"), within: .seconds(2),
            sleep: sleeper.closure,
            read: { _ in Facts(isInternal: false, isLocal: false) })

        XCTAssertEqual(location, .networkVolume)
        XCTAssertEqual(sleeper.pendingCount, 0, "and its timer is gone")
    }
}
