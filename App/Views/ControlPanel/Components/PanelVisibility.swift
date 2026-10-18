import SwiftUI

private struct PanelIsVisibleKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  /// Whether the panel's window is on screen: visible, not minimized and not covered. The root sets
  /// it from `PanelPresentation`. Anything that animates on its own reads it, so a hidden or
  /// minimized panel runs no animation at all.
  var panelIsVisible: Bool {
    get { self[PanelIsVisibleKey.self] }
    set { self[PanelIsVisibleKey.self] = newValue }
  }
}

