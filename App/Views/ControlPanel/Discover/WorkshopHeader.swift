import SwiftUI

/// What sits above the Workshop grid: one row with the three lists, the Filter button, the sort menu
/// and Refresh; under it, while an author's or a collection's wallpapers are open, the way back out;
/// and, for Your subscriptions, who is signed in and the download of what is missing. The search
/// bar above it is the detail column's (`PageSearchBar`).
///
/// The row never wraps: the tools are words in a wide page and icons in a narrower one
/// (`WorkshopHeaderDensity`), and the lists are tabs while they fit beside them, else a menu, so
/// beside an open inspector in the smallest window the grid still starts right under the row.
struct WorkshopHeader: View {
  let density: WorkshopHeaderDensity

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.workshopBrowser
    let browse = controller.workshopBrowse
    let source = browse.source
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        // Offered the row first, so the tabs give way to the menu only when the tools leave them
        // too little room; the tools keep their full size.
        WorkshopSourceTabs(current: source.list) { model.open($0) }
          .layoutPriority(1)
        Spacer(minLength: 8)
        HStack(spacing: 8) {
          WorkshopTools(isSearchable: source.isSearchable, iconsOnly: density != .wide)
        }
        .fixedSize()
      }
      if source.list == nil {
        WorkshopSourceBar(source: source, isLoading: browse.isLoading)
      }
      if source.source == .subscriptions, browse.isSignedInToSteam {
        WorkshopSubscriptionBar(browse: browse)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 10)
  }
}

// MARK: - Lists

/// Wallpapers, Collections and Your subscriptions: a segmented control that reads as three places to
/// go. Choosing the one on show searches it again from the first page, and while an author or a
/// collection is open none is current. The arrow keys move between the tabs (and wrap), Home and End
/// jump to the first and last, Space and Return choose.
///
/// Where the tabs do not fit the width they are offered they are one menu, named by the list on show,
/// and where that name does not fit either, by its symbol (the window's subtitle names the list).
struct WorkshopSourceTabs: View {
  let current: WorkshopList?
  let onSelect: (WorkshopList) -> Void

  @Environment(\.panelTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var focused: WorkshopList?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      segments
      menu(showsTitle: true)
      menu(showsTitle: false)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Workshop lists"))
    .accessibilityIdentifier("workshop-lists")
  }

  private var segments: some View {
    HStack(spacing: 0) {
      ForEach(WorkshopList.allCases, id: \.self) { list in
        let isCurrent = list == current
        Button {
          onSelect(list)
        } label: {
          Text(verbatim: list.panelTitle)
            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? theme.surface.text.color : theme.surface.muted.color)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: 24)
            .background {
              if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .fill(theme.surface.segmentSelected.color)
                  .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 1, y: 0.5)
              }
            }
            .overlay {
              if focused == list {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .strokeBorder(theme.accent.focus.color, lineWidth: 2)
              }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused, equals: list)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { press in
          move(from: list, press.key)
        }
        .onKeyPress(keys: [.space, .return]) { _ in
          onSelect(list)
          return .handled
        }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("workshop-tab-\(list)")
      }
    }
    .padding(2)
    .background(theme.surface.hover.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  /// Where focus goes from `list` on a key: the arrows wrap around, Home and End jump to the
  /// first and last tab. Nothing is chosen by moving; Space and Return choose.
  static func destination(from list: WorkshopList, key: KeyEquivalent) -> WorkshopList? {
    let all = WorkshopList.allCases
    guard let index = all.firstIndex(of: list) else { return nil }
    switch key {
    case .leftArrow: return all[(index + all.count - 1) % all.count]
    case .rightArrow: return all[(index + 1) % all.count]
    case .home: return all.first
    case .end: return all.last
    default: return nil
    }
  }

  private func move(from list: WorkshopList, _ key: KeyEquivalent) -> KeyPress.Result {
    guard let target = Self.destination(from: list, key: key) else { return .ignored }
    focused = target
    return .handled
  }

  private func menu(showsTitle: Bool) -> some View {
    Menu {
      ForEach(WorkshopList.allCases, id: \.self) { list in
        Button {
          onSelect(list)
        } label: {
          if list == current {
            Label {
              Text(verbatim: list.panelTitle)
            } icon: {
              Image(systemName: "checkmark")
            }
          } else {
            Text(verbatim: list.panelTitle)
          }
        }
      }
    } label: {
      let symbol = Image(systemName: current?.systemImage ?? "square.stack")
      if showsTitle {
        Label {
          if let current {
            Text(verbatim: current.panelTitle)
          } else {
            Text("Workshop lists")
          }
        } icon: {
          symbol
        }
      } else {
        symbol
      }
    }
    .menuStyle(.button)
    .buttonStyle(.panelCapsule)
    .menuIndicator(.visible)
    .fixedSize()
    .help(current?.panelTitle ?? L("Workshop lists"))
    .accessibilityValue(current.map { Text(verbatim: $0.panelTitle) } ?? Text(verbatim: ""))
  }
}

// MARK: - Tools

/// Filter, the sort menu and Refresh, in words or as icons.
private struct WorkshopTools: View {
  let isSearchable: Bool
  let iconsOnly: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.workshopBrowser
    let isLoading = controller.workshopBrowse.isLoading
    FilterButton(iconOnly: iconsOnly)
    if isSearchable { SortMenu(iconOnly: iconsOnly) }
    Button {
      model.refresh()
    } label: {
      Image(systemName: "arrow.clockwise")
        .font(.system(size: 12, weight: .medium))
        .frame(width: 20, height: 20)
    }
    .buttonStyle(.panelCapsule)
    .disabled(isLoading)
    .help(L("Refresh Workshop"))
    .accessibilityLabel(Text(verbatim: L("Refresh Workshop")))
    .accessibilityIdentifier("workshop-refresh")
  }
}

/// The Filter button, tinted while any filter applies or the Filters sidebar is open, with the
/// count of active filters; it opens and closes the sidebar.
private struct FilterButton: View {
  let iconOnly: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.workshopBrowser
    let shell = controller.shell
    let count = model.filterCount
    Button {
      shell.toggleFilters()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 11.5, weight: .semibold))
        if !iconOnly { Text("Filter") }
        if count > 0 { CountBadge(count: count, style: .attention) }
      }
    }
    .buttonStyle(.panelCapsule(isActive: count > 0 || shell.areFiltersShown))
    .help(shell.areFiltersShown ? L("Hide filters") : L("Show filters"))
    .accessibilityLabel(Text("Filter"))
    .accessibilityValue(count > 0 ? Text(verbatim: L("\(count) active")) : Text(verbatim: ""))
    .accessibilityIdentifier("workshop-filter")
  }
}

/// The nine sorts Steam honours. Choosing one searches at once.
private struct SortMenu: View {
  let iconOnly: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.workshopBrowser
    Menu {
      Picker(
        selection: Binding(get: { model.sort }, set: { model.choose(sort: $0) })
      ) {
        ForEach(WorkshopSort.allCases) { sort in
          Text(verbatim: sort.panelTitle).tag(sort)
        }
      } label: {
        Text("Sort wallpapers")
      }
      .pickerStyle(.inline)
    } label: {
      HStack(spacing: 5) {
        if iconOnly {
          Image(systemName: "arrow.up.arrow.down").font(.system(size: 11.5, weight: .semibold))
        } else {
          Text(verbatim: model.sort.panelTitle)
        }
      }
    }
    .menuStyle(.button)
    .buttonStyle(.panelCapsule)
    .menuIndicator(iconOnly ? .hidden : .visible)
    .fixedSize()
    .help(L("Sort wallpapers"))
    .accessibilityLabel(Text("Sort wallpapers"))
    .accessibilityValue(Text(verbatim: model.sort.panelTitle))
    .accessibilityIdentifier("workshop-sort")
  }
}

// MARK: - Sources

/// An author's or a collection's wallpapers are open: the way back, and what is open.
struct WorkshopSourceBar: View {
  let source: WorkshopSourceState
  let isLoading: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.workshopBrowser
    HStack(spacing: 8) {
      Button {
        model.goBack()
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 12, weight: .semibold))
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.panelCapsule)
      .disabled(!source.canGoBack || isLoading)
      .help(L("Go back"))
      .accessibilityLabel(Text("Go back"))
      // The name is Steam's own, so it is never a catalog key.
      Text(verbatim: source.heading)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(theme.surface.text.color)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(source.heading)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
    }
    .frame(minHeight: 30)
  }
}

/// Your subscriptions, signed in: whose list it is, how many, the one-click download of what the
/// library lacks, and the way to sign out. Nothing is subscribed or unsubscribed from here.
struct WorkshopSubscriptionBar: View {
  let browse: WorkshopBrowseState

  /// The download of what is missing is offered unless one is under way or the list has loaded and
  /// holds nothing.
  static func canDownloadMissing(isBusy: Bool, hasLoaded: Bool, totalCount: Int) -> Bool {
    !isBusy && !(hasLoaded && totalCount == 0)
  }

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.workshopBrowser
    let busy = controller.isBusy(PanelActionCoordinator.key("workshopDownloadSubscribed"))
    // One row while it fits, the account on one and its actions on the next when it does not.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        account
        Spacer(minLength: 8)
        actions(model: model, busy: busy)
      }
      VStack(alignment: .leading, spacing: 8) {
        account
        HStack(spacing: 12) { actions(model: model, busy: busy) }
      }
    }
  }

  /// Whose list it is, and how many are in it.
  private var account: some View {
    HStack(spacing: 12) {
      Label {
        Text("Signed in to Steam")
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.surface.approved.color)
      }
      .font(.system(size: 12.5, weight: .medium))
      if browse.hasLoaded {
        Text("\(browse.totalCount) subscribed")
          .font(.system(size: 12.5))
          .foregroundStyle(theme.surface.muted.color)
      }
    }
  }

  @ViewBuilder
  private func actions(model: WorkshopBrowserModel, busy: Bool) -> some View {
    Button {
      model.downloadSubscribed()
    } label: {
      Label("Download the ones not in your library", systemImage: "arrow.down.circle")
    }
    .buttonStyle(.panelPrimary(size: .compact))
    .disabled(
      !Self.canDownloadMissing(
        isBusy: busy, hasLoaded: browse.hasLoaded, totalCount: browse.totalCount)
    )
    .help(L("Downloads every wallpaper you subscribe to that isn’t in your library yet"))
    Button("Sign out of Steam") { model.signOutOfSteam() }
      .buttonStyle(.panelLink)
      .font(.system(size: 12))
      .help(L("Forgets the Steam session this app read your subscriptions with"))
  }
}
