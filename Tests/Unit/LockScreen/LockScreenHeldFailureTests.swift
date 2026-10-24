import XCTest

@testable import WallpaperMachine

/// What the lock-screen surface knows about a scene the engine could not draw when Native Metal is the only
/// renderer it may use: the engine's raw stage becomes a named one, a value nobody named is not a failure,
/// and the readiness the app reads carries the extension's note without turning it into an error.
final class LockScreenHeldFailureTests: XCTestCase {
  func testEveryStageTheEngineNamesIsKeptAndNothingElseIsInvented() {
    let names: [Int32: LockScreenHeldFailure.Stage] = [
      1: .unsupported, 2: .prepare, 3: .compile, 4: .frame, 5: .surface,
    ]
    for (raw, stage) in names {
      let held = LockScreenHeldFailure(rawStage: raw, reason: "why")
      XCTAssertEqual(held?.stage, stage, "stage \(raw)")
      XCTAssertEqual(held?.reason, "why")
    }
    XCTAssertNil(
      LockScreenHeldFailure(rawStage: 0, reason: "stale"), "zero is no failure, whatever else was read")
    for corrupt: Int32 in [6, 100, -1, Int32.max] {
      XCTAssertNil(LockScreenHeldFailure(rawStage: corrupt, reason: ""), "\(corrupt)")
    }
  }

  /// A video the extension's players could not play is held the same way, with the reason they gave. It is
  /// never read from the engine's stages, which have no number for it.
  func testAVideoTheExtensionCouldNotPlayIsHeldWithItsReason() {
    let held = LockScreenHeldFailure(video: "the clip is unavailable")
    XCTAssertEqual(held.stage, .video)
    XCTAssertEqual(held.logDetail, "stage=video reason=the clip is unavailable")
    XCTAssertFalse(
      (1...5).contains { LockScreenHeldFailure(rawStage: Int32($0), reason: "")?.stage == .video })
  }

  func testTheLogDetailNamesTheStageAndOnlyTheReasonTheEngineGave() {
    XCTAssertEqual(
      LockScreenHeldFailure(rawStage: 3, reason: "the shader did not link")?.logDetail,
      "stage=compile reason=the shader did not link")
    XCTAssertEqual(LockScreenHeldFailure(rawStage: 4, reason: "")?.logDetail, "stage=frame")
  }

  /// The note rides in the readiness file beside `error`, as a key of its own. A file an older extension
  /// wrote has no such key, and a note is never read as an error.
  func testTheReadinessNoteIsNotAnErrorAndAnOlderFileHasNone() throws {
    let held = LockScreenReadiness(revision: "r", displayID: 3, error: nil, held: "Native Metal can't draw this")
    let decoded = try JSONDecoder().decode(LockScreenReadiness.self, from: JSONEncoder().encode(held))
    XCTAssertEqual(decoded.held, "Native Metal can't draw this")
    XCTAssertNil(decoded.error, "a held scene is ready, not failed")

    let older = Data(#"{"revision":"r","displayID":3}"#.utf8)
    let read = try JSONDecoder().decode(LockScreenReadiness.self, from: older)
    XCTAssertNil(read.held)
    XCTAssertNil(read.error)
  }
}
