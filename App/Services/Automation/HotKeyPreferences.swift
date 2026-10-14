import Foundation

/// What a global keyboard shortcut does.
enum HotKeyAction: String, CaseIterable, Sendable {
    case togglePlayback, toggleMute, previousWallpaper, nextWallpaper, randomWallpaper, openControlPanel

    var command: AutomationCommand {
        switch self {
        case .togglePlayback: .togglePlayback
        case .toggleMute: .toggleMute
        case .nextWallpaper: .next(display: nil)
        case .previousWallpaper: .previous(display: nil)
        case .randomWallpaper: .random(display: nil, pool: .all)
        case .openControlPanel: .open(page: nil)
        }
    }

    /// The id the system hands back when the shortcut is pressed; stable, never zero.
    var identifier: UInt32 {
        switch self {
        case .togglePlayback: 1
        case .nextWallpaper: 2
        case .openControlPanel: 3
        case .previousWallpaper: 4
        case .randomWallpaper: 5
        case .toggleMute: 6
        }
    }

    var title: String {
        switch self {
        case .togglePlayback: String(localized: "Play or pause wallpapers")
        case .toggleMute: String(localized: "Mute or unmute wallpapers")
        case .nextWallpaper: String(localized: "Next wallpaper")
        case .previousWallpaper: String(localized: "Previous wallpaper")
        case .randomWallpaper: String(localized: "Random wallpaper")
        case .openControlPanel: String(localized: "Open the control panel")
        }
    }
}

/// A key and its modifiers as the system registers them: a Carbon virtual key code, which
/// names a key's position rather than its letter, and Carbon's modifier bits.
struct HotKey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// How the panel shows it, such as ⌃⌥⌘P.
    var label: String
}

/// The user's global keyboard shortcuts, saved in UserDefaults. None is set until the user
/// records one, so the app never takes a key combination another app expects. Changes post
/// `didChangeNotification`; `GlobalHotKeys` registers them and records here any the system
/// refused.
@MainActor
final class HotKeyPreferences {
    static let shared = HotKeyPreferences()
    static let didChangeNotification = Notification.Name("WallpaperMachine.hotKeysDidChange")
    private static let key = "WallpaperMachine.hotKeys"

    private let defaults: UserDefaults
    private(set) var bindings: [HotKeyAction: HotKey]
    /// Why the system refused a shortcut, by action. Not saved: registering again at the next
    /// launch may succeed.
    private(set) var failures: [HotKeyAction: String] = [:]

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: HotKey].self, from: $0) } ?? [:]
        var bindings: [HotKeyAction: HotKey] = [:]
        for (name, hotKey) in stored {
            if let action = HotKeyAction(rawValue: name) { bindings[action] = hotKey }
        }
        self.bindings = bindings
    }

    /// Sets or, with nil, clears the shortcut for `action`. A combination another action
    /// already uses is refused rather than silently moved.
    func set(_ hotKey: HotKey?, for action: HotKeyAction) throws {
        if let hotKey, let other = bindings.first(where: {
            $0.key != action && $0.value.keyCode == hotKey.keyCode && $0.value.modifiers == hotKey.modifiers
        })?.key {
            throw AutomationError(message: String(localized: "That shortcut is already used for “\(other.title)”."))
        }
        guard bindings[action] != hotKey else { return }
        bindings[action] = hotKey
        failures[action] = nil
        let stored = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Records whether the system accepted `action`'s shortcut; nil means it did.
    func recordFailure(_ message: String?, for action: HotKeyAction) {
        guard failures[action] != message else { return }
        failures[action] = message
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
