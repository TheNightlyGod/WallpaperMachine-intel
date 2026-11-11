import SwiftUI

/// A picture card of the Appearance row: a drawn miniature window above its name, with a ring
/// around it while it is the choice.
struct AppearanceChoiceCard: View {
  let title: String
  let miniature: SurfacePalette.Miniature
  var split: SurfacePalette.Miniature?
  /// The accents of the two looks, for a card of looks with their own; else the window's.
  var accent: Color?
  var splitAccent: Color?
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        SettingsMiniWindow(
          miniature: miniature, split: split, accent: accent ?? theme.accent.accent.color,
          splitAccent: splitAccent)
          // Room for the ring and the gap inside it, always, so choosing a card moves nothing.
          .padding(4.5)
          .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(theme.accent.primaryLine.color, lineWidth: 2.5)
              .opacity(isSelected ? 1 : 0)
          }
          .shadow(
            color: .black.opacity(isHovering && !reduceMotion ? 0.18 : 0.08), radius: isHovering ? 5 : 2,
            y: isHovering ? 2 : 1)
        Text(verbatim: title)
          .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// The three App icon options: the Dock icon as it will look, each over its name.
struct AppearanceIconOption: View {
  let icon: AppThemePreferences.Icon
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  /// The artwork is drawn inside a transparent margin of a tenth of its side, so it is drawn this
  /// much larger than the tile to make the visible icon fill it.
  private static let artworkScale: CGFloat = 1024 / 824

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(icon.imageName)
          .resizable()
          .interpolation(.high)
          .frame(width: 64 * Self.artworkScale, height: 64 * Self.artworkScale)
          .frame(width: 64, height: 64)
          .padding(4.5)
          .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
              .strokeBorder(theme.accent.primaryLine.color, lineWidth: 2.5)
              .opacity(isSelected ? 1 : 0)
          }
          .offset(y: isHovering && !isSelected && !reduceMotion ? -2 : 0)
        Text(verbatim: icon.title)
          .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? theme.accent.accent.color : theme.surface.text.color)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
    .accessibilityLabel(Text(verbatim: icon.title))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// A row of picture cards with its name, and a note under the name when it has one: beside the
/// name while there is room, under it when the window is narrow. The cards keep their size either
/// way, so a label is never cut short.
///
/// The cards never shrink, because a card that did would cut its label first ("System…"). Their
/// width cannot widen the window either: the stacked layout takes over before the row runs out of
/// room, and the Settings column asks the split view for no width (`SettingsDetail`).
struct AppearanceChoiceRow<Cards: View>: View {
  let item: SettingsItem
  let note: String?
  let cards: Cards

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  /// - Parameter note: Replaces the item's note, for one built from live values.
  init(_ item: SettingsItem, note: String? = nil, @ViewBuilder cards: () -> Cards) {
    self.item = item
    self.note = note
    self.cards = cards()
  }

  var body: some View {
    let settings = controller.settings
    if settings.search.shows(item) {
      let lead = note ?? item.note.map(settings.text)
      let title = VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: settings.text(item.title)).font(.system(size: 13))
        if let lead {
          Text(verbatim: lead)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          title.frame(maxWidth: .infinity, alignment: .leading)
          cards.fixedSize()
        }
        VStack(alignment: .leading, spacing: 8) {
          title
          cards.fixedSize()
        }
        // As wide as the card, as the side-by-side layout is.
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(minHeight: 36)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text(verbatim: settings.text(item.title)))
      .accessibilityIdentifier(item.id)
    }
  }
}
