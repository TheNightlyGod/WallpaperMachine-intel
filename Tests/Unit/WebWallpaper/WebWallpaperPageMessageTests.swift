import WebKit
import XCTest

@testable import WallpaperMachine

/// What a page may post to its host, checked once for the desktop page and the screen-saver
/// surface alike, and the host functions both surfaces call, which the host script must define.
@MainActor
final class WebWallpaperPageMessageTests: XCTestCase {
  private typealias Message = WebWallpaperProtocol.PageMessage

  func testEveryTagTheHostScriptPostsIsUnderstood() {
    for kind in [Message.Kind.audioSubscribed, .audioUnsubscribed, .mediaSubscribed, .mediaUnsubscribed] {
      XCTAssertNoThrow(try Message.parse(["type": kind.rawValue]).get(), kind.rawValue)
    }
    guard case .success(.pageDiagnostic(let payload)) = Message.parse(["type": "pageDiagnostic", "kind": "error"])
    else { return XCTFail("a diagnostic is passed on whole") }
    XCTAssertEqual(payload["kind"] as? String, "error")
    guard case .success(.randomFileRequest(let id, let property)) = Message.parse(
      ["type": "randomFileRequest", "requestId": "r1", "propertyId": "gallery"])
    else { return XCTFail("a well-formed random file request is accepted") }
    XCTAssertEqual(id, "r1")
    XCTAssertEqual(property, "gallery")
  }

  func testAnythingElseIsRejectedWithItsReason() {
    let malformed: [Any] = ["audioSubscribed", ["kind": "x"], ["type": 7]]
    for body in malformed {
      XCTAssertEqual(rejection(body), .malformed, "\(body)")
    }
    XCTAssertEqual(rejection(["type": "openURL"]), .unknownKind("openURL"))
    let long = String(repeating: "x", count: Message.maximumRequestIDLength + 1)
    let longProperty = String(repeating: "p", count: Message.maximumPropertyIDLength + 1)
    let requests: [[String: Any]] = [
      ["propertyId": "gallery"], ["requestId": "", "propertyId": "gallery"],
      ["requestId": "r1"], ["requestId": "r1", "propertyId": ""],
      ["requestId": 1, "propertyId": "gallery"],
      ["requestId": long, "propertyId": "gallery"], ["requestId": "r1", "propertyId": longProperty],
    ]
    for fields in requests {
      XCTAssertEqual(
        rejection(fields.merging(["type": "randomFileRequest"]) { $1 }), .malformedRandomFileRequest, "\(fields)")
    }
    let longest = String(repeating: "x", count: Message.maximumRequestIDLength)
    XCTAssertNil(rejection(["type": "randomFileRequest", "requestId": longest, "propertyId": "gallery"]))
  }

  func testEveryHostFunctionIsDefinedOnALoadedPage() async throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-page-message-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    try "<!doctype html><html><body></body></html>".write(
      to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    defer { page.stop() }
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)
    for function in WebWallpaperProtocol.HostFunction.allCases {
      let type = try await page.webView.callAsyncJavaScript(
        "return typeof \(WebWallpaperProtocol.hostObject).\(function.rawValue)", arguments: [:], in: nil,
        contentWorld: .page) as? String
      XCTAssertEqual(type, "function", function.rawValue)
    }
  }

  private func rejection(_ body: Any) -> Message.Rejection? {
    if case .failure(let reason) = Message.parse(body) { return reason }
    return nil
  }
}
