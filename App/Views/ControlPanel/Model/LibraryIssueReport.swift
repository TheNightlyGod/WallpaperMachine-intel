import Foundation

/// GitHub's bug report form, pre-filled with a wallpaper, the app version and what the panel knows
/// about it: the failure the user just saw and the backend drawing it, fallback reason included.
/// What went wrong is left for the user, whom the form asks for it.
/// Nothing is sent from here: the browser opens the draft and the user decides whether to submit it.
enum LibraryIssueReport {
  /// - Parameters:
  ///   - row: The installed wallpaper the report is about.
  ///   - failure: Why applying it just failed, when it did.
  ///   - renderers: What drew it, one entry for each backend that did (see `renderers(for:in:)`).
  ///   - properties: Its property rows, when the panel has them; the ones changed from the author's
  ///     default are listed (see `changedProperties(_:)`).
  ///   - missingFiles: The files the scene names and lacks, from the last compatibility check of it.
  ///   - version: The running app's version; "unknown" when the bundle has none.
  static func url(
    for row: LibraryRow, failure: String? = nil, renderers: [String] = [],
    properties: [BridgePropertyDescriptor] = [], missingFiles: [MissingSceneFile] = [],
    version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String
  ) -> URL? {
    let workshop = ExternalLink.workshopItem(id: row.id)?.absoluteString ?? row.id
    var facts = ["**Wallpaper:** \(row.title)", "**Type:** \(row.kind.rawValue)"]
    if !renderers.isEmpty { facts.append("**Renderer:** \(renderers.joined(separator: "; "))") }
    if let failure { facts.append("**Error:** \(failure)") }
    let changed = changedProperties(properties)
    if !changed.isEmpty { facts.append(contentsOf: ["**Changed properties:**"] + changed) }
    if !missingFiles.isEmpty {
      let listed = missingFiles.prefix(changedPropertyLimit).map { file in
        "- `\(file.path)`" + (file.layer.isEmpty ? "" : " (layer “\(file.layer)”)")
      }
      let rest = missingFiles.count > changedPropertyLimit
        ? ["- and \(missingFiles.count - changedPropertyLimit) more"] : []
      facts.append(contentsOf: ["**Missing files:**"] + listed + rest)
    }
    return ExternalLink.newIssue(
      title: "[\(row.kind.rawValue)] \(row.title)", wallpaper: workshop, version: version ?? "unknown",
      details: facts.joined(separator: "\n"))
  }

  /// The most property lines a report lists; the rest are counted, so the draft stays inside what a
  /// browser address carries.
  static let changedPropertyLimit = 20

  /// One line for each property whose value is not the author's default, so a Wallpaper Engine
  /// reference frame can be taken with the same options. Text the user typed and the paths of files
  /// they chose are left out: the line says the property was changed, not to what.
  static func changedProperties(_ properties: [BridgePropertyDescriptor]) -> [String] {
    let lines: [String] = properties.compactMap { property in
      guard property.value != property.defaultValue else { return nil }
      let shown: String
      switch property.kind {
      case .slider, .combo, .bool, .color:
        shown = "\(text(property.value)) (default: \(text(property.defaultValue)))"
      case .file, .directory, .texture: shown = "a file the user chose"
      case .textInput: shown = "text the user typed"
      case .text, .group, .unknown: return nil
      }
      return "- `\(property.id)`: \(shown)\(property.dirty ? " (not applied)" : "")"
    }
    guard lines.count > changedPropertyLimit else { return lines }
    return lines.prefix(changedPropertyLimit) + ["- and \(lines.count - changedPropertyLimit) more"]
  }

  /// A value the way a project file writes it: numbers without a locale and with every digit, so
  /// the option can be set again exactly, a colour as three numbers.
  private static func text(_ value: BridgePropertyValue) -> String {
    switch value {
    case .bool(let value): return value ? "true" : "false"
    case .number(let value): return number(value)
    case .string(let value): return value
    case .colorRgb(let red, let green, let blue): return [red, green, blue].map(number).joined(separator: " ")
    case .empty: return "none"
    }
  }

  /// A whole number without a fraction ("1", not "1.0"); anything else in its shortest exact form.
  private static func number(_ value: Double) -> String {
    if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
  }

  /// The backends the engine reports for `wallpaperID`, each once, in the order the scene reports
  /// and then the video reports name them: `native_metal`, or `not drawn (unsupported: …)` for a held scene.
  static func renderers(for wallpaperID: String, in settings: BridgeSettingsSnapshot) -> [String] {
    var seen = Set<String>()
    let reports =
      settings.sceneRenderers.map { ($0.wallpaperId, $0.backend, String?.none, $0.failureStage, $0.failureReason) }
      + settings.videoBackends.map { ($0.wallpaperId, $0.backend, $0.fallbackReason, String?.none, String?.none) }
    return reports.compactMap { id, backend, reason, failure, failureReason in
      guard id == wallpaperID, !backend.isEmpty else { return nil }
      // A scene held by Native Metal only has no backend to name: the failure is the renderer fact.
      let name =
        failure.map { "not drawn (\($0)\(failureReason.map { ": \($0)" } ?? ""))" }
        ?? reason.map { "\(backend) (fallback: \($0))" } ?? backend
      return seen.insert(name).inserted ? name : nil
    }
  }
}
