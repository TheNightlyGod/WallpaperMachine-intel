import Foundation
import Observation

/// The desktop widgets the person added, kept in the app's preferences. The panel changes them here;
/// `DesktopWidgetController` reads them again from the preferences whenever this store posts
/// `didChangeNotification`, so the desktop follows each change at once.
@MainActor
@Observable
final class DesktopWidgetStore {
    nonisolated static let storageKey = "WallpaperMachine.desktopWidgets"
    nonisolated static let didChangeNotification = Notification.Name("WallpaperMachine.desktopWidgetsChanged")
    nonisolated static let limit = 24

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let center: NotificationCenter
    private(set) var widgets: [DesktopWidget]

    init(defaults: UserDefaults = ClientPreferences.defaults, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
        widgets = Self.load(from: defaults)
    }

    func widget(_ id: String) throws -> DesktopWidget {
        guard let widget = widgets.first(where: { $0.id == id }) else { throw DesktopWidgetError.missing }
        return widget
    }

    /// Adds a widget of `kind` on the main display, below the widgets already there so it does not
    /// cover them.
    @discardableResult
    func add(_ kind: DesktopWidget.Kind) throws -> DesktopWidget {
        guard widgets.count < Self.limit else { throw DesktopWidgetError.tooMany }
        var widget = DesktopWidget(kind: kind)
        let taken = widgets.filter { $0.placement == .main }.map(\.y)
        while taken.contains(where: { abs($0 - widget.y) < 0.05 }), widget.y < 0.9 {
            widget.y += 0.1
        }
        try commit(widgets + [widget])
        return widget
    }

    func update(_ id: String, _ change: (inout DesktopWidget) -> Void) throws {
        var widget = try widget(id)
        change(&widget)
        widget.id = id
        let changed = widget.clamped()
        try commit(widgets.map { $0.id == id ? changed : $0 })
    }

    func remove(_ id: String) throws {
        _ = try widget(id)
        try commit(widgets.filter { $0.id != id })
    }

    // MARK: Storage

    /// The saved widgets; none when nothing is saved or what is saved cannot be read, which the log
    /// records.
    nonisolated static func load(from defaults: UserDefaults) -> [DesktopWidget] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        do {
            return try decode(data)
        } catch {
            AppLog.warn("desktop widgets: the saved widgets cannot be read: \(error.localizedDescription)")
            return []
        }
    }

    /// The widgets in `data`, refused unless every one is valid and the ids are unique.
    nonisolated static func decode(_ data: Data) throws -> [DesktopWidget] {
        guard data.count <= 256 * 1024 else { throw DesktopWidgetError.invalid }
        let widgets = try JSONDecoder().decode([DesktopWidget].self, from: data)
        guard widgets.count <= limit, Set(widgets.map(\.id)).count == widgets.count,
              widgets.allSatisfy(\.isValid) else { throw DesktopWidgetError.invalid }
        return widgets
    }

    private func commit(_ values: [DesktopWidget]) throws {
        let data = try JSONEncoder().encode(values)
        _ = try Self.decode(data)
        guard values != widgets else { return }
        defaults.set(data, forKey: Self.storageKey)
        widgets = values
        center.post(name: Self.didChangeNotification, object: nil)
    }
}

enum DesktopWidgetError: LocalizedError, Equatable {
    case missing, tooMany, invalid

    var errorDescription: String? {
        switch self {
        case .missing: String(localized: "This widget no longer exists.")
        case .tooMany: String(localized: "You can add up to 24 widgets. Remove one to add another.")
        case .invalid: String(localized: "The desktop widgets could not be saved because a value is out of range.")
        }
    }
}
