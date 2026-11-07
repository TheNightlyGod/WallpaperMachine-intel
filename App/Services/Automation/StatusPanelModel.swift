import Foundation

/// What the menu bar panel shows and offers, decided without AppKit or SwiftUI so the branching
/// can be tested, as `StatusMenuModel` is for the menu.
///
/// The panel is about one display at a time: the one chosen in its display picker, which appears
/// only when two or more displays can show a wallpaper of their own, named and ordered as the
/// menu's submenus are. Every command names that display, and a command the menu also has is the
/// menu's own `StatusMenuModel.Command`, so Next on the panel is Next in that display's submenu.
///
/// The quick switcher shows a batch of `stripSize` wallpapers that can play (supported and not
/// held back after a crash): the favorites, or the whole library when no favorite other than the
/// shown wallpaper can play. The shown wallpaper is always in it, first; the others are shuffled,
/// and a new batch takes wallpapers the previous one did not show while there are enough of them.
/// The draw takes its random source, so a test can seed it.
enum StatusPanelModel {
    /// One installed wallpaper, as much of it as the panel shows.
    struct Wallpaper: Equatable, Identifiable, Sendable {
        var id: String
        /// The author's title: untrusted text, shown verbatim.
        var title: String
        var kind: LibraryRow.Kind
        var previewFile: URL?
        /// Whether it can play: supported by the renderer and not held back after a crash.
        var isPlayable: Bool
    }

    /// What holds every wallpaper still besides the user's own Pause.
    enum Hold: Equatable, Sendable {
        /// The drive that holds the library was ejected or unplugged, which stops them until it is
        /// connected again (`LibraryDriveStatus`).
        case libraryDrive
        /// A Low Power Mode, heat, low-battery or inactivity rule pauses or stops them.
        case condition(EngagedSystemCondition)
        /// The Mac runs on battery and On battery is set to Pause.
        case onBattery
        /// An app rule, another app's sound or a Focus filter; `stopped` while they are unloaded.
        case rule(stopped: Bool)
    }

    /// What the state line says about the chosen display.
    enum State: Equatable, Sendable {
        /// No display can show a wallpaper: the app is starting or quitting, or none is enabled.
        case unavailable
        /// A wallpaper switch on this display waits or runs.
        case switching
        /// The display shows nothing.
        case empty
        /// The user paused playback.
        case paused
        case held(Hold)
        case playing
    }

    enum Command: Equatable, Sendable {
        /// What the menu bar menu does for the same item.
        case menu(StatusMenuModel.Command)
        /// Lets every wallpaper play its saved sound again after Mute Wallpapers.
        case unmuteAll
        case toggleFavorite(wallpaper: String)
        /// The wallpaper's own saved volume, from 0 to 1, as the inspector's slider sets it.
        case setVolume(wallpaper: String, volume: Double)
        /// The wallpaper's own saved mute, as the inspector's Mute this wallpaper sets it.
        case setMuted(wallpaper: String, muted: Bool)
        case openSettings
        case openUpdates
        case quit
    }

    /// The shown wallpaper's own sound settings.
    struct Volume: Equatable, Sendable {
        var wallpaperID: String
        var volume: Double
        var muted: Bool
    }

    /// Where the quick switcher drew its batch from.
    enum StripSource: Equatable, Sendable {
        case favorites, all
    }

    /// A quick-switcher batch, in order, and the pool it was drawn from, which its caption names.
    struct Batch: Equatable, Sendable {
        var ids: [String] = []
        var source = StripSource.all
    }

    struct Input: Equatable {
        /// The menu's own input: playback, Mute Wallpapers and the displays, in menu order.
        var menu: StatusMenuModel.Input
        /// The installed wallpapers in library order.
        var library: [Wallpaper]
        var favorites: Set<String> = []
        /// What holds wallpapers still besides the user's Pause; nil while nothing does.
        var hold: Hold? = nil
        /// Displays with a wallpaper switch waiting or running.
        var switching: Set<String> = []
        /// The control panel's target display, which the panel starts on when it can.
        var targetDisplayID: String? = nil
        /// Moves with every renderer snapshot, so the shown wallpaper's volume is read again.
        var snapshotRevision: UInt64 = 0
        /// Moves with every library rescan, so the covers' stamps are read again.
        var libraryRevision: UInt64 = 0
        var update: AppUpdateNotice? = nil
    }

    /// A display in the picker.
    struct DisplayChoice: Equatable, Identifiable, Sendable {
        var id: String
        /// The menu's title for it: the full name, unique among the displays.
        var title: String
        /// The name without the renderer's `(id - Role)` group, unless another display has the
        /// same name and only the full title tells them apart.
        var shortTitle: String
    }

    struct Panel: Equatable {
        var displays: [DisplayChoice] = []
        /// The display every command acts on; nil while none can.
        var displayID: String?
        var displayTitle = ""
        /// What the display shows, when it is installed.
        var wallpaper: Wallpaper?
        var state = State.unavailable
        var isFavorite = false
        var canPrevious = false
        var canNext = false
        var canRandom = false
        /// Play/Pause acts on every display, so it works while any of them shows a wallpaper.
        var canTogglePlayback = false
        var isPaused = false
        /// Mute Wallpapers is on: every wallpaper is silent, whatever its own sound settings say.
        var wallpapersMuted = false
        var strip: [Wallpaper] = []
        /// Where the batch on show was drawn from, which can differ from where the next one would be.
        var stripSource = StripSource.all
        /// Whether another batch differs from the one on show: the next draw takes another pool than
        /// the batch came from, or the pool holds a wallpaper the batch does not show.
        var canShowOthers = false
        /// Wallpapers used on the display before, newest use first, without the one it shows.
        var recent: [Wallpaper] = []
        var isLibraryEmpty = true
        var update: AppUpdateNotice? = nil

        var showsDisplayPicker: Bool { displays.count > 1 }
    }

    static let stripSize = 8
    static let recentLimit = 4

    // MARK: The panel

    /// The display the panel acts on: `requested` while it can still be one, else the control
    /// panel's target display, else the first in menu order (the main display).
    static func display(_ requested: String?, in input: Input) -> StatusMenuModel.Display? {
        let displays = input.menu.displays
        for id in [requested, input.targetDisplayID].compactMap({ $0 }) {
            if let display = displays.first(where: { $0.id == id }) { return display }
        }
        return displays.first
    }

    /// The panel for the display `requested` names (see `display(_:in:)`), with the quick
    /// switcher showing `strip`: ids that left the library are dropped, nothing is added. Its
    /// caption names `drawnFrom`, the pool the batch came from, so a click that changes what the
    /// display shows does not relabel the tiles still on show; nil names the pool a draw takes now.
    static func make(
        _ input: Input, display requested: String?, strip: [String], drawnFrom: StripSource? = nil
    ) -> Panel {
        let installed = Dictionary(input.library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var panel = Panel()
        panel.update = input.update
        panel.displays = choices(input.menu.displays)
        panel.isLibraryEmpty = input.library.isEmpty
        panel.isPaused = input.menu.paused
        panel.wallpapersMuted = input.menu.wallpapersMuted
        panel.canTogglePlayback = input.menu.playbackIsCurrent && input.menu.hasActiveWallpapers
        panel.strip = strip.compactMap { installed[$0] }
        let display = Self.display(requested, in: input)
        let pool = stripPool(input, shown: display?.wallpaperID)
        let showing = Set(panel.strip.map(\.id))
        panel.stripSource = drawnFrom ?? pool.source
        panel.canShowOthers = pool.source != panel.stripSource
            || pool.ids.contains { !showing.contains($0) && $0 != display?.wallpaperID }
        guard let display else { return panel }
        panel.displayID = display.id
        panel.displayTitle = display.title
        panel.wallpaper = display.wallpaperID.flatMap { installed[$0] }
        panel.state = state(of: display, in: input)
        panel.isFavorite = panel.wallpaper.map { input.favorites.contains($0.id) } ?? false
        panel.canPrevious = display.canPrevious
        panel.canNext = display.canNext
        panel.canRandom = display.canRandom
        panel.recent = Array(display.recent.lazy
            .filter { $0.id != display.wallpaperID }
            .compactMap { installed[$0.id] }
            .prefix(recentLimit))
        return panel
    }

    /// What holds every wallpaper still besides the user's Pause, in the most specific words there
    /// are, and first what no rule lifts: a disconnected library drive. Then a condition's rule
    /// names itself (Low Power Mode, heat, a low battery or an inactive Mac), then On battery's
    /// Pause; any other global hold (`presentation`, nil while nobody sees the panel or there is no
    /// policy) is an app rule, another app's sound or a Focus filter: a playback rule.
    static func hold(
        libraryDriveDisconnected: Bool, condition: EngagedSystemCondition?, onBatteryPauses: Bool,
        presentation: GlobalPresentation?
    ) -> Hold? {
        if libraryDriveDisconnected { return .libraryDrive }
        if let condition { return .condition(condition) }
        if onBatteryPauses { return .onBattery }
        if let presentation, presentation != .running { return .rule(stopped: presentation == .unloaded) }
        return nil
    }

    /// A switch in progress is said first, whatever else holds; an empty display has nothing to
    /// pause; the user's own Pause is named before a rule that also holds.
    static func state(of display: StatusMenuModel.Display, in input: Input) -> State {
        if input.switching.contains(display.id) { return .switching }
        guard display.wallpaperID != nil else { return .empty }
        if input.menu.paused { return .paused }
        if let hold = input.hold { return .held(hold) }
        return .playing
    }

    /// The menu's displays with the short names the picker has room for.
    static func choices(_ displays: [StatusMenuModel.Display]) -> [DisplayChoice] {
        let names = displays.map { TargetDisplayOption.name(of: $0.title) }
        return zip(displays, names).map { display, name in
            let isShared = names.filter { $0 == name }.count > 1
            return DisplayChoice(id: display.id, title: display.title, shortTitle: isShared ? display.title : name)
        }
    }

    // MARK: The quick switcher

    /// What a batch is drawn from: the favorites that can play, in library order, unless none of
    /// them is other than `shown`; then every wallpaper that can play.
    static func stripPool(_ input: Input, shown: String?) -> (source: StripSource, ids: [String]) {
        let playable = input.library.filter(\.isPlayable).map(\.id)
        let favorites = playable.filter(input.favorites.contains)
        if favorites.contains(where: { $0 != shown }) { return (.favorites, favorites) }
        return (.all, playable)
    }

    /// A new batch for the display `requested` names, keeping out the ids of `previous` while
    /// there are enough others.
    static func drawStrip(
        _ input: Input, display requested: String?, avoiding previous: Set<String>,
        using generator: inout some RandomNumberGenerator
    ) -> Batch {
        let shown = display(requested, in: input)?.wallpaperID
        let current = shown.flatMap { id in input.library.contains { $0.id == id } ? id : nil }
        let pool = stripPool(input, shown: shown)
        return Batch(
            ids: batch(pool: pool.ids, current: current, avoiding: previous, using: &generator), source: pool.source)
    }

    /// `current` first, when there is one, then the rest of `pool` shuffled: the ids `previous`
    /// does not hold before the ones it does, so a batch repeats one of the last only when the pool
    /// has too few others.
    static func batch(
        pool: [String], current: String?, avoiding previous: Set<String>, size: Int = stripSize,
        using generator: inout some RandomNumberGenerator
    ) -> [String] {
        guard size > 0 else { return [] }
        var batch = current.map { [$0] } ?? []
        var seen = Set(batch)
        let others = pool.filter { seen.insert($0).inserted }.shuffled(using: &generator)
        let fresh = others.filter { !previous.contains($0) }
        let repeated = others.filter { previous.contains($0) }
        batch += (fresh + repeated).prefix(max(0, size - batch.count))
        return batch
    }
}
