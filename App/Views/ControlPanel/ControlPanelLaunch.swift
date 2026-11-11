import Foundation

/// Decides whether the control panel opens when the app starts.
///
/// Started as a login item, the app keeps to the menu bar: wallpapers play without the panel,
/// and the status item or reopening the app brings it back. The panel still opens when the
/// user has something to finish or fix: the welcome guide they have not completed, or a
/// renderer that failed to start.
enum ControlPanelLaunch {
    /// `WALLPAPER_MACHINE_PANEL_AT_LAUNCH=0` keeps the panel closed at any launch, the way a
    /// login launch does, so a power measurement sees the wallpaper alone
    /// (docs/testing/power-benchmark.md). It changes nothing the panel would open for: an
    /// unfinished welcome guide or a failed start still opens it.
    static let panelAtLaunchKey = "WALLPAPER_MACHINE_PANEL_AT_LAUNCH"

    /// `launchEvent` is the Apple event the app is launching under; read it synchronously in
    /// `applicationDidFinishLaunching`, since it is only current while that event is handled.
    /// `environment` is the process environment, read once at that launch.
    static func opensPanel(
        launchEvent: NSAppleEventDescriptor?, welcomeSeen: Bool, startupFailed: Bool,
        environment: [String: String] = [:]
    ) -> Bool {
        let staysInMenuBar = isLoginItemLaunch(launchEvent) || environment[panelAtLaunchKey] == "0"
        return !staysInMenuBar || !welcomeSeen || startupFailed
    }

    /// `SMAppService` cannot pass launch arguments, so the only sign of a login launch is the
    /// property the system attaches to the open-application event.
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
