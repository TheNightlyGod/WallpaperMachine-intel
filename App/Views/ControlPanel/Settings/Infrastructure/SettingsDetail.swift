import SwiftUI

/// The Settings page: the list of sections along its leading edge, and beside it the page of the
/// section chosen there, or, while a search is typed in the page's search bar, every section that
/// has a match, one under another with only the matching rows.
///
/// The page offers its parts the width it was given and asks for none of its own, as Installed and
/// Steam Workshop do. The detail column carries the inspector on every page (closed here), which
/// asks for 260 points; a page that also asked for width made the window's content wider than the
/// 760-point window, clipping the cards, and at some heights AppKit looped over the window's
/// constraints and threw. A GeometryReader has no minimum of its own. The pages still have to fit
/// what the list leaves of the narrowest window, which `SettingsSectionsRenderTests` measures on
/// `SettingsPages`.
struct SettingsDetail: View {
  @Environment(\.panelTheme) private var theme

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 0) {
        SettingsSectionList()
        Rectangle().fill(theme.surface.line.color).frame(width: 0.5)
        SettingsPages().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }
}

/// The scrolling pages of the Settings detail column.
struct SettingsPages: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    let search = settings.search
    ScrollView {
      VStack(alignment: .leading, spacing: 30) {
        if search.hasNoResults {
          PanelEmptyState(
            verbatim: L("No settings match “\(search.query)”."), systemImage: "magnifyingglass"
          )
          .frame(maxWidth: .infinity, minHeight: 240)
        } else if search.isActive {
          ForEach(search.sections, id: \.self) { section in
            page(of: section)
          }
        } else {
          page(of: settings.selectedSection)
        }
      }
      .frame(maxWidth: 620, alignment: .leading)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 28)
      .padding(.vertical, 24)
    }
    // A new section, a reveal and a change of the query each start the page at its top.
    .id(
      PageIdentity(
        section: settings.selectedSection, epoch: settings.scrollEpoch, query: search.query)
    )
    // Not under the title bar, which keeps the page's colour across the window.
    .background(theme.surface.surface.color, ignoresSafeAreaEdges: [])
  }

  private struct PageIdentity: Hashable {
    let section: SettingsSection
    let epoch: Int
    let query: String
  }

  /// The one place that names every section's view.
  @ViewBuilder
  private func page(of section: SettingsSection) -> some View {
    switch section {
    case .quick: QuickSettingsSection()
    case .general: GeneralSettingsSection()
    case .appearance: AppearanceSettingsSection()
    case .desktop: DesktopSettingsSection()
    case .playback: PlaybackSettingsSection()
    case .performance: PerformanceSettingsSection()
    case .displays: DisplaysSettingsSection()
    case .shortcuts: ShortcutsSettingsSection()
    case .library: LibrarySettingsSection()
    case .storage: StorageSettingsSection()
    case .about: AboutSettingsSection()
    }
  }
}
