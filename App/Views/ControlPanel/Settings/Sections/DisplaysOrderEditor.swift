import SwiftUI

/// What a drag of one wallpaper of a display's list carries: the display it belongs to, the
/// wallpaper, and the order the list had when the row was drawn, so a drop is checked against that
/// order and a list that changed meanwhile refuses it. It travels as private JSON, so nothing
/// outside the panel can make sense of it.
struct PlaylistRowDrag: Codable, Transferable {
  let display: String
  let id: String
  let expected: [String]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .data, encoder: JSONEncoder(), decoder: JSONDecoder())
  }
}

/// "This display's list": the wallpapers a rotation draws from, in the order it plays them, as rows
/// that can be dragged, moved a place with the buttons, or removed. The list holds only wallpapers
/// the library still has; ids that left it stay in the stored list. A search keeps the whole list
/// when the row's own words match, and otherwise only the wallpapers whose titles do.
struct DisplaysOrderEditor: View {
  let display: DisplayRow
  let state: PlaylistState
  let off: Bool
  let card: DisplaysCardSearch

  @Environment(PanelController.self) private var controller
  @FocusState private var focus: DisplaysSettingsModel.ListFocus?

  var body: some View {
    let item = DisplaysSettingsSection.playlistList
    let whole = card.showsWholeList
    if whole || !card.listMatches.isEmpty {
      let model = controller.displaysSettings
      let stored = state.playlist.wallpaperIDs
      let listed = Set(stored)
      let titles = Dictionary(
        controller.store.librarySnapshot.wallpapers.filter { listed.contains($0.id) }.map {
          ($0.id, $0.title)
        }, uniquingKeysWith: { first, _ in first })
      let rows = DisplaysPlaylistList.rows(of: stored, titles: titles)
      Group {
        if rows.isEmpty {
          DisplaysNote(
            text: L(
              "The list is empty. In Installed, select wallpapers and choose Add to playlist, or use the list button in a wallpaper’s details."
            ))
        } else {
          if whole { DisplaysItemNote(item: item, forced: true) }
          ForEach(rows.filter { whole || card.listMatches.contains($0.id) }) { row in
            DisplaysOrderRow(display: display.id, row: row, expected: stored, off: off, focus: $focus)
          }
        }
      }
      .onChange(of: model.listAnnouncement) { _, text in
        guard let text else { return }
        AccessibilityNotification.Announcement(text).post()
      }
      .onChange(of: model.listFocus, initial: true) { _, target in
        guard let target, target.display == display.id else { return }
        focus = target
        model.consumeListFocus()
      }
    }
  }
}

/// One wallpaper of the list: its place, its title, and the buttons that move or remove it. Dropping
/// another row on it puts that row in this one's place.
private struct DisplaysOrderRow: View {
  let display: String
  let row: DisplaysListRow
  let expected: [String]
  let off: Bool
  var focus: FocusState<DisplaysSettingsModel.ListFocus?>.Binding

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isTargeted = false

  var body: some View {
    let model = controller.displaysSettings
    HStack(spacing: 8) {
      Text(verbatim: "\(row.position)")
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(theme.surface.faint.color)
        .frame(width: 20, alignment: .trailing)
      Text(verbatim: row.title)
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      iconButton(.up, "chevron.up", help: L("Move up"), label: L("Move \(row.title) up")) {
        move(-1)
      }
      .disabled(off || row.isFirst)
      iconButton(.down, "chevron.down", help: L("Move down"), label: L("Move \(row.title) down")) {
        move(1)
      }
      .disabled(off || row.isLast)
      iconButton(.remove, "xmark", help: L("Remove"), label: L("Remove \(row.title) from playlist")) {
        controller.launch(PanelActionCoordinator.key("playlistRemove", id: display, detail: row.id)) {
          try await controller.removeFromPlaylist(row.id, display: display)
        }
      }
      .disabled(off)
    }
    .padding(.horizontal, 12)
    .frame(height: 36)
    .background(isTargeted ? theme.accent.accent.color.opacity(0.14) : Color.clear)
    .contentShape(Rectangle())
    .modifier(DisplaysOrderDragging(isEnabled: !off, drag: PlaylistRowDrag(display: display, id: row.id, expected: expected)))
    .dropDestination(for: PlaylistRowDrag.self) { drops, _ in
      guard !off, let drop = drops.first, drop.display == display, drop.id != row.id else { return false }
      controller.launch(PanelActionCoordinator.key("playlistReorder", id: display)) {
        try await model.dropListWallpaper(drop.id, onto: row.id, expected: drop.expected, display: display)
      }
      return true
    } isTargeted: { isTargeted = $0 }
    .help(off ? "" : L("Drag to reorder"))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("displays.playlist-item.\(display).\(row.id)")
  }

  private func move(_ direction: Int) {
    controller.launch(PanelActionCoordinator.key("playlistReorder", id: display)) {
      try await controller.displaysSettings.moveListWallpaper(row.id, by: direction, display: display)
    }
  }

  private func iconButton(
    _ button: DisplaysPlaylistList.Button, _ symbol: String, help: String, label: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(DisplaysIconButtonStyle())
    .focused(focus, equals: DisplaysSettingsModel.ListFocus(display: display, id: row.id, button: button))
    .help(help)
    .accessibilityLabel(Text(verbatim: label))
  }
}

/// A borderless symbol button in the quiet colour that fades when it is disabled. A borderless
/// button given a colour of its own keeps that colour whatever its state, so a disabled Move up
/// would look like one that can be pressed.
struct DisplaysIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    DisplaysIconButtonBody(configuration: configuration)
  }
}

private struct DisplaysIconButtonBody: View {
  let configuration: ButtonStyleConfiguration

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.panelTheme) private var theme

  var body: some View {
    configuration.label
      .foregroundStyle(configuration.isPressed ? theme.surface.text.color : theme.surface.muted.color)
      .opacity(isEnabled ? 1 : 0.3)
  }
}

/// Makes a row draggable unless the display is off.
private struct DisplaysOrderDragging: ViewModifier {
  let isEnabled: Bool
  let drag: PlaylistRowDrag

  func body(content: Content) -> some View {
    if isEnabled {
      content.draggable(drag)
    } else {
      content
    }
  }
}
