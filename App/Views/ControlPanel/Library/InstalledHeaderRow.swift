import SwiftUI

/// How much room the row has: with all the words, with icons only, or with icons only and closer
/// together (the page beside an inspector in the smallest window).
private enum HeaderTier {
  case regular, compact, tight

  var showsLabels: Bool { self == .regular }
}

/// The slim row under the toolbar: Filter and the sort on the left; Select, Refresh and Import on
/// the right. When the page column is too narrow for the words, every control keeps its place and
/// loses its label, which stays as its help and accessibility name.
struct InstalledHeaderRow: View {
  var body: some View {
    ViewThatFits(in: .horizontal) {
      row(.regular).padding(.horizontal, 20)
      row(.compact).padding(.horizontal, 20)
      row(.tight).padding(.horizontal, 12)
    }
    .frame(height: 44)
  }

  private func row(_ tier: HeaderTier) -> some View {
    HStack(spacing: tier == .tight ? 4 : 6) {
      FilterButton(tier: tier)
      SortControls(tier: tier)
      Spacer(minLength: 8)
      SelectButton(tier: tier)
      RefreshButton(tier: tier)
      ImportButton(tier: tier)
    }
  }
}

/// `ToolbarCapsuleButtonStyle`, with less padding for the tight tier.
private struct HeaderCapsuleStyle: ButtonStyle {
  let tier: HeaderTier
  var isActive = false

  func makeBody(configuration: Configuration) -> some View {
    HeaderCapsuleBody(configuration: configuration, tier: tier, isActive: isActive)
  }
}

private struct HeaderCapsuleBody: View {
  let configuration: ButtonStyleConfiguration
  let tier: HeaderTier
  let isActive: Bool

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .font(.system(size: 12.5, weight: .medium))
      .foregroundStyle(isActive ? theme.accent.accent.color : theme.surface.text.color)
      .lineLimit(1)
      .padding(.horizontal, tier == .tight ? 7 : 10)
      .frame(minHeight: 26)
      .background(background, in: Capsule())
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
  }

  private var background: Color {
    if isActive { return theme.accent.accent.color.opacity(configuration.isPressed ? 0.24 : 0.16) }
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering ? theme.surface.selected.color : theme.surface.hover.color
  }
}

// MARK: - Filter

/// The Filter capsule: tinted while any filter applies or the Filters sidebar is open, with the
/// number of filters in effect beside it. It opens and closes the sidebar.
private struct FilterButton: View {
  let tier: HeaderTier

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    let shell = controller.shell
    let count = model.filterCount
    Button {
      shell.toggleFilters()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 11.5, weight: .semibold))
        if tier.showsLabels { Text("Filter") }
        if count > 0 { CountBadge(count: count, style: .attention) }
      }
    }
    .buttonStyle(HeaderCapsuleStyle(tier: tier, isActive: count > 0 || shell.areFiltersShown))
    .help(shell.areFiltersShown ? L("Hide filters") : L("Show filters"))
    .accessibilityLabel(Text("Filter"))
    .accessibilityValue(Text(verbatim: model.filterButtonValue))
    .accessibilityIdentifier("installed-filter")
  }
}

// MARK: - Sort

/// The sort: with room, a menu named for the sort key and the direction button beside it. Without
/// it, one menu that holds both, since two arrow glyphs side by side would not say which is which.
private struct SortControls: View {
  let tier: HeaderTier

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    HStack(spacing: 4) {
      Menu {
        sortPicker(model)
        if !tier.showsLabels {
          Divider()
          directionPicker(model)
        }
      } label: {
        HStack(spacing: 4) {
          if tier.showsLabels {
            Text(verbatim: model.sort.name)
            Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
          } else {
            Image(systemName: "arrow.up.arrow.down")
              .font(.system(size: 11.5, weight: .semibold))
          }
        }
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(HeaderCapsuleStyle(tier: tier))
      .fixedSize()
      .help(L("Sort wallpapers"))
      .accessibilityLabel(Text("Sort wallpapers"))
      .accessibilityValue(Text(verbatim: sortState(model)))
      .accessibilityIdentifier("installed-sort")

      if tier.showsLabels {
        Button {
          model.toggleSortDirection()
        } label: {
          Image(systemName: model.descending ? "arrow.down" : "arrow.up")
            .font(.system(size: 11.5, weight: .semibold))
            .frame(width: 14)
        }
        .buttonStyle(HeaderCapsuleStyle(tier: tier))
        .help(directionHelp(model))
        .accessibilityLabel(Text(verbatim: directionHelp(model)))
        .accessibilityIdentifier("installed-sort-direction")
      }
    }
  }

  private func sortPicker(_ model: InstalledBrowserModel) -> some View {
    Picker(selection: Binding(get: { model.sort }, set: { model.setSort($0) })) {
      ForEach(LibrarySort.allCases) { sort in
        Text(verbatim: sort.name).tag(sort)
      }
    } label: {
      Text("Sort wallpapers")
    }
    .pickerStyle(.inline)
  }

  /// Ascending and Descending, ticked as the list runs; choosing one is the direction button.
  private func directionPicker(_ model: InstalledBrowserModel) -> some View {
    Picker(selection: Binding(get: { model.descending }, set: { model.setDescending($0) })) {
      Text("Ascending").tag(false)
      Text("Descending").tag(true)
    } label: {
      Text("Sort wallpapers")
    }
    .pickerStyle(.inline)
    .labelsHidden()
  }

  /// What VoiceOver reads after "Sort wallpapers": the key, and the direction too once the menu
  /// holds it (the direction button says it otherwise).
  private func sortState(_ model: InstalledBrowserModel) -> String {
    guard !tier.showsLabels else { return model.sort.name }
    return [model.sort.name, model.descending ? L("Descending") : L("Ascending")]
      .joined(separator: ", ")
  }

  private func directionHelp(_ model: InstalledBrowserModel) -> String {
    model.descending
      ? L("\(model.sort.name), descending. Click to sort ascending")
      : L("\(model.sort.name), ascending. Click to sort descending")
  }
}

// MARK: - Select, Refresh, Import

private struct SelectButton: View {
  let tier: HeaderTier

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    Button {
      model.toggleSelecting()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: model.isSelecting ? "xmark" : "checkmark.circle")
          .font(.system(size: 11.5, weight: .semibold))
        if tier.showsLabels {
          if model.isSelecting { Text("Done") } else { Text("Select") }
        }
      }
    }
    .buttonStyle(HeaderCapsuleStyle(tier: tier, isActive: model.isSelecting))
    .help(
      model.isSelecting
        ? L("Leave selection mode")
        : L(
          "Select wallpapers to move to Trash. Holding a tile and dragging across others selects them too."
        )
    )
    .accessibilityLabel(model.isSelecting ? Text("Done") : Text("Select"))
    .accessibilityAddTraits(model.isSelecting ? .isSelected : [])
    .accessibilityIdentifier("installed-select")
  }
}

private struct RefreshButton: View {
  let tier: HeaderTier

  @Environment(PanelController.self) private var controller

  var body: some View {
    Button {
      controller.library.refreshLibrary()
    } label: {
      Image(systemName: "arrow.clockwise")
        .font(.system(size: 11.5, weight: .semibold))
        .frame(width: 14)
    }
    .buttonStyle(HeaderCapsuleStyle(tier: tier))
    .disabled(controller.isLibraryLoading)
    .help(L("Refresh library"))
    .accessibilityLabel(Text("Refresh library"))
    .accessibilityIdentifier("installed-refresh")
  }
}

/// The Import button, which hangs the Import popover. It waits while an import runs: the pill in
/// the toolbar is where that one is followed.
private struct ImportButton: View {
  let tier: HeaderTier

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    Button {
      model.toggleImport(from: .page)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "plus").font(.system(size: 11.5, weight: .semibold))
        if tier.showsLabels { Text("Import") }
      }
    }
    .buttonStyle(HeaderCapsuleStyle(tier: tier, isActive: model.importAnchor == .page))
    .disabled(controller.importState.isBusy)
    .popover(
      isPresented: Binding(
        get: { model.importAnchor == .page },
        set: { if !$0 { model.closeImport() } }),
      arrowEdge: .bottom
    ) {
      ImportPopover()
    }
    .help(L("Import wallpapers"))
    .accessibilityLabel(Text("Import"))
    .accessibilityIdentifier("installed-import")
  }
}
