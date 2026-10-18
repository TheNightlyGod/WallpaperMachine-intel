import AppKit
import Foundation

/// The sheets and pickers an action may put in front of the user.
///
/// Every one attaches to the panel's window (on top of the sheet it shows, such as the download
/// dialog) and answers "no" when there is none (the panel is hidden, closed or under test), so an
/// action that needs a confirmation or a file never proceeds on its own. That refusal is silent on
/// purpose: nothing is shown and nothing throws.
/// Tests replace the whole protocol and answer for the user.
@MainActor
protocol PanelDialogs: AnyObject {
  /// The window sheets attach to; nil when the panel has none. An import picker, which chooses
  /// its own presentation, asks for it.
  var presentingWindow: NSWindow? { get }

  /// An alert sheet with `button` first and Cancel second. True only when `button` was chosen.
  func confirm(_ title: String, detail: String, button: String) async -> Bool

  /// Runs `panel` (an open or save panel the caller configured) as a sheet and answers the URL
  /// it chose, or nil for Cancel or without a window. An open panel that allows several answers
  /// its first; use `chooseMany` to get them all.
  func choose(_ panel: NSSavePanel) async -> URL?

  /// Runs an open panel as a sheet and answers every URL chosen; empty for Cancel or without a
  /// window.
  func chooseMany(_ panel: NSOpenPanel) async -> [URL]
}

/// The AppKit implementation: an `NSAlert` or panel as a sheet of the panel's window, or of the
/// sheet the window is showing (see `sheetParent(for:)`).
@MainActor
final class AppKitPanelDialogs: PanelDialogs {
  private let windowProvider: @MainActor () -> NSWindow?

  /// `window` is asked each time, so a window that arrives after the dialogs do is still used.
  init(window: @escaping @MainActor () -> NSWindow?) { windowProvider = window }

  var presentingWindow: NSWindow? { windowProvider() }

  /// The window the next alert or panel attaches to; nil without a panel window.
  var sheetParent: NSWindow? { presentingWindow.map(Self.sheetParent(for:)) }

  /// Where a new alert or panel goes when `window` is the panel's window: on top of the sheet the
  /// panel is showing, if any, else on the window itself.
  ///
  /// AppKit holds a second sheet of a window back until the first one ends. The download dialog is
  /// a SwiftUI sheet of the panel's window, and its Locate a copy, Allow this SteamCMD, Reinstall
  /// SteamCMD?, Discard downloaded SteamCMD? and Use an existing installation ask from inside it:
  /// attached to the window they would wait, unseen, until the dialog closed, and the command queue
  /// with them. On the dialog's own window they come up at once, as they did over the web panel's
  /// in-page dialog. An alert or a file panel already up (an `NSPanel`, which a SwiftUI sheet's
  /// window is not) is never a parent: the new one waits behind it, as AppKit queues it.
  static func sheetParent(for window: NSWindow) -> NSWindow {
    var parent = window
    while let sheet = parent.attachedSheet, !(sheet is NSPanel) { parent = sheet }
    return parent
  }

  func confirm(_ title: String, detail: String, button: String) async -> Bool {
    guard let window = sheetParent else { return false }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: String(localized: "Cancel"))
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) {
        continuation.resume(returning: $0 == .alertFirstButtonReturn)
      }
    }
  }

  func choose(_ panel: NSSavePanel) async -> URL? {
    guard await run(panel) else { return nil }
    return panel.url
  }

  func chooseMany(_ panel: NSOpenPanel) async -> [URL] {
    guard await run(panel) else { return [] }
    return panel.urls
  }

  private func run(_ panel: NSSavePanel) async -> Bool {
    guard let window = sheetParent else { return false }
    return await withCheckedContinuation { continuation in
      panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK) }
    }
  }
}
