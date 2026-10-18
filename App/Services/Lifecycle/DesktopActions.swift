import AppKit
import ServiceManagement

/// Every way the app reaches out to the person's desktop by itself: opening an address in their
/// browser (or a folder in Finder), selecting files in Finder, opening System Settings › Login
/// Items, and hiding the app.
///
/// `current` is the real thing in the app. The unit tests run inside the app, so the test bundle
/// replaces `current` with a recorder as soon as it loads (`Tests/Unit/Support/TestBundle.swift`):
/// a test that reached one of these would otherwise open a browser tab, a Finder window or System
/// Settings on the developer's Mac. Code that acts on the desktop takes its default from here.
@MainActor
struct DesktopActions {
  var open: (URL) -> Bool
  var reveal: ([URL]) -> Void
  var openLoginItemsSettings: () -> Void
  var hideApplication: () -> Void

  static let live = DesktopActions(
    open: { NSWorkspace.shared.open($0) },
    reveal: { NSWorkspace.shared.activateFileViewerSelecting($0) },
    openLoginItemsSettings: { SMAppService.openSystemSettingsLoginItems() },
    hideApplication: { NSApp.hide(nil) })

  /// The actions the app takes on the desktop; see the type's comment for why tests replace it.
  static var current = live
}
