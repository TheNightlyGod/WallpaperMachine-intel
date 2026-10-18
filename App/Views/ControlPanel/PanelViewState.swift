import Foundation

/// What the panel would otherwise lose when its window closes: Installed's search, sort and tag
/// filters, and how far each library page was scrolled.
///
/// The open window keeps it current, `ControlPanelNavigation` holds the last copy that
/// `normalized()` accepted (memory only, so a fresh launch starts clean), and the next window
/// restores from it once. Property drafts are left out on purpose: a draft restored against a
/// library that changed in between could deliver a stale value.
struct PanelViewState: Codable, Equatable {
  /// Installed's filter model.
  struct Installed: Codable, Equatable {
    var text = ""
    var sort = "title"
    var descending = false
    var tags: [String] = []
    var excludedTags: [String] = []
  }

  var installed = Installed()
  /// Scroll offset in points of the shared library grid, by the page that was showing.
  var scroll: [String: Double] = [:]

  /// Installed's sort keys.
  static let sorts: Set<String> = ["title", "type", "favorites", "size", "added"]
  /// The pages that draw into the library grid.
  static let pages: Set<String> = ["installed", "discover", "pixiv"]
  static let maxTextLength = 200
  static let maxTags = 32
  static let maxTagLength = 128
  static let maxScroll = 1_000_000.0
  /// Upper bound for the encoded form, so a runaway filter cannot grow the stored copy.
  static let maxEncodedBytes = 8 * 1024

  init(installed: Installed = Installed(), scroll: [String: Double] = [:]) {
    self.installed = installed
    self.scroll = scroll
  }

  /// The state in the form the panel may keep, or nil when any part is outside its limit: an
  /// unknown sort, text or tag lists beyond their limits, a scroll offset that is negative or not
  /// a number, or an encoded form above 8 KB. Offsets above `maxScroll` are clamped, and pages
  /// that do not draw into the library grid are dropped, so a newer page never invalidates the
  /// rest.
  func normalized() -> PanelViewState? {
    guard installed.text.count <= Self.maxTextLength, Self.sorts.contains(installed.sort),
      Self.isTagList(installed.tags), Self.isTagList(installed.excludedTags)
    else { return nil }
    var kept: [String: Double] = [:]
    for (page, offset) in scroll where Self.pages.contains(page) {
      guard offset.isFinite, offset >= 0 else { return nil }
      kept[page] = min(offset, Self.maxScroll)
    }
    let state = PanelViewState(installed: installed, scroll: kept)
    guard let encoded = try? JSONEncoder().encode(state), encoded.count <= Self.maxEncodedBytes
    else { return nil }
    return state
  }

  private static func isTagList(_ tags: [String]) -> Bool {
    tags.count <= maxTags && tags.allSatisfy { $0.count <= maxTagLength }
  }
}
