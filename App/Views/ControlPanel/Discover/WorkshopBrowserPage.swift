import SwiftUI

/// The Steam Workshop page: the lists and the tools above, 30 tiles to a page, the pager beneath.
/// The search bar above it is the detail column's (`PageSearchBar`).
///
/// Steam does the searching, sorting and filtering; the page asks and shows what comes back. A tile
/// is a Workshop item with the download it wears, and the inspector beside the page says the rest.
/// The page keeps no state of its own beyond what the model holds: leaving it releases every
/// animation, and the window's close and reopen bring back the grid where it was.
struct WorkshopBrowserPage: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.panelIsVisible) private var isVisible
  var body: some View {
    // The page offers its children the width it was given and asks for none of its own: a column
    // that insists on a minimum makes the split view wider than a window that was shrunk with the
    // inspector open, and AppKit then loops over the constraints and throws. A GeometryReader has no
    // minimum of its own, which is how `PanelEmptyState` keeps its width at zero too.
    GeometryReader { proxy in
      page(density: WorkshopHeaderDensity.make(width: proxy.size.width))
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipped()
    }
  }

  private func page(density: WorkshopHeaderDensity) -> some View {
    let model = controller.workshopBrowser
    let browse = controller.workshopBrowse
    let footer = WorkshopFooterContent.make(browse: browse)
    return VStack(spacing: 0) {
      WorkshopHeader(density: density)
      content(browse: browse, model: model)
      if !footer.isEmpty {
        Divider()
        WorkshopFooter(density: density, content: footer)
      }
    }
    .onAppear { model.pageAppeared() }
    .onDisappear { model.pageDisappeared() }
    .onChange(of: isVisible, initial: true) { model.previews.setHidden(!isVisible) }
    .onChange(of: browse.pager.page) { model.syncPageText() }
  }

  @ViewBuilder
  private func content(browse: WorkshopBrowseState, model: WorkshopBrowserModel) -> some View {
    if browse.items.isEmpty {
      let state = WorkshopEmptyState.make(
        browse: browse, draftText: model.text, filterCount: model.filterCount)
      WorkshopEmptyStateView(state: state, filtersAreOpen: controller.shell.areFiltersShown)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      WorkshopGrid(items: browse.items, isLoading: browse.isLoading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

// MARK: - Grid

/// The tiles: a lazy grid that fills the width, at least three to a row. It keeps its place across a
/// closed window, goes back to the top when another list or page opens, and tells the previews which
/// tiles are on screen.
private struct WorkshopGrid: View {
  let items: [WorkshopItem]
  let isLoading: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.displayScale) private var displayScale
  @State private var position = ScrollPosition(edge: .top)
  /// The top inset the scroll view has under the toolbar, which a stored offset is measured from.
  @State private var topInset: Double = 0

  /// The offset from the top of the content and the inset it is measured against.
  private struct Metric: Equatable {
    var offset: Double
    var inset: Double
  }

  var body: some View {
    let model = controller.workshopBrowser
    let tiles = previewTiles()
    TileGrid(items, spacing: 14, onActivate: { model.select($0) }) { item in
      WorkshopTileCell(item: item)
    }
    .scrollPosition($position)
    .onScrollGeometryChange(for: Metric.self) {
      Metric(offset: $0.contentOffset.y + $0.contentInsets.top, inset: $0.contentInsets.top)
    } action: { _, metric in
      topInset = metric.inset
      model.scrolled(to: metric.offset)
    }
    .onChange(of: model.scrollEpoch) { position.scrollTo(edge: .top) }
    .onChange(of: tiles, initial: true) {
      let pixels = max(16, Int((WorkshopTileCell.pointSize * displayScale).rounded(.up)))
      model.previews.pageChanged(tiles, stillPixels: pixels)
    }
    .onAppear { restoreScroll(model) }
    .overlay(alignment: .top) {
      // A search that replaces what is on show says so without hiding it.
      if isLoading {
        ProgressView()
          .progressViewStyle(.linear)
          .padding(.horizontal, 20)
          .transition(.opacity)
          .accessibilityLabel(Text("Searching Steam Workshop…"))
      }
    }
    // The grid is one named group for VoiceOver, with the tiles inside it, and says while a search
    // replaces its tiles that they are about to change (the web page's aria-busy).
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Wallpapers"))
    .accessibilityValue(isLoading ? Text("Searching Steam Workshop…") : Text(verbatim: ""))
    .accessibilityIdentifier("workshop-grid")
  }

  /// What the preview coordinator needs of each tile: its still, and whether it may animate.
  private func previewTiles() -> [WorkshopPreviewCoordinator.Tile] {
    items.map { item in
      WorkshopPreviewCoordinator.Tile(
        id: item.id,
        still: controller.mediaLibraryContains(item.id)
          ? (controller.workshopInstalledStill(for: item.id) ?? item.thumbnail) : item.thumbnail,
        animates: item.thumbnail != nil && !controller.mediaLibraryContains(item.id))
    }
  }

  /// The grid returns to where the last window left it, once.
  private func restoreScroll(_ model: WorkshopBrowserModel) {
    guard let stored = model.takeRestoredScroll(), stored > 0 else { return }
    position.scrollTo(y: stored - topInset)
  }
}

// MARK: - Empty

/// What the grid says while it has no tiles: loading, the Workshop being unavailable, a list that
/// needs a sign-in, or why nothing matched and what to do about it.
struct WorkshopEmptyStateView: View {
  let state: WorkshopEmptyState
  let filtersAreOpen: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.workshopBrowser
    switch state {
    case .signInToSeeSubscriptions(let isSigningIn):
      signIn(
        title: L("Sign in to see your subscriptions"),
        description: L(
          "Steam shows the wallpapers you subscribe to only to you. You sign in on Steam’s own page; WallpaperMachine keeps the session only until it quits, and uses it only to read this list."
        ), isSigningIn: isSigningIn, model: model)
    case .signInToSeeFavorites(let isSigningIn):
      signIn(
        title: L("Sign in to see your favorites"),
        description: L(
          "Your favorites are read from your own Steam account. You sign in on Steam’s own page, and WallpaperMachine uses the session only to read your lists."
        ), isSigningIn: isSigningIn, model: model)
    case .loading:
      PanelEmptyState(
        verbatim: L("Loading Workshop"), systemImage: "storefront",
        description: L("Fetching wallpapers from Steam.")
      ) {
        ProgressView().controlSize(.small)
      }
    case .unavailable(let message):
      PanelEmptyState(
        verbatim: L("Workshop unavailable"), systemImage: "wifi.exclamationmark",
        description: message
      ) {
        Button {
          model.retry()
        } label: {
          Label("Try again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.panelSecondary)
      }
    case .noResults(let recovery):
      noResults(recovery, model: model)
    }
  }

  /// A personal list with no Steam session: why it needs one, and the sign-in.
  @ViewBuilder
  private func signIn(
    title: String, description: String, isSigningIn: Bool, model: WorkshopBrowserModel
  ) -> some View {
    PanelEmptyState(verbatim: title, systemImage: "person.crop.circle", description: description) {
      VStack(spacing: 12) {
        Text("This is separate from the SteamCMD sign-in in Settings, which only downloads wallpapers.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        if isSigningIn {
          Button {
            model.signInToSteam()
          } label: {
            Label("Show sign-in window", systemImage: "person.crop.circle.badge.checkmark")
          }
          .buttonStyle(.panelSecondary)
        } else {
          Button {
            model.signInToSteam()
          } label: {
            Label("Sign in to Steam…", systemImage: "person.crop.circle.badge.checkmark")
          }
          .buttonStyle(.panelPrimary)
        }
      }
    }
  }

  @ViewBuilder
  private func noResults(_ recovery: WorkshopEmptyState.Recovery, model: WorkshopBrowserModel)
    -> some View
  {
    switch recovery {
    case .clearSearchAndFilters:
      PanelEmptyState(
        verbatim: L("No wallpapers found"), systemImage: "magnifyingglass",
        description: L("Try a different search or remove some filters. Every selected tag must match.")
      ) {
        Button("Clear search and filters") { model.clearSearchAndFilters() }
          .buttonStyle(.panelSecondary)
      }
      .seasonalArt(.noResults)
    case .clearSearch:
      PanelEmptyState(
        verbatim: L("No wallpapers found"), systemImage: "magnifyingglass",
        description: L("Try a different search or remove some filters. Every selected tag must match.")
      ) {
        Button("Clear search") { model.clearSearchAndFilters() }
          .buttonStyle(.panelSecondary)
      }
      .seasonalArt(.noResults)
    case .clearFilters(let count):
      PanelEmptyState(
        verbatim: L("No wallpapers found"), systemImage: "line.3.horizontal.decrease.circle",
        description: count == 1
          ? L("The active filter hides every wallpaper.")
          : L("The \(count) active filters hide every wallpaper.")
      ) {
        HStack {
          Button("Clear filters") { model.clearFilters() }
          if !filtersAreOpen {
            Button("Show filters") { controller.shell.setFiltersShown(true) }
          }
        }
        .buttonStyle(.panelSecondary)
      }
      .seasonalArt(.noResults)
    case .screened(let isCollections, let nextPage):
      PanelEmptyState(
        verbatim: L("No wallpapers found"), systemImage: "line.3.horizontal.decrease.circle",
        description: isCollections
          ? L("The age rating filters hide every collection found for this page.")
          : L("The age rating and type filters hide every wallpaper on this page.")
      ) {
        HStack {
          if let nextPage {
            Button {
              model.showPage(nextPage)
            } label: {
              Label("Next page", systemImage: "chevron.right")
            }
          }
          if !filtersAreOpen {
            Button("Show filters") { controller.shell.setFiltersShown(true) }
          }
        }
        .buttonStyle(.panelSecondary)
      }
    case .browseWorkshop:
      PanelEmptyState(
        verbatim: L("No wallpapers found"), systemImage: "bookmark",
        description: L("Wallpapers you subscribe to on the Steam Workshop appear here.")
      ) {
        Button("Browse Workshop") { model.open(.browse) }
          .buttonStyle(.panelPrimary)
      }
    case .browseWorkshopForFavorites:
      PanelEmptyState(
        verbatim: L("No wallpapers found"), systemImage: "heart",
        description: L("Wallpapers you favorite on the Steam Workshop appear here.")
      ) {
        Button("Browse Workshop") { model.open(.browse) }
          .buttonStyle(.panelPrimary)
      }
    case .refresh:
      PanelEmptyState(
        verbatim: L("No wallpapers found"), systemImage: "storefront",
        description: L("The Workshop returned no results.")
      ) {
        Button {
          model.refresh()
        } label: {
          Label("Refresh Workshop", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.panelSecondary)
      }
    }
  }
}
