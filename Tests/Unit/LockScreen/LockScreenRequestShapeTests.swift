import XCTest

@testable import WallpaperMachine

final class LockScreenRequestShapeTests: XCTestCase {
  private enum Kind { case video, image }
  private enum Mode {
    case wallpaper(Kind)
    case idle
    case scene(name: String, index: Int)
  }
  private struct Destination {
    var size: CGSize
    var scaleFactor: CGFloat
    var directDisplayID: UInt32?
    var folder: URL
  }
  private struct Entry {
    var path: String
    var weight: Int
  }
  private struct Request {
    var identifier: UUID
    var destination: Destination
    var mode: Mode
    var idleMode: Mode
    var isPreview: Bool
    var title: String
    var entries: [Entry]
    var settings: [String: String]
    var seen: Set<String>
    var cacheDirectory: String?
    var started: Date
    var blob: Data
  }

  private let secrets = [
    "Private Title", "/Users/someone/private.mp4", "private-key", "private-value", "secret-seen",
    "/Users/someone/cache",
  ]

  private func makeRequest(cache: String? = nil) -> Request {
    Request(
      identifier: UUID(),
      destination: Destination(
        size: CGSize(width: 3456, height: 2234), scaleFactor: 2, directDisplayID: 1,
        folder: URL(fileURLWithPath: "/Users/someone/private.mp4")),
      mode: .scene(name: "Private Title", index: 3), idleMode: .idle, isPreview: false,
      title: "Private Title",
      entries: [Entry(path: "/Users/someone/private.mp4", weight: 1)],
      settings: ["private-key": "private-value"], seen: ["secret-seen"], cacheDirectory: cache,
      started: Date(), blob: Data([1, 2, 3]))
  }

  func testReturnsDottedLabelsOnlyNeverValues() {
    let labels = LockScreenRequestShape.labels(of: makeRequest(cache: "/Users/someone/cache"), maxDepth: 6)

    XCTAssertEqual(
      labels,
      [
        "blob", "cacheDirectory", "destination", "destination.directDisplayID",
        "destination.folder", "destination.scaleFactor", "destination.size",
        "destination.size.height", "destination.size.width", "entries", "entries.[]",
        "entries.[].path", "entries.[].weight", "identifier", "idleMode", "isPreview", "mode",
        "mode.scene", "mode.scene.index", "mode.scene.name", "seen", "settings", "started",
        "title",
      ])
    let text = labels.joined(separator: "\n")
    for secret in secrets { XCTAssertFalse(text.contains(secret), "\(secret) leaked into the labels") }
  }

  func testAnOptionalIsNamedTheSameWhetherOrNotItIsSet() {
    let missing = LockScreenRequestShape.labels(of: makeRequest(cache: nil))
    let present = LockScreenRequestShape.labels(of: makeRequest(cache: "/Users/someone/cache"))
    XCTAssertEqual(missing, present)
    XCTAssertTrue(present.contains("cacheDirectory"))
    XCTAssertFalse(present.contains { $0.contains("some") })

    struct Holder {
      var inner: Destination?
    }
    let destination = makeRequest().destination
    XCTAssertEqual(
      LockScreenRequestShape.labels(of: Holder(inner: destination), maxDepth: 6).filter {
        $0.hasPrefix("inner.size")
      }, ["inner.size", "inner.size.height", "inner.size.width"])
    XCTAssertEqual(LockScreenRequestShape.labels(of: Holder(inner: nil)), ["inner"])
  }

  func testDictionaryKeysAndSetMembersAreData() {
    let labels = LockScreenRequestShape.labels(of: makeRequest())
    XCTAssertTrue(labels.contains("settings"))
    XCTAssertTrue(labels.contains("seen"))
    XCTAssertFalse(labels.contains { $0.hasPrefix("settings.") || $0.hasPrefix("seen.") })
  }

  func testAnEnumCaseIsNamedOnlyWhenItCarriesAPayload() {
    XCTAssertEqual(
      LockScreenRequestShape.labels(of: Mode.scene(name: "Private Title", index: 1)),
      ["scene", "scene.index", "scene.name"])
    XCTAssertEqual(LockScreenRequestShape.labels(of: Mode.wallpaper(.video)), ["wallpaper"])
    XCTAssertEqual(LockScreenRequestShape.labels(of: Mode.idle), [])
  }

  /// Custom reflection can return any text as a name; only plain identifiers are kept.
  func testNamesThatAreNotIdentifiersAreHidden() {
    struct Odd: CustomReflectable {
      var customMirror: Mirror {
        let fields: [Mirror.Child] = [
          (label: "plain_name", value: 1), (label: "/Users/someone/private.mp4", value: 2),
          (label: "Private Title", value: 3), (label: ".7", value: 4),
        ]
        return Mirror(self, children: fields)
      }
    }
    let labels = LockScreenRequestShape.labels(of: Odd())
    XCTAssertEqual(labels, ["7", "?", "plain_name"])
  }

  func testDepthAndCountAreBounded() {
    final class Link {
      var next: Link?
      var payload = 0
      init(next: Link?) { self.next = next }
    }
    var chain = Link(next: nil)
    for _ in 0..<20 { chain = Link(next: chain) }
    let deep = LockScreenRequestShape.labels(of: chain, maxDepth: 4)
    XCTAssertEqual(deep.map { $0.split(separator: ".").count }.max(), 4)
    XCTAssertEqual(deep.count, 8, "next and payload at each of the four levels")

    struct Wide: CustomReflectable {
      var customMirror: Mirror {
        let fields: [Mirror.Child] = (0..<200).map { (label: "field\($0)", value: $0) }
        return Mirror(self, children: fields)
      }
    }
    let wide = LockScreenRequestShape.labels(of: Wide(), maxLabels: 64)
    XCTAssertEqual(wide.count, 64)
    XCTAssertEqual(Set(wide), Set((0..<64).map { "field\($0)" }), "the first names reflected are kept")
    XCTAssertEqual(LockScreenRequestShape.labels(of: Wide(), maxDepth: 0), [])
  }

  func testTheShallowestNamesSurviveATightCap() {
    let labels = LockScreenRequestShape.labels(of: makeRequest(), maxDepth: 6, maxLabels: 12)
    XCTAssertEqual(labels.count, 12)
    XCTAssertTrue(labels.allSatisfy { $0.split(separator: ".").count <= 2 })
  }

  func testSummaryFitsTheLimitAndSaysHowManyNamesWereLeftOut() throws {
    XCTAssertEqual(LockScreenRequestShape.summary(["a", "b.c"]), "a b.c")
    XCTAssertEqual(LockScreenRequestShape.summary([]), "")

    let labels = (0..<200).map { "destination.field\($0)" }
    let summary = LockScreenRequestShape.summary(labels, limit: 120)
    XCTAssertLessThanOrEqual(summary.count, 120)
    let parts = summary.split(separator: " ").map(String.init)
    let last = try XCTUnwrap(parts.last)
    XCTAssertTrue(last.hasPrefix("…+"))
    let omitted = try XCTUnwrap(Int(last.dropFirst(2)))
    XCTAssertEqual(parts.dropLast().count + omitted, labels.count)
    XCTAssertEqual(Array(parts.dropLast()), Array(labels.prefix(parts.count - 1)))
  }
}
