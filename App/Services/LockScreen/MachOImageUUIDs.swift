import Foundation

/// Reads the build UUIDs (`LC_UUID`) of a Mach-O executable file, one per architecture slice.
/// The kernel reports the same UUID for a running process (`proc_pid_rusage`), so comparing
/// the two tells which build a process runs even after its file was deleted.
///
/// Only 64-bit little-endian images are understood, thin or inside a classic universal
/// container. Anything else, or anything malformed, yields no UUID: callers must treat that
/// as "unknown", never as a mismatch.
enum MachOImageUUIDs {
  /// Reads `length` bytes at `offset`, or nil when the file cannot supply them.
  typealias Reader = (_ offset: UInt64, _ length: Int) -> Data?

  private static let thinMagic: UInt32 = 0xfeed_facf
  private static let universalMagic: UInt32 = 0xcafe_babe
  private static let uuidCommand: UInt32 = 0x1b
  private static let thinHeaderSize = 32
  /// Load commands of real binaries take a few kilobytes; a larger claim is not trusted.
  private static let maxCommandsSize = 1 << 20
  private static let maxSlices = 16

  static func uuids(at url: URL) -> Set<UUID> {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    return uuids { offset, length in
      guard (try? handle.seek(toOffset: offset)) != nil,
        let data = try? handle.read(upToCount: length), data.count == length
      else { return nil }
      return data
    }
  }

  static func uuids(read: Reader) -> Set<UUID> {
    guard let head = read(0, 8), head.count == 8 else { return [] }
    if bigEndian32(head, at: 0) == universalMagic {
      let count = Int(bigEndian32(head, at: 4))
      guard count > 0, count <= maxSlices, let table = read(8, count * 20), table.count == count * 20
      else { return [] }
      var found = Set<UUID>()
      for slice in 0..<count {
        // fat_arch: cputype, cpusubtype, offset, size, align (all big-endian, 4 bytes each).
        let offset = UInt64(bigEndian32(table, at: slice * 20 + 8))
        found.formUnion(thinUUIDs(read: read, at: offset))
      }
      return found
    }
    return thinUUIDs(read: read, at: 0)
  }

  private static func thinUUIDs(read: Reader, at base: UInt64) -> Set<UUID> {
    guard let header = read(base, thinHeaderSize), header.count == thinHeaderSize,
      littleEndian32(header, at: 0) == thinMagic
    else { return [] }
    let commandCount = Int(littleEndian32(header, at: 16))
    let commandsSize = Int(littleEndian32(header, at: 20))
    guard commandsSize > 0, commandsSize <= maxCommandsSize,
      let commands = read(base + UInt64(thinHeaderSize), commandsSize), commands.count == commandsSize
    else { return [] }

    var found = Set<UUID>()
    var offset = 0
    for _ in 0..<commandCount {
      guard offset + 8 <= commandsSize else { break }
      let command = littleEndian32(commands, at: offset)
      let size = Int(littleEndian32(commands, at: offset + 4))
      guard size >= 8, offset + size <= commandsSize else { break }
      if command == uuidCommand, size >= 24 {
        let start = commands.startIndex + offset + 8
        found.insert(UUID(uuid: commands[start..<start + 16].withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }))
      }
      offset += size
    }
    return found
  }

  private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
  }

  private static func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
  }
}
