import SwiftUI

/// The page on show, with its title, toolbar, banners, Filters sidebar and inspector. Library pages
/// (Installed, Steam Workshop, pixiv) have the Filters sidebar before them and an inspector column
/// beside them; Settings is a page of its own.
struct PanelDetail: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The slide of the Filters sidebar and the inspector, close to a system sidebar's own.
  private static let columnSlide = Animation.smooth(duration: 0.32)

  private var columnAnimation: Animation {
    reduceMotion ? .easeOut(duration: 0.15) : Self.columnSlide
  }

  var body: some View {
    let shell = controller.shell
    let selection = shell.selection
    // The counts are only read where the subtitle shows them, and not while the library loads, when
    // they would say there is nothing.
    let counts = selection == .wallpaper && !controller.isLibraryLoading ? controller.sidebarCounts : nil
    let title = PanelTitle.make(
      selection: selection, scope: controller.library.scope, counts: counts,
      settingsSection: controller.settings.selectedSection, searchQuery: controller.settings.query,
      workshopSubtitle: selection == .workshop ? controller.workshopTitleSubtitle : nil)
    // One full-width host holds the Filters sidebar, the page and the inspector column, so the title
    // bar has one section and one band across the window (`PageScrollHost`).
    PageScrollHost {
      HStack(spacing: 0) {
        if shell.areFiltersShown {
          // It slides out from the window's leading edge.
          FilterSidebar(selection: selection)
            .transition(
              reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
        }
        page(for: selection)
          // One search bar at the top of every page, kept in place across them.
          .safeAreaInset(edge: .top, spacing: 0) { PageSearchBar(selection: selection) }
          .safeAreaInset(edge: .top, spacing: 0) { PanelBanners() }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Open by the person's choice, or by the window's width while they have not chosen, on the
        // pages that have an inspector; closed on Settings, and the choice is kept for when they
        // come back.
        if shell.hasInspector && shell.isInspectorShown {
          // It slides out from the window's trailing edge, as the Filters sidebar does from the
          // leading one.
          InspectorColumn { inspector(for: selection) }
            .transition(
              reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        }
      }
      .animation(columnAnimation, value: shell.areFiltersShown)
      .animation(columnAnimation, value: shell.isInspectorShown)
    }
    .background { theme.surface.background.color.ignoresSafeArea() }
    // Under the first-run guide the bare title bar names nothing: the guide is what is on show.
    // The title names the window (the Window menu, Mission Control) but is not drawn in the
    // title bar, where the tabs already say which page is on show.
    .navigationTitle(shell.isWelcomeOpen ? "" : title.title)
    .navigationSubtitle(shell.isWelcomeOpen ? "" : title.subtitle ?? "")
    .toolbar { PanelToolbarContent(controller: controller) }
    .toolbar(removing: .title)
  }

  @ViewBuilder
  private func page(for selection: SidebarSelection) -> some View {
    switch selection {
    case .settings: SettingsDetail()
    case .workshop: WorkshopBrowserPage()
    case .pixiv: PixivBrowserPage()
    case .wallpaper: InstalledPage()
    }
  }

  @ViewBuilder
  private func inspector(for selection: SidebarSelection) -> some View {
    switch selection {
    case .settings: EmptyView()
    case .workshop: WorkshopInspector()
    case .pixiv: PixivInspector()
    case .wallpaper: InstalledInspector()
    }
  }
}

/// The page, and the inspector beside it, inside one full-width scroll view that never scrolls.
///
/// macOS 26 draws a band under the see-through title bar for each column of a window, and draws it
/// differently by what the column holds: an opaque grey over a column whose top is not a scroll
/// view, a light wash over one that is, and its own dark band over the system inspector column.
/// The system inspector (`.inspector`) made the window two columns and the bar two shades. One
/// scroll view spanning the window makes it one column, whose band is the page's colour under the
/// same light wash from the traffic lights to the window's edge. Nothing scrolls here: the pages
/// scroll their own grids.
private struct PageScrollHost<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    // The host offers its content the size it was given and asks for none of its own, as the pages
    // do: a minimum here would make the window's content wider than the smallest window.
    GeometryReader { proxy in
      ScrollView(.vertical) {
        content.frame(width: proxy.size.width, height: proxy.size.height)
      }
      .scrollDisabled(true)
      .scrollIndicators(.never)
      .scrollBounceBehavior(.basedOnSize)
    }
  }
}
