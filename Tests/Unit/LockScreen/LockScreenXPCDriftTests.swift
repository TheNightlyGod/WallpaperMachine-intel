import XCTest

@testable import WallpaperMachine

/// Reply shapes as the extension declares them and as macOS 27 does: a Boolean reply.
@objc private protocol DriftBooleanReply {
  func ready(_ identifier: Any?, reply: @escaping (Bool, Error?) -> Void)
  func shared(_ identifier: Any?, reply: @escaping (Error?) -> Void)
  func onlyHere(_ identifier: Any?, reply: @escaping (Error?) -> Void)
}

/// The same selectors where `ready` replies with an object, and one selector only this side has.
@objc private protocol DriftObjectReply {
  func ready(_ identifier: Any?, reply: @escaping (Any?, Error?) -> Void)
  func shared(_ identifier: Any?, reply: @escaping (Error?) -> Void)
  func onlyThere(_ identifier: Any?, reply: @escaping (Error?) -> Void)
}

final class LockScreenXPCDriftTests: XCTestCase {
  func testNormalizationIgnoresClassAnnotationsButKeepsTypeCodes() {
    let system =
      "v40@0:8@\"WallpaperIDXPC\"16@\"WallpaperCreationRequestXPC\"24@?<v@?@\"WallpaperRemoteContextXPC\"@\"NSError\">32"
    let ours = "v40@0:8@16@24@?<v@?@@\"NSError\">32"
    XCTAssertEqual(LockScreenXPCDrift.normalized(system), LockScreenXPCDrift.normalized(ours))
    XCTAssertEqual(LockScreenXPCDrift.normalized(system), "v40@0:8@16@24@?<v@?@@>32")
  }

  func testBoolReplyDiffersFromObjectReply() {
    let booleanReply = "v32@0:8@16@?<v@?B@\"NSError\">24"
    let objectReply = "v32@0:8@16@?<v@?@\"NSNumber\"@\"NSError\">24"
    let unchanged = "v32@0:8@\"WallpaperIDXPC\"16@?<v@?@\"NSError\">24"
    let report = LockScreenXPCDrift.compare(
      ours: ["isChoiceDownloadedWith:reply:": booleanReply, "invalidateWithId:reply:": "v32@0:8@16@?<v@?@\"NSError\">24"],
      system: ["isChoiceDownloadedWith:reply:": objectReply, "invalidateWithId:reply:": unchanged])
    XCTAssertEqual(report.differing, ["isChoiceDownloadedWith:reply:"])
    XCTAssertTrue(report.missing.isEmpty)
    XCTAssertTrue(report.extra.isEmpty)
    XCTAssertFalse(report.isClean)
  }

  func testMissingAndExtraSelectorsAreListedSortedAndCleanTablesAreClean() {
    let shape = "v32@0:8@16@?24"
    let report = LockScreenXPCDrift.compare(
      ours: ["zeta:reply:": shape, "kept:reply:": shape, "alpha:reply:": shape],
      system: ["kept:reply:": shape, "migrateFrom:to:reply:": shape, "cancelDownloadFor:reply:": shape])
    XCTAssertEqual(report.missing, ["cancelDownloadFor:reply:", "migrateFrom:to:reply:"])
    XCTAssertEqual(report.extra, ["alpha:reply:", "zeta:reply:"])
    XCTAssertTrue(report.differing.isEmpty)

    let table = ["kept:reply:": shape, "other:reply:": shape]
    XCTAssertTrue(LockScreenXPCDrift.compare(ours: table, system: table).isClean)
    XCTAssertTrue(LockScreenXPCDrift.compare(ours: [:], system: [:]).isClean)
  }

  func testTheRuntimeReportsEachSelectorOfAnObjectiveCProtocolWithItsReplyShape() throws {
    let booleanReply = try XCTUnwrap(
      LockScreenXPCDrift.encodings(of: NSXPCInterface(with: DriftBooleanReply.self).protocol))
    let objectReply = try XCTUnwrap(
      LockScreenXPCDrift.encodings(of: NSXPCInterface(with: DriftObjectReply.self).protocol))
    XCTAssertEqual(Set(booleanReply.keys), ["ready:reply:", "shared:reply:", "onlyHere:reply:"])

    let report = LockScreenXPCDrift.compare(ours: booleanReply, system: objectReply)
    XCTAssertEqual(report.differing, ["ready:reply:"], "a Boolean and an object reply are different blocks")
    XCTAssertEqual(report.missing, ["onlyThere:reply:"])
    XCTAssertEqual(report.extra, ["onlyHere:reply:"])

    XCTAssertTrue(LockScreenXPCDrift.compare(ours: booleanReply, system: booleanReply).isClean)
  }
}
