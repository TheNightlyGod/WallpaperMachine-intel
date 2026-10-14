import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperPreviewLayoutTests: XCTestCase {
    func testMinimumWidthKeepsLocalizedControlsAndFailureTextInSeparateRows() async throws {
        let reason = String(repeating: "A preview resource could not load. Reload the preview. ", count: 4)
        let session = WallpaperPreviewSession(load: { _ in throw WallpaperPreviewFailure(message: reason) }, makeSurface: { _, _ in
            throw WallpaperPreviewFailure(message: "A failed load must not create a surface")
        })
        let controller = WallpaperPreviewWindowController(session: session)
        let root = controller.makeContentView(size: CGSize(width: 480, height: 320))
        XCTAssertNil(root.window)
        session.open(.init(wallpaperID: "fixture", displayID: "primary"))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(session.phase, .failed(reason))
        let controls = try XCTUnwrap(root.subviews.compactMap { $0 as? NSStackView }.first)
        let buttons = controls.arrangedSubviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3)
        let status = try XCTUnwrap(root.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "preview-status" })
        for titles in [["Pause", "Unmute", "Reload preview"], ["暂停", "取消静音", "重新载入预览"], ["一時停止", "消音を解除", "プレビューを再読み込み"]] {
            for (button, title) in zip(buttons, titles) { button.title = title }
            root.layoutSubtreeIfNeeded()
            for button in buttons {
                let rect = button.convert(button.bounds, to: root)
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertLessThanOrEqual(rect.maxX, root.bounds.width)
                XCTAssertGreaterThanOrEqual(rect.width + 1, button.intrinsicContentSize.width)
            }
            XCTAssertGreaterThan(status.frame.width, 400)
            XCTAssertLessThanOrEqual(status.frame.maxY, controls.frame.minY)
            XCTAssertEqual(status.toolTip, reason, "the complete diagnostic remains available even when its visible lines are capped")
            XCTAssertTrue(status.isSelectable)
        }
        session.close()
    }

    // MARK: Window size for the target display's shape

    private let ordinary = CGSize(width: 1440, height: 875)

    func testWindowSizeFollowsTheDisplayShapeOnAnOrdinaryScreen() {
        let controls = WallpaperPreviewWindowController.controlsHeight
        // No display answer keeps what every preview got before: a 16:9 stage under the controls.
        let standard = WallpaperPreviewWindowController.contentSize(visibleSize: ordinary)
        XCTAssertEqual(standard.width, 1000)
        XCTAssertEqual(standard.height, 1000 * 9 / 16 + controls, accuracy: 0.01)
        XCTAssertEqual(WallpaperPreviewWindowController.contentSize(visibleSize: ordinary, aspect: 16.0 / 9), standard)

        let shapes: [CGFloat] = [21.0 / 9, 32.0 / 9, 4.0 / 3, 3.0 / 4, 9.0 / 16]
        for aspect in shapes {
            let size = WallpaperPreviewWindowController.contentSize(visibleSize: ordinary, aspect: aspect)
            let stageHeight = size.height - controls
            XCTAssertLessThanOrEqual(size.height, ordinary.height - 80, "\(aspect) fits the screen")
            XCTAssertLessThanOrEqual(size.width, 1000)
            // The stage the window leaves for the wallpaper has the display's shape.
            let stageWidth = stageHeight * aspect
            XCTAssertLessThanOrEqual(stageWidth, size.width + 0.01, "\(aspect) is not cropped by the window")
            if aspect >= 1 { XCTAssertEqual(stageWidth, size.width, accuracy: 0.01, "\(aspect) uses the full width") }
        }
        let ultrawide = WallpaperPreviewWindowController.contentSize(visibleSize: ordinary, aspect: 21.0 / 9)
        XCTAssertLessThan(ultrawide.height, standard.height, "an ultrawide display needs less height")
        let portrait = WallpaperPreviewWindowController.contentSize(visibleSize: ordinary, aspect: 9.0 / 16)
        XCTAssertGreaterThan(portrait.height, standard.height, "a portrait display needs more height")
        XCTAssertEqual(portrait.height, ordinary.height - 80, accuracy: 0.01, "and shrinks to the screen instead of letterboxing")
        XCTAssertGreaterThanOrEqual(portrait.width, WallpaperPreviewWindowController.minimumContentWidth)
    }

    func testWindowSizeStaysUsableOnSmallScreensAndForOddShapes() {
        for visible in [CGSize(width: 520, height: 420), CGSize(width: 1024, height: 640), CGSize(width: 300, height: 200)] {
            let aspects: [CGFloat?] = [nil, 16.0 / 9, 21.0 / 9, 9.0 / 16, 4.0 / 3, 100, 0.001, CGFloat.nan, -2]
            for aspect in aspects {
                let size = WallpaperPreviewWindowController.contentSize(visibleSize: visible, aspect: aspect)
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.width, max(1, visible.width - 40) + 0.01, "\(visible) \(String(describing: aspect))")
                XCTAssertLessThanOrEqual(size.height, visible.height - 80 + 0.01, "\(visible) \(String(describing: aspect))")
                if visible.width >= 520 {
                    XCTAssertGreaterThanOrEqual(size.width, WallpaperPreviewWindowController.minimumContentWidth,
                        "the control row keeps room for localized buttons")
                }
            }
        }
        XCTAssertEqual(WallpaperPreviewWindowController.contentSize(visibleSize: CGSize(width: 520, height: 420), aspect: nil),
            WallpaperPreviewWindowController.contentSize(visibleSize: CGSize(width: 520, height: 420), aspect: .nan),
            "a display that has no shape is treated like an unknown one")
    }

    // MARK: Stage inside the window

    private func makeController() -> WallpaperPreviewWindowController {
        let session = WallpaperPreviewSession(load: { _ in throw WallpaperPreviewFailure(message: "unused") },
            makeSurface: { _, _ in throw WallpaperPreviewFailure(message: "unused") })
        return WallpaperPreviewWindowController(session: session)
    }

    private func stage(in root: NSView) throws -> NSView {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "preview-stage" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(root))
    }

    /// The stage is the largest box of the display's shape inside the black backdrop, centred.
    private func assertStage(_ stage: NSView, aspect: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try XCTUnwrap(stage.superview, file: file, line: line)
        XCTAssertEqual(stage.frame.width / stage.frame.height, aspect, accuracy: 0.01, "shape", file: file, line: line)
        XCTAssertEqual(stage.frame.midX, container.bounds.midX, accuracy: 0.5, "centred across", file: file, line: line)
        XCTAssertEqual(stage.frame.midY, container.bounds.midY, accuracy: 0.5, "centred down", file: file, line: line)
        XCTAssertLessThanOrEqual(stage.frame.width, container.bounds.width + 0.01, file: file, line: line)
        XCTAssertLessThanOrEqual(stage.frame.height, container.bounds.height + 0.01, file: file, line: line)
        let touchesWidth = abs(stage.frame.width - container.bounds.width) < 0.5
        let touchesHeight = abs(stage.frame.height - container.bounds.height) < 0.5
        XCTAssertTrue(touchesWidth || touchesHeight, "as large as the backdrop allows", file: file, line: line)
    }

    func testStageTakesTheDisplayShapeAndFollowsTheWindowSize() throws {
        let controller = makeController()
        let root = controller.makeContentView(size: CGSize(width: 900, height: 700))
        let stage = try stage(in: root)
        root.layoutSubtreeIfNeeded()
        try assertStage(stage, aspect: 16.0 / 9)  // nothing is known about the display yet

        controller.setStageAspect(9.0 / 16)
        root.layoutSubtreeIfNeeded()
        try assertStage(stage, aspect: 9.0 / 16)
        XCTAssertLessThan(stage.frame.width, stage.frame.height)

        // Switching display replaces the shape; the old one must not linger as a second constraint.
        controller.setStageAspect(21.0 / 9)
        root.layoutSubtreeIfNeeded()
        try assertStage(stage, aspect: 21.0 / 9)
        controller.setStageAspect(4.0 / 3)
        root.layoutSubtreeIfNeeded()
        try assertStage(stage, aspect: 4.0 / 3)

        // A window dragged to another shape keeps the display's proportions, with bars.
        for size in [CGSize(width: 480, height: 900), CGSize(width: 1400, height: 400), CGSize(width: 600, height: 600)] {
            root.setFrameSize(size)
            root.layoutSubtreeIfNeeded()
            try assertStage(stage, aspect: 4.0 / 3)
        }
    }

    func testStageClampsAnUnusableShapeAndFallsBackToWidescreen() throws {
        let controller = makeController()
        let root = controller.makeContentView(size: CGSize(width: 900, height: 700))
        let stage = try stage(in: root)
        let cases: [(CGFloat?, CGFloat)] = [(nil, 16.0 / 9), (CGFloat.nan, 16.0 / 9), (0, 16.0 / 9), (-1, 16.0 / 9), (100, 4), (0.001, 0.25)]
        for (given, expected) in cases {
            controller.setStageAspect(given)
            root.layoutSubtreeIfNeeded()
            try assertStage(stage, aspect: expected)
        }
    }

    func testShapeChosenBeforeTheContentViewExistsIsKept() throws {
        let controller = makeController()
        controller.setStageAspect(9.0 / 16)  // present() runs this before the window is made
        let root = controller.makeContentView(size: CGSize(width: 900, height: 700))
        root.layoutSubtreeIfNeeded()
        try assertStage(try stage(in: root), aspect: 9.0 / 16)
    }

    func testSurfaceFillsTheStageNotTheWholeBackdrop() throws {
        let session = WallpaperPreviewSession(load: { _ in throw WallpaperPreviewFailure(message: "unused") },
            makeSurface: { _, _ in throw WallpaperPreviewFailure(message: "unused") })
        let controller = WallpaperPreviewWindowController(session: session)
        let root = controller.makeContentView(size: CGSize(width: 900, height: 700))
        let stage = try stage(in: root)
        controller.setStageAspect(9.0 / 16)
        root.layoutSubtreeIfNeeded()

        let surface = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        session.onSurface?(surface)
        XCTAssertTrue(surface.superview === stage)
        XCTAssertEqual(surface.frame, stage.bounds)
        XCTAssertLessThan(surface.frame.width, 600, "a portrait display's surface is narrow, as the display will be")

        controller.setStageAspect(21.0 / 9)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.frame.size.width, stage.bounds.width, accuracy: 0.5)
        XCTAssertEqual(surface.frame.size.height, stage.bounds.height, accuracy: 0.5)
        XCTAssertEqual(surface.frame.width / surface.frame.height, 21.0 / 9, accuracy: 0.02, "the page or scene sees the new shape")

        session.onSurface?(nil)
        XCTAssertTrue(stage.subviews.isEmpty)
    }
}
