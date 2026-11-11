import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperSpaceReplicasTests: XCTestCase {
    @MainActor private final class Surface: WallpaperSpaceReplicaSurface {
        let number: Int
        var image: CGImage?
        var closed = false
        var presentations = 0
        var placedBeforePresentation = false
        let mover: Mover
        init(_ number: Int, mover: Mover) { self.number = number; self.mover = mover }
        func setImage(_ image: CGImage, frame: CGRect) { self.image = image }
        func present(below window: Int) {
            presentations += 1
            placedBeforePresentation = mover.membership[number]?.count == 1
        }
        func close() { closed = true; image = nil }
    }

    @MainActor private final class Mover: WallpaperSpaceWindowMoving {
        var membership: [Int: [UInt64]] = [:]
        var refuses = false
        func spaces(ofWindow number: Int) -> [UInt64]? { membership[number] ?? [] }
        func move(windows: [Int], toSpace space: UInt64) {
            if !refuses { for window in windows { membership[window] = [space] } }
        }
        func place(window: Int, onSpaces spaces: [UInt64]) -> Bool { false }
    }

    @MainActor private final class Rig {
        let mover = Mover()
        var plan: WallpaperSpaceReplicas.Plan = [:]
        var sources: [WallpaperSpaceReplicas.Source] = []
        var surfaces: [Surface] = []
        var captures = 0
        var capture: ((WallpaperSpaceReplicas.Source) async -> CGImage?)?
        var pixels = WallpaperSpaceReplicasTests.image(16)
        lazy var replicas = WallpaperSpaceReplicas(
            plan: { [unowned self] in plan }, sources: { [unowned self] in sources }, mover: mover,
            capture: { [unowned self] source in
                captures += 1
                if let capture { return await capture(source) }
                return pixels
            }, makeWindow: { [unowned self] _ in
                let surface = Surface(surfaces.count + 100, mover: mover)
                surfaces.append(surface)
                return surface
            }, maximumImageBytes: 4_096)

        func add(_ wallpaper: String, spaces: Set<UInt64>, display: UInt32 = 1) {
            let key = WallpaperSpaceReplicas.Key(display: display, wallpaper: wallpaper)
            plan[key] = spaces
            sources.append(.init(key: key, window: sources.count + 1, layer: CALayer(),
                                 frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                 revision: 0, parked: true, visit: nil))
        }
    }

    private static func image(_ edge: Int) -> CGImage {
        DesktopPosterFrame(pixels: Data(repeating: 255, count: edge * edge * 4),
                           width: edge, height: edge, bgra: false).cgImage()!
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Replica work did not finish")
    }

    func testABABHasAnIndependentPictureOnEveryDesktopBeforeArrival() async throws {
        let rig = Rig()
        rig.add("A", spaces: [1, 3]); rig.add("B", spaces: [2, 4])
        rig.capture = { Self.image($0.key.wallpaper == "A" ? 16 : 8) }
        rig.replicas.update()
        defer { rig.replicas.stop() }
        try await wait { rig.surfaces.count == 4 }
        XCTAssertEqual(Set(rig.mover.membership.values.flatMap { $0 }), [1, 2, 3, 4])
        XCTAssertTrue(rig.surfaces.allSatisfy { $0.placedBeforePresentation && $0.image != nil })
        XCTAssertEqual(rig.captures, 2, "one frame per wallpaper, shared by its desktop windows")
        XCTAssertTrue(rig.surfaces[0].image === rig.surfaces[1].image)
        for surface in rig.surfaces {
            let space = try XCTUnwrap(rig.mover.membership[surface.number]?.first)
            XCTAssertEqual(surface.image?.width, [1, 3].contains(space) ? 16 : 8)
        }
        for _ in 0..<20 { rig.replicas.update() }
        XCTAssertEqual(rig.captures, 2, "no polling, repeated captures or extra renderers while idle")
    }

    func testABCDNeedsNoReplicas() async throws {
        let rig = Rig()
        for (index, name) in ["A", "B", "C", "D"].enumerated() { rig.add(name, spaces: [UInt64(index + 1)]) }
        rig.replicas.update()
        await Task.yield()
        XCTAssertEqual(rig.captures, 0)
        XCTAssertTrue(rig.surfaces.isEmpty)
        rig.replicas.stop()
    }

    func testParkingRefreshesTheSharedPictureWithoutRecreatingWindows() async throws {
        let rig = Rig()
        rig.add("A", spaces: [1, 3])
        rig.sources[0].parked = false
        rig.replicas.update()
        defer { rig.replicas.stop() }
        try await wait { rig.surfaces.count == 2 }
        let earlier = rig.surfaces[0].image
        rig.pixels = Self.image(8)
        rig.sources[0].parked = true
        rig.replicas.update()
        try await wait { rig.surfaces[0].image !== earlier }
        XCTAssertEqual(rig.surfaces.count, 2)
        XCTAssertTrue(rig.surfaces[0].image === rig.surfaces[1].image)
        XCTAssertEqual(rig.captures, 2)
    }

    func testChangedChoicesAndMemoryPressureReleaseWindowsAndFrames() async throws {
        let rig = Rig()
        rig.add("A", spaces: [1, 3]); rig.add("B", spaces: [2, 4])
        rig.replicas.update()
        try await wait { rig.surfaces.count == 4 }
        rig.plan[.init(display: 1, wallpaper: "A")] = [1]
        rig.replicas.update()
        XCTAssertEqual(rig.surfaces.filter(\.closed).count, 2)
        rig.plan = [:] // The parking owner empties its plan under pressure or unloading.
        rig.replicas.update()
        XCTAssertTrue(rig.surfaces.allSatisfy { $0.closed && $0.image == nil })
        XCTAssertEqual(rig.replicas.retainedImageBytes, 0)
        rig.replicas.stop()
    }

    func testLateCaptureCannotRestoreARemovedWallpaper() async throws {
        let rig = Rig()
        rig.add("A", spaces: [1, 3])
        var finish: CheckedContinuation<CGImage?, Never>?
        rig.capture = { _ in await withCheckedContinuation { finish = $0 } }
        rig.replicas.update()
        try await wait { finish != nil }
        rig.plan = [:]
        rig.replicas.update()
        finish?.resume(returning: Self.image(16))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(rig.surfaces.isEmpty)
        XCTAssertEqual(rig.replicas.retainedImageBytes, 0)
        rig.replicas.stop()
    }

    func testImagesStayWithinTheSharedBudgetAcrossDisplays() async throws {
        let rig = Rig()
        rig.pixels = Self.image(128)
        rig.add("A", spaces: [1, 3]); rig.add("A", spaces: [2, 4], display: 2)
        rig.replicas.update()
        defer { rig.replicas.stop() }
        try await wait { rig.surfaces.count == 4 }
        XCTAssertLessThanOrEqual(rig.replicas.retainedImageBytes, 4_096)
        XCTAssertTrue(rig.surfaces.allSatisfy { ($0.image?.width ?? 0) > 0 })
        XCTAssertEqual(rig.captures, 2, "different displays keep their own framing")
    }

    func testARefusedSpaceMoveNeverShowsTheReplicaOnTheWrongDesktop() async throws {
        let rig = Rig()
        rig.add("A", spaces: [1, 3]); rig.mover.refuses = true
        rig.replicas.update()
        defer { rig.replicas.stop() }
        try await wait { rig.surfaces.count == 2 }
        XCTAssertTrue(rig.surfaces.allSatisfy { $0.closed && $0.presentations == 0 })
    }

    func testAChangedSourceDiscardsTheOldReadAndCapturesItsNewRevision() async throws {
        let rig = Rig()
        rig.add("A", spaces: [1, 3])
        var finish: CheckedContinuation<CGImage?, Never>?
        rig.capture = { source in
            if source.revision == 0 { return await withCheckedContinuation { finish = $0 } }
            return Self.image(8)
        }
        rig.replicas.update()
        defer { rig.replicas.stop() }
        try await wait { finish != nil }
        rig.sources[0].revision = 1
        rig.replicas.update()
        finish?.resume(returning: Self.image(16))
        try await wait { rig.surfaces.count == 2 }
        XCTAssertTrue(rig.surfaces.allSatisfy { $0.image?.width == 8 })
        XCTAssertEqual(rig.captures, 2)
    }

    func testAReplicaGrabIgnoresLateAnswersFromOtherRequests() async throws {
        let center = NotificationCenter(), layer = CALayer()
        let grab = DesktopPosterGrab(center: center, contextPrefix: "space-replica", acceptsOtherRequests: false)
        let observer = center.addObserver(forName: DesktopPosterNotification.request, object: layer, queue: .main) { note in
            MainActor.assumeIsolated {
                DesktopPosterFrame(pixels: Data(repeating: 0, count: 16), width: 2, height: 2, bgra: false)
                    .publish(for: layer, to: center, context: "space-replica:obsolete")
                DesktopPosterFrame(pixels: Data(repeating: 255, count: 4), width: 1, height: 1, bgra: false)
                    .publish(for: layer, to: center, context: DesktopPosterNotification.context(in: note.userInfo))
            }
        }
        defer { center.removeObserver(observer) }
        let frame = await grab.run(on: layer, timeout: .seconds(1), sleep: { try await Task.sleep(for: $0) })
        XCTAssertEqual(frame?.width, 1)
    }

    func testCancelledGrabDoesNotIssueAnotherCapture() async {
        let center = NotificationCenter()
        let grab = DesktopPosterGrab(center: center)
        var requests = 0
        let observer = center.addObserver(forName: DesktopPosterNotification.request, object: nil, queue: .main) { _ in
            requests += 1
        }
        defer { center.removeObserver(observer) }
        grab.cancel()
        let frame = await grab.run(on: CALayer(), timeout: .seconds(1), sleep: { try await Task.sleep(for: $0) })
        XCTAssertNil(frame)
        XCTAssertEqual(requests, 0)
    }
}
