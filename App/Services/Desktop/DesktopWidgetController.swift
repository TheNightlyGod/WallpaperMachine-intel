import AppKit
import Foundation

/// Puts the desktop widgets on the displays and keeps their words current.
///
/// One window per widget and display, sized to what it shows. Without widgets it keeps no window and
/// no timer and only listens for the store's change. With widgets it redraws when what they show
/// changes (each second for a clock with seconds, each minute for another clock, at a greeting's
/// hour, at sunrise and sunset, at midnight for dates, countdowns and the month), and only while one
/// of its windows can be seen: covered by other windows, on a sleeping display or behind the lock
/// screen it schedules nothing, and the window's occlusion change brings it back. Text never needs
/// a timer, and a battery widget listens to the battery's own notification, which it keeps only
/// while one is placed. A change of the clock, the time zone, the region format, the day, the
/// sunrise and sunset location or a wake redraws at once; a screen change moves the windows and
/// touches only the ones whose frame changed.
@MainActor
final class DesktopWidgetController {
    /// A display as the widgets see it.
    struct Screen: Equatable, Sendable {
        var displayID: UInt32
        /// Core Graphics' UUID for the display, stable across reboots; nil when it has none.
        var uuid: String?
        var name: String
        var frame: NSRect
        /// Whether it is the display with the menu bar.
        var isMain: Bool
    }

    /// The time, the calendar and the language the words are written in.
    struct Clock {
        var now: () -> Date
        var calendar: () -> Calendar
        var locale: () -> Locale

        static let system = Clock(
            now: Date.init, calendar: { Calendar.autoupdatingCurrent }, locale: { Locale.autoupdatingCurrent })
    }

    /// A widget on a display, as last drawn.
    struct Shown: Equatable {
        var widgetID: String
        var displayID: UInt32
        var frame: NSRect
        var text: String
    }

    private struct Key: Hashable {
        var widgetID: String
        var displayID: UInt32
    }

    private let defaults: UserDefaults
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let screens: @MainActor () -> [Screen]
    private let makeSurface: @MainActor () -> any DesktopWidgetSurface
    private let clock: Clock
    private let schedule: @MainActor (Date, @escaping @MainActor () -> Void) -> () -> Void
    private let makeBattery: @MainActor () -> any BatteryLevelSource
    private let formatters = DesktopWidgetRendering.Formatters()

    private var widgets: [DesktopWidget] = []
    private var surfaces: [Key: any DesktopWidgetSurface] = [:]
    private var drawn: [Key: Shown] = [:]
    private var cancelTimer: (() -> Void)?
    private(set) var nextChange: Date?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The battery's notification, kept only while a battery widget is placed.
    private var battery: (any BatteryLevelSource)?
    private var batteryReading: BatteryReading?
    private var solar: WallpaperSolarSettings?

    /// `makeSurface` makes and shows a widget's window, `schedule` runs its action once at a date
    /// and returns what cancels it, and `makeBattery` makes the battery's source; tests pass ones
    /// that keep everything off screen and the clock and the battery in their hands.
    init(
        defaults: UserDefaults = ClientPreferences.defaults, center: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        screens: @escaping @MainActor () -> [Screen] = DesktopWidgetController.systemScreens,
        makeSurface: @escaping @MainActor () -> any DesktopWidgetSurface = DesktopWidgetWindow.present,
        clock: Clock = .system,
        schedule: @escaping @MainActor (Date, @escaping @MainActor () -> Void) -> () -> Void =
            DesktopWidgetController.scheduleTimer,
        makeBattery: @escaping @MainActor () -> any BatteryLevelSource = { SystemBatteryLevel() }
    ) {
        self.defaults = defaults
        self.center = center
        self.workspaceCenter = workspaceCenter
        self.screens = screens
        self.makeSurface = makeSurface
        self.clock = clock
        self.schedule = schedule
        self.makeBattery = makeBattery
    }

    /// What each widget window shows now, by widget then display.
    var shown: [Shown] {
        drawn.values.sorted { ($0.widgetID, $0.displayID) < ($1.widgetID, $1.displayID) }
    }

    // MARK: Running

    func start() {
        guard observers.isEmpty else { return }
        observe(center, DesktopWidgetStore.didChangeNotification) { $0.reload() }
        // An XDR display posts a screen change for every frame of an EDR headroom ramp; a change that
        // moves no widget touches no window.
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.place() }
        for name in [
            Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
            NSLocale.currentLocaleDidChangeNotification,
        ] {
            observe(center, name) { $0.render() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(workspaceCenter, name) { controller in
                controller.batteryReading = controller.battery?.reading
                controller.render()
            }
        }
        observe(center, WallpaperAutomationStore.didChangeNotification) { controller in
            controller.solar = Self.savedSolar(in: controller.defaults)
            controller.render()
        }
        observe(center, NSWindow.didChangeOcclusionStateNotification) { controller, notification in
            guard let window = notification.object as AnyObject?,
                  controller.surfaces.values.contains(where: { $0 === window }) else { return }
            controller.render()
        }
        reload()
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        cancelTimer?()
        cancelTimer = nil
        nextChange = nil
        battery?.stop()
        battery = nil
        batteryReading = nil
        for surface in surfaces.values { surface.remove() }
        surfaces.removeAll()
        drawn.removeAll()
    }

    /// The words are due to change: draws them, which schedules the next change.
    func tick() {
        cancelTimer = nil
        render()
    }

    // MARK: Drawing

    private func reload() {
        widgets = DesktopWidgetStore.load(from: defaults).filter(\.isShown)
        solar = Self.savedSolar(in: defaults)
        place()
    }

    /// Makes a window for each widget on each display it belongs on, removes the rest, and draws.
    private func place() {
        let screens = screens()
        var wanted = Set<Key>()
        for widget in widgets {
            for screen in screens where widget.isPlaced(onDisplayUUID: screen.uuid, isMain: screen.isMain) {
                wanted.insert(Key(widgetID: widget.id, displayID: screen.displayID))
            }
        }
        for (key, surface) in surfaces where !wanted.contains(key) {
            surface.remove()
            surfaces[key] = nil
            drawn[key] = nil
        }
        for key in wanted where surfaces[key] == nil {
            surfaces[key] = makeSurface()
        }
        let placed = Set(wanted.map(\.widgetID))
        observeBattery(widgets.contains { $0.kind == .battery && placed.contains($0.id) })
        render(screens: screens)
    }

    private func render() { render(screens: screens()) }

    private func render(screens: [Screen]) {
        let inputs = DesktopWidgetRendering.Inputs(
            date: clock.now(), calendar: clock.calendar(), locale: clock.locale(), battery: batteryReading,
            solar: solar)
        let frames = Dictionary(screens.map { ($0.displayID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        for widget in widgets {
            let content = DesktopWidgetRendering.content(for: widget, inputs: inputs, formatters: formatters)
            for (key, surface) in surfaces where key.widgetID == widget.id {
                guard let display = frames[key.displayID] else { continue }
                let frame = DesktopWidgetRendering.frame(
                    textSize: content.size, padding: content.padding, widget: widget, display: display)
                let shown = Shown(widgetID: widget.id, displayID: key.displayID, frame: frame, text: content.text)
                surface.show(content.drawing, padding: content.padding, frame: frame)
                drawn[key] = shown
            }
        }
        scheduleNextChange(after: inputs)
    }

    /// Schedules the next redraw, or none while no widget window can be seen.
    private func scheduleNextChange(after inputs: DesktopWidgetRendering.Inputs) {
        cancelTimer?()
        cancelTimer = nil
        nextChange = nil
        guard surfaces.values.contains(where: \.isOnScreen) else { return }
        let placed = Set(surfaces.keys.map(\.widgetID))
        guard let next = DesktopWidgetRendering.nextChange(
            after: inputs, widgets: widgets.filter { placed.contains($0.id) }) else { return }
        nextChange = next
        cancelTimer = schedule(next) { [weak self] in self?.tick() }
    }

    /// Starts listening to the battery when a battery widget is placed, and stops when none is.
    private func observeBattery(_ wanted: Bool) {
        if wanted, battery == nil {
            let source = makeBattery()
            battery = source
            batteryReading = source.reading
            source.start { [weak self, weak source] in
                guard let self, let source else { return }
                batteryReading = source.reading
                render()
            }
        } else if !wanted, let source = battery {
            source.stop()
            battery = nil
            batteryReading = nil
        }
    }

    /// The sunrise and sunset settings the automatic wallpapers saved, read as their store reads
    /// them; nil when none are saved or they cannot be read.
    nonisolated static func savedSolar(in defaults: UserDefaults) -> WallpaperSolarSettings? {
        if let data = defaults.data(forKey: WallpaperAutomationStore.solarKey),
           let settings = try? JSONDecoder().decode(WallpaperSolarSettings.self, from: data), settings.isValid {
            return settings
        }
        guard let data = defaults.data(forKey: WallpaperAutomationStore.locationKey),
              let location = try? JSONDecoder().decode(WallpaperSolarLocation.self, from: data),
              location.isValid else { return nil }
        return WallpaperSolarSettings(source: .coordinates, location: location)
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ action: @escaping @MainActor (DesktopWidgetController, Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self, notification)
            }
        }
        observers.append((center, token))
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ action: @escaping @MainActor (DesktopWidgetController) -> Void
    ) {
        observe(center, name) { controller, _ in action(controller) }
    }

    // MARK: The system

    /// The connected displays as AppKit reports them now.
    static func systemScreens() -> [Screen] {
        let main = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let displayID = SystemDisplays.id(of: screen) else { return nil }
            return Screen(
                displayID: displayID, uuid: displayUUID(displayID), name: screen.localizedName,
                frame: screen.frame, isMain: displayID == main)
        }
    }

    nonisolated static func displayUUID(_ displayID: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// A one-shot timer on the main run loop, a few milliseconds after `date` so the words read
    /// the new second or minute.
    static func scheduleTimer(at date: Date, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(fire: date.addingTimeInterval(0.005), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
