import Combine
import SwiftUI

// Native menu commands share navigation with the bundled WebKit interface.
enum SidebarSelection: String {
  case wallpaper, workshop, pixiv, display, settings
}

enum SettingsSection: String, CaseIterable {
  case performance, general, appearance, displays, library, storage, about
}

@MainActor
final class ControlPanelNavigation: ObservableObject {
  @Published var selection: SidebarSelection?
  @Published var targetDisplayID = "primary"
  @Published private(set) var settingsSection = SettingsSection.performance
  @Published private(set) var settingsSectionToken: UInt64 = 0
  /// Installed's filters and the library scroll offsets the last page reported, handed to
  /// the next page when the window is reopened. Memory only, and not `@Published`: the page
  /// reports while the person scrolls, and nothing in SwiftUI reads it.
  var viewState: PanelViewState?

  init(selection: SidebarSelection? = .wallpaper) { self.selection = selection }

  func revealSettingsSection(_ section: SettingsSection) {
    settingsSection = section
    settingsSectionToken &+= 1
  }
}

struct ControlPanelView: View {
  let store: BridgeStore
  @ObservedObject var navigation: ControlPanelNavigation
  let workshop: WorkshopStore
  let pixiv: PixivStore
  let updater: AppUpdateStore
  let imports: LibraryImportStore

  init(
    store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore,
    pixiv: PixivStore, updater: AppUpdateStore, imports: LibraryImportStore
  ) {
    self.store = store
    self.navigation = navigation
    self.workshop = workshop
    self.pixiv = pixiv
    self.updater = updater
    self.imports = imports
  }

  var body: some View {
    WebControlPanel(
      store: store, navigation: navigation, workshop: workshop, pixiv: pixiv, updater: updater,
      imports: imports)
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      // The page owns the title-bar strip; the window only keeps the traffic lights there.
      .ignoresSafeArea()
  }
}
