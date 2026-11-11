import AppKit

/// The same regular geometry used by press-and-sweep, with attributes only for requested rows.
/// Scrolling changes the clip view's origin; it never invalidates the collection's layout.
@MainActor
final class LibraryCollectionLayout: NSCollectionViewLayout {
  private(set) var geometry = LibraryGridGeometry()
  private(set) var itemCount = 0

  /// The two single-line captions (15 and 14 points), their 1-point gap, and the 7-point art gap.
  static let captionHeight: CGFloat = {
    func line(_ size: CGFloat, weight: NSFont.Weight) -> CGFloat {
      let font = NSFont.systemFont(ofSize: size, weight: weight)
      return ceil(font.ascender - font.descender + font.leading)
    }
    return line(12, weight: .semibold) + line(11, weight: .regular) + 8
  }()

  @discardableResult
  func configure(viewport: CGSize, preferredWidth: CGFloat, count: Int) -> Bool {
    var next = LibraryGridGeometry()
    next.viewport = viewport
    next.preferredTileWidth = preferredWidth
    let columns = next.columns
    let width = max(0, (viewport.width - LibraryGridGeometry.insets.leading
      - LibraryGridGeometry.insets.trailing - CGFloat(columns - 1) * LibraryGridGeometry.spacing)
      / CGFloat(columns))
    next.cellSize = CGSize(width: width, height: width + Self.captionHeight)
    let rowCount = (count + columns - 1) / columns
    next.contentHeight = LibraryGridGeometry.insets.top + LibraryGridGeometry.insets.bottom
      + CGFloat(rowCount) * next.cellSize.height
      + CGFloat(max(0, rowCount - 1)) * LibraryGridGeometry.spacing
    guard next != geometry || itemCount != count else { return false }
    geometry = next
    itemCount = count
    invalidateLayout()
    return true
  }

  override var collectionViewContentSize: CGSize {
    CGSize(width: geometry.viewport.width, height: geometry.contentHeight)
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { false }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
    guard indexPath.section == 0, (0..<itemCount).contains(indexPath.item) else { return nil }
    let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
    attributes.frame = geometry.frame(ofIndex: indexPath.item)
    return attributes
  }

  override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
    guard geometry.isMeasured, itemCount > 0 else { return [] }
    let pitch = geometry.cellSize.height + LibraryGridGeometry.spacing
    let firstRow = max(0, Int(floor((rect.minY - LibraryGridGeometry.insets.top) / pitch)))
    let lastRow = max(firstRow, Int(floor((rect.maxY - LibraryGridGeometry.insets.top) / pitch)))
    let first = min(itemCount, firstRow * geometry.columns)
    let end = min(itemCount, (lastRow + 1) * geometry.columns)
    return (first..<end).compactMap { index in
      let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: 0))
      return attributes?.frame.intersects(rect) == true ? attributes : nil
    }
  }
}
