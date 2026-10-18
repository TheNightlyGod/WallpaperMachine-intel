import Foundation

extension PanelPropertyAsset {
  /// What the chosen path offers the importer: its name, and for a folder how many files the import
  /// would take.
  ///
  /// First level only, matching extensions only, and one past the limit so that exceeding it can be
  /// reported rather than silently dropping the remainder. A folder that cannot be read counts
  /// nothing, which the inspector reports as unreadable instead of as empty.
  ///
  /// The three screens beyond the extension (hidden entries, anything that is not a regular file,
  /// anything unreadable) are the ones `UserAssetStore` applies, so this count cannot come out above
  /// what staging would take. A folder named `photos.png` is the case a bare extension test gets
  /// wrong.
  static func measure(path: String, directory: Bool, filter: UserAssetFilter) -> PanelPropertyAsset {
    let url = URL(fileURLWithPath: path)
    var asset = PanelPropertyAsset(path: path, name: url.lastPathComponent)
    guard directory else { return asset }
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
    else { return asset }
    let allowed = filter.allowedExtensions
    let limit = UserAssetStore.defaultDirectoryFileLimit
    var matches = 0
    for entry in entries where allowed.contains(entry.pathExtension.lowercased()) {
      guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
        FileManager.default.isReadableFile(atPath: entry.path)
      else { continue }
      guard matches < limit else {
        asset.truncated = true
        break
      }
      matches += 1
    }
    asset.matches = matches
    return asset
  }

  /// The file types a property accepts. An absent `fileFilter` means the author declared no
  /// file-type option, which the protocol defines as both kinds it knows, not as any file at all.
  static func filter(for value: BridgeFileFilter?) -> UserAssetFilter {
    switch value {
    case .image: .image
    case .video: .video
    case nil: .any
    }
  }
}
