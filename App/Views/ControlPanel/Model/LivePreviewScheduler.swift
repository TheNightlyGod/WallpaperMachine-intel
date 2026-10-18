import Foundation

/// Decides which Discover tiles load their animated preview, and when.
///
/// Every tile shows its cached still at once; the animation follows only for a tile that is on
/// screen and whose still has arrived, and only after every still of the page has settled (loaded
/// or failed), so a slow link reveals the whole page before any tile spends bandwidth on motion.
/// At most six animations load at once, in grid order. A tile that scrolls out of view, a hidden
/// window or leaving the page releases its animation (the disk cache keeps the bytes, so coming back
/// is a local read), and one that failed, a single-frame preview among them, is never retried by
/// scrolling. The grid reports what it shows and what happened; this type keeps the books.
struct LivePreviewScheduler {
  /// How many animations load at once.
  static let concurrency = 6

  enum State: Equatable {
    /// Wanted, waiting for the window, the stills or a free place.
    case queued
    /// The animation is being fetched or decoded.
    case loading
    /// It plays.
    case ready
    /// It could not be shown; the still stays and it is not tried again.
    case failed
  }

  /// A tile of the grid, in grid order.
  struct Tile: Equatable {
    let id: String
    /// The tile is inside the grid's visible part.
    let isOnScreen: Bool
    /// The item has an animated preview and a still to replace.
    let hasAnimation: Bool
    /// The still has arrived and has a size.
    let hasStill: Bool
  }

  private(set) var states: [String: State] = [:]
  private var tiles: [Tile] = []
  private var stillsSettled = false
  private var isHidden = false

  /// Whether the tile's animation should be attached right now, loading or playing.
  func isAttached(_ id: String) -> Bool { states[id] == .loading || states[id] == .ready }

  /// Whether the animation has replaced the still.
  func isPlaying(_ id: String) -> Bool { states[id] == .ready }

  /// Re-evaluates after anything changed: a still settled, the grid scrolled or resized, the
  /// window hid or showed, a new page arrived.
  mutating func update(tiles: [Tile], stillsSettled: Bool, isHidden: Bool) {
    self.tiles = tiles
    self.stillsSettled = stillsSettled
    self.isHidden = isHidden
    let canLoad = !isHidden && stillsSettled
    for tile in tiles {
      let state = states[tile.id]
      if isHidden || !tile.isOnScreen {
        // Keeps the still and the disk cache, releases the decoder.
        if state == .loading || state == .ready { states[tile.id] = .queued }
        continue
      }
      if canLoad, state == nil, tile.hasAnimation, tile.hasStill { states[tile.id] = .queued }
    }
    pump()
  }

  /// The tile's animation loaded and plays (`loaded`), or could not be shown. Only an animation
  /// that was attached can settle.
  mutating func finish(_ id: String, loaded: Bool) {
    guard isAttached(id) else { return }
    states[id] = loaded ? .ready : .failed
    pump()
  }

  /// Forgets the tiles that are no longer on the page, so they are asked for afresh if they return.
  mutating func retire(keeping ids: Set<String>) {
    states = states.filter { ids.contains($0.key) }
  }

  /// Leaving Discover releases every animation and forgets which failed.
  mutating func releaseAll() {
    states = [:]
    tiles = []
  }

  /// Fills the free places, in grid order, with visible tiles that wait.
  private mutating func pump() {
    guard !isHidden, stillsSettled else { return }
    var loading = states.values.filter { $0 == .loading }.count
    for tile in tiles {
      if loading >= Self.concurrency { break }
      guard states[tile.id] == .queued, tile.isOnScreen else { continue }
      states[tile.id] = .loading
      loading += 1
    }
  }
}
