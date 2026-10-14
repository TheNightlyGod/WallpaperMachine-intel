import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperDisplayTransferTests: XCTestCase {
    private var state: WallpaperDisplayTransfer.Snapshot!
    private var applied: [String] = []
    override func setUp() {
        super.setUp()
        state = .init(displays: [
            .init(id: "primary", title: "Main", eligible: true, wallpaperID: "a"),
            .init(id: "identity:secondary", title: "Second", eligible: true, wallpaperID: "b"),
        ], wallpapers: ["a", "b", "c"])
        applied = []
    }
    private func set(_ id: String?, on display: String) {
        if let index = state.displays.firstIndex(where: { $0.id == display }) { state.displays[index].wallpaperID = id }
    }
    private func run(_ request: WallpaperDisplayTransfer.Request,
                     prepare: @escaping @MainActor (Set<String>) async throws -> Void = { _ in },
                     action: (@MainActor (String, String) async throws -> Void)? = nil) async throws {
        _ = try await WallpaperDisplayTransfer.execute(request, snapshot: { self.state }, prepare: prepare,
            apply: { id, display in
                self.applied.append("\(display)=\(id)")
                if let action { try await action(id, display) }
                else { self.set(id, on: display) }
            }, clear: { _, display in self.set(nil, on: display) })
    }
    private var assignments: [String?] { state.displays.map(\.wallpaperID) }

    func testCaptureKeepsStableDisplayIdentityAndExcludesEmptyAndMirroredDisplays() throws {
        state.displays += [.init(id: "empty", title: "Empty", eligible: true, wallpaperID: nil),
                           .init(id: "mirror", title: "Mirror", eligible: false, wallpaperID: "a")]
        let values = try WallpaperDisplayTransfer.capture(state)
        XCTAssertEqual(values.map(\.displayID), ["primary", "identity:secondary"])
        XCTAssertEqual(values.map(\.wallpaperID), ["a", "b"])
    }

    func testARequestIsAChoiceForEveryDisplayItGivesAWallpaperTo() {
        let layout = [WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "c"),
                      WallpaperDisplayAssignment(displayID: "identity:secondary", displayTitle: "Second", wallpaperID: "a")]
        XCTAssertEqual(WallpaperDisplayTransfer.Request.layout(layout).displayIDs(in: state), ["primary", "identity:secondary"])
        XCTAssertEqual(WallpaperDisplayTransfer.Request.copy(from: "primary", to: "identity:secondary").displayIDs(in: state),
                       ["identity:secondary"], "A copy leaves its source as it was")
        XCTAssertEqual(WallpaperDisplayTransfer.Request.swap("primary", "identity:secondary").displayIDs(in: state),
                       ["primary", "identity:secondary"])
        XCTAssertEqual(WallpaperDisplayTransfer.Request.everywhere(wallpaperID: "c").displayIDs(in: state),
                       ["primary", "identity:secondary"])
    }

    /// Three displays listed with the main one in the middle, one disabled and one mirrored.
    private func addDisplays() {
        state.displays = [
            .init(id: "identity:secondary", title: "Second", eligible: true, wallpaperID: "b"),
            .init(id: "off", title: "Off", eligible: false, wallpaperID: nil),
            .init(id: "primary", title: "Main", eligible: true, wallpaperID: "a"),
            .init(id: "mirror", title: "Mirror", eligible: false, wallpaperID: "a"),
            .init(id: "identity:third", title: "Third", eligible: true, wallpaperID: nil),
        ]
    }

    func testEverywhereExpandsOverEligibleDisplaysMainDisplayFirst() throws {
        addDisplays()
        let request = WallpaperDisplayTransfer.Request.everywhere(wallpaperID: "c")
        let plan = try WallpaperDisplayTransfer.plan(request, in: state)
        XCTAssertEqual(plan.map(\.displayID), ["primary", "identity:secondary", "identity:third"],
                       "the main display first, then the rest in snapshot order, without disabled or mirrored ones")
        XCTAssertEqual(plan.map(\.wallpaperID), ["c", "c", "c"])
        XCTAssertEqual(plan.map(\.displayTitle), ["Main", "Second", "Third"])
        XCTAssertEqual(request.displayIDs(in: state), plan.map(\.displayID))
    }

    func testEverywhereIsRefusedWithoutAnEligibleDisplayOrAnUnavailableWallpaper() {
        let request = WallpaperDisplayTransfer.Request.everywhere(wallpaperID: "c")
        for index in state.displays.indices { state.displays[index].eligible = false }
        XCTAssertThrowsError(try WallpaperDisplayTransfer.plan(request, in: state)) { error in
            guard case WallpaperDisplayLayoutError.noEligibleDisplays = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertFalse(WallpaperDisplayLayoutError.noEligibleDisplays.localizedDescription.isEmpty)
        XCTAssertEqual(request.displayIDs(in: state), [])

        for index in state.displays.indices { state.displays[index].eligible = true }
        XCTAssertThrowsError(try WallpaperDisplayTransfer.plan(.everywhere(wallpaperID: "missing"), in: state)) { error in
            guard case WallpaperDisplayLayoutError.unavailableWallpaper("missing") = error else { return XCTFail("unexpected \(error)") }
        }
        state.reliable = false
        XCTAssertThrowsError(try WallpaperDisplayTransfer.plan(request, in: state), "a snapshot that may be stale is not planned from") { error in
            guard case WallpaperDisplayLayoutError.changed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testEverywhereAppliesInPlanOrderAndSkipsADisplayThatAlreadyShowsTheWallpaper() async throws {
        addDisplays()
        set("c", on: "identity:secondary")
        try await run(.everywhere(wallpaperID: "c"))
        XCTAssertEqual(applied, ["primary=c", "identity:third=c"], "the second display already showed c, so it is not written")
        XCTAssertEqual(state.displays.filter(\.eligible).map(\.wallpaperID), ["c", "c", "c"])
        XCTAssertEqual(state.displays.first { $0.id == "mirror" }?.wallpaperID, "a", "a mirror is left alone")
    }

    /// A wallpaper held back after a crash keeps its display assignment, so its display reads as
    /// showing it. Naming the wallpaper for every display must still reach that display, or
    /// nothing would lift the hold.
    func testEverywhereAppliesAgainOnADisplayShowingAHeldWallpaperUntilTheHoldIsLifted() async throws {
        addDisplays()
        set("c", on: "primary")
        state.held = ["c"]
        try await run(.everywhere(wallpaperID: "c"), action: { id, display in
            self.set(id, on: display)
            self.state.held = []
        })
        XCTAssertEqual(applied, ["primary=c", "identity:secondary=c", "identity:third=c"],
                       "the held display is applied again; once the hold is lifted the others are written as usual")

        applied = []
        set("a", on: "identity:secondary")
        state.held = []
        try await run(.everywhere(wallpaperID: "c"))
        XCTAssertEqual(applied, ["identity:secondary=c"], "without a hold a display showing the wallpaper is skipped")
    }

    func testEverywhereReappliesEveryDisplayShowingAHeldWallpaperWhileTheHoldStays() async throws {
        addDisplays()
        for display in ["primary", "identity:secondary", "identity:third"] { set("c", on: display) }
        state.held = ["c"]
        try await run(.everywhere(wallpaperID: "c"), action: { _, _ in })
        XCTAssertEqual(applied, ["primary=c", "identity:secondary=c", "identity:third=c"],
                       "a hold the engine did not lift is not assumed lifted")
    }

    func testOnlyNamingOneWallpaperForEveryDisplayReleasesAHold() async throws {
        let layout = [WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "c")]
        XCTAssertTrue(WallpaperDisplayTransfer.Request.everywhere(wallpaperID: "c").releasesHold)
        XCTAssertFalse(WallpaperDisplayTransfer.Request.layout(layout).releasesHold)
        XCTAssertFalse(WallpaperDisplayTransfer.Request.copy(from: "primary", to: "identity:secondary").releasesHold)
        XCTAssertFalse(WallpaperDisplayTransfer.Request.swap("primary", "identity:secondary").releasesHold)

        set("c", on: "primary")
        state.held = ["c"]
        try await run(.layout(layout))
        XCTAssertTrue(applied.isEmpty, "a layout that restores what is already assigned leaves a held display alone")
    }

    func testEverywhereRefusesADisplaySetThatChangedWhilePreparingBeforeAnyWrite() async {
        addDisplays()
        do {
            try await run(.everywhere(wallpaperID: "c"), prepare: { _ in
                self.state.displays[0].eligible = false
            })
            XCTFail("planned from a stale display set")
        } catch {
            guard case WallpaperDisplayLayoutError.changed = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(state.displays.map(\.wallpaperID), ["b", nil, "a", "a", nil])
    }

    func testAFailureOnTheLastDisplayPutsEveryOtherDisplayBackIncludingAnEmptyOne() async {
        addDisplays()
        do {
            try await run(.everywhere(wallpaperID: "c"), action: { id, display in
                self.set(id, on: display)
                if display == "identity:third" { throw CocoaError(.fileReadUnknown) }
            })
            XCTFail("failure was hidden")
        } catch {
            guard case WallpaperDisplayLayoutError.restored = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(state.displays.map(\.wallpaperID), ["b", nil, "a", "a", nil])
        XCTAssertEqual(applied, ["primary=c", "identity:secondary=c", "identity:third=c", "identity:secondary=b", "primary=a"],
                       "the displays are put back in reverse, and the one that began empty is cleared rather than applied")
    }

    func testCopyChangesOnlyTheDestinationAndSwapUsesTheOriginalAssignments() async throws {
        try await run(.copy(from: "primary", to: "identity:secondary"))
        XCTAssertEqual(assignments, ["a", "a"])
        set("b", on: "identity:secondary")
        applied = []
        try await run(.swap("primary", "identity:secondary"))
        XCTAssertEqual(assignments, ["b", "a"])
        XCTAssertEqual(applied, ["identity:secondary=a", "primary=b"])
    }

    func testEveryDisplayAndWallpaperIsValidatedBeforeAnyWrite() async throws {
        let layout = try WallpaperDisplayTransfer.capture(state)
        state.displays[1].eligible = false
        do { try await run(.layout(layout)); XCTFail("accepted disabled screen") } catch {}
        XCTAssertTrue(applied.isEmpty)
        state.displays[1].eligible = true
        state.wallpapers.remove("b")
        do { try await run(.layout(layout)); XCTFail("accepted missing wallpaper") } catch {}
        XCTAssertTrue(applied.isEmpty)
        do { try await run(.copy(from: "primary", to: "primary")); XCTFail("accepted same screen") } catch {}
    }

    func testChangesWhilePreparingAbortBeforeAnyWrite() async {
        do {
            try await run(.swap("primary", "identity:secondary"), prepare: { _ in self.set("c", on: "primary") })
            XCTFail("used a stale source")
        } catch {}
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(assignments, ["c", "b"])
    }

    func testSecondStepFailureRestoresBothAssignmentsIncludingAMutatedFailingStep() async {
        do {
            try await run(.swap("primary", "identity:secondary"), action: { id, display in
                self.set(id, on: display)
                if id == "b", display == "primary" { throw CocoaError(.fileReadUnknown) }
            })
            XCTFail("failure was hidden")
        } catch {
            guard case WallpaperDisplayLayoutError.restored = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(assignments, ["a", "b"])
    }

    func testFailedCopyToAnEmptyDisplayRestoresItsEmptyAssignment() async {
        set(nil, on: "identity:secondary")
        do {
            try await run(.copy(from: "primary", to: "identity:secondary"), action: { id, display in
                self.set(id, on: display); throw CocoaError(.fileReadUnknown)
            })
            XCTFail("failure was hidden")
        } catch {}
        XCTAssertEqual(assignments, ["a", nil])
    }

    func testRecoveryPreservesAnExternalChoiceAndReportsIncompleteRestoration() async {
        do {
            try await run(.swap("primary", "identity:secondary"), action: { id, display in
                if display == "primary" {
                    self.set("c", on: "identity:secondary")
                    throw CocoaError(.fileReadUnknown)
                }
                self.set(id, on: display)
            })
            XCTFail("failure was hidden")
        } catch {
            guard case WallpaperDisplayLayoutError.incomplete(let displays, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(displays.contains("Second"))
        }
        XCTAssertEqual(assignments, ["a", "c"])
        XCTAssertFalse(applied.contains("identity:secondary=b"))
    }

    func testCancellationStillRunsRecoveryOutsideTheCancelledTask() async {
        let task = Task { @MainActor in
            try await run(.swap("primary", "identity:secondary"), action: { id, display in
                try Task.checkCancellation()
                self.set(id, on: display)
                if id == "a", display == "identity:secondary" { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { try await task.value; XCTFail("cancellation was ignored") } catch {}
        XCTAssertEqual(assignments, ["a", "b"])
    }
}
