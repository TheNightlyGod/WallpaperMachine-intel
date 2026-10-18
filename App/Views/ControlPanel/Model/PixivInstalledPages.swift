import Foundation

/// Which pages of pixiv works are in the library, read off the wallpaper ids the packager gives
/// them: `pixiv-<work>-p<page>`.
enum PixivInstalledPages {
  /// The saved pages of every work among `ids`, sorted. An id counts only in the exact form the
  /// packager writes: three parts, a valid work id, and `p` followed by a canonical integer
  /// (no leading zeros, no sign), so `pixiv-42-p01`, `pixiv-0-p0` and `pixiv-42-p2-extra` are
  /// someone else's wallpapers.
  static func index(in ids: [String]) -> [String: [Int]] {
    var pages: [String: [Int]] = [:]
    for id in ids where id.hasPrefix("pixiv-") {
      let parts = id.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 3, PixivWork.isValidID(String(parts[1])), parts[2].first == "p",
        let page = Int(parts[2].dropFirst()), page >= 0, String(page) == parts[2].dropFirst()
      else { continue }
      pages[String(parts[1]), default: []].append(page)
    }
    return pages.mapValues { $0.sorted() }
  }
}
