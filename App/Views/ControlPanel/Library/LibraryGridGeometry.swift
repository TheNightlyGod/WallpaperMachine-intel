import SwiftUI

/// Where each tile of the Installed grid is, worked out from what the grid reports about itself
/// rather than asked of the views.
///
/// The press-and-sweep selection needs the tile under the pointer, and SwiftUI cannot answer that
/// for a lazy grid. The grid is regular, so a point maps to a tile by arithmetic: the number of
/// columns is the grid's own rule (`TileGridLayout`), a tile's size is measured once from a
/// drawn tile, and the scroll offset is read off the scroll view. Nothing here runs unless the
/// pointer is down.
struct LibraryGridGeometry: Equatable {
  /// The gap between tiles, and the room around the grid, which the page passes to `TileGrid`.
  static let spacing: CGFloat = 14
  static let insets = EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20)
  /// The round controls in a tile's corners (check and heart), and the room around them. 24 points
  /// is about the web panel's 26-pixel minimum, a target a pointer finds without aiming.
  static let controlSize: CGFloat = 24
  static let controlInset: CGFloat = 6

  /// The scroll view's own size.
  var viewport = CGSize.zero
  /// One drawn tile, caption included.
  var cellSize = CGSize.zero
  /// How far the content is scrolled.
  var offsetY: CGFloat = 0
  var contentHeight: CGFloat = 0

  /// Whether a tile has been drawn and measured, which hit-testing waits for.
  var isMeasured: Bool { viewport.width > 0 && cellSize.width > 0 && cellSize.height > 0 }

  var columns: Int {
    TileGridLayout.columnCount(
      forWidth: viewport.width - Self.insets.leading - Self.insets.trailing, spacing: Self.spacing)
  }

  /// The farthest the content can scroll.
  var maxOffset: CGFloat { max(0, contentHeight - viewport.height) }

  /// The tile at `index`, in the scroll view's own coordinates (what is on screen).
  func frame(ofIndex index: Int) -> CGRect {
    let columns = max(1, columns)
    let (row, column) = index.quotientAndRemainder(dividingBy: columns)
    return CGRect(
      x: Self.insets.leading + CGFloat(column) * (cellSize.width + Self.spacing),
      y: Self.insets.top + CGFloat(row) * (cellSize.height + Self.spacing) - offsetY,
      width: cellSize.width, height: cellSize.height)
  }

  /// The index of the tile at `point` (scroll view coordinates), nil in a gap, in the margin or
  /// past the last tile.
  func index(at point: CGPoint, count: Int) -> Int? {
    guard isMeasured, count > 0 else { return nil }
    let x = point.x - Self.insets.leading
    let y = point.y + offsetY - Self.insets.top
    guard x >= 0, y >= 0 else { return nil }
    let pitch = CGSize(
      width: cellSize.width + Self.spacing, height: cellSize.height + Self.spacing)
    let column = Int((x / pitch.width).rounded(.down))
    let row = Int((y / pitch.height).rounded(.down))
    let inColumn = x - CGFloat(column) * pitch.width
    let inRow = y - CGFloat(row) * pitch.height
    guard column < columns, inColumn < cellSize.width, inRow < cellSize.height else { return nil }
    let index = row * columns + column
    return index < count ? index : nil
  }

  /// Whether `point` is on a tile's check, the control a sweep that begins at once may start from.
  func isOnCheck(_ point: CGPoint, tileIndex: Int) -> Bool {
    let frame = frame(ofIndex: tileIndex)
    let reach = Self.controlInset + Self.controlSize
    return point.x >= frame.minX && point.x <= frame.minX + reach + 2
      && point.y >= frame.minY && point.y <= frame.minY + reach + 2
  }

  /// Whether `point` is on a tile's heart, a press on which is a click on the heart and never the
  /// start of a sweep. The check is not excluded: starting a sweep from it is how a sweep that
  /// begins at once is made.
  func isOnHeart(_ point: CGPoint, tileIndex: Int) -> Bool {
    let frame = frame(ofIndex: tileIndex)
    let reach = Self.controlInset + Self.controlSize
    return point.x >= frame.maxX - reach - 2 && point.x <= frame.maxX && point.y >= frame.minY
      && point.y <= frame.minY + reach + 2
  }
}
