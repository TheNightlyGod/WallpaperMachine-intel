import Foundation
import WallpaperMedia

/// Why a Matroska or WebM file cannot be played.
struct WebMOpenFailure: Error, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// The bytes are not Matroska or WebM at all.
    case notMatroska
    /// A valid file whose video this Mac or this app does not play. `format` names the codec
    /// as a person would ("VP8", "AV1"), and is nil when the file said nothing usable.
    case unsupported(format: String?)
    /// Cut off or damaged beyond what the reader tolerates.
    case damaged
    /// The file could not be read at all: a busy volume, a file that went away.
    case unreadable
  }

  var kind: Kind
  /// The reader's own words, for the log. Not for a person: the app words refusals itself.
  var detail: String
}

/// The file objects the readers hand out are immutable once opened and every reader over one
/// keeps its own position, so a file can be handed between queues.
extension WebMFile: @unchecked @retroactive Sendable {}

/// Opens Matroska and WebM files for playback. The project's own reader (Renderer/Media)
/// indexes the file, so this reads headers and block headers and can take as long as a slow
/// volume makes it: call it off the main thread.
enum WebMOpening {
  static func open(url: URL) -> Result<WebMFile, WebMOpenFailure> {
    do { return .success(try WebMFile.open(at: url)) } catch { return .failure(failure(from: error as NSError)) }
  }

  static func open(data: Data) -> Result<WebMFile, WebMOpenFailure> {
    do { return .success(try WebMFile.open(with: data)) } catch { return .failure(failure(from: error as NSError)) }
  }

  private static func failure(from error: NSError) -> WebMOpenFailure {
    let detail = error.localizedDescription
    guard error.domain == WMWebMErrorDomain else {
      return WebMOpenFailure(kind: .unreadable, detail: detail)
    }
    switch WMWebMError.Code(rawValue: error.code) {
    case .notMatroska:
      return WebMOpenFailure(kind: .notMatroska, detail: detail)
    case .unsupportedFormat:
      let name = error.userInfo[WMWebMFormatNameKey] as? String
      return WebMOpenFailure(kind: .unsupported(format: name), detail: detail)
    case .damaged:
      return WebMOpenFailure(kind: .damaged, detail: detail)
    default:
      return WebMOpenFailure(kind: .unreadable, detail: detail)
    }
  }
}

/// Files opened to judge a wallpaper, kept for the surface that plays them, so a file the format check
/// has just indexed is not indexed again. A handful at most, each tied to the file's size and
/// modification time: a file that changed on disk is a different entry.
final class WebMOpenedFiles: @unchecked Sendable {
  static let shared = WebMOpenedFiles()
  static let capacity = 4

  private struct Key: Hashable {
    var path: String
    var size: Int64
    var modified: TimeInterval
  }

  private let lock = NSLock()
  private var entries: [(key: Key, file: WebMFile)] = []

  private func key(for url: URL) -> Key? {
    // A URL caches what it read; the file may have changed since.
    var fresh = url
    fresh.removeAllCachedResourceValues()
    guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
      let size = values.fileSize
    else { return nil }
    return Key(
      path: url.standardizedFileURL.path, size: Int64(size),
      modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
  }

  func store(_ file: WebMFile, for url: URL) {
    guard let key = key(for: url) else { return }
    lock.withLock {
      entries.removeAll { $0.key == key }
      entries.append((key, file))
      if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
  }

  func file(for url: URL) -> WebMFile? {
    guard let key = key(for: url) else { return nil }
    return lock.withLock { entries.last { $0.key == key }?.file }
  }

  func removeAll() { lock.withLock { entries.removeAll() } }
}
