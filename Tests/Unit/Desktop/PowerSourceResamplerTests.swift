import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class PowerSourceResamplerTests: XCTestCase {
    func testAWakeReadsAtOnceAndOnceMoreWhenTheFollowUpArrives() async throws {
        let rig = Rig()
        defer { rig.resampler.stop() }
        rig.resampler.start()

        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await rig.waitUntil { rig.reads == 1 }
        try await rig.waitUntil { rig.sleeper.waiting == 1 }
        XCTAssertEqual(rig.reads, 1, "the follow-up must wait for its sleep")

        rig.sleeper.releaseAll()
        try await rig.waitUntil { rig.reads == 2 }
        await rig.flushMainQueue()
        XCTAssertEqual(rig.reads, 2, "one wake is two reads, never a stream")
    }

    func testDisplayAndSystemWakeBackToBackReadTwiceNowAndOnceLater() async throws {
        let rig = Rig()
        defer { rig.resampler.stop() }
        rig.resampler.start()

        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        rig.center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await rig.waitUntil { rig.reads == 2 }
        try await rig.waitUntil { rig.sleeper.waiting == 2 }

        // The first wake's follow-up was replaced, even by a sleep that does not notice.
        rig.sleeper.releaseAll()
        try await rig.waitUntil { rig.reads == 3 }
        await rig.flushMainQueue()
        XCTAssertEqual(rig.reads, 3)
    }

    func testAnotherWakeAfterTheFollowUpHasItsOwnFollowUp() async throws {
        let rig = Rig()
        defer { rig.resampler.stop() }
        rig.resampler.start()

        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await rig.waitUntil { rig.sleeper.waiting == 1 }
        rig.sleeper.releaseAll()
        try await rig.waitUntil { rig.reads == 2 }

        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await rig.waitUntil { rig.reads == 3 }
        try await rig.waitUntil { rig.sleeper.waiting == 1 }
        rig.sleeper.releaseAll()
        try await rig.waitUntil { rig.reads == 4 }
    }

    func testStoppingCancelsAPendingFollowUpAndEndsObservation() async throws {
        let rig = Rig()
        rig.resampler.start()
        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await rig.waitUntil { rig.sleeper.waiting == 1 }

        rig.resampler.stop()
        rig.sleeper.releaseAll()
        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        rig.center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await rig.flushMainQueue()
        await rig.flushMainQueue()

        XCTAssertEqual(rig.reads, 1, "only the read from before stop()")
        XCTAssertEqual(rig.sleeper.started, 1, "no follow-up was scheduled after stop()")
    }

    func testStartingTwiceDoesNotObserveTwice() async throws {
        let rig = Rig()
        defer { rig.resampler.stop() }
        rig.resampler.start()
        rig.resampler.start()

        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await rig.waitUntil { rig.reads == 1 }
        await rig.flushMainQueue()

        XCTAssertEqual(rig.reads, 1)
        XCTAssertEqual(rig.sleeper.started, 1)
    }

    func testStoppingTwiceAndRestartingStillWorks() async throws {
        let rig = Rig()
        defer { rig.resampler.stop() }
        rig.resampler.start()
        rig.resampler.stop()
        rig.resampler.stop()
        rig.resampler.start()

        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)

        try await rig.waitUntil { rig.reads == 1 }
    }

    func testNothingIsReadUntilTheMacWakes() async throws {
        let rig = Rig()
        defer { rig.resampler.stop() }
        rig.resampler.start()

        rig.center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await rig.flushMainQueue()

        XCTAssertEqual(rig.reads, 0)
        XCTAssertEqual(rig.sleeper.started, 0)
    }
}

/// A resampler on a private notification center, counting its reads, and a sleep the test
/// releases by hand. The sleep ignores cancellation, as the worst real one could.
@MainActor
private final class Rig {
    let center = NotificationCenter()
    let sleeper = ManualSleep()
    private(set) var reads = 0
    private(set) var resampler: PowerSourceResampler!

    init() {
        let sleeper = sleeper
        resampler = PowerSourceResampler(
            workspaceCenter: center,
            followUp: .seconds(2),
            resample: { [unowned self] in reads += 1 },
            sleep: { await sleeper.sleep(for: $0) }
        )
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Notifications reach the resampler through the main queue, so once an operation added
    /// afterwards has run, every notification posted before it has been delivered.
    func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            OperationQueue.main.addOperation { continuation.resume() }
        }
    }
}
