import Foundation

/// The facts that say whether a video file is still the file that was examined: its size,
/// modification date and file-system identity. Two reads that disagree mean it was replaced.
struct VideoFileStamp: Hashable, Sendable {
  let size: Int
  let modified: Date?
  let identity: String

  init(size: Int, modified: Date?, identity: String) {
    self.size = size
    self.modified = modified
    self.identity = identity
  }

  init(url: URL) throws {
    // A URL value caches the resource values it has been asked for, so a second read through the
    // same URL would repeat the first answer and never see a file replaced in between.
    var uncached = url
    uncached.removeAllCachedResourceValues()
    let values = try uncached.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
    ])
    self.init(size: values.fileSize ?? 0, modified: values.contentModificationDate,
              identity: values.fileResourceIdentifier.map { String(describing: $0) } ?? "")
  }
}
