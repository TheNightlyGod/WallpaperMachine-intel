import Darwin
import XCTest

@testable import WallpaperMachine

final class MachOImageUUIDsTests: XCTestCase {
  private let first = UUID()
  private let second = UUID()

  private func uuids(_ data: Data) -> Set<UUID> {
    MachOImageUUIDs.uuids { offset, length in
      guard offset + UInt64(length) <= UInt64(data.count) else { return nil }
      return data.subdata(in: Int(offset)..<Int(offset) + length)
    }
  }

  func testTheUUIDIsFoundAfterOtherLoadCommands() {
    let image = MachOFixture.thin(uuid: first, leading: [(0x19, 72), (0x19, 152), (0x32, 24)])
    XCTAssertEqual(uuids(image), [first])
  }

  func testEverySliceOfAUniversalImageContributesItsUUID() {
    let image = MachOFixture.universal([
      MachOFixture.thin(uuid: first, leading: [(0x19, 72)]), MachOFixture.thin(uuid: second),
    ])
    XCTAssertEqual(uuids(image), [first, second])
  }

  func testAnImageWithoutAUUIDOrNotUnderstoodYieldsNothing() {
    XCTAssertEqual(uuids(MachOFixture.thin(uuid: nil, leading: [(0x19, 72)])), [])
    XCTAssertEqual(uuids(Data()), [])
    XCTAssertEqual(uuids(Data("#!/bin/sh\nexit 0\n".utf8)), [])
    // A Java class file shares the universal magic; its "slice count" is far too large.
    XCTAssertEqual(uuids(Data([0xca, 0xfe, 0xba, 0xbe, 0x00, 0x00, 0x00, 0x41]) + Data(count: 64)), [])
  }

  func testMalformedLoadCommandsNeverReadPastTheirBoundsAndKeepWhatWasFound() {
    let image = MachOFixture.thin(uuid: first, leading: [(0x19, 72)])
    // A truncated file cannot supply the commands it claims.
    XCTAssertEqual(uuids(image.prefix(image.count - 1)), [])

    // A command size that overruns the command area ends the walk, but the UUID before it stays.
    var overrun = MachOFixture.thin(uuid: first, leading: [])
    overrun += Data([0x19, 0, 0, 0, 0xff, 0xff, 0, 0])
    overrun.replaceSubrange(20..<24, with: withUnsafeBytes(of: UInt32(32).littleEndian) { Data($0) })
    overrun.replaceSubrange(16..<20, with: withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) })
    XCTAssertEqual(uuids(overrun), [first])

    // A command smaller than its own header would never advance: the walk stops there.
    var stuck = MachOFixture.thin(uuid: first, leading: [(0x19, 8)])
    stuck.replaceSubrange(36..<40, with: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) })
    XCTAssertEqual(uuids(stuck), [])
  }

  func testTheKernelAndTheFileAgreeOnTheRunningBuild() throws {
    // Both halves of the comparison, against the real test host: the UUID the kernel keeps
    // for this process and the one read from its executable file.
    let executable = try XCTUnwrap(Bundle.main.executableURL)
    let running = try XCTUnwrap(LockScreenExtensionProcesses.imageUUID(of: getpid()))
    XCTAssertTrue(MachOImageUUIDs.uuids(at: executable).contains(running))
  }

  func testAnUnreadableFileYieldsNothing() {
    XCTAssertEqual(MachOImageUUIDs.uuids(at: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")), [])
    XCTAssertEqual(MachOImageUUIDs.uuids(at: FileManager.default.temporaryDirectory), [])
  }
}
