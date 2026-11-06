import AppKit
import Foundation

/// A player this app knows how to ask.
///
/// The bundle identifier is what decides whether it is asked at all: an Apple
/// Event sent to an application that is not running launches it, and a
/// wallpaper must never start the user's music player.
enum AppleScriptPlayer: String, CaseIterable, Sendable {
    case music
    case spotify

    var bundleIdentifier: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }
}

/// One Music.app or Spotify snapshot. Absent fields stay empty; nothing here
/// invents a title, position or cover.
struct AppleScriptNowPlaying: Equatable, Sendable {
    var player: AppleScriptPlayer
    var playback: SystemMediaPlaybackState
    var properties: SystemMediaProperties
    var position: Double?
    var duration: Double?
    /// Identifies the track this snapshot describes. Cover art is fetched when
    /// this changes rather than once a second, because the artwork is the one
    /// expensive thing either player can be asked for. Empty when the player
    /// published no identifier, which simply means no cover is fetched.
    var trackIdentity = ""
    /// Where the cover can be fetched when the player publishes a URL instead
    /// of bytes. Nil for a player whose cover is read over Apple Events.
    var artworkURL: URL?
}

/// Runs the Music.app / Spotify queries. Injected so tests never execute a
/// real script, reach the network or prompt for Automation access.
@MainActor
protocol AppleScriptRunning: AnyObject {
    /// Players that are running right now. Nothing else is contacted.
    func runningPlayers() -> [AppleScriptPlayer]
    /// Asks one player what it is playing. Cheap enough to poll: no cover.
    func query(_ player: AppleScriptPlayer) async -> AppleScriptNowPlaying?
    /// Reads the cover of whatever `player` has loaded, over Apple Events.
    func fetchArtwork(from player: AppleScriptPlayer) async -> Data?
    /// Downloads a cover the player described by URL.
    func fetchArtwork(at url: URL) async -> Data?
    /// Asks one player to carry out a transport command.
    func control(_ player: AppleScriptPlayer, _ command: SystemMediaCommand) async -> Bool
}

/// Asks the music players the user already has open what they are playing.
///
/// The first running player with a loaded track wins. A player that is not
/// running is never contacted, so this neither launches anything nor asks for
/// Automation permission for an app the user is not using. A player that
/// answers with nothing is skipped rather than turned into a placeholder track.
@MainActor
final class AppleScriptMediaProvider: SystemMediaProvider {
    private(set) var availability: SystemMediaAvailability
    var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?

    private let runner: any AppleScriptRunning
    private let scheduler: any MediaTimerScheduling
    private let artwork: MediaArtwork
    private let pollInterval: TimeInterval
    typealias ObservePlayers = (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private let observePlayers: ObservePlayers
    private var cancelPlayerObservation: (@MainActor () -> Void)?
    private var knownPlayers: [AppleScriptPlayer] = []
    private var subscription: UInt64 = 0
    private var refreshPending = false

    private var consumers = 0
    private var ticker: (any MediaTimerToken)?
    private var properties = SystemMediaProperties()
    /// The player whose state is currently being reported, and so the one a
    /// transport command belongs to.
    private var reading: AppleScriptPlayer?
    private var thumbnail: SystemMediaThumbnail?
    private var playback = SystemMediaPlaybackState.stopped
    private var timeline: SystemMediaTimeline?
    /// Bumped whenever this provider stops, so a cover that finishes loading
    /// afterwards is discarded instead of being shown next to a later song.
    private var generation = 0
    /// The track whose cover has already been looked for, successfully or not.
    private var coveredTrack: String?
    private var polling = false

    init(
        runner: (any AppleScriptRunning)? = nil,
        scheduler: (any MediaTimerScheduling)? = nil,
        artwork: MediaArtwork? = nil,
        pollInterval: TimeInterval = 1,
        observePlayers: ObservePlayers? = nil
    ) {
        self.runner = runner ?? NSAppleScriptNowPlayingRunner()
        self.scheduler = scheduler ?? FoundationMediaTimerScheduler()
        self.artwork = artwork ?? MediaArtwork()
        self.pollInterval = pollInterval
        self.observePlayers = observePlayers ?? Self.observeRunningPlayers
        availability = .unavailable(
            reason: MediaRemoteUnavailable(code: .notStarted).localizedDescription)
    }

    func addConsumer() {
        consumers += 1
        guard consumers == 1 else { return }
        subscription &+= 1
        let current = subscription
        cancelPlayerObservation = observePlayers { [weak self] in
            guard let self, self.subscription == current, self.consumers > 0 else { return }
            self.playersChanged()
        }
        playersChanged(forceRefresh: true)
    }

    func removeConsumer() {
        guard consumers > 0 else { return }
        consumers -= 1
        guard consumers == 0 else { return }
        subscription &+= 1
        cancelPlayerObservation?()
        cancelPlayerObservation = nil
        ticker?.cancel()
        ticker = nil
        knownPlayers = []
        refreshPending = false
        generation &+= 1
        availability = .unavailable(
            reason: MediaRemoteUnavailable(code: .notStarted).localizedDescription)
        properties = SystemMediaProperties()
        reading = nil
        thumbnail = nil
        playback = .stopped
        timeline = nil
        coveredTrack = nil
    }

    func replayCurrentState() {
        guard consumers > 0, case .available = availability else { return }
        onPropertiesChanged?(properties)
        if let thumbnail { onThumbnailChanged?(thumbnail) }
        onPlaybackChanged?(playback)
        onTimelineChanged?(timeline)
    }

    /// Launch/exit notifications replace the idle poll while neither supported player runs.
    /// Register before the initial snapshot so a launch cannot fall into the gap between them.
    private static func observeRunningPlayers(_ changed: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let center = NSWorkspace.shared.notificationCenter
        let tokens = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed() }
            }
        }
        return { for token in tokens { center.removeObserver(token) } }
    }

    private func playersChanged(forceRefresh: Bool = false) {
        let players = runner.runningPlayers()
        let changed = updatePlayers(players)
        guard !players.isEmpty, changed || forceRefresh else { return }
        if polling { refreshPending = true } else { refresh() }
    }

    /// Each live poll also checks membership instead of using a list cached before a
    /// termination whose workspace notification has not reached the main actor yet.
    @discardableResult
    private func updatePlayers(_ players: [AppleScriptPlayer]) -> Bool {
        let changed = players != knownPlayers
        if changed {
            knownPlayers = players
            generation &+= 1
        }
        if players.isEmpty {
            ticker?.cancel()
            ticker = nil
            refreshPending = false
            report(unavailable: String(localized: "No music player this app can read is running."))
        } else if ticker == nil {
            let current = subscription
            ticker = scheduler.schedule(every: pollInterval) { [weak self] in
                guard let self, self.subscription == current else { return }
                self.refresh()
            }
        }
        return changed
    }

    /// One poll at a time. The scripts run off the main thread and a slow
    /// answer must not queue another round behind it.
    private func refresh() {
        guard consumers > 0, !knownPlayers.isEmpty, !polling else { return }
        polling = true
        let current = subscription
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.subscription == current { await self.poll() }
            self.polling = false
            // A launch or restart during a slow query is read as soon as that query
            // finishes, without overlapping Apple Events or waiting for another tick.
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    private func poll() async {
        let players = runner.runningPlayers()
        updatePlayers(players)
        guard !players.isEmpty else { return }

        let started = generation
        var snapshot: AppleScriptNowPlaying?
        for player in players {
            snapshot = await runner.query(player)
            guard consumers > 0, generation == started else { return }
            if snapshot != nil { break }
        }
        guard let snapshot else {
            report(unavailable: String(localized: "Neither Music nor Spotify reported what is playing."))
            return
        }

        availability = .available
        apply(snapshot)
        await applyArtwork(for: snapshot, generation: started)
    }

    private func report(unavailable reason: String) {
        guard consumers > 0 else { return }
        availability = .unavailable(reason: reason)
        generation &+= 1
        reading = nil
        coveredTrack = nil
        let hadProperties = properties != SystemMediaProperties()
        let hadThumbnail = thumbnail != nil && thumbnail != .empty
        let wasPlaying = playback != .stopped
        let hadTimeline = timeline != nil
        properties = SystemMediaProperties()
        thumbnail = .empty
        playback = .stopped
        timeline = nil
        if hadProperties { onPropertiesChanged?(properties) }
        if hadThumbnail { onThumbnailChanged?(.empty) }
        if wasPlaying { onPlaybackChanged?(.stopped) }
        if hadTimeline { onTimelineChanged?(nil) }
    }

    /// Controls the player this provider is reading, not a fixed one: a
    /// command aimed at Music while Spotify is playing would change the wrong
    /// thing, or nothing.
    func send(_ command: SystemMediaCommand) async -> Bool {
        guard consumers > 0, case .available = availability, let player = reading else { return false }
        guard runner.runningPlayers().contains(player) else {
            report(unavailable: String(localized: "No music player this app can read is running."))
            return false
        }
        return await runner.control(player, command)
    }

    private func apply(_ snapshot: AppleScriptNowPlaying) {
        reading = snapshot.player
        if snapshot.properties != properties {
            properties = snapshot.properties
            onPropertiesChanged?(snapshot.properties)
        }
        if snapshot.playback != playback {
            playback = snapshot.playback
            onPlaybackChanged?(snapshot.playback)
        }
        let nextTimeline: SystemMediaTimeline?
        if let duration = snapshot.duration, duration > 0, let position = snapshot.position {
            nextTimeline = SystemMediaTimeline(
                position: min(max(position, 0), duration), duration: duration)
        } else {
            nextTimeline = nil
        }
        if nextTimeline != timeline {
            timeline = nextTimeline
            onTimelineChanged?(nextTimeline)
        }
    }

    /// Loads the cover of a track whose cover has not been looked for yet. A
    /// track that turns out to have none is remembered as looked-for too, so a
    /// coverless album is not re-fetched once a second.
    private func applyArtwork(
        for snapshot: AppleScriptNowPlaying, generation started: Int
    ) async {
        guard snapshot.trackIdentity != coveredTrack else { return }
        if snapshot.trackIdentity.isEmpty {
            coveredTrack = snapshot.trackIdentity
            publishArtwork(nil)
            return
        }
        let data: Data?
        if let url = snapshot.artworkURL {
            data = await runner.fetchArtwork(at: url)
        } else {
            data = await runner.fetchArtwork(from: snapshot.player)
        }
        guard consumers > 0, generation == started else { return }
        coveredTrack = snapshot.trackIdentity
        publishArtwork(data.flatMap { $0.isEmpty ? nil : artwork.thumbnail(for: $0) })
    }

    private func publishArtwork(_ cover: SystemMediaThumbnail?) {
        let next = cover ?? .empty
        guard next != thumbnail else { return }
        thumbnail = next
        onThumbnailChanged?(next)
    }
}

/// Compiles and runs the Music.app / Spotify queries through `NSAppleScript`.
///
/// `NSAppleScript` is synchronous and an Apple Event round trip to a busy
/// player takes as long as that player wants, so every execution happens on one
/// private serial queue. Nothing here runs on the main thread.
@MainActor
final class NSAppleScriptNowPlayingRunner: AppleScriptRunning {
    /// `NSAppleScript` is not thread safe, so one serial queue owns every
    /// instance this type ever compiles.
    private let queue = DispatchQueue(label: "WallpaperMachine.applescript-now-playing")
    /// Each source is compiled once and run again on every poll: compiling parses the
    /// script and loads the player's scripting terminology, which is most of what a
    /// once-a-second query costs. Touched only on `queue`.
    private let scripts: AppleScriptCache<NSAppleScript>
    private let session: URLSession

    /// `compile` runs on the private queue; tests pass one that counts and compiles a
    /// script that contacts no application.
    init(
        session: URLSession = .shared,
        compile: @escaping @Sendable (String) -> NSAppleScript? = { NSAppleScriptNowPlayingRunner.compile($0) }
    ) {
        self.session = session
        scripts = AppleScriptCache(compile: compile)
    }

    nonisolated static func compile(_ source: String) -> NSAppleScript? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        return script.compileAndReturnError(&error) ? script : nil
    }

    func runningPlayers() -> [AppleScriptPlayer] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return AppleScriptPlayer.allCases.filter { running.contains($0.bundleIdentifier) }
    }

    func query(_ player: AppleScriptPlayer) async -> AppleScriptNowPlaying? {
        let scripts = scripts
        return await offMainThread {
            Self.parse(Self.run(Self.stateSource(for: player), from: scripts), player: player)
        }
    }

    func fetchArtwork(from player: AppleScriptPlayer) async -> Data? {
        guard player == .music else { return nil }
        let scripts = scripts
        return await offMainThread {
            let data = Self.run(Self.musicArtworkSource, from: scripts)?.data
            return data?.isEmpty == false ? data : nil
        }
    }

    func fetchArtwork(at url: URL) async -> Data? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        guard let (data, response) = try? await session.data(from: url),
            (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true
        else { return nil }
        return data
    }

    /// Tells one player to carry out a transport command.
    ///
    /// Both players understand the same three verbs, so the command maps
    /// directly. Run off the main thread like every other Apple Event here: a
    /// busy player can take a while to answer.
    func control(_ player: AppleScriptPlayer, _ command: SystemMediaCommand) async -> Bool {
        let verb = switch command {
        case .togglePlayPause: "playpause"
        case .nextTrack: "next track"
        case .previousTrack: "previous track"
        }
        // Addressed by bundle identifier, as every other script here is: a
        // name can be localised or claimed by something else.
        let source = "tell application id \"\(player.bundleIdentifier)\" to \(verb)"
        let scripts = scripts
        return await offMainThread { Self.run(source, from: scripts) != nil }
    }

    private func offMainThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Script execution

    /// Runs the compiled script for `source`; on `queue` only. A script stays
    /// addressed by bundle identifier once compiled, so a player that quits and opens
    /// again is reached by the same script. Every variable it reads is set first in the
    /// same run, so nothing one run leaves behind reaches the next.
    private nonisolated static func run(
        _ source: String, from scripts: AppleScriptCache<NSAppleScript>
    ) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = scripts.script(for: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil && result.numberOfItems == 0 && result.stringValue == nil { return nil }
        return result
    }

    /// Reads one player's reply list. This is where a player's units are
    /// turned into the protocol's, so it is reachable on its own.
    nonisolated static func parse(
        _ descriptor: NSAppleEventDescriptor?, player: AppleScriptPlayer
    ) -> AppleScriptNowPlaying? {
        guard let descriptor, descriptor.numberOfItems >= 8 else { return nil }
        let text = { (index: Int) in descriptor.atIndex(index)?.stringValue ?? "" }
        let title = text(2)
        let artist = text(3)
        let album = text(4)
        if title.isEmpty && artist.isEmpty && album.isEmpty { return nil }

        var properties = SystemMediaProperties()
        properties.title = title
        properties.artist = artist
        properties.albumTitle = album
        properties.albumArtist = text(5)
        properties.contentType = "music"

        // Music reports a duration in seconds, Spotify in milliseconds. Both
        // report the position in seconds.
        let rawDuration = double(descriptor.atIndex(7))
        let identity = text(8)
        let status = text(1).lowercased()
        // Music has no artwork URL and its script returns an empty string
        // there. `URL(string: "")` is not nil — it is an empty relative URL —
        // and taking it would send this track down the download path and
        // silently skip Music's own cover.
        let artwork = text(9).trimmingCharacters(in: .whitespacesAndNewlines)

        return AppleScriptNowPlaying(
            player: player,
            playback: status.contains("play")
                ? .playing : status.contains("pause") ? .paused : .stopped,
            properties: properties,
            position: double(descriptor.atIndex(6)),
            duration: player == .spotify ? rawDuration.map { $0 / 1000 } : rawDuration,
            // Namespaced by player so switching apps always counts as a new
            // track, even when two players agree on an identifier.
            trackIdentity: identity.isEmpty ? "" : "\(player.rawValue)\u{1F}\(identity)",
            artworkURL: artwork.isEmpty ? nil : URL(string: artwork))
    }

    private nonisolated static func double(_ descriptor: NSAppleEventDescriptor?) -> Double? {
        guard let descriptor else { return nil }
        if let text = descriptor.stringValue, let parsed = Double(text) { return parsed }
        if descriptor.data.count == MemoryLayout<Double>.size {
            return descriptor.data.withUnsafeBytes { $0.load(as: Double.self) }
        }
        if descriptor.data.count == MemoryLayout<Float>.size {
            return Double(descriptor.data.withUnsafeBytes { $0.load(as: Float.self) })
        }
        let number = descriptor.int32Value
        return number == 0 ? nil : Double(number)
    }

    // MARK: - Sources

    /// Addressed by bundle identifier and only ever sent to a running player,
    /// so no query here can launch an application.
    ///
    /// Every optional field is read inside its own `try`: `album artist`,
    /// `artwork url` and the track identifier exist in some versions of these
    /// applications and not others, and one missing property must not cost the
    /// title and artist next to it.
    private nonisolated static func stateSource(for player: AppleScriptPlayer) -> String {
        let identity = player == .music ? "(database ID of t) as text" : "(id of t) as text"
        let artworkURL = player == .spotify ? "set u to (artwork url of t) as text" : ""
        return """
            tell application id "\(player.bundleIdentifier)"
              if player state is stopped then return {}
              set t to current track
              set a to ""
              try
                set a to (album artist of t) as text
              end try
              set i to ""
              try
                set i to \(identity)
              end try
              set u to ""
              try
                \(artworkURL)
              end try
              return {player state as text, (name of t) as text, (artist of t) as text, \
            (album of t) as text, a, player position, duration of t, i, u}
            end tell
            """
    }

    /// Cover bytes are asked for on their own, and only when the track changed:
    /// a megabyte of artwork in every one-second poll would be the most
    /// expensive thing this provider does.
    private nonisolated static let musicArtworkSource = """
        tell application id "com.apple.Music"
          if player state is stopped then return ""
          set t to current track
          try
            if (count of artworks of t) is 0 then return ""
            return raw data of artwork 1 of t
          on error
            return ""
          end try
        end tell
        """
}

/// Compiled scripts by source text. The sources are a fixed handful (one state query
/// per player, the cover query and three transport commands), so it never grows past
/// them. A source that fails to compile is not kept, and is compiled again next time,
/// as it was before scripts were kept. Not thread safe: its owner calls it from one
/// serial queue.
final class AppleScriptCache<Script>: @unchecked Sendable {
    private let compile: (String) -> Script?
    private var compiled: [String: Script] = [:]

    init(compile: @escaping (String) -> Script?) {
        self.compile = compile
    }

    func script(for source: String) -> Script? {
        if let script = compiled[source] { return script }
        guard let script = compile(source) else { return nil }
        compiled[source] = script
        return script
    }
}
