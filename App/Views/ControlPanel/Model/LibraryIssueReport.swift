import Foundation

/// GitHub's new-issue form, pre-filled with a wallpaper, the app version and what the panel knows
/// about it: the failure the user just saw and the backend drawing it, fallback reason included.
/// Nothing is sent from here: the browser opens the draft and the user decides whether to submit it.
enum LibraryIssueReport {
  /// - Parameters:
  ///   - row: The installed wallpaper the report is about.
  ///   - failure: Why applying it just failed, when it did.
  ///   - renderers: What drew it, one entry for each backend that did (see `renderers(for:in:)`).
  ///   - version: The running app's version; "unknown" when the bundle has none.
  static func url(
    for row: LibraryRow, failure: String? = nil, renderers: [String] = [],
    version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String
  ) -> URL? {
    let workshop = ExternalLink.workshopItem(id: row.id)?.absoluteString ?? row.id
    var facts = [
      "**Wallpaper:** \(row.title)", "**Workshop item:** \(workshop)", "**Type:** \(row.kind.rawValue)",
      "**App version:** \(version ?? "unknown")",
    ]
    if !renderers.isEmpty { facts.append("**Renderer:** \(renderers.joined(separator: "; "))") }
    if let failure { facts.append("**Error:** \(failure)") }
    return ExternalLink.newIssue(
      title: "[\(row.kind.rawValue)] \(row.title)",
      body: (facts + ["", "**What went wrong?**", "", ""]).joined(separator: "\n"))
  }

  /// The backends the engine reports for `wallpaperID`, each once, in the order the scene reports
  /// and then the video reports name them: `legacy_vulkan (fallback: lit particles)`.
  static func renderers(for wallpaperID: String, in settings: BridgeSettingsSnapshot) -> [String] {
    var seen = Set<String>()
    let reports =
      settings.sceneRenderers.map { ($0.wallpaperId, $0.backend, $0.fallbackReason) }
      + settings.videoBackends.map { ($0.wallpaperId, $0.backend, $0.fallbackReason) }
    return reports.compactMap { id, backend, reason in
      guard id == wallpaperID, !backend.isEmpty else { return nil }
      let name = reason.map { "\(backend) (fallback: \($0))" } ?? backend
      return seen.insert(name).inserted ? name : nil
    }
  }
}
