import SwiftUI

/// The bar under the grid. It says how many wallpapers a search or filter leaves and offers the
/// Workshop's updates; while some are ticked it becomes the tools for them: Add to playlist, the
/// collection tools and Move to Trash; and while the library loads it says so. With nothing to say
/// it is not there: the window's subtitle already counts the view on show.
struct InstalledFooter: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var width: CGFloat = 1000

  /// Below this width the tools show their icons only.
  private static let compactWidth: CGFloat = 470

  var body: some View {
    let model = controller.library
    let selected = model.selectedIDs.count
    // An empty grid says what is wrong itself; a count of zero under it adds nothing.
    if controller.isLibraryLoading || selected > 0
      || (model.emptyState == nil && IdleBar.hasContent(controller))
    {
      VStack(spacing: 0) {
        Rectangle().fill(theme.surface.divider.color).frame(height: 0.5)
        Group {
          if controller.isLibraryLoading {
            HStack(spacing: 8) {
              ProgressRing(value: nil, lineWidth: 1.75).frame(width: 13, height: 13)
              Text("Loading your library…")
            }
          } else if selected > 0 {
            SelectionBar(count: selected, isCompact: width < Self.compactWidth)
          } else {
            IdleBar()
          }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.muted.color)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(theme.surface.surface.color)
      .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
      .accessibilityIdentifier("installed-summary")
    }
  }
}

/// A link in the bar: the accent colour, which the bar's muted text would otherwise take.
private struct FooterLink: ViewModifier {
  @Environment(\.panelTheme) private var theme

  func body(content: Content) -> some View {
    content.buttonStyle(.link).foregroundStyle(theme.accent.accent.color)
  }
}

/// A tool's label: words and icon, or the icon alone in a narrow bar, where the words stay as the
/// help and the accessibility name.
private struct ToolLabel: ViewModifier {
  let isCompact: Bool

  func body(content: Content) -> some View {
    if isCompact {
      content.labelStyle(.iconOnly)
    } else {
      content.labelStyle(.titleAndIcon)
    }
  }
}

// MARK: - Idle

/// How many wallpapers a search or filter leaves, the Workshop's updates, and, in selection mode,
/// how to select. The count of the whole view is the window's subtitle, so it is not repeated here.
private struct IdleBar: View {
  @Environment(PanelController.self) private var controller

  /// Whether the bar has anything to show.
  static func hasContent(_ controller: PanelController) -> Bool {
    let model = controller.library
    return model.narrowsView || controller.workshopUpdates.count > 0 || model.isSelecting
  }

  var body: some View {
    let model = controller.library
    let count = model.visibleRows.count
    let updates = controller.workshopUpdates.count
    VStack(alignment: .leading, spacing: 6) {
      TagFlow(spacing: 12) {
        if model.narrowsView {
          if count == 1 { Text("\(count) wallpaper") } else { Text("\(count) wallpapers") }
        }
        if updates > 0 {
          Button {
            model.updateAll()
          } label: {
            Label {
              if updates == 1 {
                Text("Update 1 wallpaper")
              } else {
                Text("Update \(updates) wallpapers")
              }
            } icon: {
              Image(systemName: "arrow.down.circle")
            }
          }
          .modifier(FooterLink())
          .disabled(controller.isBusy(PanelActionCoordinator.key("workshopUpdateAll")))
          .help(L("Download the new versions the Workshop has of your wallpapers"))
        }
        if model.isSelecting && count > 0 {
          if !model.showsSweepTip { Text("Click or drag across tiles to select them.") }
          Button("Select all") { model.selectAllVisible() }
            .modifier(FooterLink())
        }
      }
      if model.isSelecting && model.showsSweepTip { SweepTip() }
    }
  }
}

// MARK: - Selection

/// The tools for the ticked wallpapers. "Ticked" includes wallpapers a search or filter now hides:
/// every action reaches all of them, and the confirmation of Move to Trash says how many.
private struct SelectionBar: View {
  let count: Int
  let isCompact: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.library
    VStack(alignment: .leading, spacing: 6) {
      TagFlow(spacing: 10) {
        Text("\(count) selected")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.surface.text.color)
        Button("Select all") { model.selectAllVisible() }
          .modifier(FooterLink())
          .disabled(model.selection.containsAll(of: model.visibleIDs))
        Button("Clear") { model.clearSelection() }
          .modifier(FooterLink())
        Button {
          model.addSelectionToPlaylist()
        } label: {
          Label {
            if count == 1 { Text("Add to playlist") } else { Text("Add \(count) to playlist") }
          } icon: {
            Image(systemName: "text.badge.plus")
          }
        }
        .modifier(ToolLabel(isCompact: isCompact))
        .buttonStyle(.panelCapsule)
        .disabled(!model.canAddSelectionToPlaylist)
        .help(L("Adds them to the list of the target display’s playlist"))
        CollectionTools(count: count, isCompact: isCompact)
        Button(role: .destructive) {
          model.trashSelection()
        } label: {
          Label {
            if count == 1 { Text("Move to Trash") } else { Text("Move \(count) to Trash") }
          } icon: {
            Image(systemName: "trash")
          }
          .foregroundStyle(theme.surface.danger.color)
        }
        .modifier(ToolLabel(isCompact: isCompact))
        .buttonStyle(.panelCapsule)
        .disabled(!model.canTrash)
        .help(count == 1 ? L("Move to Trash") : L("Move \(count) to Trash"))
        .accessibilityIdentifier("installed-trash")
        if let notice = model.notice {
          Text(verbatim: notice)
            .accessibilityAddTraits(.updatesFrequently)
        }
      }
      if model.showsSweepTip { SweepTip() }
    }
  }
}

/// Add to collection, and Remove from the collection on show.
private struct CollectionTools: View {
  let count: Int
  let isCompact: Bool

  @Environment(PanelController.self) private var controller
  @FocusState private var isNameFocused: Bool

  var body: some View {
    let model = controller.library
    if model.newCollectionName != nil {
      nameField(model)
    } else {
      Menu {
        let collections = controller.collectionRows
        ForEach(collections) { collection in
          Button { model.addSelection(to: collection) } label: { Text(verbatim: collection.name) }
        }
        if !collections.isEmpty { Divider() }
        Button("New collection…") { model.beginNewCollection() }
      } label: {
        Label {
          if count == 1 {
            Text("Add to collection…")
          } else {
            Text("Add \(count) to collection…")
          }
        } icon: {
          Image(systemName: "folder.badge.plus")
        }
      }
      .modifier(ToolLabel(isCompact: isCompact))
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.panelCapsule)
      .fixedSize()
      .disabled(model.isChangingCollection)
      .help(L("Adds the selected wallpapers to a collection"))
      .accessibilityLabel(Text("Add to collection"))
      if let collection = model.shownCollection {
        Button {
          model.removeSelectionFromShownCollection()
        } label: {
          Label {
            Text("Remove from “\(collection.name)”")
          } icon: {
            Image(systemName: "folder.badge.minus")
          }
        }
        .modifier(ToolLabel(isCompact: isCompact))
        .buttonStyle(.panelCapsule)
        .disabled(!model.canRemoveSelectionFromCollection)
        .help(L("Remove from “\(collection.name)”"))
      }
    }
  }

  /// "New collection…" turns the picker into the name of the collection made from the selection.
  private func nameField(_ model: InstalledBrowserModel) -> some View {
    HStack(spacing: 6) {
      TextField(
        text: Binding(
          get: { model.newCollectionName ?? "" }, set: { model.setNewCollectionName($0) }),
        prompt: Text("Collection name")
      ) {
        Text("Collection name")
      }
      .textFieldStyle(.roundedBorder)
      .frame(width: 170)
      .focused($isNameFocused)
      .onSubmit { model.createCollectionFromSelection() }
      .onExitCommand { model.cancelNewCollection() }
      .onAppear { isNameFocused = true }
      Button("Create") { model.createCollectionFromSelection() }
        .buttonStyle(.panelPrimary(size: .compact))
        .disabled(model.isChangingCollection)
      Button("Cancel") { model.cancelNewCollection() }
        .modifier(FooterLink())
    }
  }
}

/// The hint that teaches press-and-sweep, until it has been used once or dismissed.
private struct SweepTip: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        icon
        text.fixedSize(horizontal: true, vertical: false)
        gotIt
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          icon
          text
        }
        gotIt.padding(.leading, 19)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var icon: some View {
    Image(systemName: "hand.point.up.left").font(.system(size: 11))
  }

  private var text: some View {
    Text("Tip: hold a tile, then drag across others to select them all at once.")
  }

  private var gotIt: some View {
    Button("Got it") { controller.markDragSelectLearned() }
      .modifier(FooterLink())
  }
}
