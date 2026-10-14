import Foundation

/// Synthetic Mach-O images: just the headers and load commands the UUID reader looks at.
enum MachOFixture {
  /// A thin 64-bit little-endian image. `leading` load commands (each padded to `size`
  /// bytes) come before the UUID command, as the segment commands do in a real binary.
  static func thin(uuid: UUID?, leading: [(command: UInt32, size: Int)] = []) -> Data {
    var commands = Data()
    for (command, size) in leading {
      commands += le(command) + le(UInt32(size)) + Data(count: size - 8)
    }
    if let uuid {
      commands += le(0x1b) + le(24) + withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
    let count = leading.count + (uuid == nil ? 0 : 1)
    // magic, cputype (arm64), cpusubtype, filetype (execute), ncmds, sizeofcmds, flags, reserved
    return le(0xfeed_facf) + le(0x0100_000c) + le(0) + le(2) + le(UInt32(count)) + le(UInt32(commands.count))
      + le(0) + le(0) + commands
  }

  /// A classic universal container whose slices start on 16 KiB boundaries.
  static func universal(_ slices: [Data]) -> Data {
    var header = be(0xcafe_babe) + be(UInt32(slices.count))
    var body = Data()
    var offset = 0x4000
    for slice in slices {
      header += be(0x0100_000c) + be(0) + be(UInt32(offset)) + be(UInt32(slice.count)) + be(14)
      body += Data(count: offset - 0x4000 - body.count) + slice
      offset = ((offset + slice.count) + 0x3fff) & ~0x3fff
    }
    return header + Data(count: 0x4000 - header.count) + body
  }

  private static func le(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
  private static func be(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}
