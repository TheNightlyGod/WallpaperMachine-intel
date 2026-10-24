import XCTest

@testable import WallpaperMachine

/// Each request is one POST with a product user agent, and anything but a 2xx is a failure.
final class TelemetryClientTests: XCTestCase {
    private final class Stub: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var status = 204
        nonisolated(unsafe) static var seen: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var recorded = request
            // URLSession moves the body into a stream before a protocol sees it.
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close()
                recorded.httpBody = data
            }
            Self.lock.withLock { Self.seen.append(recorded) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Self.lock.withLock { Self.status }, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func client() -> TelemetryClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return TelemetryClient(
            endpoint: URL(string: "https://telemetry-\(UUID().uuidString).invalid/api/telemetry")!,
            session: GitHubReleaseClient.makeSession(configuration: configuration), version: "1.4.1")
    }

    override func setUp() {
        super.setUp()
        Stub.lock.withLock {
            Stub.status = 204
            Stub.seen = []
        }
    }

    func testReportIsPostedAsJSONWithTheAppsUserAgent() async throws {
        try await client().send(Data(#"{"schema":1}"#.utf8))
        let request = try XCTUnwrap(Stub.lock.withLock { Stub.seen.first })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "WallpaperMachine/1.4.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, Data(#"{"schema":1}"#.utf8))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testDeletionNamesOnlyTheInstall() async throws {
        try await client().delete(install: "8F1C2B9E-0000-4000-8000-000000000001")
        let request = try XCTUnwrap(Stub.lock.withLock { Stub.seen.first })
        XCTAssertEqual(request.url?.path, "/api/telemetry/delete")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String],
                       ["install": "8F1C2B9E-0000-4000-8000-000000000001"])
    }

    func testActivePingGoesToItsOwnPath() async throws {
        try await client().sendActive(Data(#"{"schema":1}"#.utf8))
        let request = try XCTUnwrap(Stub.lock.withLock { Stub.seen.first })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/telemetry/active")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "WallpaperMachine/1.4.1")
        XCTAssertEqual(request.httpBody, Data(#"{"schema":1}"#.utf8))
    }

    func testNon2xxIsAFailure() async {
        Stub.lock.withLock { Stub.status = 429 }
        do {
            try await client().send(Data("{}".utf8))
            XCTFail("a refused upload must not count as sent")
        } catch {
            XCTAssertEqual(error as? TelemetryUploadError, TelemetryUploadError(status: 429))
        }
    }
}
