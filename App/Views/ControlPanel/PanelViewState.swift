import Foundation

/// What the control panel's page keeps only in its own memory and would otherwise lose when
/// the window closes: Installed's search, sort and tag filters, and how far each library page
/// was scrolled.
///
/// The page reports it as it changes, native keeps the last valid copy on
/// `ControlPanelNavigation` (memory only, so a fresh launch starts clean), and the reply to a
/// new page's first `ready` hands it back. Property drafts are left out on purpose: a draft
/// restored against a library that changed in between could deliver a stale value.
struct PanelViewState: Codable, Equatable {
  /// The page's Installed filter model, the same fields `installed` holds in `panel.js`.
  struct Installed: Codable, Equatable {
    var text = ""
    var sort = "title"
    var descending = false
    var tags: [String] = []
    var excludedTags: [String] = []
  }

  var installed = Installed()
  /// Scroll offset in pixels of the shared library grid, by the page that was showing.
  var scroll: [String: Double] = [:]

  /// Installed's sort keys, as `installedSorts` in `panel.js` names them.
  static let sorts: Set<String> = ["title", "type", "favorites", "size", "added"]
  /// The pages that draw into the library grid.
  static let pages: Set<String> = ["installed", "discover", "pixiv"]
  static let maxTextLength = 200
  static let maxTags = 32
  static let maxTagLength = 128
  static let maxScroll = 1_000_000.0
  /// Upper bound for the encoded form, so a misbehaving page cannot grow the stored copy.
  static let maxEncodedBytes = 8 * 1024

  init(installed: Installed = Installed(), scroll: [String: Double] = [:]) {
    self.installed = installed
    self.scroll = scroll
  }

  /// Reads the page's report, or returns nil when any part of it is not what the page can
  /// legitimately send: an unknown sort, text or tag lists beyond their limits, a scroll
  /// offset that is negative or not a number, or an encoded form above 8 KB. Pages other
  /// than the library's are skipped rather than refused, so a newer page never invalidates
  /// the rest.
  init?(validating body: [String: Any]) {
    guard let installed = body["installed"] as? [String: Any],
      let text = installed["text"] as? String, text.count <= Self.maxTextLength,
      let sort = installed["sort"] as? String, Self.sorts.contains(sort),
      let descending = Self.flag(installed["descending"]),
      let tags = Self.tagList(installed["tags"]),
      let excludedTags = Self.tagList(installed["excludedTags"])
    else { return nil }
    var scroll: [String: Double] = [:]
    if let reported = body["scroll"] {
      guard let reported = reported as? [String: Any] else { return nil }
      for (page, value) in reported where Self.pages.contains(page) {
        guard let offset = Self.offset(value) else { return nil }
        scroll[page] = min(offset, Self.maxScroll)
      }
    }
    let state = PanelViewState(
      installed: Installed(
        text: text, sort: sort, descending: descending, tags: tags, excludedTags: excludedTags),
      scroll: scroll)
    guard let encoded = try? JSONEncoder().encode(state), encoded.count <= Self.maxEncodedBytes
    else { return nil }
    self = state
  }

  /// The form the page receives: plain values `callAsyncJavaScript` accepts.
  var payload: [String: Any] {
    [
      "installed": [
        "text": installed.text, "sort": installed.sort, "descending": installed.descending,
        "tags": installed.tags, "excludedTags": installed.excludedTags,
      ] as [String: Any],
      "scroll": scroll,
    ]
  }

  private static func flag(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return nil
    }
    return number.boolValue
  }

  private static func offset(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, number.doubleValue >= 0
    else { return nil }
    return number.doubleValue
  }

  private static func tagList(_ value: Any?) -> [String]? {
    guard let tags = value as? [String], tags.count <= maxTags,
      tags.allSatisfy({ $0.count <= maxTagLength })
    else { return nil }
    return tags
  }
}
