import AppKit

/// Finds the search field a page puts in the window and gives it the keyboard, which is what
/// Command-F does.
///
/// Every page's field is the search bar at the top of the page (`PageSearchBar`), an
/// `NSSearchField` in the window's content, found here instead of through a focus binding each
/// page would have to share.
@MainActor
enum PanelSearchFocus {
  /// The first visible search field in the window's content.
  static func field(in window: NSWindow) -> NSSearchField? {
    window.contentView.flatMap(firstField)
  }

  /// Starts a search in the window. True when a field took the keyboard.
  @discardableResult
  static func focus(in window: NSWindow) -> Bool {
    guard let field = field(in: window) else { return false }
    return window.makeFirstResponder(field)
  }

  private static func firstField(in view: NSView) -> NSSearchField? {
    if view.isHidden { return nil }
    if let field = view as? NSSearchField { return field }
    for subview in view.subviews {
      if let found = firstField(in: subview) { return found }
    }
    return nil
  }
}
