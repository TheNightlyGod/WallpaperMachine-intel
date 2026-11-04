import SwiftUI

/// The row of views above the Library grid: All wallpapers and Favorites, each with its count, and
/// while a collection is on show, that collection too. One is lit: the view the grid shows.
///
/// Collections are chosen, made, renamed and deleted in the filters panel's Collections group; the
/// collection's chip here says which one is on show and puts it away. All wallpapers carries an
/// accent dot while Workshop wallpapers have an update, with how many as its tooltip and for
/// VoiceOver.
///
/// Play at the end, with its order menu, turns the view on show into the target display's rotation,
/// so a collection plays from where it is chosen rather than only from Settings › Displays.
struct InstalledScopeBar: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    // The counts say nothing while the library loads, when they would say there is nothing.
    let counts = controller.isLibraryLoading ? nil : controller.sidebarCounts
    let scope = model.scope
    HStack(spacing: 6) {
      ScopeChip(
        title: Text("All wallpapers"), systemImage: "square.grid.2x2", count: counts?.all,
        isOn: scope == .all, note: counts?.updateTooltip, identifier: "scope-all"
      ) { model.show(.all) }
      ScopeChip(
        title: Text("Favorites"), systemImage: "heart", count: counts?.favorites,
        isOn: scope == .favorites, identifier: "scope-favorites"
      ) { model.show(.favorites) }
      if let collection = model.shownCollection {
        let count = counts?.collections.first { $0.id == collection.id }?.count
        ScopeChip(
          title: Text(verbatim: collection.name), systemImage: "folder", count: count,
          isOn: true, closes: true, help: L("Show all wallpapers"), identifier: "scope-collection"
        ) { model.show(.all) }
        .frame(maxWidth: 260, alignment: .leading)
      }
      Spacer(minLength: 0)
      ScopePlayButtons(scope: scope)
    }
    .padding(.horizontal, 20)
    .frame(height: 34)
    .padding(.top, 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Library"))
  }
}

/// Play and its order menu, the two halves of one capsule: the target display rotates through the view on show and changes to it
/// at once. Play keeps the order that display already uses; the menu beside it shows that order and
/// plays in the one chosen. Unavailable while the view has no wallpaper that can play or the target
/// display has no playlist of its own (off, or a mirror).
private struct ScopePlayButtons: View {
  let scope: LibraryScope

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let key = PanelActionCoordinator.key("playlistPlay")
    let isEnabled =
      controller.targetDisplay?.isSelectable == true && !controller.isBusy(key)
      && controller.canPlay(scope.playlistSource)
    let order = controller.playlistState(for: controller.targetDisplayID).playlist.order
    HStack(spacing: 0) {
      Button {
        play(order: order, key: key)
      } label: {
        Label("Play", systemImage: "play.fill")
      }
      .buttonStyle(PlaySegmentStyle(leading: 10, trailing: 8))
      .help(
        order == .shuffle
          ? L("Plays these wallpapers in a random order on this display")
          : L("Plays these wallpapers in order on this display")
      )
      .accessibilityValue(Text(verbatim: order == .shuffle ? L("Shuffle") : L("In order")))
      .accessibilityIdentifier("scope-play")
      Rectangle()
        .fill(theme.surface.divider.color)
        .frame(width: 1, height: 14)
        .accessibilityHidden(true)
      Menu {
        // Toggles rather than a picker, so choosing the order already ticked still plays.
        ForEach([PlaylistOrder.sequential, .shuffle], id: \.self) { choice in
          Toggle(
            isOn: Binding(get: { order == choice }, set: { _ in play(order: choice, key: key) })
          ) {
            if choice == .shuffle {
              Label("Shuffle", systemImage: "shuffle")
            } else {
              Label("In order", systemImage: "repeat")
            }
          }
        }
      } label: {
        HStack(spacing: 4) {
          if order == .shuffle {
            Text("Shuffle")
          } else {
            Text("In order")
          }
          Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
        }
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(PlaySegmentStyle(leading: 8, trailing: 10))
      .help(L("Order"))
      .accessibilityLabel(Text("Order"))
      .accessibilityValue(Text(verbatim: order == .shuffle ? L("Shuffle") : L("In order")))
      .accessibilityIdentifier("scope-play-order")
    }
    .background(theme.surface.hover.color, in: Capsule())
    .clipShape(Capsule())
    .opacity(isEnabled ? 1 : 0.4)
    .fixedSize()
    .disabled(!isEnabled)
  }

  private func play(order: PlaylistOrder, key: String) {
    let source = scope.playlistSource
    controller.launch(key) { [controller] in try await controller.playPlaylist(source, order: order) }
  }
}

/// One half of the Play capsule: the capsule's type and height, lit on its own on hover and press
/// by a pill inset within the half.
/// The capsule's resting fill and its dimming while unavailable belong to the whole.
private struct PlaySegmentStyle: ButtonStyle {
  let leading: CGFloat
  let trailing: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    PlaySegmentBody(configuration: configuration, leading: leading, trailing: trailing)
  }
}

private struct PlaySegmentBody: View {
  let configuration: ButtonStyleConfiguration
  let leading: CGFloat
  let trailing: CGFloat

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .font(.system(size: 12.5, weight: .medium))
      .foregroundStyle(theme.surface.text.color)
      .lineLimit(1)
      .padding(.leading, leading)
      .padding(.trailing, trailing)
      .frame(minHeight: 26)
      // An inset pill, so the light stops short of the divider and the capsule's edge.
      .background(Capsule().fill(background).padding(2))
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
  }

  private var background: Color {
    guard isEnabled else { return .clear }
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering ? theme.surface.selected.color : .clear
  }
}

/// One view of the library as a capsule: its symbol, its name and its count, tinted while it is the
/// one on show. A collection's chip ends in a cross, since pressing it puts the collection away.
private struct ScopeChip: View {
  let title: Text
  let systemImage: String
  let count: Int?
  let isOn: Bool
  var note: String?
  var closes = false
  /// The tooltip, when the note does not give one.
  var help: String?
  let identifier: String
  let action: () -> Void

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
        title.truncationMode(.tail)
        if let count {
          Text(count, format: .number)
            .monospacedDigit()
            .foregroundStyle(isOn ? theme.accent.accent.color : theme.surface.muted.color)
        }
        if note != nil {
          Circle().fill(.tint).frame(width: 6, height: 6).accessibilityHidden(true)
        }
        if closes {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .accessibilityHidden(true)
        }
      }
    }
    .buttonStyle(.panelCapsule(isActive: isOn))
    .help(note ?? help ?? "")
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityIdentifier(identifier)
  }

  /// The count first, then the update note.
  private var value: Text {
    let parts = [count.map { $0.formatted(.number.locale(PanelLocale.shared.locale)) }, note]
    return Text(verbatim: parts.compactMap { $0 }.joined(separator: ", "))
  }
}
