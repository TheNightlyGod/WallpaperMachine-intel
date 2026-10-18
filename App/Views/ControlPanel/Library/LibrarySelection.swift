import CoreGraphics
import Foundation

/// The wallpapers ticked for a batch action (Add to playlist, a collection, Move to Trash), apart
/// from the one the inspector shows.
///
/// The set keeps the order ticks were made in, which is the order a batch is sent in, and an
/// anchor: the tile a Shift-click extends from. It lives as long as the window, not as long as
/// what is on screen: switching the view, searching, filtering, sorting or visiting another page
/// leaves it as it is, and a batch action reaches every member, hidden ones included. (The
/// confirmation of a Move to Trash names the whole count.) The one thing that removes members on
/// its own is a wallpaper leaving the library.
struct LibrarySelection: Equatable, Sendable {
  /// The members, in the order they were ticked.
  private(set) var ids: [String] = []
  private var members = Set<String>()
  /// The tile a Shift-click extends from: the last one ticked on.
  private(set) var anchor: String?

  var isEmpty: Bool { ids.isEmpty }
  var count: Int { ids.count }

  func contains(_ id: String) -> Bool { members.contains(id) }

  @discardableResult
  private mutating func insert(_ id: String) -> Bool {
    guard members.insert(id).inserted else { return false }
    ids.append(id)
    return true
  }

  private mutating func remove(_ id: String) {
    guard members.remove(id) != nil else { return }
    ids.removeAll { $0 == id }
  }

  /// A click on a tile while selecting.
  ///
  /// With `range` and an anchor that is on screen, every tile between the anchor and `id` in the
  /// order shown joins the selection; it never removes anything and the anchor stays. Otherwise the
  /// tile is ticked or unticked, and the anchor moves to it only when it was ticked.
  ///
  /// - Parameter visible: The ids on screen, in order.
  mutating func toggle(_ id: String, range: Bool = false, visible: [String] = []) {
    if range, let anchor, let from = visible.firstIndex(of: anchor),
      let to = visible.firstIndex(of: id)
    {
      for each in visible[min(from, to)...max(from, to)] { insert(each) }
      return
    }
    if members.contains(id) { remove(id) } else { insert(id) }
    if members.contains(id) { anchor = id }
  }

  /// Ticks every tile on screen. The tile ticked first stays the anchor when there is none.
  mutating func selectAll(visible: [String]) {
    for id in visible { insert(id) }
    if anchor == nil { anchor = ids.first }
  }

  mutating func clear() {
    ids = []
    members = []
    anchor = nil
  }

  /// Drops members that are no longer installed, and the anchor with them.
  mutating func prune(keeping installed: (String) -> Bool) {
    guard ids.contains(where: { !installed($0) }) else { return }
    ids = ids.filter(installed)
    members = Set(ids)
    if let anchor, !members.contains(anchor) { self.anchor = nil }
  }

  /// Whether every id of `visible` is ticked, which is when Select all has nothing to do.
  func containsAll(of visible: [String]) -> Bool { visible.allSatisfy(members.contains) }

  /// Sets the selection a sweep paints: the members it began with, then the run it covers added
  /// or taken away. The anchor is where the sweep began when it adds, and is dropped when a sweep
  /// that removes took it out.
  fileprivate mutating func paint(
    base: LibrarySelection, run: ArraySlice<String>, adds: Bool, start: String
  ) {
    self = base
    for each in run {
      if adds { insert(each) } else { remove(each) }
    }
    if adds {
      anchor = start
    } else if let anchor, !members.contains(anchor) {
      self.anchor = nil
    }
  }
}

/// A press-and-sweep selection in progress: holding a tile still for a moment ticks it (or
/// unticks it if it was ticked), and every tile the pointer then sweeps over follows suit.
///
/// The swept run is the one from the pressed tile to the one under the pointer in grid order, so a
/// fast sweep never skips a tile and sweeping back gives the overshoot back. Outside a selection
/// the hold is required, so a stray drag changes nothing; once a selection is under way, or from
/// a tile's check, moving onto another tile starts the sweep at once. This is the gesture's logic
/// alone: the page reads the pointer and the clock and tells it what happened.
struct SweepSelection: Equatable, Sendable {
  /// How long a press must rest before it ticks the tile.
  static let holdDuration = Duration.milliseconds(350)
  /// How far the pointer may drift while a hold is pending, in points.
  static let slop: CGFloat = 6
  /// The band at the top and bottom of the grid in which it scrolls under the pointer.
  static let edgeBand: CGFloat = 48
  /// How far inside the grid the tile under a scrolling pointer is looked for.
  static let inset: CGFloat = 16

  let startID: String
  let origin: CGPoint
  /// A selection is under way, or the press began on a tile's check: moving is enough to sweep.
  let isEager: Bool
  private(set) var point: CGPoint
  /// The hold has completed (or an eager sweep has begun) and the selection is being painted.
  private(set) var isPainting = false
  /// The pointer left the slop before the hold completed, which an eager press takes as a sweep
  /// about to begin and any other press takes as a plain drag.
  private(set) var hasMoved = false
  private var ids: [String] = []
  private var base = LibrarySelection()
  private var adds = true
  private var last: String?
  /// The most tiles the sweep has covered at once.
  private(set) var spread = 0

  /// What the page should do after the pointer moved.
  enum Outcome: Equatable {
    case continues
    /// An ordinary drag outside a selection: the gesture is over, and left alone.
    case cancelled
  }

  init(startID: String, at point: CGPoint, isEager: Bool) {
    self.startID = startID
    origin = point
    self.point = point
    self.isEager = isEager
  }

  /// The pressed tile shows the hold in progress: neither painting nor given up by moving.
  var isArming: Bool { !isPainting && !hasMoved }

  /// Sweeping across two or more tiles once is what retires the tip that teaches it.
  var hasLearned: Bool { spread > 1 }

  /// The hold completed, or an eager press found a second tile: starts painting and paints the
  /// pressed tile. Pressing a ticked tile sweeps to untick instead.
  mutating func begin(selection: inout LibrarySelection, visible: [String]) {
    guard !isPainting else { return }
    isPainting = true
    ids = visible
    base = selection
    adds = !selection.contains(startID)
    spread = 0
    last = nil
    paint(startID, selection: &selection)
  }

  /// The hold's time is up. It ticks the tile only if the press is still resting on it: a press
  /// that moved, or already began as an eager sweep, has nothing left to wait for.
  mutating func holdElapsed(selection: inout LibrarySelection, visible: [String]) {
    guard isArming else { return }
    begin(selection: &selection, visible: visible)
  }

  /// The pointer moved to `point`, over `tile` (nil between tiles).
  mutating func move(
    to point: CGPoint, over tile: String?, selection: inout LibrarySelection, visible: [String]
  ) -> Outcome {
    self.point = point
    if isPainting {
      if let tile { paint(tile, selection: &selection) }
      return .continues
    }
    if !hasMoved, hypot(point.x - origin.x, point.y - origin.y) > Self.slop {
      // Moving gives up the hold: an ordinary drag outside a selection is left alone.
      guard isEager else { return .cancelled }
      hasMoved = true
    }
    if isEager, let tile, tile != startID {
      begin(selection: &selection, visible: visible)
      paint(tile, selection: &selection)
    }
    return .continues
  }

  /// Paints the run from the pressed tile to `id`. A repeat of the last tile, or a tile that is
  /// not in the grid, does nothing.
  mutating func paint(_ id: String, selection: inout LibrarySelection) {
    guard isPainting, id != last, let from = ids.firstIndex(of: startID),
      let to = ids.firstIndex(of: id)
    else { return }
    last = id
    spread = max(spread, abs(to - from) + 1)
    selection.paint(
      base: base, run: ids[min(from, to)...max(from, to)], adds: adds, start: startID)
  }

  /// How far the grid scrolls this frame while the pointer rests at `y` (viewport coordinates)
  /// in a grid `height` tall: nothing in the middle, and faster the deeper into the edge band,
  /// up to a third of the band's double width. Positive scrolls down.
  static func scrollStep(pointerY y: CGFloat, viewportHeight height: CGFloat) -> CGFloat {
    let below = y - (height - edgeBand)
    let above = edgeBand - y
    if below > 0 { return min(below, edgeBand * 2) / 3 }
    if above > 0 { return -min(above, edgeBand * 2) / 3 }
    return 0
  }

  /// The pointer, held `inset` inside a viewport, which is where the tile that scrolled beneath
  /// a resting pointer is looked for.
  static func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(
      x: min(max(point.x, inset), max(inset, size.width - inset)),
      y: min(max(point.y, inset), max(inset, size.height - inset)))
  }
}
