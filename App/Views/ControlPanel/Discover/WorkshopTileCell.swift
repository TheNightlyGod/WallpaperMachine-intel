import AppKit
import SwiftUI

/// One tile of the Workshop grid: the picture, its marks, its title and kind, and the download ring.
///
/// The tile asks the controller for everything it wears (`workshopTile(for:)`), so a progress tick
/// re-renders only the tile whose download moved and never the grid. A click selects, a double-click
/// does what the state of the item calls for (`WorkshopBrowserModel.doubleClick`), and the ring has
/// a click of its own.
struct WorkshopTileCell: View {
  let item: WorkshopItem

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The tile never draws its picture larger than this, in points; the stills are decoded to it.
  static let pointSize: CGFloat = 192

  var body: some View {
    let model = controller.workshopBrowser
    let tile = controller.workshopTile(for: item)
    let isSelected = controller.workshop.selectedItem?.id == item.id
    let marks = Self.marks(of: tile)
    WallpaperTile(
      title: item.title, subtitle: subtitle, kind: item.kindLabel, isSelected: isSelected
    ) {
      artwork(tile: tile, model: model)
    }
    .topLeadingBadge { MarkStack(marks: marks) }
    .contentShape(Rectangle())
    // One tap handler tells a click from a double-click by the event itself, so a click selects at
    // once and the second click of a double-click does not wait for a timer. A button on top (the
    // ring) takes its own click first.
    .onTapGesture {
      if NSApp.currentEvent?.clickCount == 2 { model.doubleClick(item) } else { model.select(item) }
    }
    .accessibilityLabel(Text(verbatim: accessibilityLabel(marks: marks)))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityActionIfNamed(Self.doubleClickName(controller.workshopDoubleClick(for: item))) {
      model.doubleClick(item)
    }
    .onScrollVisibilityChange(threshold: 0.25) { model.previews.setOnScreen(item.id, $0) }
    .onDisappear { model.previews.setOnScreen(item.id, false) }
  }

  // MARK: Parts

  /// The kind, and how many people subscribe to it: "Scene · 48K".
  private var subtitle: String {
    guard !item.isCollection, item.subscriptions > 0 else { return item.kindLabel }
    let count = item.subscriptions.formatted(
      .number.notation(.compactName).locale(locale))
    return "\(item.kindLabel) · \(count)"
  }

  @ViewBuilder
  private func artwork(tile: WorkshopTile, model: WorkshopBrowserModel) -> some View {
    let previews = model.previews
    let playing = !tile.isInstalled && previews.isPlaying(item.id)
    ZStack {
      PanelImage(source: still(tile), pointSize: Self.pointSize)
      if playing, let data = previews.animation(for: item.id) {
        // The animation lies over the still; the still stays under it for when it is released.
        AnimatedPreview(data: data, isPlaying: true)
          .transition(.opacity)
      }
      if let ring = tile.download {
        // The picture dims under a ring, so the ring reads on any wallpaper.
        Color.black.opacity(0.4)
        GeometryReader { proxy in
          let diameter = min(WorkshopTileRing.largestDiameter, proxy.size.width * 0.52)
          WorkshopTileRing(state: ring, diameter: diameter) {
            controller.downloads.perform(ring.action, forItem: item.id)
          }
          .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: playing)
  }

  /// A wallpaper that is installed shows the library's own cover, the picture the Installed page
  /// shows, until that is ready; every other tile shows Steam's still.
  private func still(_ tile: WorkshopTile) -> PanelImageSource? {
    if tile.isInstalled, let cover = controller.workshopInstalledStill(for: item.id) {
      return cover
    }
    return item.thumbnail
  }

  /// The name VoiceOver's actions menu gives what the double-click does, by the same rule the
  /// double-click follows (`PanelController.workshopDoubleClick`), so the name never promises what
  /// the click will not do. Only selecting has no action of its own: a download under way, or a
  /// wallpaper in the library that the target display cannot show (disabled or mirroring) or whose
  /// type it cannot name.
  static func doubleClickName(_ doubleClick: WorkshopTileDoubleClick) -> String? {
    switch doubleClick {
    case .openCollection: L("Open collection")
    case .apply: L("Apply wallpaper")
    case .continueSetup: L("Continue setup")
    case .requestDownload: L("Download")
    case .select: nil
    }
  }

  // MARK: Marks

  /// A mark in the tile's top corner, in the order they stack.
  enum Mark: Hashable {
    /// The wallpaper is in the library.
    case installed
    /// Wallpaper Engine's staff approved it.
    case approved
    /// The installed copy is one of the favorites.
    case favorite

    @MainActor
    var label: String {
      switch self {
      case .installed: L("In your library")
      case .approved: L("Approved by Wallpaper Engine")
      case .favorite: L("Favorite")
      }
    }
  }

  static func marks(of tile: WorkshopTile) -> [Mark] {
    var marks: [Mark] = []
    if tile.isInstalled { marks.append(.installed) }
    if tile.item.isApproved { marks.append(.approved) }
    if tile.isFavorite { marks.append(.favorite) }
    return marks
  }

  /// "Title, Scene, In your library, Favorite": what VoiceOver reads for the tile.
  private func accessibilityLabel(marks: [Mark]) -> String {
    ([item.title, item.kindLabel] + marks.map(\.label)).joined(separator: ", ")
  }
}

/// The marks of a tile, stacked in its top leading corner as small round chips.
private struct MarkStack: View {
  let marks: [WorkshopTileCell.Mark]

  @Environment(\.panelTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(marks, id: \.self) { mark in
        chip(mark)
      }
    }
  }

  private func chip(_ mark: WorkshopTileCell.Mark) -> some View {
    let fill: Color
    let glyph: Color
    let symbol: String
    switch mark {
    case .installed:
      fill = theme.accent.primary.color
      glyph = theme.accent.onPrimary.color
      symbol = "checkmark"
    case .approved:
      fill = .black.opacity(0.58)
      glyph = theme.surface.approved.color
      symbol = "trophy.fill"
    case .favorite:
      fill = .black.opacity(0.58)
      glyph = theme.surface.heart.color
      symbol = "heart.fill"
    }
    return Image(systemName: symbol)
      .font(.system(size: 9.5, weight: .bold))
      .foregroundStyle(glyph)
      .frame(width: 20, height: 20)
      .background(fill, in: Circle())
      .help(mark.label)
      .accessibilityHidden(true)
  }
}

private extension View {
  /// An accessibility action under `name`, or none when there is no name.
  @ViewBuilder
  func accessibilityActionIfNamed(_ name: String?, _ action: @escaping () -> Void) -> some View {
    if let name {
      accessibilityAction(named: Text(verbatim: name), action)
    } else {
      self
    }
  }
}
