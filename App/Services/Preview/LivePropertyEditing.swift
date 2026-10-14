import Foundation

/// Whether the displays follow a wallpaper's pending property edits while they are made, before
/// Apply changes. The preview window always follows them; this switch is only about the desktop.
///
/// It is off until the user turns it on, because showing an edit on the desktop leans on the
/// renderer's in-place property update, which a fresh load can differ from for the few things a
/// scene reads only while it loads, and which the lock screen, the screen saver and the Mission
/// Control picture do not follow. The choice is this Mac's: it is not part of a backup.
enum LivePropertyEditing {
    static let defaultsKey = "WallpaperMachine.livePropertyEdits"
    /// Posted after the preference is written.
    static let didChange = Notification.Name("WallpaperMachine.LivePropertyEditing.didChange")

    /// What applies until the user chooses. Changing it here is the one-line change that makes
    /// the desktop follow edits for everyone who has not chosen.
    static let buildDefault = false

    /// The stored choice, or the build default when none was made. An explicit value always wins,
    /// in either direction.
    static func isEnabled(defaults: UserDefaults = ClientPreferences.defaults) -> Bool {
        (defaults.object(forKey: defaultsKey) as? Bool) ?? buildDefault
    }

    static func setEnabled(
        _ enabled: Bool, defaults: UserDefaults = ClientPreferences.defaults,
        center: NotificationCenter = .default
    ) {
        let changed = isEnabled(defaults: defaults) != enabled
        defaults.set(enabled, forKey: defaultsKey)
        if changed { AppLog.info("live property edits on the desktop \(enabled ? "enabled" : "disabled")") }
        center.post(name: didChange, object: nil)
    }
}
