import Foundation

/// A decoded image filter: a colour cube of `size`³ entries as RGBA Float32, red fastest, the
/// layout `CIColorCubeWithColorSpace` takes.
struct VideoLut: Equatable, Sendable {
  let size: Int
  let cube: Data
}

/// Decodes Wallpaper Engine's volume `.tex` LUTs (`materials/lut/<name>.tex`) through the
/// renderer (`owe_lut_load_rgba8`), once per file: a process-wide cache keyed by path and
/// modification time keeps the last four.
enum VideoLutLoader {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var cache: [(key: String, lut: VideoLut)] = []
  private static let capacity = 4

  static func load(_ url: URL) -> VideoLut? {
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate?.timeIntervalSince1970 ?? 0
    let key = "\(url.path)|\(modified)"
    lock.lock()
    if let hit = cache.first(where: { $0.key == key }) {
      lock.unlock()
      return hit.lut
    }
    lock.unlock()
    guard let lut = decode(url) else { return nil }
    lock.lock()
    cache.removeAll { $0.key == key }
    cache.append((key, lut))
    if cache.count > capacity { cache.removeFirst(cache.count - capacity) }
    lock.unlock()
    return lut
  }

  private static func decode(_ url: URL) -> VideoLut? {
    url.path.withCString { path -> VideoLut? in
      var size: UInt32 = 0
      guard owe_lut_load_rgba8(path, &size, nil, 0) == 0, size > 1, size <= 128 else { return nil }
      let requestedSize = size
      let count = Int(size) * Int(size) * Int(size) * 4
      var bytes = [UInt8](repeating: 0, count: count)
      let status = bytes.withUnsafeMutableBufferPointer {
        owe_lut_load_rgba8(path, &size, $0.baseAddress, count)
      }
      guard status == 0, size == requestedSize else { return nil }
      // ccsimple samples only the LUT's RGB; the table must not alter video alpha.
      let floats = bytes.enumerated().map { index, byte in index % 4 == 3 ? Float(1) : Float(byte) / 255 }
      return VideoLut(size: Int(size), cube: floats.withUnsafeBufferPointer { Data(buffer: $0) })
    }
  }
}
