import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperSpaceMonitorTests: XCTestCase {
    private func group(_ display: String = "uuid-screen", current: String = "a", order: [String] = ["a", "b"]) -> [String: Any] {
        ["Display Identifier": display, "Current Space": ["uuid": current],
         "Spaces": order.enumerated().map { ["uuid": $0.element, "type": 0, "ManagedSpaceID": $0.offset + 1] as [String: Any] }]
    }

    func testTopologyUsesUUIDsAndKeepsEachDisplayIndependent() throws {
        let result = try XCTUnwrap(WallpaperSpaceMonitor.decode(groups: [group(), group("external", current: "c", order: ["c"])], displays: ["1": "UUID-SCREEN", "2": "external"]))
        XCTAssertEqual(result["1"]?.spaces.map(\.id), ["a", "b"])
        XCTAssertEqual(result["1"]?.current, "a")
        XCTAssertEqual(result["2"]?.current, "c")
        XCTAssertEqual(result["1"]?.currentManagedID, 1, "the window server's number for the current desktop")
        XCTAssertEqual(result["1"]?.spaces.map(\.managedID), [1, 2], "and for every other desktop, to keep a window on")
        let reordered = try XCTUnwrap(WallpaperSpaceMonitor.decode(groups: [group(order: ["b", "a"])], displays: ["1": "uuid-screen"]))
        XCTAssertEqual(reordered["1"]?.current, "a")
        XCTAssertEqual(reordered["1"]?.spaces.first(where: { $0.id == "a" })?.number, 2)
    }

    func testSharedMainGroupAndFullscreenCurrentSpace() throws {
        var input = group("Main")
        input["Spaces"] = [["uuid": "a", "type": 0, "ManagedSpaceID": 1], ["type": 4, "ManagedSpaceID": 2]]
        input["Current Space"] = ["ManagedSpaceID": 2]
        let result = try XCTUnwrap(WallpaperSpaceMonitor.decode(groups: [input], displays: ["1": "first", "2": "second"]))
        XCTAssertEqual(Set(result.keys), ["1", "2"])
        XCTAssertEqual(result["1"]?.spaces.map(\.id), ["a"])
        XCTAssertNil(result["1"]?.current)
        XCTAssertNil(result["1"]?.currentManagedID, "no desktop to move a window to on a full-screen Space")
    }

    func testMalformedAndAmbiguousGroupsFailWithoutInventingASpace() {
        var input = group()
        input["Current Space"] = ["uuid": "unknown"]
        XCTAssertNil(WallpaperSpaceMonitor.decode(groups: [input], displays: ["1": "uuid-screen"]))
        input = group()
        input["Spaces"] = [["uuid": "a", "type": false]]
        XCTAssertNil(WallpaperSpaceMonitor.decode(groups: [input], displays: ["1": "uuid-screen"]))
        XCTAssertNil(WallpaperSpaceMonitor.decode(groups: [group(), group()], displays: ["1": "uuid-screen"]))
        XCTAssertNil(WallpaperSpaceMonitor.decode(groups: [group(order: ["a", "a"])], displays: ["1": "uuid-screen"]))
    }

    func testVisitsPersistAcrossRelaunchAndChangeOnlyWhenTheDesktopChanges() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        var value: [String: WallpaperDisplaySpaces]? = ["1": .init(displayUUID: "screen", spaces: [.init(id: "a", number: 1), .init(id: "b", number: 2)], current: "a")]
        let monitor = WallpaperSpaceMonitor(defaults: defaults, provider: { value }); defer { monitor.stop() }
        monitor.refresh()
        let before = try XCTUnwrap(monitor.visit(for: "1"))
        XCTAssertEqual(before.firstSpaceID, "a")
        value?["1"]?.spaces.reverse(); monitor.refresh()
        let first = try XCTUnwrap(monitor.visit(for: "1"))
        XCTAssertEqual([first.spaceID, first.token], [before.spaceID, before.token], "reordering is not a different desktop visit")
        XCTAssertEqual(first.firstSpaceID, "b", "Desktop 1 is whichever desktop comes first now")
        let relaunched = WallpaperSpaceMonitor(defaults: defaults, provider: { value }); defer { relaunched.stop() }
        relaunched.refresh()
        XCTAssertEqual(relaunched.visit(for: "1"), first)
        value?["1"]?.current = nil; relaunched.refresh()
        XCTAssertNil(relaunched.visit(for: "1"))
        value?["1"]?.current = "a"; relaunched.refresh()
        XCTAssertEqual(relaunched.visit(for: "1"), first, "fullscreen return is not a different desktop visit")
        value?["1"]?.current = "b"; relaunched.refresh()
        value?["1"]?.current = "a"; relaunched.refresh()
        XCTAssertNotEqual(relaunched.visit(for: "1")?.token, first.token)
        value = nil; relaunched.refresh()
        XCTAssertFalse(relaunched.available)
        XCTAssertNil(relaunched.visit(for: "1"))
    }

    func testSpaceAndScreenNotificationsRefreshAndStopUnsubscribes() {
        let workspace = NotificationCenter(), display = NotificationCenter()
        var reads = 0
        var displays = DisplayConfiguration(displays: [])
        let monitor = WallpaperSpaceMonitor(provider: { reads += 1; return [:] }, workspaceCenter: workspace,
                                            displayCenter: display, displayConfiguration: { displays })
        monitor.start()
        XCTAssertEqual(reads, 1)
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        displays.displays.append(.init(id: 2, frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), scale: 1, refreshRate: 60))
        display.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(reads, 3)
        monitor.stop()
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(reads, 3)
    }

    /// Every read is a window-server round trip, and an XDR display posts a screen change
    /// for each frame of an EDR headroom ramp with every display where it was.
    func testOnlyAScreenChangeThatMovesADisplayRereadsTheSpaces() {
        let display = NotificationCenter()
        var configuration = DisplayConfiguration(displays: [])
        var reads = 0
        let monitor = WallpaperSpaceMonitor(provider: { reads += 1; return [:] }, displayCenter: display,
                                            displayConfiguration: { configuration })
        monitor.start(); defer { monitor.stop() }
        XCTAssertEqual(reads, 1)
        for _ in 0..<240 { display.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) }
        XCTAssertEqual(reads, 1)
        configuration.displays.append(.init(id: 2, frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), scale: 1, refreshRate: 60))
        display.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(reads, 2)
    }
}
