import AppKit
import Observation
import SwiftUI

extension EnvironmentValues {
  @Entry var libraryCollectionTile: LibraryCollectionTileState?
}

/// Copy only values a tile inherits from the panel. Assigning the entire environment on each
/// collection update marks every reused tile dirty even when none of these values changed.
struct LibraryCollectionAppearance: Equatable {
  var theme: PanelTheme
  var locale: Locale
  var colorScheme: ColorScheme
  var layoutDirection: LayoutDirection
  var displayScale: CGFloat
  var isEnabled: Bool
  var panelIsVisible: Bool
  var imagesID: ObjectIdentifier?

  init(_ environment: EnvironmentValues) {
    theme = environment.panelTheme
    locale = environment.locale
    colorScheme = environment.colorScheme
    layoutDirection = environment.layoutDirection
    displayScale = environment.displayScale
    isEnabled = environment.isEnabled
    panelIsVisible = environment.panelIsVisible
    imagesID = environment.panelImages.map(ObjectIdentifier.init)
  }
}

/// Reused along with the host: changing rows updates existing SwiftUI nodes instead of building
/// another tile hierarchy during a fast swipe. The collection keeps a bounded pool of hosts.
@MainActor @Observable
final class LibraryCollectionTileState {
  var row: LibraryRow?
  var otherDisplays = Set<String>()
  var appearance = LibraryCollectionAppearance(EnvironmentValues())
  @ObservationIgnored var controller: PanelController?
  @ObservationIgnored var images: PanelImagePipeline?
  var isFocused = false
  var isHovering = false
  var isOnScreen = false
}

@MainActor
final class LibraryCollectionItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("LibraryCollectionItem")
  let tile = LibraryCollectionTileState()

  override func loadView() {
    let hosting = NSHostingView(rootView: LibraryCollectionTileRoot(tile: tile))
    hosting.sizingOptions = []
    hosting.safeAreaRegions = []
    view = hosting
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    tile.isFocused = false
    tile.isHovering = false
    tile.isOnScreen = false
  }

  func configure(row: LibraryRow, others: Set<String>, controller: PanelController, environment: EnvironmentValues) {
    tile.controller = controller
    tile.images = environment.panelImages
    if tile.row != row { tile.row = row }
    if tile.otherDisplays != others { tile.otherDisplays = others }
    let appearance = LibraryCollectionAppearance(environment)
    if tile.appearance != appearance { tile.appearance = appearance }
  }
}

private struct LibraryCollectionTileRoot: View {
  let tile: LibraryCollectionTileState

  var body: some View {
    if let row = tile.row, let controller = tile.controller {
      let appearance = tile.appearance
      InstalledTile(row: row, otherDisplayIDs: tile.otherDisplays)
        .environment(controller)
        .environment(\.panelImages, tile.images)
        .environment(\.panelTheme, appearance.theme)
        .environment(\.locale, appearance.locale)
        .environment(\.colorScheme, appearance.colorScheme)
        .environment(\.layoutDirection, appearance.layoutDirection)
        .environment(\.displayScale, appearance.displayScale)
        .environment(\.isEnabled, appearance.isEnabled)
        .environment(\.libraryCollectionTile, tile)
        .environment(\.panelIsVisible, appearance.panelIsVisible && tile.isOnScreen)
        .tint(appearance.theme.accent.accent.color)
    }
  }
}
