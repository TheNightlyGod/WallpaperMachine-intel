import SwiftUI

extension SettingsSection {
  /// The name in the section list, as the title of the page and in the window title.
  var title: LocalizedStringResource {
    switch self {
    case .quick: "Quick Settings"
    case .general: "General"
    case .appearance: "Appearance"
    case .desktop: "Desktop & Lock Screen"
    case .playback: "Playback & Power"
    case .performance: "Performance"
    case .displays: "Displays"
    case .shortcuts: "Keyboard shortcuts"
    case .library: "Library & Steam"
    case .storage: "Storage"
    case .about: "About"
    }
  }

  /// The link that opens this page from a note on another one: "Open Performance", "Open Playback &
  /// Power".
  @MainActor var openTitle: String {
    self == .performance
      ? L("Open Performance") : L("Open \(PanelLocale.shared.string(resolving: title))")
  }

  /// The sentence under the title of the page.
  var summary: LocalizedStringResource {
    switch self {
    case .quick: "The switches people change most, in one place."
    case .general: "Language, startup and the welcome guide."
    case .appearance: "How this window looks. Your wallpapers are not affected."
    case .desktop: "How wallpapers meet the macOS desktop, lock screen and screen saver."
    case .playback: "When wallpapers pause, mute or stop on their own."
    case .performance: "Energy use, picture quality and the renderers behind them."
    case .displays: "Each display’s wallpaper, playlist and automatic changes."
    case .shortcuts: "Shortcuts that work in any app, the Shortcuts app and links."
    case .library: "Where wallpapers live, and the Steam tools that download them."
    case .storage: "Disk space, backups and troubleshooting."
    case .about: "Version, updates and credits."
    }
  }

  /// The SF Symbol on the section's tile.
  var systemImage: String {
    switch self {
    case .quick: "switch.2"
    case .general: "gearshape"
    case .appearance: "circle.lefthalf.filled"
    case .desktop: "photo.on.rectangle"
    case .playback: "play"
    case .performance: "gauge.with.dots.needle.67percent"
    case .displays: "display"
    case .shortcuts: "keyboard"
    case .library: "books.vertical"
    case .storage: "internaldrive"
    case .about: "info.circle"
    }
  }

  /// The colour of the section's tile, from System Settings' palette.
  var tileColor: Color {
    switch self {
    case .quick, .general, .shortcuts, .storage, .about: .gray
    case .appearance, .displays: .blue
    case .desktop: .teal
    case .playback: .green
    case .performance: .orange
    case .library: .indigo
    }
  }

  /// Whether the section list leaves a gap above this section: the list reads as five clusters, as in
  /// the web panel's.
  var startsCluster: Bool {
    switch self {
    case .general, .desktop, .library, .about: true
    default: false
    }
  }
}
