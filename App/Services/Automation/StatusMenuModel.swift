import Foundation

/// What the menu bar menu offers, decided without AppKit so the branching can be tested.
///
/// A Mac with one display (or one that can show its own wallpaper) keeps the flat menu:
/// Previous, Next, Random Wallpaper and Recently used act on that display. With two or more, each
/// display gets a submenu with its own commands, so any of them can be changed without opening the panel.
/// While Workshop downloads run, a line under Control Panel says how many and how far they are,
/// and opens Discover where the downloads list is. On a Mac with a battery, an On Battery submenu
/// after Mute Wallpapers holds the battery choice and Pause While Using Other Apps, whichever
/// layout.
/// `AppDelegate` gathers the `Input` and turns the entries into `NSMenuItem`s; the update,
/// error and Exit items stay there.
enum StatusMenuModel {
    /// What choosing an item does. Every per-display command names its display.
    enum Command: Equatable {
        case openControlPanel
        /// Opens Discover, where the downloads list is.
        case openDownloads
        case playPause
        /// Mutes every wallpaper, or lets them play their own sound again; see `AutomationCommand.toggleMute`.
        case toggleMute
        /// Settings › Playback & Power › On battery, through the engine as the panel sets it.
        case batteryMode(BridgeBatteryMode)
        /// Settings › Playback & Power › When another app is in front, set to this choice.
        case otherAppInFront(OtherAppInFrontAction)
        case previous(display: String)
        case next(display: String)
        /// A random wallpaper other than the one the display shows; see `AutomationCommand.random`.
        case random(display: String)
        case apply(wallpaper: String, display: String)
        case remove(display: String)
        case startAgain(wallpaper: String, display: String)
        case openInPanel(display: String)
        /// Hides Finder's desktop icons, or shows them again; see `FinderDesktopIcons`.
        case toggleDesktopIcons
        case lockScreen
    }

    enum Entry: Equatable {
        case command(Command, title: String, checked: Bool)
        case submenu(title: String, entries: [Entry])
        case separator
    }

    struct Recent: Equatable {
        var id: String
        var title: String
    }

    /// Workshop downloads that are moving or waiting their turn, for the one line the menu gives them.
    struct DownloadActivity: Equatable {
        var count: Int
        /// How much of the bytes all of them expect has arrived, or nil when any of them cannot say.
        var percent: Int?

        /// `jobs` are the downloads in progress (`WorkshopDownloadManager.inProgressTransfers`): not
        /// paused ones, finished or failed ones, nor the sign-in that downloads nothing. A job
        /// still waiting for a slot or signing in has no byte counts, and the percent is left
        /// out instead of guessed. The last percent is Steam's own success line to claim, so a
        /// job that is still in progress never reads as complete.
        static func make(_ jobs: [(received: Int64?, expected: Int64?)]) -> DownloadActivity? {
            guard !jobs.isEmpty else { return nil }
            var received = 0.0
            var expected = 0.0
            for job in jobs {
                guard let jobReceived = job.received, let jobExpected = job.expected, jobExpected > 0 else {
                    return DownloadActivity(count: jobs.count, percent: nil)
                }
                received += Double(max(jobReceived, 0))
                expected += Double(jobExpected)
            }
            let percent = Int((100 * received / expected).rounded())
            return DownloadActivity(count: jobs.count, percent: min(max(percent, 0), 99))
        }

        var title: String {
            if let percent { return String(localized: "Downloads: \(count) in progress, \(percent)%") }
            return String(localized: "Downloads: \(count) in progress")
        }
    }

    struct Display: Equatable {
        var id: String
        var title: String
        /// What the display shows of its own; nil when it is empty.
        var wallpaperID: String?
        var canPrevious: Bool
        var canNext: Bool
        /// Whether the library holds a wallpaper that can play, is not held back and is not the
        /// one this display shows.
        var canRandom: Bool = false
        /// Wallpapers used on this display, newest use first, that are still in the library.
        var recent: [Recent]
    }

    struct Input: Equatable {
        /// Whether the playback state is the renderer's own, rather than from before a failure.
        var playbackIsCurrent: Bool
        var hasActiveWallpapers: Bool
        var paused: Bool
        /// Whether the user has muted every wallpaper.
        var wallpapersMuted: Bool = false
        /// The Workshop downloads in progress; nil when there are none.
        var downloads: DownloadActivity? = nil
        /// The On Battery submenu (`Battery.offered`); nil leaves it out.
        var battery: Battery? = nil
        /// The displays a command can act on, in menu order (`orderedDisplays`); empty while
        /// the app starts or quits.
        var displays: [Display]
        var canLockScreen: Bool
        /// Whether Finder hides its desktop icons, read each time the menu is built; nil leaves the
        /// item out, as while the app quits.
        var desktopIconsHidden: Bool? = nil
    }

    /// What the On Battery submenu shows: the battery choice, and whether "When another app is in
    /// front" pauses on battery.
    struct Battery: Equatable {
        var mode: BridgeBatteryMode
        var otherAppInFront: OtherAppInFrontAction

        /// The submenu's state where it belongs: on a Mac with an internal battery, as Quick
        /// Settings offers its On battery module, or wherever one of its two choices is not the
        /// default, so a choice a restored backup brought can be undone. Nil otherwise.
        static func offered(
            hasBattery: Bool, mode: BridgeBatteryMode, otherAppInFront: OtherAppInFrontAction
        ) -> Battery? {
            guard hasBattery || mode != .keepRunning || otherAppInFront == .pauseOnBattery else { return nil }
            return Battery(mode: mode, otherAppInFront: otherAppInFront)
        }

        /// Ticked only for Pause on battery: a Mute or Pause chosen in Settings, which applies on
        /// every power source, reads as unticked here, and choosing the item replaces it.
        var pausesWhileUsingOtherApps: Bool { otherAppInFront == .pauseOnBattery }
    }

    /// A display the menu may list, before its order and title are settled.
    struct Candidate: Equatable {
        var id: String
        var title: String
        /// The CoreGraphics id, to find the screen it is on.
        var physicalID: UInt32?
        /// Where the screen's left edge is in the global desktop space.
        var minX: Double
    }

    /// How many recently used wallpapers a display's menu lists.
    static let recentLimit = 10

    static func entries(for input: Input) -> [Entry] {
        var entries: [Entry] = [.command(.openControlPanel, title: String(localized: "Control Panel"), checked: false)]
        if let downloads = input.downloads {
            entries.append(.command(.openDownloads, title: downloads.title, checked: false))
        }
        var actions: [Entry] = []
        if input.playbackIsCurrent, input.hasActiveWallpapers {
            let title = input.paused ? String(localized: "Play") : String(localized: "Pause")
            actions.append(.command(.playPause, title: title, checked: false))
        }
        // Ticked while muted, and offered then whatever is playing, so a mute can always be undone.
        if input.wallpapersMuted || (input.playbackIsCurrent && input.hasActiveWallpapers) {
            actions.append(.command(.toggleMute, title: String(localized: "Mute Wallpapers"), checked: input.wallpapersMuted))
        }
        // Choices for the whole Mac, offered whatever is playing, like the settings they are.
        if let battery = input.battery {
            actions.append(.submenu(title: String(localized: "On Battery"), entries: batteryEntries(battery)))
        }
        if input.displays.count > 1 {
            actions += input.displays.map { .submenu(title: $0.title, entries: submenu(for: $0)) }
        } else if let display = input.displays.first {
            actions += navigation(for: display)
        }
        // Ticked while the icons are hidden, as Mute Wallpapers is while muted.
        if let hidden = input.desktopIconsHidden {
            actions.append(.command(.toggleDesktopIcons, title: String(localized: "Hide Desktop Icons"), checked: hidden))
        }
        if input.canLockScreen {
            actions.append(.command(.lockScreen, title: String(localized: "Lock Screen"), checked: false))
        }
        if !actions.isEmpty {
            entries.append(.separator)
            entries += actions
        }
        return entries
    }

    /// The same commands for the Wallpaper menu in the app's menu bar, shown while the panel is
    /// in front: everything but the lines that open the panel, which is already open, in a
    /// display's submenu too.
    static func wallpaperMenuEntries(for input: Input) -> [Entry] {
        withoutPanelCommands(entries(for: input))
    }

    /// `entries` without the commands that open the panel, with no separator left at either end
    /// or doubled, and no submenu left empty.
    private static func withoutPanelCommands(_ entries: [Entry]) -> [Entry] {
        var kept: [Entry] = []
        for entry in entries {
            switch entry {
            case .command(.openControlPanel, _, _), .command(.openDownloads, _, _), .command(.openInPanel, _, _):
                continue
            case .submenu(let title, let entries):
                let inner = withoutPanelCommands(entries)
                if !inner.isEmpty { kept.append(.submenu(title: title, entries: inner)) }
            case .separator:
                if let last = kept.last, last != .separator { kept.append(.separator) }
            case .command:
                kept.append(entry)
            }
        }
        if kept.last == .separator { kept.removeLast() }
        return kept
    }

    /// The displays a command can act on: enabled, showing a wallpaper of their own rather
    /// than mirroring another, and connected right now. A row's CoreGraphics id comes from the
    /// `(id - Role)` suffix of its renderer title.
    static func eligibleDisplays(_ rows: [BridgeDisplaySettingsRow], connected: Set<UInt32>) -> [BridgeDisplaySettingsRow] {
        rows.filter { row in
            guard row.isIndependent,
                  let physicalID = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title)
            else { return false }
            return connected.contains(physicalID)
        }
    }

    /// The main display first (the renderer's `primary`, or the screen macOS lists first, which
    /// has the menu bar), then left to right, so the submenus follow how the screens sit on the
    /// desk. Displays with the same title get ` (2)`, ` (3)` after it, so each submenu can be told apart.
    static func orderedDisplays(_ candidates: [Candidate], mainDisplay: UInt32?) -> [Candidate] {
        func isMain(_ candidate: Candidate) -> Bool {
            candidate.id == "primary" || (mainDisplay != nil && candidate.physicalID == mainDisplay)
        }
        let sorted = candidates.sorted { first, second in
            if isMain(first) != isMain(second) { return isMain(first) }
            if first.minX != second.minX { return first.minX < second.minX }
            return first.id < second.id
        }
        var used = Set<String>()
        return sorted.map { candidate in
            var title = candidate.title
            var count = 1
            while !used.insert(title).inserted {
                count += 1
                title = "\(candidate.title) (\(count))"
            }
            var named = candidate
            named.title = title
            return named
        }
    }

    // MARK: Building blocks

    /// The On Battery submenu: Keep Running, Reduced Quality and Pause with the current choice
    /// ticked, then Pause While Using Other Apps, which turns "When another app is in front" to
    /// Pause on battery, or back to Keep running while it is ticked.
    private static func batteryEntries(_ battery: Battery) -> [Entry] {
        let modes: [(BridgeBatteryMode, String)] = [
            (.keepRunning, String(localized: "Keep Running")),
            (.reducedQuality, String(localized: "Reduced Quality")),
            (.pause, String(localized: "Pause")),
        ]
        let pauses = battery.pausesWhileUsingOtherApps
        return modes.map { mode, title in
            .command(.batteryMode(mode), title: title, checked: mode == battery.mode)
        } + [
            .separator,
            .command(.otherAppInFront(pauses ? .keepRunning : .pauseOnBattery),
                     title: String(localized: "Pause While Using Other Apps"), checked: pauses),
        ]
    }

    /// Previous, Next, Random Wallpaper and Recently used for one display; each appears only
    /// when it can act.
    private static func navigation(for display: Display) -> [Entry] {
        var items: [Entry] = []
        if display.canPrevious {
            items.append(.command(.previous(display: display.id), title: String(localized: "Previous Wallpaper"), checked: false))
        }
        if display.canNext {
            items.append(.command(.next(display: display.id), title: String(localized: "Next Wallpaper"), checked: false))
        }
        if display.canRandom {
            items.append(.command(.random(display: display.id), title: String(localized: "Random Wallpaper"), checked: false))
        }
        let recent = display.recent.prefix(recentLimit)
        if !recent.isEmpty {
            items.append(.submenu(title: String(localized: "Recently used"), entries: recent.map {
                .command(.apply(wallpaper: $0.id, display: display.id), title: $0.title, checked: $0.id == display.wallpaperID)
            }))
        }
        return items
    }

    /// One display's submenu. Removing a wallpaper leaves the display empty, and the wallpaper
    /// it showed is the newest in its history, so an empty display offers to start it again.
    private static func submenu(for display: Display) -> [Entry] {
        var groups = [navigation(for: display)]
        if display.wallpaperID != nil {
            groups.append([.command(.remove(display: display.id), title: String(localized: "Remove from Display"), checked: false)])
        } else if let latest = display.recent.first {
            groups.append([.command(.startAgain(wallpaper: latest.id, display: display.id),
                                    title: String(localized: "Start Again"), checked: false)])
        }
        groups.append([.command(.openInPanel(display: display.id), title: String(localized: "Open in Control Panel"), checked: false)])
        var entries: [Entry] = []
        for group in groups where !group.isEmpty {
            if !entries.isEmpty { entries.append(.separator) }
            entries += group
        }
        return entries
    }
}

extension StatusMenuModel.Command {
    /// What the item runs through `AppAutomation`, the path a link or a keyboard shortcut takes
    /// too; nil for the items that open a window or lock the screen. The menu bar panel's buttons
    /// carry the same commands, so they act as these items do.
    var automation: AutomationCommand? {
        switch self {
        case .playPause: .togglePlayback
        case .toggleMute: .toggleMute
        case .previous(let display): .previous(display: display)
        case .next(let display): .next(display: display)
        case .random(let display): .random(display: display, pool: .all)
        case .apply(let id, let display), .startAgain(let id, let display): .apply(wallpaperID: id, display: display)
        case .remove(let display): .removeWallpaper(display: display)
        case .openControlPanel, .openDownloads, .openInPanel, .lockScreen, .toggleDesktopIcons, .batteryMode,
             .otherAppInFront: nil
        }
    }
}
