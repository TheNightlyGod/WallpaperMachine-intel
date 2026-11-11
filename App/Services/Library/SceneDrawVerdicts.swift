import Foundation

/// What was last learned about whether Native Metal can draw one scene.
struct SceneDrawVerdict: Codable, Equatable, Sendable {
  enum Outcome: String, Codable, Sendable {
    /// Native Metal drew the scene.
    case drawn
    /// The renderer's check read the whole scene and found nothing that keeps Native Metal from
    /// drawing it. Weaker than `drawn`: shader compilation and the render graph come later.
    case passedCheck
    /// Native Metal could not draw it, for a reason the scene's own content decides (something it
    /// does not support, or shaders that do not compile for Metal), so it will not on a retry.
    case notDrawn
  }

  var outcome: Outcome
  /// The bridge's stage name (`unsupported`, `compile`) for `notDrawn`.
  var stage: String?
  /// The renderer's own explanation for `notDrawn`, in English.
  var reason: String?
  /// The app build that reached it: another build's renderer may decide otherwise.
  var build: String
  /// The scene's files when it was reached (see `SceneDrawVerdicts.contentStamp`).
  var content: String
  var recorded: Date
}

/// The last Native Metal verdict on each scene, from the desktop and from compatibility checks, kept
/// in one small JSON file so the Compatibility card can say what is known without running the scene.
///
/// A verdict counts only for the app build and the scene files it was reached with: an update of
/// either makes it unknown again. Only outcomes the scene's content decides are kept; a failure of
/// the surface or of one frame says nothing about the next attempt.
actor SceneDrawVerdicts {
  static let entryLimit = 2_000

  private let file: URL
  private let library: @Sendable () -> URL
  private let build: String
  private var entries: [String: SceneDrawVerdict]
  /// The newest snapshot whose reports were recorded. Each snapshot's reports arrive in a task of
  /// their own, which may run after a newer one's.
  private var recordedRevision: UInt64?

  init(
    file: URL, library: @escaping @Sendable () -> URL = { ClientPaths.libraryURL },
    build: String = SceneDrawVerdicts.currentBuild
  ) {
    self.file = file
    self.library = library
    self.build = build
    do {
      entries =
        FileManager.default.fileExists(atPath: file.path)
        ? try JSONDecoder().decode([String: SceneDrawVerdict].self, from: Data(contentsOf: file))
        : [:]
    } catch {
      // Verdicts are learned again the next time each scene runs or is checked.
      AppLog.error("Scene draw verdicts could not be read and start empty: \(error.localizedDescription)")
      entries = [:]
    }
  }

  static var currentBuild: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? "unknown"
    return "\(version) (\(build))"
  }

  /// The outcome a scene report states about the scene's content, or nil when it states none:
  /// still preparing, or held for a reason a retry can clear.
  static func outcome(backend: String, failureStage: String?) -> SceneDrawVerdict.Outcome? {
    switch failureStage {
    case "unsupported", "compile": return .notDrawn
    case nil: return backend == "native_metal" ? .drawn : nil
    default: return nil
    }
  }

  /// The verdict for `wallpaperID` when it was reached by this build on the scene's current files.
  func verdict(for wallpaperID: String) -> SceneDrawVerdict? {
    guard let entry = entries[wallpaperID], entry.build == build,
      entry.content == contentStamp(wallpaperID)
    else { return nil }
    return entry
  }

  /// Records what the running scenes report; reports that state nothing about the content are skipped.
  /// `revision` orders snapshots: reports older than ones already recorded are dropped, since they
  /// describe scenes that have changed since.
  func record(reports: [BridgeSceneBackendReport], revision: UInt64? = nil) {
    if let revision {
      if let recordedRevision, revision <= recordedRevision { return }
      recordedRevision = revision
    }
    var changed = false
    for report in reports {
      guard let outcome = Self.outcome(backend: report.backend, failureStage: report.failureStage)
      else { continue }
      changed = remember(
        report.wallpaperId, outcome: outcome, stage: report.failureStage, reason: report.failureReason)
        || changed
    }
    if changed { save() }
  }

  /// Records the result of a compatibility check. A check that found nothing wrong does not replace
  /// a scene seen drawing on the same files.
  func record(
    _ wallpaperID: String, outcome: SceneDrawVerdict.Outcome, stage: String?, reason: String?
  ) {
    if remember(wallpaperID, outcome: outcome, stage: stage, reason: reason) { save() }
  }

  private func remember(
    _ wallpaperID: String, outcome: SceneDrawVerdict.Outcome, stage: String?, reason: String?,
    now: Date = Date()
  ) -> Bool {
    guard let content = contentStamp(wallpaperID) else { return false }
    let entry = SceneDrawVerdict(
      outcome: outcome, stage: outcome == .notDrawn ? stage : nil,
      reason: outcome == .notDrawn ? reason : nil, build: build, content: content, recorded: now)
    if let existing = entries[wallpaperID], existing.build == build, existing.content == content {
      if outcome == .passedCheck && existing.outcome == .drawn { return false }
      if existing.outcome == entry.outcome && existing.stage == entry.stage
        && existing.reason == entry.reason
      {
        return false
      }
    }
    entries[wallpaperID] = entry
    if entries.count > Self.entryLimit,
      let oldest = entries.min(by: { $0.value.recorded < $1.value.recorded })?.key
    {
      entries.removeValue(forKey: oldest)
    }
    return true
  }

  /// The size and modification time of the files that define a scene: its manifest, and its
  /// package or scene file. Cheap enough to read for every verdict, and a Workshop update or a
  /// reinstall changes it. Nil when the project has no manifest.
  func contentStamp(_ wallpaperID: String) -> String? {
    guard !wallpaperID.isEmpty, !wallpaperID.contains("/"), wallpaperID != "..", wallpaperID != "."
    else { return nil }
    let root = library().appendingPathComponent(wallpaperID, isDirectory: true)
    var parts: [String] = []
    for name in ["project.json", "scene.pkg", "scene.json"] {
      let url = root.appendingPathComponent(name)
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      else {
        if name == "project.json" { return nil }
        continue
      }
      let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
      parts.append("\(name):\(values.fileSize ?? 0):\(modified)")
    }
    return parts.joined(separator: "|")
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    } catch {
      AppLog.error("Scene draw verdicts could not be saved: \(error.localizedDescription)")
    }
  }
}
