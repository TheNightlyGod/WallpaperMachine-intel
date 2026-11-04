import AppKit
import Observation

/// The icons of the apps the App rules name, by bundle identifier, for their rows. Each is looked up
/// through Launch Services once and kept while the window lives; an app that is not installed is
/// looked up again the next time its row appears, so one installed meanwhile gets its icon.
@MainActor
@Observable
final class AppIconCache {
  private(set) var icons: [String: NSImage] = [:]
  /// Test seam: finds an app's icon, nil when no app has the identifier.
  @ObservationIgnored private let lookup: @MainActor (String) -> NSImage?

  init(lookup: (@MainActor (String) -> NSImage?)? = nil) {
    self.lookup = lookup ?? { bundleIdentifier in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map {
        NSWorkspace.shared.icon(forFile: $0.path)
      }
    }
  }

  /// The icon found for `bundleIdentifier`, nil until `load` found one.
  func icon(for bundleIdentifier: String) -> NSImage? { icons[bundleIdentifier] }

  /// Looks the app's icon up unless it is held already.
  func load(_ bundleIdentifier: String) {
    guard icons[bundleIdentifier] == nil, let icon = lookup(bundleIdentifier) else { return }
    icons[bundleIdentifier] = icon
  }
}
