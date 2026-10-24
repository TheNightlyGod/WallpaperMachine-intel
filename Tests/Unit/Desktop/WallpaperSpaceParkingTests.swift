import XCTest
@testable import WallpaperMachine

/// Which wallpapers each display keeps paused for its other desktops, and when it lets go of them.
/// The renderer and the hosts are recorders; nothing is loaded.
@MainActor
final class WallpaperSpaceParkingTests: XCTestCase {
    @MainActor
    private final class Rig {
        var plan: WallpaperSpaceParking.Plan = [:]
        var sent: [(UInt32, [String])] = []
        var hostPlans: [WallpaperSpaceParking.Plan] = []
        var failing = false
        let center = NotificationCenter()
        private(set) var parking: WallpaperSpaceParking!

        init() {
            parking = WallpaperSpaceParking(
                plan: { [unowned self] in self.plan },
                send: { [unowned self] display, wallpapers in
                    if self.failing { throw CancellationError() }
                    self.sent.append((display, wallpapers))
                },
                hosts: { [unowned self] in self.hostPlans.append($0) },
                footprint: { 1_000 },
                center: center)
        }

        /// Lets the sends in flight finish, for an assertion that nothing more is sent.
        func settle() async {
            for _ in 0..<50 { await Task.yield() }
        }

        /// Waits, two seconds at most, until `count` lists have been sent in all.
        func sends(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
            let deadline = ContinuousClock.now + .seconds(2)
            while sent.count < count {
                guard ContinuousClock.now < deadline else {
                    XCTFail("\(sent.count) of \(count) lists sent", file: file, line: line)
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        var sentLists: [String] { sent.map { "\($0.0): \($0.1.joined(separator: ","))" } }
    }

    func testEachDisplayIsToldTheWallpapersItsDesktopsAreSetTo() async {
        let rig = Rig()
        rig.plan = [1: ["aurora", "basalt"], 2: ["cobalt"], 3: []]
        rig.parking.start()
        await rig.sends(2)

        XCTAssertEqual(rig.sentLists, ["1: aurora,basalt", "2: cobalt"], "a display with nothing to keep is not told")
        XCTAssertEqual(rig.hostPlans.last, [1: ["aurora", "basalt"], 2: ["cobalt"]])

        rig.plan = [1: ["aurora"], 2: ["cobalt"]]
        rig.parking.update()
        await rig.sends(3)
        XCTAssertEqual(rig.sentLists.last, "1: aurora", "only what changed is sent")
        XCTAssertEqual(rig.sent.count, 3)

        rig.parking.update()
        await rig.settle()
        XCTAssertEqual(rig.sent.count, 3, "nothing changed, nothing is sent")
    }

    func testMemoryPressureLetsGoOfEverythingUntilItIsOver() async {
        let rig = Rig()
        rig.plan = [1: ["aurora", "basalt"]]
        rig.parking.start()
        await rig.sends(1)

        rig.parking.setUnderPressure(true)
        await rig.sends(2)
        XCTAssertEqual(rig.sentLists.last, "1: ", "an empty list frees what the display keeps")
        XCTAssertEqual(rig.hostPlans.last, [:])

        rig.parking.update()
        await rig.settle()
        XCTAssertEqual(rig.sentLists.last, "1: ", "the choices do not bring them back while it lasts")

        rig.parking.setUnderPressure(false)
        await rig.sends(3)
        XCTAssertEqual(rig.sentLists.last, "1: aurora,basalt")
    }

    func testUnloadedWallpapersKeepNothing() async {
        let rig = Rig()
        rig.plan = [1: ["aurora"]]
        rig.parking.start()
        await rig.sends(1)

        rig.parking.setUnloaded(true)
        await rig.sends(2)
        XCTAssertEqual(rig.sentLists.last, "1: ")
        XCTAssertEqual(rig.hostPlans.last, [:])

        rig.parking.setUnloaded(false)
        await rig.sends(3)
        XCTAssertEqual(rig.sentLists.last, "1: aurora")
    }

    func testADesktopChangeIsPickedUpAndStopLetsGo() async {
        let rig = Rig()
        rig.parking.start()
        rig.plan = [1: ["aurora"]]
        rig.center.post(name: WallpaperSpaceMonitor.didChangeNotification, object: nil)
        await rig.sends(1)
        XCTAssertEqual(rig.sentLists, ["1: aurora"])

        rig.parking.stop()
        await rig.sends(2)
        XCTAssertEqual(rig.sentLists.last, "1: ")
        XCTAssertEqual(rig.hostPlans.last, [:])
    }

    func testAListTheRendererRefusedIsSentAgainOnTheNextUpdate() async {
        let rig = Rig()
        rig.failing = true
        rig.plan = [1: ["aurora"]]
        rig.parking.start()
        await rig.settle()
        XCTAssertTrue(rig.sent.isEmpty)

        rig.failing = false
        rig.parking.update()
        await rig.sends(1)
        XCTAssertEqual(rig.sentLists, ["1: aurora"])
    }
}
