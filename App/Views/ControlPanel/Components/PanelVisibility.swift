import SwiftUI

extension EnvironmentValues {
  /// Whether the panel's window is on screen: visible, not minimized and not covered. The root sets
  /// it from `PanelPresentation`. Anything that animates on its own reads it, so a hidden or
  /// minimized panel runs no animation at all.
  @Entry var panelIsVisible = true
}
