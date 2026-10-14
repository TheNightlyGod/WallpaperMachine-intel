import Foundation

/// Whether the web wallpapers this app shows may be attached to Safari's Web
/// Inspector. Inspection hands the page's JavaScript context to anyone who can
/// open the Develop menu on this Mac, so a release build keeps it off until the
/// user turns it on in Settings. A debug build keeps it on, as it always has been.
///
/// Only desktop and preview pages follow this switch. The screen saver, the lock
/// screen extension and the control panel are never governed by it.
enum WebWallpaperInspection {
    static let defaultsKey = "WallpaperMachine.inspectWebWallpapers"
    /// Posted after the preference is written, so pages that are already running
    /// can follow it without being reloaded.
    static let didChange = Notification.Name("WallpaperMachine.WebWallpaperInspection.didChange")

    /// What applies until the user chooses: on while developing the app, off for
    /// everyone else.
    static var buildDefault: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// The stored choice, or the build default when none was made. An explicit
    /// value always wins, in either direction.
    static func isEnabled(defaults: UserDefaults = ClientPreferences.defaults) -> Bool {
        (defaults.object(forKey: defaultsKey) as? Bool) ?? buildDefault
    }

    static func setEnabled(
        _ enabled: Bool, defaults: UserDefaults = ClientPreferences.defaults,
        center: NotificationCenter = .default
    ) {
        let changed = isEnabled(defaults: defaults) != enabled
        defaults.set(enabled, forKey: defaultsKey)
        if changed { AppLog.info("web wallpaper inspection \(enabled ? "enabled" : "disabled")") }
        center.post(name: didChange, object: nil)
    }
}
