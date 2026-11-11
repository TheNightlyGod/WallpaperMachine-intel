import Foundation
import XCTest

@testable import WallpaperMachine

final class ConnectionInterruptedTests: XCTestCase {
    private let pixiv = URL(string: "https://www.pixiv.net/ajax/top/illust")!

    func testResetAndRefusedConnectionsGetTheProxyExplanationNamingTheFailedHost() {
        let codes: [URLError.Code] = [
            .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired, .networkConnectionLost, .cannotConnectToHost, .timedOut,
            .dnsLookupFailed, .cannotFindHost,
        ]
        for code in codes {
            let error = URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: pixiv])
            let explained = ConnectionInterrupted(error, site: "fallback.example")
            XCTAssertEqual(explained?.host, "www.pixiv.net", "\(code)")
            XCTAssertEqual(
                ConnectionInterrupted.message(for: error, site: "fallback.example"),
                ConnectionInterrupted(host: "www.pixiv.net").localizedDescription, "\(code)")
            XCTAssertNotEqual(
                ConnectionInterrupted.message(for: error, site: "fallback.example"), error.localizedDescription, "\(code)")
        }
    }

    func testWebKitsNSErrorIsRecognisedAndAnErrorWithoutAnAddressNamesTheSite() {
        // WebKit reports a failed navigation as an NSError in NSURLErrorDomain.
        let webKit = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://login.steampowered.com/")!])
        XCTAssertEqual(ConnectionInterrupted(webKit, site: "steamcommunity.com")?.host, "login.steampowered.com")
        XCTAssertEqual(
            ConnectionInterrupted(URLError(.networkConnectionLost), site: "steamcommunity.com")?.host, "steamcommunity.com")
    }

    func testOtherFailuresKeepTheirOwnDescription() {
        let errors: [Error] = [
            URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: pixiv]),
            URLError(.cancelled), URLError(.badServerResponse), URLError(.userAuthenticationRequired),
            URLError(.cannotDecodeContentData), CocoaError(.fileNoSuchFile), CancellationError(),
        ]
        for error in errors {
            XCTAssertNil(ConnectionInterrupted(error, site: "www.pixiv.net"), "\(error)")
            XCTAssertEqual(ConnectionInterrupted.message(for: error, site: "www.pixiv.net"), error.localizedDescription)
            XCTAssertFalse(ConnectionInterrupted.explaining(error, site: "www.pixiv.net") is ConnectionInterrupted)
        }
        // A cancellation stays recognisable as one after passing through.
        let cancelled = ConnectionInterrupted.explaining(URLError(.cancelled), site: "www.pixiv.net")
        XCTAssertEqual((cancelled as? URLError)?.code, .cancelled)
    }

    func testWorkshopRequestsCutOffByTheNetworkExplainTheProxy() async throws {
        let fixture = FailingSession(.secureConnectionFailed)
        defer { fixture.close() }
        do {
            _ = try await WorkshopService(session: fixture.session).details(ids: ["123"])
            XCTFail("a failed connection returned details")
        } catch let error as ConnectionInterrupted {
            XCTAssertFalse(error.host.isEmpty)
        }
    }

    func testWorkshopRequestsKeepOtherFailures() async throws {
        let fixture = FailingSession(.notConnectedToInternet)
        defer { fixture.close() }
        do {
            _ = try await WorkshopService(session: fixture.session).details(ids: ["123"])
            XCTFail("a failed connection returned details")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    func testPixivRequestsCutOffByTheNetworkExplainTheProxy() async throws {
        let fixture = FailingSession(.secureConnectionFailed)
        defer { fixture.close() }
        do {
            _ = try await URLSessionPixivTransport(session: fixture.session).image(from: pixiv, limit: 1024) { _, _ in }
            XCTFail("a failed connection returned an image")
        } catch let failure as PixivFailure {
            XCTAssertEqual(failure.code, .network(ConnectionInterrupted(host: "www.pixiv.net").localizedDescription))
        }
    }
}

/// A session whose every request fails the way a reset or offline connection does, naming the
/// address it was for, so nothing reaches the network.
private struct FailingSession {
    let session: URLSession

    init(_ code: URLError.Code) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [code == .notConnectedToInternet ? OfflineProtocol.self : ResetProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func close() { session.invalidateAndCancel() }
}

private class FailingProtocol: URLProtocol, @unchecked Sendable {
    class var code: URLError.Code { .unknown }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var userInfo: [String: Any] = [:]
        if let url = request.url { userInfo[NSURLErrorFailingURLErrorKey] = url }
        client?.urlProtocol(self, didFailWithError: URLError(Self.code, userInfo: userInfo))
    }
    override func stopLoading() {}
}

private final class ResetProtocol: FailingProtocol, @unchecked Sendable {
    override class var code: URLError.Code { .secureConnectionFailed }
}

private final class OfflineProtocol: FailingProtocol, @unchecked Sendable {
    override class var code: URLError.Code { .notConnectedToInternet }
}
