import SwiftUI

/// The Collections group of the Library's filters panel: one row per collection with its size,
/// which shows that collection in the grid (and pressed again, every wallpaper), New collection…
/// under them, and Play, Shuffle, Rename… and Delete… in each row's menu.
///
/// A new collection or a rename is typed in a field in the group itself: Return saves, Escape
/// cancels, and a refusal of the name is written under the field. Deleting asks first. The result
/// of a delete is shown under the group for a few seconds and spoken, and an empty group says what
/// collections are for.
struct CollectionsFilterGroup: View {
  @Binding var isExpanded: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    let shell = controller.shell
    let editor = shell.collectionEditor
    let collections = controller.sidebarCounts.collections
    let shownID = model.shownCollection?.id
    FilterGroup("Collections", count: shownID == nil ? 0 : 1, isExpanded: $isExpanded) {
      ForEach(collections) { collection in
        if editor.mode == .rename(collection.id) {
          CollectionNameRow(editor: editor)
        } else {
          CollectionFilterRow(collection: collection, isShown: collection.id == shownID, editor: editor)
        }
      }
      if editor.mode == .create {
        CollectionNameRow(editor: editor)
      }
      if collections.isEmpty && !editor.isOpen {
        CollectionsNote(Text("Group wallpapers to browse them together or play them in turn."))
      }
      Button {
        editor.beginCreate()
      } label: {
        Label("New collection…", systemImage: "plus")
      }
      .buttonStyle(.link)
      .font(.system(size: 12))
      .disabled(editor.isChanging || editor.mode == .create)
      .accessibilityIdentifier("collection-new")
      if let notice = shell.notice {
        // A collection's name can be long, and the sentence is up for a few seconds only.
        CollectionsNote(Text(verbatim: notice))
          .accessibilityIdentifier("collection-notice")
      }
    }
    // A collection deleted from elsewhere takes the name field that was renaming it along.
    .onChange(of: collections.map(\.id)) { editor.reconcile() }
  }
}

/// A collection: its name and size, lit while it is the one the grid shows. Pressing it shows it,
/// or, when it is already shown, every wallpaper again.
private struct CollectionFilterRow: View {
  let collection: SidebarCounts.Collection
  let isShown: Bool
  let editor: CollectionEditorModel

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    let model = controller.library
    Button {
      model.show(isShown ? .all : .collection(collection.id))
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isShown ? "folder.fill" : "folder")
          .foregroundStyle(isShown ? theme.accent.accent.color : theme.surface.muted.color)
          .frame(width: 16)
        Text(verbatim: collection.name)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 8)
        Text(collection.count, format: .number)
          .monospacedDigit()
          .foregroundStyle(theme.surface.muted.color)
      }
      .font(.system(size: 13, weight: isShown ? .semibold : .regular))
      .foregroundStyle(isShown ? theme.accent.accent.color : theme.surface.text.color)
      .padding(.horizontal, 8)
      .frame(minHeight: 26)
      .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu {
      Button {
        play(order: .sequential)
      } label: {
        Label("Play", systemImage: "play.fill")
      }
      .disabled(!canPlay)
      Button {
        play(order: .shuffle)
      } label: {
        Label("Shuffle", systemImage: "shuffle")
      }
      .disabled(!canPlay)
      Divider()
      Button("Rename…") { editor.beginRename(collection.id) }
        .disabled(editor.isChanging)
      Button("Delete…", role: .destructive) { editor.requestDelete(collection.id) }
        .disabled(editor.isChanging)
    }
    .help(isShown ? L("Show all wallpapers") : "")
    // The same commands for VoiceOver, which does not open a context menu.
    .accessibilityAction(named: Text("Play")) { if canPlay { play(order: .sequential) } }
    .accessibilityAction(named: Text("Shuffle")) { if canPlay { play(order: .shuffle) } }
    .accessibilityAction(named: Text("Rename…")) { editor.beginRename(collection.id) }
    .accessibilityAction(named: Text("Delete…")) { editor.requestDelete(collection.id) }
    .accessibilityAddTraits(isShown ? .isSelected : [])
    .accessibilityIdentifier("collection-\(collection.id)")
  }

  /// Play's action key, shared with Installed's Play and Shuffle.
  private static let playKey = PanelActionCoordinator.key("playlistPlay")

  /// Play needs a wallpaper in the collection that can play, a target display with a playlist of
  /// its own, and no Play request still pending.
  private var canPlay: Bool {
    controller.targetDisplay?.isSelectable == true && !controller.isBusy(Self.playKey)
      && controller.canPlay(.collection(id: collection.id))
  }

  /// The target display rotates through the collection and changes to it at once.
  private func play(order: PlaylistOrder) {
    let source = PlaylistSourceChoice.collection(id: collection.id)
    controller.launch(Self.playKey) { [controller] in
      try await controller.playPlaylist(source, order: order)
    }
  }

  private var background: Color {
    if isShown { return theme.accent.accent.color.opacity(0.14) }
    return isHovering ? theme.surface.hover.color : .clear
  }
}

/// A line of quiet text in the Collections group: the empty group's hint, and the result of a
/// change. It wraps rather than being cut.
struct CollectionsNote: View {
  let text: Text

  init(_ text: Text) { self.text = text }

  var body: some View {
    text
      .font(.system(size: 11.5))
      .foregroundStyle(.secondary)
      .lineLimit(4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// The field a collection is named in. The name is whatever the person types; the store's refusals
/// ("Enter a name between 1 and 128 characters, on one line.") are shown under it.
private struct CollectionNameRow: View {
  @Bindable var editor: CollectionEditorModel

  @Environment(\.panelTheme) private var theme
  @FocusState private var isFocused: Bool

  var body: some View {
    let isRenaming = editor.mode != .create
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "folder")
          .foregroundStyle(theme.surface.muted.color)
          .accessibilityHidden(true)
        TextField("Collection name", text: $editor.name)
          .textFieldStyle(.plain)
          .focused($isFocused)
          .onSubmit { editor.submit() }
          .onExitCommand { editor.cancel() }
          .onChange(of: editor.name) { editor.clearFailure() }
          .accessibilityIdentifier("collection-name")
        Button {
          editor.submit()
        } label: {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .disabled(editor.isChanging || editor.name.trimmingCharacters(in: .whitespaces).isEmpty)
        .help(isRenaming ? L("Save") : L("Create"))
        .accessibilityLabel(Text(verbatim: isRenaming ? L("Save") : L("Create")))
        .accessibilityIdentifier("collection-name-save")
        Button {
          editor.cancel()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(theme.surface.faint.color)
        }
        .buttonStyle(.plain)
        .help(L("Cancel"))
        .accessibilityLabel(Text(verbatim: L("Cancel")))
        .accessibilityIdentifier("collection-name-cancel")
      }
      .padding(.horizontal, 8)
      .frame(minHeight: 28)
      .background(
        theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(
            editor.failure == nil ? theme.surface.line.color : theme.surface.danger.color,
            lineWidth: editor.failure == nil ? 0.5 : 1)
      }
      if let failure = editor.failure {
        Text(verbatim: failure)
          .font(.system(size: 11))
          .foregroundStyle(theme.surface.danger.color)
          .lineLimit(4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("collection-name-error")
      }
    }
    .onAppear {
      // The row has to be in the panel before it can take the keyboard.
      DispatchQueue.main.async { isFocused = true }
    }
  }
}
