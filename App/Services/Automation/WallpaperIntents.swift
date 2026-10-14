import AppIntents

/// An installed wallpaper as the Shortcuts app lists and chooses it.
struct WallpaperEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wallpaper"
    static let defaultQuery = WallpaperQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

/// The installed wallpapers that can play, in library order.
struct WallpaperQuery: EntityStringQuery {
    func entities(for identifiers: [WallpaperEntity.ID]) async throws -> [WallpaperEntity] {
        await Self.all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [WallpaperEntity] {
        await Self.all().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [WallpaperEntity] {
        await Self.all()
    }

    private static func all() async -> [WallpaperEntity] {
        await AppAutomation.shared.availableWallpapers().map { WallpaperEntity(id: $0.id, title: $0.title) }
    }
}

struct PauseWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Wallpapers"
    static let description: IntentDescription? = IntentDescription("Pauses every wallpaper, as Pause in the menu bar does.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.pause)
        return .result()
    }
}

struct ResumeWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Wallpapers"
    static let description: IntentDescription? = IntentDescription("Plays every wallpaper again after a pause.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.play)
        return .result()
    }
}

struct ToggleWallpaperPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause Wallpapers"
    static let description: IntentDescription? = IntentDescription("Pauses wallpapers that are playing, and plays them when paused.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.togglePlayback)
        return .result()
    }
}

struct MuteWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Wallpapers"
    static let description: IntentDescription? = IntentDescription(
        "Silences every wallpaper without changing their saved sound settings.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.mute)
        return .result()
    }
}

struct UnmuteWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmute Wallpapers"
    static let description: IntentDescription? = IntentDescription(
        "Lets every wallpaper play its saved sound again after Mute Wallpapers.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.unmute)
        return .result()
    }
}

struct ToggleWallpaperMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Wallpapers"
    static let description: IntentDescription? = IntentDescription(
        "Silences every wallpaper, or lets them play their saved sound again when they are already silenced.")

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.toggleMute)
        return .result()
    }
}

struct NextWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Changes a chosen display to its next wallpaper, or the target display when none is chosen.")

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.next(display: display?.id))
        return .result()
    }
}

struct PreviousWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Returns a chosen display to its previous wallpaper, or the target display when none is chosen.")

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.previous(display: display?.id))
        return .result()
    }
}

/// Where Random Wallpaper draws from.
enum RandomWallpaperSource: String, AppEnum {
    case all, favorites

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Choose from"
    static let caseDisplayRepresentations: [RandomWallpaperSource: DisplayRepresentation] = [
        .all: "All wallpapers", .favorites: "Favorites",
    ]

    var pool: AutomationCommand.RandomPool {
        switch self {
        case .all: .all
        case .favorites: .favorites
        }
    }
}

struct RandomWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Random Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Changes a chosen display to a random wallpaper other than the one it shows, or the target display when none is chosen.")

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    @Parameter(title: "Choose from", default: .all)
    var source: RandomWallpaperSource

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.random(display: display?.id, pool: source.pool))
        return .result()
    }
}

struct ApplyWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Wallpaper"
    static let description: IntentDescription? = IntentDescription(
        "Applies an installed wallpaper to a chosen display, to every display, or to the target display when none is chosen.")

    @Parameter(title: "Wallpaper")
    var wallpaper: WallpaperEntity

    @Parameter(title: "Display")
    var display: WallpaperDisplayEntity?

    /// Wins over a chosen display: the wallpaper goes on every enabled independent display,
    /// all of them or none.
    @Parameter(title: "On all displays", default: false)
    var allDisplays: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$wallpaper)") {
            \.$display
            \.$allDisplays
        }
    }

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(
            allDisplays ? .applyEverywhere(wallpaperID: wallpaper.id) : .apply(wallpaperID: wallpaper.id, display: display?.id))
        return .result()
    }
}

struct OpenControlPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "Open WallpaperMachine"
    static let description: IntentDescription? = IntentDescription("Opens the control panel.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        try await AppAutomation.shared.perform(.open(page: nil))
        return .result()
    }
}

/// The actions Siri and Spotlight offer without the user building a shortcut first.
struct WallpaperMachineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleWallpaperPlaybackIntent(),
            phrases: ["Play or pause \(.applicationName)", "Play or pause wallpapers in \(.applicationName)"],
            shortTitle: "Play or Pause", systemImageName: "playpause")
        AppShortcut(
            intent: ToggleWallpaperMuteIntent(),
            phrases: ["Mute or unmute wallpapers in \(.applicationName)", "Mute wallpapers with \(.applicationName)"],
            shortTitle: "Mute or Unmute", systemImageName: "speaker.slash")
        AppShortcut(
            intent: NextWallpaperIntent(),
            phrases: ["Next wallpaper in \(.applicationName)", "Change wallpaper with \(.applicationName)"],
            shortTitle: "Next Wallpaper", systemImageName: "forward")
        AppShortcut(
            intent: RandomWallpaperIntent(),
            phrases: ["Random wallpaper in \(.applicationName)", "Pick a random wallpaper with \(.applicationName)"],
            shortTitle: "Random Wallpaper", systemImageName: "shuffle")
        AppShortcut(
            intent: ApplyWallpaperIntent(),
            phrases: ["Apply a wallpaper with \(.applicationName)"],
            shortTitle: "Apply Wallpaper", systemImageName: "photo.on.rectangle")
        AppShortcut(
            intent: PreviousWallpaperIntent(),
            phrases: ["Previous wallpaper in \(.applicationName)"],
            shortTitle: "Previous Wallpaper", systemImageName: "backward")
        AppShortcut(
            intent: ApplyWallpaperPlaylistIntent(),
            phrases: ["Apply a playlist with \(.applicationName)"],
            shortTitle: "Apply Playlist", systemImageName: "list.bullet")
        AppShortcut(
            intent: ApplyWallpaperPropertyPresetIntent(),
            phrases: ["Apply a property preset with \(.applicationName)"],
            shortTitle: "Apply Property Preset", systemImageName: "slider.horizontal.3")
        AppShortcut(
            intent: ApplyWallpaperDisplayLayoutIntent(),
            phrases: ["Apply a display layout with \(.applicationName)"],
            shortTitle: "Apply Display Layout", systemImageName: "display.2")
    }
}
