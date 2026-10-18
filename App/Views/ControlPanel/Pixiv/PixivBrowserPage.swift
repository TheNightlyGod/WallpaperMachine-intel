import SwiftUI

/// The pixiv page: rankings and tag search, the filters, a grid of works, and the paging bar.
///
/// The search bar above it is the detail column's (`PageSearchBar`): Return asks for the first
/// page afresh, typing waits for a pause. Under it a slim row holds Filter, the
/// ranking or search-order menu and Refresh, with a way to sign in while signed out. The inspector
/// shows the selected work. The paging bar is there while it has something to page or to say
/// about the works on show (`PixivPagerBar.isShown(for:)`).
struct PixivBrowserPage: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.pixivBrowser
    let browse = controller.pixivBrowse
    VStack(spacing: 0) {
      PixivBar(height: 48) { PixivHeaderRow(browse: browse) }
      content(browse)
      if PixivPagerBar.isShown(for: browse) {
        PixivPagerBar(browse: browse)
      }
    }
    .onChange(of: model.isSignedIn, initial: true) { model.reconcileAccount() }
    .task { model.loadIfNeeded() }
    .onDisappear {
      // A search that was waiting for its pause still goes out, and the grid's place is stored at
      // once rather than at the end of its 400 ms wait.
      model.flushScrollReport()
    }
    .accessibilityIdentifier("pixiv-page")
  }

  @ViewBuilder
  private func content(_ browse: PixivBrowseState) -> some View {
    if let empty = PixivEmptyState.make(browse) {
      PixivEmptyView(state: empty)
    } else {
      // The grid is laid over a flexible filler instead of being the page's own content. Its
      // lazy rows would otherwise feed the split view's hosting view an ideal height that keeps
      // changing as rows are built, and at the smallest window, beside an open inspector, AppKit
      // never finishes its constraint pass. A new listing or another page is a new grid, which
      // starts at the top.
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          PixivGrid(works: browse.works, selectedID: browse.selectedID)
            .id(
              PixivScrollKey(
                listing: controller.pixiv.committedQuery?.listing, page: browse.pager.page))
        }
    }
  }
}

/// The tiles in a lazy grid that keeps its place across a closed window: the offset is reported
/// to the model as it changes, and the first grid of the next window scrolls back to it, once.
///
/// Restoring waits for a settled grid, as Installed's does: while a window lays out, the scroll
/// view reports a viewport of a few points and a content height that is only an estimate, so the
/// target is asserted again with each report until the grid is there (a few reports at most),
/// clamped to what the grid holds. Nothing is reported while it waits, so the grid's first look at
/// its top does not overwrite the place it is going back to.
///
/// Once nothing waits to be restored, only the offset is watched. A lazy grid's content height is
/// an estimate that moves while rows are built, and each scroll action asks the hosting view for
/// another update from inside AppKit's layout pass: at the smallest window beside an open
/// inspector, watching the height made that pass never end ("needing another Update Constraints
/// in Window pass").
private struct PixivGrid: View {
  let works: [PixivWork]
  let selectedID: String?

  @Environment(PanelController.self) private var controller
  @State private var position = ScrollPosition(edge: .top)
  @State private var pendingOffset: Double?
  @State private var restoreAttempts = 0

  /// A scroll view reporting less than this is still being laid out.
  private static let settledViewport: Double = 100
  private static let restoreAttempts = 8

  /// What the scroll view reports about itself: the offset, and its sizes only while a restore
  /// needs them.
  private struct Metrics: Equatable {
    var offset: Double
    var contentHeight: Double = 0
    var viewportHeight: Double = 0

    init(_ geometry: ScrollGeometry, measuresContent: Bool) {
      offset = geometry.contentOffset.y + geometry.contentInsets.top
      if measuresContent {
        contentHeight = geometry.contentSize.height
        viewportHeight = geometry.containerSize.height
      }
    }
  }

  var body: some View {
    let model = controller.pixivBrowser
    TileGrid(works, onActivate: { model.select($0) }) { work in
      PixivTileCell(work: work, isSelected: work.id == selectedID)
    }
    .scrollPosition($position)
    .onScrollGeometryChange(for: Metrics.self) { [isRestoring = pendingOffset != nil] geometry in
      Metrics(geometry, measuresContent: isRestoring)
    } action: { _, metrics in
      scrolled(metrics, model: model)
    }
    .onAppear {
      guard let stored = model.takeRestoredScroll(), stored > 0 else {
        // A grid that starts at its top says so: the scroll view reports only changes, so
        // without this a new listing or page would keep the place the grid before it had.
        model.scrolled(to: 0)
        return
      }
      pendingOffset = stored
      position.scrollTo(y: stored)
    }
    .accessibilityIdentifier("pixiv-grid")
  }

  private func scrolled(_ metrics: Metrics, model: PixivBrowserModel) {
    if let target = pendingOffset {
      guard metrics.viewportHeight > Self.settledViewport else { return }
      let clamped = min(target, max(0, metrics.contentHeight - metrics.viewportHeight))
      restoreAttempts += 1
      if abs(metrics.offset - clamped) <= 1 || restoreAttempts > Self.restoreAttempts {
        pendingOffset = nil
      } else {
        position.scrollTo(y: clamped)
        return
      }
    }
    model.scrolled(to: metrics.offset)
  }
}

/// A bar of controls laid over a filler of a fixed height, so that nothing in it feeds the split
/// view an ideal or minimum size of its own. The page column has no minimum width (the inspector
/// beside it already asks for 260 points of a 760-point window), and a button in the page's own
/// layout made the split view's detail pane report a new minimum size on every pass, which AppKit
/// never finishes laying out. The bar's controls shrink or leave instead (`PixivHeaderRow`).
struct PixivBar<Content: View>: View {
  let height: CGFloat
  @ViewBuilder var content: Content

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .overlay { content }
  }
}

/// What a grid belongs to: its listing and page. A different one is a different grid.
struct PixivScrollKey: Hashable {
  let listing: PixivListing?
  let page: Int
}

/// The slim row under the toolbar: Filter, the menu, and on the trailing side the sign-in link and
/// Refresh. It never asks for more width than it is given: the menu's label shortens first, then
/// the sign-in link takes its short words ("Sign in") and then leaves (the Filters sidebar still
/// has it). Refresh turns into a spinner while a load replaces works on show; while the page's
/// centre says it is loading, that is the one indicator, and Refresh only waits.
struct PixivHeaderRow: View {
  let browse: PixivBrowseState

  @Environment(PanelController.self) private var controller
  @State private var width: CGFloat = 0

  /// How much of the sign-in link a row of `width` points has room for.
  enum SignInStyle: Equatable { case text, short, hidden }

  static func signInStyle(forWidth width: CGFloat) -> SignInStyle {
    if width >= 560 { return .text }
    if width >= 380 { return .short }
    return .hidden
  }

  /// Whether Refresh shows a spinner: only while a load replaces works that are on show. A page
  /// with nothing on show has its loading said in the middle, once.
  static func refreshSpins(_ browse: PixivBrowseState) -> Bool {
    browse.isLoading && PixivEmptyState.make(browse) == nil
  }

  var body: some View {
    let model = controller.pixivBrowser
    HStack(spacing: 8) {
      PixivFilterButton()
      PixivListingMenu()
      Spacer(minLength: 0)
      if !model.isSignedIn {
        signIn(Self.signInStyle(forWidth: width))
      }
      Button {
        model.refresh()
      } label: {
        Group {
          if Self.refreshSpins(browse) {
            ProgressRing(value: nil, lineWidth: 1.8).frame(width: 13, height: 13)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .frame(width: 14, height: 14)
      }
      .buttonStyle(.panelCapsule)
      .disabled(browse.isLoading)
      .help(L("Refresh pixiv"))
      .accessibilityLabel(L("Refresh pixiv"))
      .accessibilityIdentifier("pixiv-refresh")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }

  @ViewBuilder
  private func signIn(_ style: SignInStyle) -> some View {
    let isSigningIn = controller.pixivAccount.isSigningIn
    switch style {
    case .text:
      PixivSignInButton(isSigningIn: isSigningIn).buttonStyle(.link).controlSize(.small)
    case .short:
      PixivSignInButton(isSigningIn: isSigningIn, isShort: true)
        .buttonStyle(.link)
        .controlSize(.small)
    case .hidden:
      EmptyView()
    }
  }
}

/// The Filter capsule: how many filters are on; it opens and closes the Filters sidebar.
private struct PixivFilterButton: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.pixivBrowser
    let shell = controller.shell
    let count = model.filterCount
    Button {
      shell.toggleFilters()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 11, weight: .semibold))
        Text("Filter")
        if count > 0 { CountBadge(count: count, style: .attention) }
      }
    }
    .buttonStyle(.panelCapsule(isActive: count > 0 || shell.areFiltersShown))
    .help(shell.areFiltersShown ? L("Hide filters") : L("Show filters"))
    .accessibilityValue(count > 0 ? L("\(count) active") : "")
    .accessibilityIdentifier("pixiv-filter-button")
  }
}

/// The menu beside Filter: the rankings while the search box is empty, the search orders once it
/// has text. The R-18 rankings appear only for a signed-in account with Mature ticked.
private struct PixivListingMenu: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.pixivBrowser
    let query = model.query
    let isSearching = model.isSearching
    let current = isSearching ? query.order.title : query.ranking.title
    let label = isSearching ? L("Search order") : L("Ranking")
    Menu {
      if isSearching {
        Picker(
          label,
          selection: Binding(get: { query.order }, set: { model.choose(order: $0) })
        ) {
          ForEach(PixivSearchOrder.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } else {
        Picker(
          label,
          selection: Binding(get: { query.ranking }, set: { model.choose(ranking: $0) })
        ) {
          ForEach(model.rankingChoices, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
    } label: {
      HStack(spacing: 5) {
        Text(verbatim: current).lineLimit(1).truncationMode(.tail)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 8.5, weight: .bold))
          .foregroundStyle(.secondary)
      }
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.panelCapsule)
    .layoutPriority(-1)
    .accessibilityLabel(label)
    .accessibilityValue(current)
    .accessibilityIdentifier("pixiv-listing-menu")
  }
}

/// What the page shows in place of the grid: loading, an error, filters that hide the whole page,
/// or nothing found.
private struct PixivEmptyView: View {
  let state: PixivEmptyState

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.pixivBrowser
    switch state {
    case .loading:
      PanelEmptyState(
        "Loading pixiv", systemImage: "paintpalette",
        description: "Fetching illustrations from pixiv."
      ) {
        ProgressView().controlSize(.small)
      }
    case .error(let message):
      PanelEmptyState(
        verbatim: L("pixiv unavailable"), systemImage: "exclamationmark.triangle",
        description: message
      ) {
        Button {
          controller.launch("pixivRetry") { try await controller.pixivRetry() }
        } label: {
          Label("Try again", systemImage: "arrow.clockwise")
        }
      }
    case .filtersHideAll(let hidden, let canGoNext):
      PanelEmptyState(
        verbatim: L("No matching illustrations"), systemImage: "line.3.horizontal.decrease",
        description: hidden == 1
          ? L("Your filters hide the only work on this page.")
          : L("Your filters hide all \(hidden) works on this page.")
      ) {
        HStack {
          Button("Clear filters") { model.clearFilters() }
          if canGoNext {
            Button {
              model.showPage(controller.pixivBrowse.pager.nextPage)
            } label: {
              Label("Next page", systemImage: "chevron.right")
            }
          }
        }
      }
    case .nothing(let searching):
      PanelEmptyState(
        verbatim: L("No illustrations found"), systemImage: "photo.on.rectangle",
        description: searching
          ? L("Try other tags. pixiv matches tags, not titles.")
          : L("pixiv returned an empty ranking.")
      ) {
        if searching { Button("Clear search") { model.clearSearch() } }
      }
    }
  }
}
