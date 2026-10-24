import Foundation
import Observation

/// Loads Discover's stills and, once they are all in, the animated previews of the tiles on screen.
///
/// Every tile shows its cached still at once. A tile on screen whose still has arrived then asks for
/// its animation, but only after every still of the page has settled (loaded or failed), so a slow
/// link shows the whole page before any tile spends bandwidth on motion; `LivePreviewScheduler`
/// keeps those books, at most six animations loading at once and in grid order. A tile that
/// scrolls away, a hidden window and leaving the page release their animation (the disk cache keeps
/// the bytes), and one that failed, a single-frame preview among them, is never asked again by
/// scrolling. The animations are played by `AnimatedPreview`, which draws one decoded frame at a
/// time: nothing is ever read back from the screen.
///
/// The stills are fetched here at the size the tiles draw them (`PanelImage` asks for the same
/// pixels), so the tile finds its image already in the pipeline's memory.
@MainActor
@Observable
final class WorkshopPreviewCoordinator {
  /// What the coordinator needs to know of a tile of the page.
  struct Tile: Equatable {
    let id: String
    /// The still the tile draws; nil when Steam gave no usable preview.
    let still: PanelImageSource?
    /// The tile may play an animation: it has a Steam preview and is not installed (an installed
    /// copy shows the library's own cover).
    let animates: Bool
  }

  @ObservationIgnored private let images: PanelImagePipeline
  /// The scheduler's books, observed so a tile starts or stops playing as they change.
  private(set) var scheduler = LivePreviewScheduler()
  /// The animation bytes of the tiles that play, by tile id.
  private(set) var animations: [String: Data] = [:]

  @ObservationIgnored private var tiles: [Tile] = []
  @ObservationIgnored private var onScreen = Set<String>()
  @ObservationIgnored private var isHidden = false
  /// Whether each tile's still loaded, once it has settled.
  @ObservationIgnored private var stills: [String: Bool] = [:]
  @ObservationIgnored private var stillTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var animationTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var stillPixels = 0
  /// How many animation requests have been started, for tests: each preview downloads once.
  @ObservationIgnored private(set) var animationRequests = 0

  init(images: PanelImagePipeline) { self.images = images }

  // MARK: What the page reports

  /// A page arrived or its tiles changed: forgets the tiles that left, loads the stills of the
  /// others. `stillPixels` is the size `PanelImage` decodes them at.
  func pageChanged(_ tiles: [Tile], stillPixels: Int) {
    self.tiles = tiles
    let ids = Set(tiles.map(\.id))
    let pixelsChanged = self.stillPixels != stillPixels
    self.stillPixels = stillPixels
    for id in stillTasks.keys where !ids.contains(id) || pixelsChanged {
      stillTasks.removeValue(forKey: id)?.cancel()
    }
    if pixelsChanged { stills = [:] }
    stills = stills.filter { ids.contains($0.key) }
    onScreen.formIntersection(ids)
    // A tile that cannot animate (an installed copy) gives its place back.
    scheduler.retire(keeping: Set(tiles.filter(\.animates).map(\.id)))
    for tile in tiles {
      guard let source = tile.still, stills[tile.id] == nil, stillTasks[tile.id] == nil else {
        continue
      }
      stillTasks[tile.id] = Task { [weak self, images] in
        let loaded = (try? await images.image(for: source, maxPixelSize: stillPixels)) != nil
        guard !Task.isCancelled else { return }
        self?.stillSettled(tile.id, loaded: loaded)
      }
    }
    refresh()
  }

  /// A tile came into or left the grid's visible part.
  func setOnScreen(_ id: String, _ isOnScreen: Bool) {
    guard isOnScreen != onScreen.contains(id) else { return }
    if isOnScreen { onScreen.insert(id) } else { onScreen.remove(id) }
    refresh()
  }

  /// The window hid or showed.
  func setHidden(_ hidden: Bool) {
    guard hidden != isHidden else { return }
    isHidden = hidden
    refresh()
  }

  /// Leaving Discover: every animation is released and the failed ones are forgotten.
  func releaseAll() {
    for task in stillTasks.values { task.cancel() }
    for task in animationTasks.values { task.cancel() }
    stillTasks = [:]
    animationTasks = [:]
    animations = [:]
    stills = [:]
    tiles = []
    onScreen = []
    scheduler.releaseAll()
  }

  // MARK: What the tiles read

  func animation(for id: String) -> Data? { animations[id] }

  /// The animation has replaced the still.
  func isPlaying(_ id: String) -> Bool { scheduler.isPlaying(id) }

  // MARK: Books

  private func stillSettled(_ id: String, loaded: Bool) {
    stillTasks[id] = nil
    stills[id] = loaded
    refresh()
  }

  /// Re-evaluates after anything changed, then starts and stops the loads the scheduler decided.
  private func refresh() {
    // A tile without a still has nothing to wait for; the rest must all have settled.
    let settled = tiles.allSatisfy { $0.still == nil || stills[$0.id] != nil }
    scheduler.update(
      tiles: tiles.map { tile in
        LivePreviewScheduler.Tile(
          id: tile.id, isOnScreen: onScreen.contains(tile.id), hasAnimation: tile.animates,
          hasStill: stills[tile.id] == true)
      },
      stillsSettled: settled, isHidden: isHidden)
    // Released by key, not by the current tiles: a tile that left the page is detached too, and its
    // bytes must not outlive it.
    for id in Array(animationTasks.keys) where !scheduler.isAttached(id) {
      animationTasks.removeValue(forKey: id)?.cancel()
    }
    for id in animations.keys.filter({ !scheduler.isAttached($0) }) { animations[id] = nil }
    for tile in tiles where scheduler.isAttached(tile.id) {
      if animationTasks[tile.id] == nil, animations[tile.id] == nil, let source = tile.still {
        start(tile.id, source)
      }
    }
  }

  private func start(_ id: String, _ source: PanelImageSource) {
    animationRequests += 1
    animationTasks[id] = Task { [weak self, images] in
      do {
        let data = try await images.animation(for: source)
        guard !Task.isCancelled else { return }
        self?.animationArrived(id, data: data)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self?.animationArrived(id, data: nil)
      }
    }
  }

  private func animationArrived(_ id: String, data: Data?) {
    animationTasks[id] = nil
    // A tile released while its animation was on the way takes nothing.
    guard scheduler.isAttached(id) else { return }
    if let data { animations[id] = data }
    scheduler.finish(id, loaded: data != nil)
    refresh()
  }
}
