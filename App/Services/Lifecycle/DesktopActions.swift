import AppKit
import ServiceManagement

/// Every way the app reaches out to the person's desktop by itself: opening an address in their
/// browser (or a folder in Finder), selecting files in Finder, opening System Settings › Login
/// Items, hiding the app, and changing Finder's desktop icons, which restarts Finder.
///
/// `current` is the real thing in the app. The unit tests run inside the app, so the test bundle
/// replaces `current` with a recorder as soon as it loads (`Tests/Unit/Support/TestBundle.swift`):
/// a test that reached one of these would otherwise open a browser tab, a Finder window or System
/// Settings on the developer's Mac, or restart their Finder. Code that acts on the desktop takes
/// its default from here.
@MainActor
struct DesktopActions {
  var open: (URL) -> Bool
  var reveal: ([URL]) -> Void
  var openLoginItemsSettings: () -> Void
  var hideApplication: () -> Void
  /// Finder's stored `CreateDesktop` preference as macOS returns it; nil when it was never set.
  var finderDesktopPreference: () -> Any?
  /// Stores Finder's `CreateDesktop` preference; false when macOS did not accept it.
  var setFinderDesktopPreference: (Bool) -> Bool
  /// Ends a running Finder so it starts again and reads its preferences anew, and starts none that
  /// was not running; false when a running Finder could not be ended.
  var restartFinder: () -> Bool

  static let live = DesktopActions(
    open: { NSWorkspace.shared.open($0) },
    reveal: { NSWorkspace.shared.activateFileViewerSelecting($0) },
    openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() },
    hideApplication: { NSApp.hide(nil) },
    finderDesktopPreference: { FinderDesktopIcons.readSystemPreference() },
    setFinderDesktopPreference: { FinderDesktopIcons.writeSystemPreference(shown: $0) },
    restartFinder: { FinderDesktopIcons.restartSystemFinder() })

  /// The actions the app takes on the desktop; see the type's comment for why tests replace it.
  static var current = live
}
