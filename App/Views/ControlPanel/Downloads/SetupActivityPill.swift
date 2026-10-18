import SwiftUI

/// The toolbar pill that says SteamCMD is being set up, on every page, while the setup runs. It is a
/// status, not a button: the dialog that started the setup can be closed and the work goes on.
struct SetupActivityPill: View {
  /// Whether the toolbar shows the pill: SteamCMD is being downloaded, unpacked, validated or
  /// saved. The first look at what is installed ("Checking SteamCMD…", which every panel opening
  /// and every setup step begins with) is not setting anything up, so it shows no pill: the pill
  /// would otherwise flash at every opening of the window.
  static func isActive(in controller: PanelController) -> Bool {
    let setup = controller.workshop.steamCMDSetup
    return shows(state: setup.state, isBusy: setup.isBusy)
  }

  static func shows(state: SteamCMDSetupState, isBusy: Bool) -> Bool {
    isBusy && state != .checking
  }

  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(spacing: 6) {
      // Spins only while the window is on screen and Reduce Motion is off.
      ProgressRing(value: nil, lineWidth: 1.8)
        .frame(width: 14, height: 14)
      Text("Setting up SteamCMD…")
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
    }
    .padding(.horizontal, 6)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityIdentifier("setup-activity")
  }
}
