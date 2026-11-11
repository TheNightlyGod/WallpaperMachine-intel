import Foundation

/// What a click on the menu bar icon opens: the panel with what is playing and a quick switcher,
/// or the menu. A right click or a Control-click opens the menu either way, so every menu command
/// stays one click away. Chosen in Settings › General; `didChangeNotification` tells the status
/// item to follow at once.
enum StatusItemClick: String, CaseIterable, Sendable {
    case panel
    case menu

    static let defaultsKey = "WallpaperMachine.statusItemClick"
    static let didChangeNotification = Notification.Name("WallpaperMachine.statusItemClickDidChange")

    /// The saved choice; the panel when none was made or the saved value is not one of these.
    static func current(in defaults: UserDefaults = ClientPreferences.defaults) -> StatusItemClick {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .panel
    }

    /// Saves `click`, the default as no value at all, and tells the status item.
    static func save(_ click: StatusItemClick, in defaults: UserDefaults, center: NotificationCenter = .default) {
        if click == .panel {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(click.rawValue, forKey: defaultsKey)
        }
        center.post(name: didChangeNotification, object: nil)
    }
}
