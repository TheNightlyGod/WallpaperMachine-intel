import Foundation

/// Something the app can be told to do from outside its window: a `wallpapermachine://` link,
/// the Shortcuts app, or a global keyboard shortcut. Each is something the menu bar or the
/// panel already offers; nothing here deletes or downloads wallpaper files.
enum AutomationCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayback
    /// Silences every wallpaper without changing their saved sound settings
    /// (`PlaybackPreferences.wallpapersMuted`). `unmute` lets each play as it was saved, and
    /// `toggleMute` does whichever the current state calls for.
    case mute
    case unmute
    case toggleMute
    /// The next wallpaper on `display`, or on the panel's target display when nil.
    case next(display: String?)
    /// Walks back through successful switches on this display.
    case previous(display: String?)
    /// A wallpaper from `pool` other than the one `display` shows (or the target display, when
    /// nil), going through the whole pool before it repeats one.
    case random(display: String?, pool: RandomPool)
    /// Applies an installed wallpaper on `display`, or on the target display when nil.
    case apply(wallpaperID: String, display: String?)
    /// Applies an installed wallpaper on every enabled independent display in one step: all of
    /// them change or none does.
    case applyEverywhere(wallpaperID: String)
    /// Takes whatever `display` shows (or the target display, when nil) off it and leaves it
    /// empty; a playlist waits until the user puts a wallpaper there again. Only the menu bar
    /// sends it: it has no link, so a web page or a script cannot blank a display.
    case removeWallpaper(display: String?)
    case applyPlaylist(planID: String, display: String?)
    case applyPreset(presetID: String)
    case applyDisplayLayout(layoutID: String)
    /// Brings up the control panel, on one of its pages when named.
    case open(page: Page?)

    enum Page: String, CaseIterable, Sendable {
        case installed, discover, pixiv, settings
    }

    /// Where Random Wallpaper draws from. The raw value is what a link says (`from=favorites`)
    /// and what a saved round is filed under.
    enum RandomPool: String, CaseIterable, Sendable {
        case all, favorites

        /// The wallpapers a pick may be, in `library` order: those that can play, narrowed to
        /// the favorites for `.favorites`, and never one the app is holding back after a crash.
        /// Picking is the user's own choice, which would release that hold, so a roll of the
        /// dice must not be able to reopen the wallpaper that killed the app.
        func candidates(library: [String], favorites: Set<String>, held: Set<String>) -> [String] {
            library.filter { !held.contains($0) && (self == .all || favorites.contains($0)) }
        }
    }

    static let scheme = "wallpapermachine"
    /// What `display=` says to mean every display rather than one.
    private static let everyDisplay = "all"

    /// Reads a `wallpapermachine://` link: the command is the host, and `display`, `id` and
    /// `page` are query items. Anything else answers nil rather than guessing.
    ///
    ///     wallpapermachine://toggle
    ///     wallpapermachine://togglemute
    ///     wallpapermachine://next?display=primary
    ///     wallpapermachine://random?from=favorites
    ///     wallpapermachine://apply?id=3632513108
    ///     wallpapermachine://apply?id=3632513108&display=all
    ///     wallpapermachine://open?page=settings
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.path.isEmpty || components.path == "/"
        else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // A name given twice is ambiguous; refuse it instead of picking one.
            guard values[item.name] == nil, let value = item.value, !value.isEmpty, value.count <= 1024 else { return nil }
            values[item.name] = value
        }
        let display = values["display"]
        switch host {
        case "play" where values.isEmpty: self = .play
        case "pause" where values.isEmpty: self = .pause
        case "toggle" where values.isEmpty: self = .togglePlayback
        case "mute" where values.isEmpty: self = .mute
        case "unmute" where values.isEmpty: self = .unmute
        case "togglemute" where values.isEmpty: self = .toggleMute
        case "next" where Set(values.keys).isSubset(of: ["display"]): self = .next(display: display)
        case "previous" where Set(values.keys).isSubset(of: ["display"]): self = .previous(display: display)
        case "random" where Set(values.keys).isSubset(of: ["display", "from"]):
            var pool = RandomPool.all
            if let from = values["from"] {
                guard let known = RandomPool(rawValue: from.lowercased()) else { return nil }
                pool = known
            }
            self = .random(display: display, pool: pool)
        case "apply" where Set(values.keys).isSubset(of: ["id", "display"]):
            guard let id = values["id"] else { return nil }
            // `all` cannot be a display's own selector (`primary`, a number or `identity:{…}`).
            if display?.lowercased() == Self.everyDisplay {
                self = .applyEverywhere(wallpaperID: id)
            } else {
                self = .apply(wallpaperID: id, display: display)
            }
        case "playlist" where Set(values.keys).isSubset(of: ["id", "display"]):
            guard let id = values["id"] else { return nil }
            self = .applyPlaylist(planID: id, display: display)
        case "preset" where Set(values.keys) == ["id"]:
            guard let id = values["id"] else { return nil }
            self = .applyPreset(presetID: id)
        case "layout" where Set(values.keys) == ["id"]:
            guard let id = values["id"] else { return nil }
            self = .applyDisplayLayout(layoutID: id)
        case "open" where Set(values.keys).isSubset(of: ["page"]):
            if let page = values["page"] {
                guard let known = Page(rawValue: page.lowercased()) else { return nil }
                self = .open(page: known)
            } else {
                self = .open(page: nil)
            }
        default:
            return nil
        }
    }
}

/// Why a command from outside the window could not run.
struct AutomationError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    static var notReady: AutomationError {
        AutomationError(message: String(localized: "WallpaperMachine is still starting, or its renderer could not start. Try again in a moment."))
    }
}
