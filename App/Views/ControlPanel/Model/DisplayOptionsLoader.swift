import Foundation
import Observation

/// Reads the saved options of every wallpaper shown on another display, for Settings › Displays.
///
/// The bridge reports options for the one wallpaper the inspector has open, but each display row
/// shows the scaling, frame rate and volume of its *own* wallpaper's configuration. So while
/// Settings is on screen in a visible window, this fetches the options of each distinct wallpaper
/// on a display that does not mirror another, other than the open one.
///
/// What keeps it cheap and correct:
/// - It runs only while `isActive` says so, and fetches once per `store.snapshotRevision`. The
///   revision is recorded before the first read, so a failure falls back to the saved values and
///   never loops; leaving and re-entering, or a new revision, asks again.
/// - Reads are sequential, and every step re-checks the generation, the revision and `isActive`
///   after each await, so a cancelled or outdated read can neither overwrite newer options nor
///   resurrect a display that is gone.
/// - A row consumes the result only while `revision` equals the store's, so options read for an
///   older snapshot are never shown.
@MainActor
@Observable
final class DisplayOptionsLoader {
  /// Options by wallpaper id, as last read for `revision`.
  private(set) var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
  /// The snapshot revision the fetch was started for; nil when nothing is fetched or held.
  private(set) var revision: UInt64?

  @ObservationIgnored private let store: BridgeStore
  @ObservationIgnored private let isActive: @MainActor () -> Bool
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation: UInt64 = 0

  /// `isActive` is true while the options can be seen: the panel is visible, running, and on
  /// Settings.
  init(store: BridgeStore, isActive: @escaping @MainActor () -> Bool) {
    self.store = store
    self.isActive = isActive
  }

  /// The options read for `wallpaperID` for the store's current snapshot, or nil when none were
  /// read or they are older.
  func options(for wallpaperID: String) -> BridgeWallpaperOptionsSnapshot? {
    guard revision == store.snapshotRevision else { return nil }
    return options[wallpaperID]
  }

  /// Starts the fetch the current state calls for, or drops what no longer applies. Safe to call
  /// on every change of the inputs: with nothing new to read it does nothing.
  func refresh() {
    guard isActive() else {
      cancel()
      return
    }
    let revision = store.snapshotRevision
    guard self.revision != revision else { return }
    cancel()
    self.revision = revision
    var ids = Set<String>()
    for row in store.monitorInformationSnapshot.rows
    where row.mirrorTargetDisplayId == nil && !row.wallpaperId.isEmpty
      && row.wallpaperId != store.wallpaperOptionsSnapshot?.wallpaperId
    {
      ids.insert(row.wallpaperId)
    }
    guard !ids.isEmpty else { return }
    let generation = generation
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.generation == generation { self.task = nil }
      }
      var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
      for id in ids {
        guard self.stillWanted(generation, revision) else { return }
        let value = try? await self.store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
        guard self.stillWanted(generation, revision) else { return }
        if let value { options[id] = value }
      }
      guard self.stillWanted(generation, revision) else { return }
      self.options = options
    }
  }

  /// Drops the options and stops reading; the next `refresh()` reads again.
  func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
    revision = nil
    if !options.isEmpty { options.removeAll() }
  }

  /// Resolves once the fetch has ended, so a test never sleeps for one.
  func settled() async {
    while let task { await task.value }
  }

  private func stillWanted(_ generation: UInt64, _ revision: UInt64) -> Bool {
    !Task.isCancelled && self.generation == generation && store.snapshotRevision == revision
      && isActive()
  }
}
