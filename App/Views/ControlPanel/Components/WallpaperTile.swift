import SwiftUI

/// How a tile is set apart from the others in its grid.
enum TileEmphasis: Equatable, Sendable {
  case none
  /// The tile on show: an accent ring set off from the artwork by a gap the colour of the surface.
  case selected
  /// The tile on show while the page has others ticked: a thin neutral ring, which no ticked tile
  /// wears, so the two can never be mistaken for each other.
  case quietSelection
  /// Ticked for a batch action: the accent ring, with the artwork dimmed under it.
  case checked
}

/// One wallpaper in a grid: square artwork with its title and a line of detail beneath.
///
/// The tile only draws. It has no gestures of its own: the page that shows it decides what a click,
/// a double click or a modifier click does, and puts its buttons in the badge slots. The artwork is
/// whatever the page passes (a `PanelImage`, an `AnimatedPreview`). A selected tile has an accent
/// ring set off from the artwork by a gap the colour of the surface; a hovered one lifts 2 points.
struct WallpaperTile<Artwork: View>: View {
  let title: String
  var subtitle: String?
  /// What the wallpaper is ("Video", "Scene"), read after the title by VoiceOver.
  var kind: String
  var isSelected = false
  @ViewBuilder var artwork: Artwork

  private var topLeading: AnyView?
  private var topTrailing: AnyView?
  private var bottomTrailing: AnyView?
  /// Set by a page that ticks tiles; otherwise `isSelected` decides between `.selected` and
  /// `.none`.
  private var emphasisOverride: TileEmphasis?

  @Environment(\.panelTheme) private var theme
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  static var cornerRadius: CGFloat { 10 }

  init(
    title: String, subtitle: String? = nil, kind: String, isSelected: Bool = false,
    @ViewBuilder artwork: () -> Artwork
  ) {
    self.title = title
    self.subtitle = subtitle
    self.kind = kind
    self.isSelected = isSelected
    self.artwork = artwork()
  }

  /// A mark in the artwork's top leading corner.
  func topLeadingBadge<Badge: View>(@ViewBuilder _ badge: () -> Badge) -> Self {
    var copy = self
    copy.topLeading = AnyView(badge())
    return copy
  }

  /// A mark in the artwork's top trailing corner.
  func topTrailingBadge<Badge: View>(@ViewBuilder _ badge: () -> Badge) -> Self {
    var copy = self
    copy.topTrailing = AnyView(badge())
    return copy
  }

  /// How the tile is set apart, for a page whose tiles can be ticked as well as selected. It
  /// changes only the drawing: `isSelected` still says whether VoiceOver reads the tile as
  /// selected.
  func emphasis(_ emphasis: TileEmphasis) -> Self {
    var copy = self
    copy.emphasisOverride = emphasis
    return copy
  }

  /// A mark in the artwork's bottom trailing corner.
  func bottomTrailingBadge<Badge: View>(@ViewBuilder _ badge: () -> Badge) -> Self {
    var copy = self
    copy.bottomTrailing = AnyView(badge())
    return copy
  }

  var body: some View {
    let radius = Self.cornerRadius
    let lifted = isHovering && !reduceMotion
    let emphasis = emphasisOverride ?? (isSelected ? .selected : .none)
    VStack(alignment: .leading, spacing: 7) {
      Color.clear
        .aspectRatio(1, contentMode: .fit)
        .overlay { artwork }
        // A ticked tile's artwork darkens by the same 18 % the web panel's `brightness(.82)` took,
        // beneath its own controls so they stay as bright as on any other tile.
        .overlay {
          if emphasis == .checked { Color.black.opacity(0.18).allowsHitTesting(false) }
        }
        .overlay(alignment: .topLeading) { topLeading.padding(6) }
        .overlay(alignment: .topTrailing) { topTrailing.padding(6) }
        .overlay(alignment: .bottomTrailing) { bottomTrailing.padding(6) }
        .background(theme.surface.mediaWell.color)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
        }
        .overlay { ring(emphasis, radius: radius) }
        .shadow(color: .black.opacity(lifted ? 0.2 : 0), radius: lifted ? 9 : 0, y: lifted ? 4 : 0)
        .offset(y: lifted ? -2 : 0)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(1)
        if let subtitle {
          Text(verbatim: subtitle)
            .font(.system(size: 11))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 2)
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: lifted)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: emphasis)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: "\(title), \(kind)"))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// The selection ring sits outside the artwork, on a gap the colour of the page, so it reads as
  /// a frame around the tile rather than a border of the picture. The quiet ring is thinner and
  /// neutral. Keyboard focus draws a thinner ring directly on the edge.
  @ViewBuilder
  private func ring(_ emphasis: TileEmphasis, radius: CGFloat) -> some View {
    switch emphasis {
    case .selected, .checked:
      outlined(radius: radius, color: theme.accent.primaryLine.color, lineWidth: 2.5)
    case .quietSelection:
      outlined(radius: radius, color: theme.surface.muted.color, lineWidth: 1.5)
    case .none:
      if isFocused {
        RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
          .strokeBorder(theme.accent.focus.color, lineWidth: 2)
          .padding(-2)
      }
    }
  }

  /// A ring of `lineWidth` around a 3-point gap the colour of the page.
  private func outlined(radius: CGFloat, color: Color, lineWidth: CGFloat) -> some View {
    let outset = 3 + lineWidth
    return RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
      .strokeBorder(theme.surface.background.color, lineWidth: 3)
      .padding(-3)
      .overlay {
        RoundedRectangle(cornerRadius: radius + outset, style: .continuous)
          .strokeBorder(color, lineWidth: lineWidth)
          .padding(-outset)
      }
  }
}
