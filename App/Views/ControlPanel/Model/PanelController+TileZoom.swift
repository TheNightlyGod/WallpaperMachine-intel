import Foundation

/// What View › Zoom In, Zoom Out and Actual Size ask of the tile grids.
enum TileZoomCommand: Equatable, Sendable {
  case zoomIn, zoomOut, actualSize
}

/// The size of the tiles in every grid (Installed, Discover, pixiv), which the View menu steps
/// through `TileGridLayout.zoomWidths`. Each grid still fits its width with whole columns, never
/// fewer than three, so a narrow window shrinks the tiles it can no longer fit.
extension PanelController {
  /// Applies `command` and saves the step; false when there is no further step that way, which
  /// the menu reads to disable the item.
  @discardableResult
  func zoomTiles(_ command: TileZoomCommand) -> Bool {
    let next =
      switch command {
      case .zoomIn: TileZoom.clamped(tileZoom + 1)
      case .zoomOut: TileZoom.clamped(tileZoom - 1)
      case .actualSize: 0
      }
    guard next != tileZoom else { return false }
    setTileZoom(next)
    return true
  }

  /// Whether `command` would change the tiles' size now.
  func canZoomTiles(_ command: TileZoomCommand) -> Bool {
    switch command {
    case .zoomIn: TileZoom.clamped(tileZoom + 1) != tileZoom
    case .zoomOut: TileZoom.clamped(tileZoom - 1) != tileZoom
    case .actualSize: tileZoom != 0
    }
  }

  func setTileZoom(_ zoom: Int) {
    tileZoom = TileZoom.clamped(zoom)
    PanelPreferences.setTileZoom(tileZoom, in: defaults)
  }
}
