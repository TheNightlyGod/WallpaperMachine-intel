import AppKit
import Combine
import SwiftUI

/// What the panel shows. The native menu commands, the status item and `wallpapermachine://open`
/// links write it through `ControlPanelNavigation`, and the tabs write it back.
enum SidebarSelection: String {
  case wallpaper, workshop, pixiv, settings
}

/// The Settings sections, in the order of Settings' section list.
enum SettingsSection: String, CaseIterable {
  case quick, general, appearance, desktop, playback, performance, displays, shortcuts, library,
    storage, about
}

/// What the panel remembers across a closed window: the section on show, the target display and
/// the Settings section the app asked to reveal. It belongs to `AppDelegate`, so reopening the
/// panel (a Dock click, the status item) resumes where it was.
@MainActor
final class ControlPanelNavigation: ObservableObject {
  @Published var selection: SidebarSelection?
  @Published var targetDisplayID = "primary"
  @Published private(set) var settingsSection = SettingsSection.quick
  @Published private(set) var settingsSectionToken: UInt64 = 0
  /// Installed's filters and the library scroll offsets the last window had, handed to the next
  /// window when the panel is reopened. Memory only, and not `@Published`: nothing in SwiftUI
  /// reads it, the window writes it as the person types and scrolls.
  var viewState: PanelViewState?
  /// The Settings reveal a panel last acted on, so a window opened afterwards starts on Quick
  /// Settings instead of repeating it. Not `@Published`: only `SettingsModel.adoptReveal` uses it.
  var handledSettingsRevealToken: UInt64 = 0

  init(selection: SidebarSelection? = .wallpaper) { self.selection = selection }

  func revealSettingsSection(_ section: SettingsSection) {
    settingsSection = section
    settingsSectionToken &+= 1
  }
}

/// The panel's root: creates the controller for the window's lifetime and shows the panel. The six
/// store arguments are what `AppDelegate` builds it with; `defaults` and `appLanguage` are the
/// seams a test passes so the panel never touches the installed app's preferences and can be
/// rendered in any language.
///
/// The window gives the controller its life: it starts when the view appears and stops when the
/// window closes. Everything the panel draws is `PanelRootView` and what it hosts.
struct ControlPanelView: View {
  @State private var controller: PanelController

  init(
    store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore,
    pixiv: PixivStore, updater: AppUpdateStore, imports: LibraryImportStore,
    defaults: UserDefaults = ClientPreferences.defaults, appLanguage: AppLanguageStore? = nil
  ) {
    let controller = PanelController(
      store: store, navigation: navigation, workshop: workshop, pixiv: pixiv, updater: updater,
      imports: imports, defaults: defaults, appLanguage: appLanguage, automations: .shared,
      solarLocationTracker: .shared,
      displayLayouts: .shared, spaces: .shared)
    // The panel's strings follow the language of the store the controller was built over.
    PanelLocale.shared.bind(to: controller.appLanguage)
    _controller = State(initialValue: controller)
  }

  var body: some View {
    PanelRootView()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .environment(controller)
      .environment(\.panelImages, controller.images)
      .background(WindowObserver { controller.presentation.attach(to: $0) })
      .onAppear { controller.start() }
      .onDisappear { controller.stop() }
  }
}

/// Reports the window its view is in, and nil when it leaves it.
private struct WindowObserver: NSViewRepresentable {
  let onWindow: @MainActor (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = ObservingView()
    view.onWindow = onWindow
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    (view as? ObservingView)?.onWindow = onWindow
  }

  private final class ObservingView: NSView {
    var onWindow: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let window = window
      // Reported on the next turn: SwiftUI is still building the view when the window arrives.
      Task { @MainActor [weak self] in self?.onWindow?(window) }
    }
  }
}
