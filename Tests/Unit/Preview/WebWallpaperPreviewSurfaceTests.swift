import WebKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class WebWallpaperPreviewSurfaceTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("web-preview-\(UUID().uuidString)")
        project = root.appendingPathComponent("preview")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
        <!doctype html><html><head><script>
        window.received = null;
        window.paused = false;
        window.wallpaperPropertyListener = {
          applyUserProperties(properties) { window.received = properties; },
          setPaused(value) { window.paused = value; }
        };
        </script></head><body>Original preview fixture</body></html>
        """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private nonisolated static let defaultProperties = #"{"message":{"type":"textinput","value":"Unapplied text"},"choice":{"type":"combo","value":2}}"#

    private func makeSurface(generation: UInt64, inspectable: Bool = false,
                             properties: String = WebWallpaperPreviewSurfaceTests.defaultProperties) throws -> WebWallpaperPreviewSurface {
        let request = try WallpaperPreviewRequest(.init(wallpaperId: "preview", title: "Preview", kind: .webpage,
            projectPath: project.path, entryFile: "index.html", assetsPath: project.path,
            propertiesJson: properties,
            fps: 30, scalingMode: .fill, scalingFactor: 1, volume: 0.5, engineOptions: nil, lutPath: nil,
            sceneQuality: .wallpaperEngineDefault))
        let assets = UserAssetStore(projectURL: project, wallpaperId: "preview",
            managed: ManagedUserAssetStore(root: root.appendingPathComponent("UserAssets")))
        return WebWallpaperPreviewSurface(request: request, generation: generation, assets: assets, inspectable: inspectable)
    }

    private func waitForProperties(_ surface: WebWallpaperPreviewSurface) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if surface.page.isLoaded,
               try await surface.page.webView.callAsyncJavaScript("return Boolean(window.received)", arguments: [:], in: nil, contentWorld: .page) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WallpaperPreviewFailure(message: "Fixture properties did not arrive")
    }

    /// Waits until the page has been handed `condition`'s value by its property listener.
    private func waitForPage(_ surface: WebWallpaperPreviewSurface, _ expression: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await surface.page.webView.callAsyncJavaScript("return Boolean(\(expression))", arguments: [:], in: nil, contentWorld: .page) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WallpaperPreviewFailure(message: "The page never received: \(expression)")
    }

    private func keys(_ surface: WebWallpaperPreviewSurface) async throws -> [String] {
        let value = try await surface.page.webView.callAsyncJavaScript("return Object.keys(window.received).sort().join(',')", arguments: [:], in: nil, contentWorld: .page) as? String
        return (value ?? "").split(separator: ",").map(String.init)
    }

    func testASecondDeliveryChangesOnlyTheEditedProperty() async throws {
        let surface = try makeSurface(generation: 1)
        defer { surface.stop() }
        try surface.setMuted(true)
        try await surface.start()
        try await waitForProperties(surface)
        let started = try await keys(surface)
        XCTAssertEqual(started, ["choice", "message"], "the first delivery carries every property")

        try surface.applyProperties(#"{"choice":{"type":"combo","value":3},"message":{"type":"textinput","value":"Unapplied text"}}"#)
        try await waitForPage(surface, "received.choice && received.choice.value === 3")
        let changed = try await keys(surface)
        XCTAssertEqual(changed, ["choice"], "a property that did not change is not delivered again")
        surface.stop()
        try surface.applyProperties(#"{"choice":{"type":"combo","value":4}}"#)  // a stopped preview ignores it
    }

    func testAStagedFileKeepsItsValueWhenALaterDeliveryNamesTheUsersPathAgain() async throws {
        let source = root.appendingPathComponent("picture.png")
        try Data("picture-bytes".utf8).write(to: source)
        let first = #"{"choice":{"type":"combo","value":2},"pic":{"type":"file","fileFilter":"image","value":"\#(source.path)"}}"#
        let surface = try makeSurface(generation: 1, properties: first)
        defer { surface.stop() }
        try surface.setMuted(true)
        try await surface.start()
        try await waitForProperties(surface)
        let staged = try await surface.page.webView.callAsyncJavaScript("return received.pic.value", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertNotEqual(staged, source.path, "the page was handed the staged copy, not the user's path")

        try surface.applyProperties(#"{"choice":{"type":"combo","value":3},"pic":{"type":"file","fileFilter":"image","value":"\#(source.path)"}}"#)
        try await waitForPage(surface, "received.choice && received.choice.value === 3")
        let changed = try await keys(surface)
        XCTAssertEqual(changed, ["choice"], "the file is still the staged copy the page already has")
    }

    func testAPreviewCanBeAttachedToByTheInspectorOnlyWhenAllowed() throws {
        let closed = try makeSurface(generation: 1)
        let open = try makeSurface(generation: 2, inspectable: true)
        defer { closed.stop(); open.stop() }
        XCTAssertFalse(closed.page.webView.isInspectable)
        XCTAssertTrue(open.page.webView.isInspectable)
    }

    func testWebPreviewIsMutedIsolatedAndDeliversTypedPropertiesWithoutAWindow() async throws {
        let first = try makeSurface(generation: 1)
        let second = try makeSurface(generation: 2)
        defer { first.stop(); second.stop() }
        try first.setMuted(true)
        try await first.start()
        try await waitForProperties(first)
        let web = first.page.webView
        XCTAssertNil(web.window)
        XCTAssertEqual(WebWallpaperAudioOutput.isMuted(web), true)
        let message = try await web.callAsyncJavaScript("return received.message.value", arguments: [:], in: nil, contentWorld: .page) as? String
        let choice = try await web.callAsyncJavaScript("return received.choice.value", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(message, "Unapplied text")
        XCTAssertEqual(choice, 2)
        _ = try await web.callAsyncJavaScript("localStorage.setItem('preview-only', 'first')", arguments: [:], in: nil, contentWorld: .page)
        try second.setMuted(true)
        try await second.start()
        try await waitForProperties(second)
        let isolated = try await second.page.webView.callAsyncJavaScript("return localStorage.getItem('preview-only') === null", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(isolated, true, "preview documents must not share storage even at the same file origin")
        let captureBlocked = try await web.callAsyncJavaScript("""
            const media = navigator.mediaDevices;
            if (!media) return true;
            const descriptor = Object.getOwnPropertyDescriptor(media, 'getUserMedia');
            if (!descriptor || descriptor.configurable || descriptor.writable) return false;
            return descriptor.value({ audio: true }).then(() => false, error => error.name === 'NotAllowedError');
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(captureBlocked, true, "this executes the installed rejecting stub, never a capture-device request")
        try first.setPaused(true)
        XCTAssertTrue(first.page.hostSuspended)
        try first.setPaused(false)
        XCTAssertFalse(first.page.hostSuspended)
        first.stop()
        XCTAssertNil(web.superview)
        XCTAssertFalse(first.page.isLoaded)
    }
}
