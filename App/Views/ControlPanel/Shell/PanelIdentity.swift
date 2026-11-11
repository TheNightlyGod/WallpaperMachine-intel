import SwiftUI

/// The app's name at the leading end of the title bar, beside the traffic lights, as the web panel
/// had it: the mark, "WallpaperMachine" and the version. In a narrow window
/// (`ShellModel.isCompact`) only the mark stays, so the tabs and the tools keep their room; the name
/// and version then are its tooltip. It is text, never a control.
struct PanelIdentity: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  /// The version the bundle carries (`CFBundleShortVersionString`), empty when it has none.
  static let version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

  var body: some View {
    let isCompact = controller.shell.isCompact
    HStack(spacing: 7) {
      AppMark(size: 20, season: theme.season)
        .foregroundStyle(theme.surface.text.color)
        // A season's piece of the mark is a graphic, not text: the accent fitted for graphics.
        .tint(theme.accent.focus.color)
      if !isCompact {
        // A proper noun: never translated.
        Text(verbatim: "WallpaperMachine")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(theme.surface.text.color)
        if !Self.version.isEmpty {
          Text(verbatim: Self.version)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(theme.surface.muted.color)
        }
      }
    }
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, 4)
    .help(isCompact ? Self.label : "")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: Self.label))
    .accessibilityIdentifier("panel-identity")
  }

  /// "WallpaperMachine 1.2.3".
  static var label: String {
    version.isEmpty ? "WallpaperMachine" : "WallpaperMachine \(version)"
  }
}
