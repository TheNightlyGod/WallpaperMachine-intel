import Foundation

/// Per-wallpaper facts the renderer's library snapshot does not carry: how much a
/// wallpaper's folder weighs, when it entered the library, whether Wallpaper Engine
/// staff approved it, the Workshop-style tags its manifest implies, and the manifest's
/// words its search reads. Installed sorts on the first two, marks the third, filters on
/// the fourth and searches the last.
///
/// All come from the file system. Summing a folder is a directory walk, and the panel
/// builds a snapshot many times a second, so nothing is measured on the snapshot path:
/// `metrics(for:revision:)` answers from the cache and queues whatever is missing for a
/// background walk, then `onChange` asks the panel for a fresh snapshot once the walk
/// has landed. Until then the page sees `nil` and sorts those wallpapers last.
///
/// A measurement is kept until the folder's own modification date moves (a re-downloaded
/// Workshop item replaces its files) and is checked only when the library itself was
/// reloaded (`revision`), never per snapshot. Ids that leave the library are forgotten.
@MainActor
final class LibraryMetricsService {
  struct Metrics: Equatable {
    /// Sum of the regular files inside the folder, in bytes.
    var size: Int64
    /// When the folder was added to the library (falls back to its creation date).
    var addedAt: Date?
    /// Whether `project.json` carries Wallpaper Engine's staff approval (`approved: true`
    /// or the `Approved` tag).
    var approved = false
    /// Workshop-style tags read from `project.json`, so Installed filters with the same
    /// boxes as Discover: the manifest's genre `tags`, its `contentrating` (Everyone,
    /// Questionable or Mature), `Approved` for staff approval, `Audio responsive` when the
    /// wallpaper declares audio processing and `Customizable` when it ships user properties
    /// beyond the stock scheme colour. Resolution is not in a manifest, so it never appears.
    var tags: [String] = []
    /// The manifest's words as Installed's search reads them, folded (`searchText(project:tags:)`).
    /// Never shown: the author and description are the manifest's own, untrusted text.
    var searchText = ""
    /// The folder's content modification date when it was measured.
    var stamp: Date?
  }

  let libraryURL: URL
  /// Called on the main actor after a background walk stored new values.
  var onChange: (@MainActor () -> Void)?
  private(set) var measured: [String: Metrics] = [:]
  private(set) var contentRevision: UInt64 = 0
  /// Ids the renderer lists but the library folder cannot show; left alone until a reload.
  private var unmeasurable: Set<String> = []
  private var pending: Set<String> = []
  private var task: Task<Void, Never>?
  private var generation = 0
  private var revision: UInt64?

  init(libraryURL: URL = ClientPaths.libraryURL) {
    self.libraryURL = libraryURL
  }

  /// What is known for `ids`. Missing ids are queued for a walk; a changed `revision`
  /// (the library was reloaded) re-checks every kept folder's stamp as well, since a
  /// reload may follow a re-download that replaced a folder's files.
  func metrics(for ids: [String], revision: UInt64) -> [String: Metrics] {
    let wanted = Set(ids)
    for id in measured.keys where !wanted.contains(id) { measured[id] = nil }
    pending.formIntersection(wanted)
    unmeasurable.formIntersection(wanted)
    var queue: Set<String>
    if self.revision != revision {
      self.revision = revision
      unmeasurable.removeAll()
      queue = wanted.subtracting(pending)
    } else {
      queue = wanted.filter {
        measured[$0] == nil && !pending.contains($0) && !unmeasurable.contains($0)
      }
    }
    guard !queue.isEmpty else { return measured }
    pending.formUnion(queue)
    schedule()
    return measured
  }

  /// Drops everything measured so far; the next snapshot measures again.
  func invalidate() {
    contentRevision &+= 1
    generation &+= 1
    task?.cancel()
    task = nil
    pending.removeAll()
    measured.removeAll()
    unmeasurable.removeAll()
    revision = nil
  }

  private func schedule() {
    guard task == nil else { return }
    let generation = generation
    let root = libraryURL
    let batch = pending
    let known = measured
    task = Task { [weak self] in
      let results = await Task.detached(priority: .utility) { () -> [String: Metrics?] in
        var results: [String: Metrics?] = [:]
        for id in batch.sorted() {
          guard !Task.isCancelled else { break }
          let folder = root.appendingPathComponent(id, isDirectory: true)
          if let kept = known[id], kept.stamp != nil, Self.stamp(of: folder) == kept.stamp {
            results[id] = kept
          } else {
            // `.some(nil)` keeps the key: a folder that cannot be measured is an answer too.
            results[id] = .some(Self.measure(folder: folder))
          }
        }
        return results
      }.value
      guard let self, !Task.isCancelled, self.generation == generation else { return }
      var changed = false
      for (id, metrics) in results {
        self.pending.remove(id)
        guard let metrics else {
          self.unmeasurable.insert(id)
          continue
        }
        if self.measured[id] != metrics {
          self.measured[id] = metrics
          changed = true
        }
      }
      self.task = nil
      if !self.pending.isEmpty { self.schedule() }
      if changed { self.contentRevision &+= 1; self.onChange?() }
    }
  }

  nonisolated static func stamp(of folder: URL) -> Date? {
    try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  /// Walks the folder once. A folder that is missing or unreadable measures as empty
  /// with no date rather than failing, so a wallpaper the renderer lists but the file
  /// system cannot show still sorts predictably (last).
  nonisolated static func measure(folder: URL) -> Metrics? {
    guard
      let values = try? folder.resourceValues(forKeys: [
        .isDirectoryKey, .contentModificationDateKey, .addedToDirectoryDateKey,
        .creationDateKey,
      ]), values.isDirectory == true
    else { return nil }
    var size: Int64 = 0
    if let enumerator = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    {
      for case let file as URL in enumerator {
        guard let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          attributes.isRegularFile == true
        else { continue }
        size += Int64(attributes.fileSize ?? 0)
      }
    }
    let manifest = manifest(at: folder.appendingPathComponent("project.json"))
    return Metrics(
      size: size, addedAt: values.addedToDirectoryDate ?? values.creationDate,
      approved: manifest.approved, tags: manifest.tags, searchText: manifest.searchText,
      stamp: values.contentModificationDate)
  }

  /// The manifest's Steam-facing facts and the words its search reads. A missing, oversized
  /// or unreadable manifest is simply not approved and carries no tags or words.
  nonisolated static func manifest(at url: URL) -> (approved: Bool, tags: [String], searchText: String) {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_000_000,
      let data = try? Data(contentsOf: url),
      let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (false, [], "") }
    let approved = approved(project: project)
    let tags = tags(project: project, approved: approved)
    return (approved, tags, searchText(project: project, tags: tags))
  }

  /// How many characters of a description the search reads, which bounds what one runaway
  /// manifest can make the panel keep.
  nonisolated static let searchedDescriptionLength = 8_000

  /// The words beside the title that Installed's search reads, folded (`LibrarySearchText`):
  /// the tags joined by spaces, then on lines of their own the author the manifest names (its
  /// `author`, or that of the `pixiv` block a pixiv save records; a Workshop manifest names
  /// none) and the start of its `description`. A typed query holds no line break, so it never
  /// spans two of them.
  nonisolated static func searchText(project: [String: Any], tags: [String]) -> String {
    let pixiv = project["pixiv"] as? [String: Any]
    let author = project["author"] as? String ?? pixiv?["author"] as? String ?? ""
    let description = (project["description"] as? String).map { String($0.prefix(searchedDescriptionLength)) }
    return [tags.joined(separator: " "), author, description ?? ""].map(LibrarySearchText.fold)
      .joined(separator: "\n")
  }

  /// Wallpaper Engine writes `"approved": true` into the manifest of a staff-approved
  /// Workshop wallpaper and Steam lists the same wallpapers under the `Approved` tag;
  /// either counts.
  nonisolated static func approved(project: [String: Any]) -> Bool {
    if project["approved"] as? Bool == true { return true }
    return (project["tags"] as? [String])?.contains { $0.caseInsensitiveCompare("Approved") == .orderedSame } ?? false
  }

  /// Steam's tags as far as a manifest can tell: genre tags as written (minus any
  /// `Approved`, which staff approval covers), the content rating, and the three
  /// "Show only" facts Discover offers. Each tag appears once, in that order.
  nonisolated static func tags(project: [String: Any], approved: Bool) -> [String] {
    var tags: [String] = []
    var seen: Set<String> = []
    func add(_ tag: String) {
      let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
      tags.append(trimmed)
    }
    for tag in project["tags"] as? [String] ?? [] where tag.caseInsensitiveCompare("Approved") != .orderedSame { add(tag) }
    if let rating = project["contentrating"] as? String { add(rating) }
    if approved { add("Approved") }
    let general = project["general"] as? [String: Any] ?? [:]
    if general["supportsaudioprocessing"] as? Bool == true { add("Audio responsive") }
    let properties = general["properties"] as? [String: Any] ?? [:]
    if properties.keys.contains(where: { $0.lowercased() != "schemecolor" }) { add("Customizable") }
    return tags
  }
}
