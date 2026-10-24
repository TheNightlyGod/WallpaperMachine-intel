import AppKit
import QuartzCore
import XCTest
@testable import WallpaperMachine

/// Timers the test fires by hand, by the duration that was asked for. A hold has several at a
/// time (its ceiling, a host's settle, a fade), so firing "the oldest" would fire the wrong one.
private final class TimerBook: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var waiters: [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelledEarly = Set<Int>()
    private var asked: [Duration] = []

    var requested: [Duration] { lock.withLock { asked } }
    var pending: [Duration] { lock.withLock { waiters.map(\.duration) } }

    var closure: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await self.sleep(duration) }
    }

    private func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            asked.append(duration)
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early = lock.withLock { () -> Bool in
                    if cancelledEarly.remove(id) != nil { return true }
                    waiters.append((id, duration, continuation))
                    return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                    cancelledEarly.insert(id)
                    return nil
                }
                return waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest waiting timer of exactly this length.
    @discardableResult
    func fire(_ duration: Duration) -> Bool {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard let index = waiters.firstIndex(where: { $0.duration == duration }) else { return nil }
            return waiters.remove(at: index).continuation
        }
        waiter?.resume()
        return waiter != nil
    }

    /// Lets the main actor run until a timer of this length is waiting.
    @MainActor
    func waitFor(_ duration: Duration, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if pending.contains(duration) { return }
            await Task.yield()
        }
        XCTFail("no timer of \(duration) is waiting; waiting: \(pending)", file: file, line: line)
    }
}

/// A hold with a notification center, layers, a clock and timers that the test owns, and a
/// stand-in for the visible wallpaper that answers (or does not answer) requests for a frame.
@MainActor
private final class HoldRig {
    static let fadeWait = Duration.seconds(WallpaperSwitchHold.Configuration().fade) + .milliseconds(50)

    let center = NotificationCenter()
    let timers = TimerBook()
    private(set) var clock = ContinuousClock.now
    /// The live wallpaper layers per display, front first.
    var live: [UInt32: [CALayer]] = [:]
    var holdable = Set<UInt32>()
    var reduceMotion = false
    var concealed = Set<UInt32>()
    private(set) var released: [UInt32] = []
    /// What the visible wallpaper answers with; nil leaves the request unanswered.
    var answer: (CALayer) -> DesktopPosterFrame? = { _ in HoldRig.frame() }
    private(set) var requests: [(layer: CALayer, context: String)] = []
    private(set) var hold: WallpaperSwitchHold!
    private var responder: NSObjectProtocol?

    init(displays: [UInt32] = [7]) {
        for display in displays {
            live[display] = [Self.screenLayer(), Self.screenLayer()]
            holdable.insert(display)
        }
        hold = WallpaperSwitchHold(
            center: center,
            layers: { [unowned self] in self.live[$0] ?? [] },
            shouldHold: { [unowned self] in self.holdable.contains($0) },
            reduceMotion: { [unowned self] in self.reduceMotion },
            concealed: { [unowned self] in self.concealed.contains($0) },
            sleep: timers.closure,
            now: { [unowned self] in self.clock })
        responder = center.addObserver(forName: DesktopPosterNotification.request, object: nil, queue: nil) {
            [unowned self] note in
            MainActor.assumeIsolated {
                guard let layer = note.object as? CALayer else { return }
                let context = note.userInfo?["context"] as? String ?? ""
                self.requests.append((layer, context))
                self.answer(layer)?.publish(for: layer, to: self.center, context: context)
            }
        }
        hold.onReleased = { [unowned self] in self.released.append($0) }
        hold.start()
    }

    func finish() {
        hold.stop()
        if let responder { center.removeObserver(responder) }
    }

    func advance(_ duration: Duration) { clock = clock.advanced(by: duration) }

    /// A 2 by 2 red picture.
    static func frame(bgra: Bool = false, bytes: Int = 16) -> DesktopPosterFrame {
        let pixel: [UInt8] = bgra ? [0, 0, 255, 255] : [255, 0, 0, 255]
        return DesktopPosterFrame(pixels: Data((0..<bytes).map { pixel[$0 % 4] }),
                                  width: 2, height: 2, bgra: bgra)
    }

    static func screenLayer() -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 160, height: 90)
        return layer
    }

    /// What the renderer's window code posts for a layer: the name, the keys and the strings are
    /// spelled out here, as `window.rs` spells them.
    func announce(_ layer: CALayer, display: UInt32, reason: String) {
        center.post(name: Notification.Name("WallpaperMachine.wallpaperLayerInstalled"), object: layer,
                    userInfo: ["displayID": NSNumber(value: display), "reason": reason as NSString])
    }

    func veil(on layer: CALayer) -> CALayer? {
        layer.sublayers?.first { $0.name == "MWEHandoffVeil" }
    }

    func state(_ display: UInt32 = 7) -> WallpaperSwitchHold.Phase? { hold.stateForTest(display: display) }

    func settle() async { for _ in 0..<40 { await Task.yield() } }
}

/// The switch hold: what it asks the visible wallpaper for, where it puts the picture and when
/// it takes it away again. Nothing here opens a window.
@MainActor
final class WallpaperSwitchHoldTests: XCTestCase {
    func testBeginAsksTheFrontLayerForAStillAndArmsOnTheAnswer() async throws {
        for bgra in [false, true] {
            let rig = HoldRig()
            defer { rig.finish() }
            rig.answer = { _ in HoldRig.frame(bgra: bgra) }

            await rig.hold.begin(displays: [7])

            XCTAssertEqual(rig.requests.count, 1)
            XCTAssertTrue(rig.requests[0].layer === rig.live[7]?[0], "the front window is asked, not the one behind")
            XCTAssertTrue(rig.requests[0].context.hasPrefix("switch-hold:"))
            XCTAssertEqual(rig.hold.activeDisplayIDs, [7])
            XCTAssertEqual(rig.state(), .armed)
        }
    }

    func testAnAnswerThatArrivesAfterTheRequestWasPostedIsTaken() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        // An answer that comes later, as the renderer's does: after the request was posted.
        rig.answer = { layer in
            Task { @MainActor in HoldRig.frame().publish(for: layer, to: rig.center) }
            return nil
        }

        await rig.hold.begin(displays: [7])

        XCTAssertEqual(rig.state(), .armed)
    }

    func testADisplayWithoutAVisibleWallpaperOrOneThatIsNotSeenIsNotHeld() async throws {
        let rig = HoldRig(displays: [7, 8])
        defer { rig.finish() }
        rig.live[7] = []
        rig.holdable.remove(8)

        await rig.hold.begin(displays: [7, 8, 9])

        XCTAssertTrue(rig.requests.isEmpty, "nothing is asked of a display nobody can see")
        XCTAssertTrue(rig.hold.activeDisplayIDs.isEmpty)
        XCTAssertNil(rig.state(7))
        XCTAssertNil(rig.state(8))
    }

    func testAnUnansweredRequestTimesOutAndLeavesNoTicket() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        rig.answer = { _ in nil }

        let begun = Task { await rig.hold.begin(displays: [7]) }
        await rig.timers.waitFor(.milliseconds(250))
        XCTAssertEqual(rig.state(), .capturing)
        rig.timers.fire(.milliseconds(250))
        await begun.value

        XCTAssertNil(rig.state())
        XCTAssertTrue(rig.hold.activeDisplayIDs.isEmpty, "the switch goes on as it always did")
    }

    func testAFrameThatCannotBeShownLeavesNoTicket() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        rig.answer = { _ in HoldRig.frame(bytes: 15) }

        await rig.hold.begin(displays: [7])

        XCTAssertNil(rig.state())
    }

    func testReplacingASceneMovesTheVeilOntoTheNewLayerUntilTheEngineSettles() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let fresh = HoldRig.screenLayer()

        rig.announce(fresh, display: 7, reason: "replace")

        let veil = try XCTUnwrap(rig.veil(on: fresh), "the veil is on the new layer before it is first composited")
        XCTAssertNotNil(veil.contents)
        XCTAssertEqual(veil.frame, fresh.bounds)
        XCTAssertEqual(rig.state(), .onScene)

        rig.hold.engineSettled(displays: [7])

        XCTAssertEqual(rig.state(), .dismissing)
        XCTAssertNotNil(veil.animation(forKey: SwitchHoldVeil.fadeAnimationKey), "it fades out")
        XCTAssertNotNil(rig.veil(on: fresh), "and stays until the fade is over")
        await rig.timers.waitFor(HoldRig.fadeWait)
        rig.timers.fire(HoldRig.fadeWait)
        await rig.settle()
        XCTAssertNil(rig.veil(on: fresh))
        XCTAssertNil(rig.state())
    }

    func testReconfiguringTheVisibleLayerBeforeAnySuccessorHasALayerLeavesTheVeilWaiting() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let fresh = HoldRig.screenLayer()

        rig.announce(fresh, display: 7, reason: "reconfigure")

        XCTAssertNil(rig.veil(on: fresh), "the visible renderer keeps its frame through a reconfigure")
        XCTAssertEqual(rig.state(), .armed)
    }

    func testAReconfigureWhileTheSceneSuccessorStillLoadsMovesTheVeilOntoTheNewLayer() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let loading = HoldRig.screenLayer(), reconfigured = HoldRig.screenLayer()
        rig.announce(loading, display: 7, reason: "replace")
        let veil = try XCTUnwrap(rig.veil(on: loading))

        // The display's surface changed before the successor presented: the window got a new
        // layer, which shows nothing until the first frame, and the old one is released.
        rig.announce(reconfigured, display: 7, reason: "reconfigure")

        XCTAssertTrue(rig.veil(on: reconfigured) === veil, "the veil is on the layer that is shown now")
        XCTAssertNil(rig.veil(on: loading), "and no longer on the one that was released")
        XCTAssertEqual(veil.frame, reconfigured.bounds)
        XCTAssertEqual(rig.state(), .onScene)

        rig.hold.engineSettled(displays: [7])

        XCTAssertEqual(rig.state(), .dismissing)
        XCTAssertNotNil(veil.animation(forKey: SwitchHoldVeil.fadeAnimationKey), "the first frame fades it out")
        await rig.timers.waitFor(HoldRig.fadeWait)
        rig.timers.fire(HoldRig.fadeWait)
        await rig.settle()
        XCTAssertNil(rig.veil(on: reconfigured))
        XCTAssertNil(rig.state())
    }

    func testAReconfigureDoesNotRestartTheCeilingOfALoadThatKeepsGoing() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        rig.announce(HoldRig.screenLayer(), display: 7, reason: "replace")
        await rig.settle()
        XCTAssertEqual(rig.timers.requested.filter { $0 == .seconds(30) }.count, 2, "the still's and the replacement's")

        rig.advance(.seconds(20))
        let reconfigured = HoldRig.screenLayer()
        rig.announce(reconfigured, display: 7, reason: "reconfigure")
        await rig.settle()

        XCTAssertNotNil(rig.veil(on: reconfigured))
        XCTAssertEqual(rig.timers.requested.filter { $0 == .seconds(30) }.count, 2,
                       "the load did not start over, so the veil keeps the ten seconds it had left")
        XCTAssertEqual(rig.timers.pending, [.seconds(30)])
    }

    func testAReconfigureLeavesAVeilOnAHostWindowAlone() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let host = HoldRig.screenLayer(), reconfigured = HoldRig.screenLayer()
        XCTAssertTrue(rig.hold.adopt(into: host, displayID: 7))

        rig.announce(reconfigured, display: 7, reason: "reconfigure")

        XCTAssertNil(rig.veil(on: reconfigured), "a scene's layer is not the host window the veil covers")
        XCTAssertNotNil(rig.veil(on: host))
        XCTAssertEqual(rig.state(), .onHost)
    }

    func testAnAnnouncementForAnotherDisplayOrWithoutATicketIsIgnored() async throws {
        let rig = HoldRig(displays: [7, 8])
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let other = HoldRig.screenLayer()

        rig.announce(other, display: 8, reason: "replace")

        XCTAssertNil(rig.veil(on: other))
        XCTAssertEqual(rig.state(7), .armed)
        rig.center.post(name: Notification.Name("WallpaperMachine.wallpaperLayerInstalled"), object: other,
                        userInfo: ["reason": "replace"])
        XCTAssertNil(rig.veil(on: other), "an announcement without a display id is not one")
        XCTAssertEqual(rig.state(7), .armed)
    }

    func testANewWindowTheEngineOpensTakesTheVeil() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let opened = HoldRig.screenLayer()

        rig.announce(opened, display: 7, reason: "open")

        XCTAssertNotNil(rig.veil(on: opened))
        XCTAssertEqual(rig.state(), .onScene)
    }

    func testASecondSwitchKeepsTheHeldStillAndMovesTheVeilToTheReplacementLayer() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let first = HoldRig.screenLayer(), second = HoldRig.screenLayer()
        rig.announce(first, display: 7, reason: "replace")

        await rig.hold.begin(displays: [7])
        XCTAssertEqual(rig.requests.count, 1, "what is on screen is the held still: it is not captured again")
        rig.announce(second, display: 7, reason: "replace")

        XCTAssertNil(rig.veil(on: first), "the layer it sat on is gone")
        XCTAssertNotNil(rig.veil(on: second))
        XCTAssertEqual(rig.hold.activeDisplayIDs, [7])
    }

    func testASwitchWhileTheVeilFadesCapturesAFreshStill() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let fresh = HoldRig.screenLayer()
        rig.announce(fresh, display: 7, reason: "replace")
        rig.hold.engineSettled(displays: [7])
        XCTAssertEqual(rig.state(), .dismissing)

        await rig.hold.begin(displays: [7])

        XCTAssertEqual(rig.requests.count, 2, "the renderer's own picture is what a fade leaves, so it is captured again")
        XCTAssertNil(rig.veil(on: fresh), "the fading veil is gone")
        XCTAssertEqual(rig.state(), .armed)
    }

    func testAHostWindowKeepsTheVeilUntilItsContentIsReadyAndSettled() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let host = HoldRig.screenLayer()

        XCTAssertTrue(rig.hold.adopt(into: host, displayID: 7))
        XCTAssertNotNil(rig.veil(on: host))
        XCTAssertEqual(rig.state(), .onHost)

        rig.hold.engineSettled(displays: [7])
        XCTAssertEqual(rig.state(), .onHost, "the engine finishing says nothing about a host's page or clip")

        rig.hold.contentReady(displayID: 7, after: .milliseconds(500))
        await rig.timers.waitFor(.milliseconds(500))
        XCTAssertNotNil(rig.veil(on: host), "the content settles first")
        XCTAssertEqual(rig.state(), .onHost)
        rig.timers.fire(.milliseconds(500))
        await rig.settle()
        XCTAssertEqual(rig.state(), .dismissing)
        await rig.timers.waitFor(HoldRig.fadeWait)
        rig.timers.fire(HoldRig.fadeWait)
        await rig.settle()
        XCTAssertNil(rig.veil(on: host))
        XCTAssertNil(rig.state())
    }

    func testContentReadyWithoutASettleFadesAtOnce() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let host = HoldRig.screenLayer()
        rig.hold.adopt(into: host, displayID: 7)

        rig.hold.contentReady(displayID: 7)

        XCTAssertEqual(rig.state(), .dismissing)
    }

    func testReadinessOfAnotherDisplayOrOfASceneVeilReleasesNothing() async throws {
        let rig = HoldRig(displays: [7, 8])
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let scene = HoldRig.screenLayer()
        rig.announce(scene, display: 7, reason: "replace")

        rig.hold.contentReady(displayID: 7)
        rig.hold.contentReady(displayID: 8)

        XCTAssertEqual(rig.state(), .onScene, "only the scene's own first frame releases a scene's veil")
        XCTAssertNotNil(rig.veil(on: scene))
    }

    func testAHostTakesOverOnlyAVeilThatIsNotOnAWindowStillOnScreen() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        XCTAssertFalse(rig.hold.adopt(into: HoldRig.screenLayer(), displayID: 7), "no veil waits")
        await rig.hold.begin(displays: [7])
        let scene = HoldRig.screenLayer(), host = HoldRig.screenLayer()
        rig.live[7] = [scene]
        rig.announce(scene, display: 7, reason: "replace")

        XCTAssertFalse(rig.hold.adopt(into: host, displayID: 7), "the scene window it covers is still showing")
        XCTAssertNotNil(rig.veil(on: scene))
        XCTAssertNil(rig.veil(on: host))

        rig.live[7] = []
        XCTAssertTrue(rig.hold.adopt(into: host, displayID: 7), "the window it sat on has closed")
        XCTAssertNil(rig.veil(on: scene))
        XCTAssertNotNil(rig.veil(on: host))
        XCTAssertEqual(rig.state(), .onHost)
    }

    func testAHostWindowThatClosesTakesTheVeilItCarriesWithIt() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let host = HoldRig.screenLayer()
        rig.hold.adopt(into: host, displayID: 7)

        rig.hold.windowClosed(host, displayID: 7)

        XCTAssertNil(rig.veil(on: host), "the window is gone, so it is not faded on screen")
        XCTAssertNil(rig.state())
        XCTAssertTrue(rig.hold.activeDisplayIDs.isEmpty)
        XCTAssertTrue(rig.timers.pending.isEmpty, "no ceiling is left running for a picture nobody has")
    }

    func testAWindowThatClosesLeavesAVeilThatIsNotOnItAlone() async throws {
        let rig = HoldRig(displays: [7, 8])
        defer { rig.finish() }
        await rig.hold.begin(displays: [7, 8])
        let closing = HoldRig.screenLayer(), other = HoldRig.screenLayer(), scene = HoldRig.screenLayer()

        // Still waiting for a window: the closing one is not its successor.
        rig.hold.windowClosed(closing, displayID: 7)
        XCTAssertEqual(rig.state(7), .armed)

        // On a scene: the scene's own first frame ends it.
        rig.announce(scene, display: 7, reason: "replace")
        rig.hold.windowClosed(closing, displayID: 7)
        XCTAssertEqual(rig.state(7), .onScene)
        XCTAssertNotNil(rig.veil(on: scene))

        // On another host window, or on another display's window.
        rig.hold.adopt(into: other, displayID: 8)
        rig.hold.windowClosed(closing, displayID: 8)
        rig.hold.windowClosed(nil, displayID: 8)
        XCTAssertEqual(rig.state(8), .onHost)
        XCTAssertNotNil(rig.veil(on: other))

        // A display with no veil at all.
        rig.hold.windowClosed(closing, displayID: 9)
        XCTAssertNil(rig.state(9))
    }

    func testTheCeilingReleasesAVeilNothingElseEnds() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        let scene = HoldRig.screenLayer()
        rig.announce(scene, display: 7, reason: "replace")

        await rig.timers.waitFor(.seconds(30))
        rig.advance(.seconds(30))
        rig.timers.fire(.seconds(30))
        await rig.settle()

        XCTAssertEqual(rig.state(), .dismissing)
        await rig.timers.waitFor(HoldRig.fadeWait)
        rig.timers.fire(HoldRig.fadeWait)
        await rig.settle()
        XCTAssertNil(rig.veil(on: scene))
        XCTAssertNil(rig.state())
    }

    func testEachSignalRestartsTheCeiling() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        await rig.timers.waitFor(.seconds(30))

        rig.advance(.seconds(20))
        rig.announce(HoldRig.screenLayer(), display: 7, reason: "replace")
        await rig.settle()

        XCTAssertEqual(rig.timers.pending, [.seconds(30)], "the old timer is gone")
        XCTAssertEqual(rig.timers.requested.filter { $0 == .seconds(30) }.count, 2,
                       "and the new one counts 30 s from now, not the 10 s the first had left")
    }

    func testEngineSettledShortensAnUnclaimedStillToTheHostGrace() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        await rig.timers.waitFor(.seconds(30))

        rig.advance(.seconds(5))
        rig.hold.engineSettled(displays: [7])
        await rig.timers.waitFor(.seconds(8))

        XCTAssertEqual(rig.timers.pending, [.seconds(8)])
        rig.timers.fire(.seconds(8))
        await rig.settle()
        XCTAssertNil(rig.state(), "no window took it, and it was never on one, so it goes without a fade")
        XCTAssertTrue(rig.hold.activeDisplayIDs.isEmpty)
    }

    func testTheHostGraceNeverOutlastsTheCeilingThatIsCloser() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        await rig.timers.waitFor(.seconds(30))

        rig.advance(.seconds(27))
        rig.hold.engineSettled(displays: [7])
        await rig.settle()

        XCTAssertEqual(rig.timers.pending, [.seconds(30)], "three seconds of ceiling are left, which is less than the grace")
    }

    func testEngineSettledOnADisplayWithoutATicketDoesNothing() async throws {
        let rig = HoldRig()
        defer { rig.finish() }

        rig.hold.engineSettled(displays: [7, 99])

        XCTAssertTrue(rig.timers.pending.isEmpty)
        XCTAssertNil(rig.state())
    }

    func testCancelReleasesAStillThatWasNeverShownAtOnceAndFadesOneThatWas() async throws {
        let rig = HoldRig(displays: [7, 8])
        defer { rig.finish() }
        await rig.hold.begin(displays: [7, 8])
        let scene = HoldRig.screenLayer()
        rig.announce(scene, display: 8, reason: "replace")

        rig.hold.cancel(displays: [7, 8])

        XCTAssertNil(rig.state(7), "a still that is on no window has nothing to fade")
        XCTAssertEqual(rig.state(8), .dismissing)
        await rig.timers.waitFor(HoldRig.fadeWait)
        rig.timers.fire(HoldRig.fadeWait)
        await rig.settle()
        XCTAssertNil(rig.veil(on: scene))
        XCTAssertNil(rig.state(8))
    }

    func testCancelWhileAStillIsOnItsWayLeavesNoTicket() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        rig.answer = { _ in nil }

        let begun = Task { await rig.hold.begin(displays: [7]) }
        await rig.timers.waitFor(.milliseconds(250))
        rig.hold.cancel(displays: [7])
        await begun.value

        XCTAssertNil(rig.state())
        XCTAssertTrue(rig.hold.activeDisplayIDs.isEmpty)
    }

    func testStopRemovesEveryVeilAndIgnoresLaterAnnouncementsAndSwitches() async throws {
        let rig = HoldRig(displays: [7, 8])
        defer { rig.finish() }
        await rig.hold.begin(displays: [7, 8])
        let scene = HoldRig.screenLayer(), host = HoldRig.screenLayer()
        rig.announce(scene, display: 7, reason: "replace")
        rig.hold.adopt(into: host, displayID: 8)

        rig.hold.stop()

        XCTAssertNil(rig.veil(on: scene))
        XCTAssertNil(rig.veil(on: host))
        XCTAssertTrue(rig.hold.activeDisplayIDs.isEmpty)
        let late = HoldRig.screenLayer()
        rig.announce(late, display: 7, reason: "replace")
        XCTAssertNil(rig.veil(on: late))
        let asked = rig.requests.count
        await rig.hold.begin(displays: [7])
        XCTAssertEqual(rig.requests.count, asked, "a stopped hold asks for nothing")
    }

    func testStopWhileAStillIsOnItsWayLeavesNoTicket() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        rig.answer = { _ in nil }

        let begun = Task { await rig.hold.begin(displays: [7]) }
        await rig.timers.waitFor(.milliseconds(250))
        rig.hold.stop()
        await begun.value

        XCTAssertNil(rig.state())
    }

    func testReduceMotionRemovesTheVeilWithoutFading() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        rig.reduceMotion = true
        await rig.hold.begin(displays: [7])
        let scene = HoldRig.screenLayer()
        rig.announce(scene, display: 7, reason: "replace")

        rig.hold.engineSettled(displays: [7])

        XCTAssertNil(rig.veil(on: scene), "no fade to wait for")
        XCTAssertNil(rig.state())
        XCTAssertFalse(rig.timers.pending.contains(HoldRig.fadeWait))
    }

    func testAHiddenDisplayLosesItsVeilAtOnceAndSaysSo() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        await rig.hold.begin(displays: [7])
        XCTAssertTrue(rig.hold.isHolding(7))
        let scene = HoldRig.screenLayer()
        rig.announce(scene, display: 7, reason: "replace")
        rig.concealed = [7]

        rig.hold.engineSettled(displays: [7])

        XCTAssertNil(rig.veil(on: scene), "nobody sees the veil, so it does not fade over the new picture")
        XCTAssertFalse(rig.hold.isHolding(7))
        XCTAssertEqual(rig.released, [7])
    }

    func testAStillThatNeverCameIsReportedAsReleased() async throws {
        let rig = HoldRig()
        defer { rig.finish() }
        rig.answer = { _ in HoldRig.frame(bytes: 15) }

        await rig.hold.begin(displays: [7])

        XCTAssertFalse(rig.hold.isHolding(7))
        XCTAssertEqual(rig.released, [7], "whoever waits for the hold is not left waiting")
    }

    func testDisplaysAreHeldAndReleasedIndependently() async throws {
        let rig = HoldRig(displays: [7, 8])
        defer { rig.finish() }

        await rig.hold.begin(displays: [7, 8, 7])

        XCTAssertEqual(rig.requests.count, 2, "once per distinct display")
        XCTAssertEqual(rig.hold.activeDisplayIDs, [7, 8])
        let first = HoldRig.screenLayer(), second = HoldRig.screenLayer()
        rig.announce(first, display: 7, reason: "replace")
        rig.announce(second, display: 8, reason: "replace")
        rig.hold.engineSettled(displays: [7])

        XCTAssertEqual(rig.state(7), .dismissing)
        XCTAssertEqual(rig.state(8), .onScene, "the other display's switch is still loading")
        XCTAssertNotNil(rig.veil(on: second))
    }
}
