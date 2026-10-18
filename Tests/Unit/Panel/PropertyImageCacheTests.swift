import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

final class PropertyImageCacheTests: XCTestCase {
    func testCancellingTheLastConsumerStopsAnIncompleteResponseAndAllowsRetry() async throws {
        let fixture = ImageLoadFixture()
        defer { fixture.close() }
        let cache = PropertyImageCache(session: fixture.session)
        let url = URL(string: "https://i.ibb.co/held.png")!
        let returned = expectation(description: "Cancelled image consumer returns")
        let first = Task {
            defer { returned.fulfill() }
            return try await cache.image(for: url)
        }
        defer { first.cancel() }
        let requests = try await fixture.waitForRequests(1)
        // Deliver headers and only part of the body: cancellation must reach the
        // byte stream too, not just the initial response-header await.
        requests[0].beginBody()
        first.cancel()
        let settled = await XCTWaiter().fulfillment(of: [returned, requests[0].stopped], timeout: 2)
        XCTAssertEqual(settled, .completed)
        guard settled == .completed else { throw URLError(.timedOut) }
        do {
            _ = try await first.value
            XCTFail("A cancelled consumer must not receive artwork")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let retried = Task { try await cache.image(for: url) }
        defer { retried.cancel() }
        let retriedRequests = try await fixture.waitForRequests(2)
        retriedRequests[1].succeed(Self.pixel)
        let image = try await retried.value
        XCTAssertNotNil(CGImageSourceCreateWithData(image.data as CFData, nil))
        XCTAssertEqual(fixture.inbox.requests.count, 2, "Retired work must not seed the cache or consume the new request")
    }

    func testTransfersAreBoundedAcrossHostsAndQueuedConsumersCancelWithoutStarting() async throws {
        let fixture = ImageLoadFixture()
        defer { fixture.close() }
        let cache = PropertyImageCache(session: fixture.session)
        let urls = (0..<12).map { index in
            URL(string: "https://\(index.isMultiple(of: 2) ? "i.ibb.co" : "i.imgur.com")/\(index).png")!
        }
        let requests = urls.map { url in
            let returned = expectation(description: "Consumer \(url.lastPathComponent) returns")
            let task = Task {
                defer { returned.fulfill() }
                return try await cache.image(for: url)
            }
            return (url, task, returned)
        }
        defer { requests.forEach { $0.1.cancel() } }
        let active = try await fixture.waitForRequests(4)
        let activeURLs = Set(active.map { $0.request.url! })
        let queued = requests.filter { !activeURLs.contains($0.0) }
        queued.forEach { $0.1.cancel() }
        await fulfillment(of: queued.map(\.2), timeout: 2)
        XCTAssertEqual(fixture.inbox.requests.count, 4, "Queued artwork must not allocate another transfer")

        requests.filter { activeURLs.contains($0.0) }.forEach { $0.1.cancel() }
        await fulfillment(of: requests.filter { activeURLs.contains($0.0) }.map(\.2) + active.map(\.stopped), timeout: 2)
        XCTAssertEqual(fixture.inbox.requests.count, 4, "Cancelled queue entries must not restart after slots become free")

        let replacements = urls.prefix(4).map { url in Task { try await cache.image(for: url) } }
        defer { replacements.forEach { $0.cancel() } }
        let replacementRequests = try await fixture.waitForRequests(8)
        for request in replacementRequests.suffix(4) { request.succeed(Self.pixel) }
        for replacement in replacements {
            let image = try await replacement.value
            XCTAssertNotNil(CGImageSourceCreateWithData(image.data as CFData, nil))
        }
    }

    private static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!

    func testAuthorImagesCannotBecomeAnArbitraryNetworkProxy() throws {
        let accepted = try XCTUnwrap(URL(string: "https://i.ibb.co/art/image.gif"))
        XCTAssertTrue(PropertyImageCache.allowedURL(accepted))
        for address in [
            "http://i.ibb.co/art/image.gif", "https://i.ibb.co:8443/art.png",
            "https://user:password@i.ibb.co/art.png", "https://i.ibb.co.evil.test/art.png",
            "https://127.0.0.1/art.png", "https://[::1]/art.png", "file:///etc/passwd",
        ] {
            XCTAssertFalse(PropertyImageCache.allowedURL(try XCTUnwrap(URL(string: address))))
        }
        let html = """
            <img src='https://i.ibb.co/art/image.gif' onerror='alert(1)'>
            <img src="https://127.0.0.1/private"><a href="https://i.ibb.co/not-an-image">Link</a>
            """
        XCTAssertEqual(PropertyImageCache.sources(in: html), [accepted.absoluteString: accepted])
    }

    func testRasterValidationPreservesTransparentPixelsAndAnimation() throws {
        for type in [UTType.png, UTType.gif] {
            let data = NSMutableData()
            let frames = type == .gif ? 2 : 1
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for frame in 0..<frames {
                context.clear(CGRect(x: 0, y: 0, width: 2, height: 2))
                context.setFillColor(CGColor(red: CGFloat(frame), green: 0.5, blue: 0.5, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let image = try PropertyImageCache.decode(data as Data)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithData(image.data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(decoded), frames)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true)
        }
        XCTAssertThrowsError(try PropertyImageCache.decode(Data("<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>".utf8)))
        XCTAssertThrowsError(try PropertyImageCache.decode(Data("<html>not an image</html>".utf8)))
    }
}

private final class ImageLoadFixture {
    let identifier = UUID().uuidString
    let inbox = ImageRequestInbox()
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedPropertyImageProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Property-Image-Test": identifier]
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        DelayedPropertyImageProtocol.register(identifier, inbox: inbox)
    }

    func waitForRequests(_ count: Int) async throws -> [DelayedPropertyImageProtocol] {
        let deadline = Date().addingTimeInterval(2)
        while inbox.requests.count < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = inbox.requests
        guard requests.count >= count else {
            XCTFail("Expected \(count) image requests, got \(requests.count)")
            throw URLError(.timedOut)
        }
        return requests
    }

    func close() {
        session.invalidateAndCancel()
        DelayedPropertyImageProtocol.remove(identifier)
    }
}

private final class ImageRequestInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [DelayedPropertyImageProtocol] = []
    var requests: [DelayedPropertyImageProtocol] { lock.withLock { received } }
    func append(_ request: DelayedPropertyImageProtocol) { lock.withLock { received.append(request) } }
}

private final class DelayedPropertyImageProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var inboxes: [String: ImageRequestInbox] = [:]
    private let responseLock = NSRecursiveLock()
    private var finished = false
    let stopped = XCTestExpectation(description: "Transport cancellation reached the delayed response")

    static func register(_ identifier: String, inbox: ImageRequestInbox) {
        registryLock.withLock { inboxes[identifier] = inbox }
    }
    static func remove(_ identifier: String) {
        _ = registryLock.withLock { inboxes.removeValue(forKey: identifier) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let inbox = Self.registryLock.withLock {
            Self.inboxes[request.value(forHTTPHeaderField: "X-Property-Image-Test") ?? ""]
        }
        guard let inbox else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        inbox.append(self)
    }
    override func stopLoading() {
        responseLock.withLock {
            guard !finished else { return }
            finished = true
            stopped.fulfill()
        }
    }
    func beginBody() {
        responseLock.withLock {
            guard !finished else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "image/png", "Content-Length": "1024"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0x89, 0x50, 0x4e, 0x47]))
        }
    }
    func succeed(_ body: Data) {
        responseLock.withLock {
            guard !finished else { return }
            finished = true
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
