import XCTest

@testable import WallpaperMachine

@MainActor
final class FallbackSystemMediaProviderTests: XCTestCase {
    func testAdapterIsPreferredWhenItAnswers() {
        let primary = RecordingSystemMediaProvider(availability: .available)
        let fallback = RecordingSystemMediaProvider(availability: .available)
        let scheduler = ManualMediaTimerScheduler()
        let provider = FallbackSystemMediaProvider(
            primary: primary, fallback: fallback, scheduler: scheduler, probeTimeout: 2)

        provider.addConsumer()
        scheduler.fireDelayed()

        XCTAssertEqual(primary.addCount, 1)
        XCTAssertEqual(fallback.addCount, 0, "AppleScript must stay dark while the adapter answers")
        if case .available = provider.availability {
        } else {
            XCTFail("A working adapter must remain available")
        }
    }

    func testUnansweredAdapterFallsBackAfterTheProbe() {
        let primary = RecordingSystemMediaProvider(
            availability: .unavailable(
                reason: MediaRemoteUnavailable(code: .notStarted).localizedDescription))
        var track = SystemMediaProperties()
        track.title = "From Music"
        let fallback = RecordingSystemMediaProvider(availability: .available)
        fallback.properties = track
        let scheduler = ManualMediaTimerScheduler()
        var received: [SystemMediaProperties] = []
        let provider = FallbackSystemMediaProvider(
            primary: primary, fallback: fallback, scheduler: scheduler, probeTimeout: 2)
        provider.onPropertiesChanged = { received.append($0) }

        provider.addConsumer()
        XCTAssertEqual(fallback.addCount, 0, "The fallback waits for the adapter probe")
        scheduler.fireDelayed()

        XCTAssertEqual(primary.addCount, 1)
        XCTAssertEqual(primary.removeCount, 1)
        XCTAssertEqual(fallback.addCount, 1)
        fallback.emitProperties()
        XCTAssertEqual(received, [track])
    }

    func testBothSourcesEmptyStayUnavailableAndInventNothing() {
        let primary = RecordingSystemMediaProvider(
            availability: .unavailable(reason: "The system media service is unavailable."))
        let fallback = RecordingSystemMediaProvider(
            availability: .unavailable(reason: "Neither Music nor Spotify reported what is playing."))
        let scheduler = ManualMediaTimerScheduler()
        var properties: [SystemMediaProperties] = []
        let provider = FallbackSystemMediaProvider(
            primary: primary, fallback: fallback, scheduler: scheduler, probeTimeout: 2)
        provider.onPropertiesChanged = { properties.append($0) }

        provider.addConsumer()
        scheduler.fireDelayed()

        XCTAssertEqual(fallback.addCount, 1)
        XCTAssertTrue(properties.isEmpty, "An empty source must not invent a track")
        guard case let .unavailable(reason) = provider.availability else {
            return XCTFail("Two empty sources are still unavailable")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    /// The panel asks this while the wallpaper runs. A player the user starts
    /// minutes after the switch has to change the answer.
    func testAvailabilityFollowsTheLiveSourceAfterTheSwitch() {
        let primary = RecordingSystemMediaProvider(
            availability: .unavailable(
                reason: MediaRemoteUnavailable(code: .notStarted).localizedDescription))
        let fallback = RecordingSystemMediaProvider(
            availability: .unavailable(reason: "No music player this app can read is running."))
        let scheduler = ManualMediaTimerScheduler()
        let provider = FallbackSystemMediaProvider(
            primary: primary, fallback: fallback, scheduler: scheduler, probeTimeout: 2)

        provider.addConsumer()
        scheduler.fireDelayed()
        XCTAssertEqual(fallback.addCount, 1)
        guard case .unavailable = provider.availability else {
            return XCTFail("No player is running yet")
        }

        fallback.availability = .available
        guard case .available = provider.availability else {
            return XCTFail("A player that started later must be reported as available")
        }

        provider.removeConsumer()
        guard case .unavailable = provider.availability else {
            return XCTFail("Nothing is watched once the last consumer is gone")
        }
    }
}

@MainActor
final class AppleScriptMediaProviderTests: XCTestCase {
    func testUnavailableWithdrawsTrackCoverAndControlsThenRecovers() async throws {
        let runner = FakeAppleScriptRunner()
        runner.running = [.music]
        runner.answers[.music] = Self.track(.music, title: "Old track", durationSeconds: 100)
        runner.artwork = try makeSolidPNG(200, 40, 40)
        let scheduler = ManualMediaTimerScheduler()
        let provider = AppleScriptMediaProvider(runner: runner, scheduler: scheduler)
        var titles: [String] = []
        var covers: [SystemMediaThumbnail] = []
        var states: [SystemMediaPlaybackState] = []
        var timelines: [SystemMediaTimeline?] = []
        provider.onPropertiesChanged = { titles.append($0.title) }
        provider.onThumbnailChanged = { covers.append($0) }
        provider.onPlaybackChanged = { states.append($0) }
        provider.onTimelineChanged = { timelines.append($0) }
        provider.addConsumer()
        defer { provider.removeConsumer() }
        try await poll { covers.count == 1 }
        runner.answers[.music] = nil
        try await poll(after: { scheduler.fireRepeating() }) { titles.last == "" }
        XCTAssertEqual(covers.last, .empty)
        XCTAssertEqual(states.last, .stopped)
        XCTAssertNil(timelines.last!)
        let controlled = await provider.send(.nextTrack)
        XCTAssertFalse(controlled)
        XCTAssertTrue(runner.controls.isEmpty)
        titles.removeAll()
        provider.replayCurrentState()
        XCTAssertTrue(titles.isEmpty)
        runner.answers[.music] = Self.track(.music, title: "Recovered", durationSeconds: 100)
        try await poll(after: { scheduler.fireRepeating() }) { titles == ["Recovered"] && covers.count == 3 }
        XCTAssertEqual(runner.artworkFetches, 2, "Recovery must reacquire the cover even for the same ID")
        runner.running = []
        let afterExit = await provider.send(.nextTrack)
        XCTAssertFalse(afterExit)
        XCTAssertEqual(titles.last, "")
        XCTAssertTrue(runner.controls.isEmpty)
    }

    func testTrackWithoutArtworkClearsPreviousCover() async throws {
        let runner = FakeAppleScriptRunner()
        runner.running = [.music]
        runner.answers[.music] = Self.track(.music, title: "Covered", durationSeconds: 100)
        runner.artwork = try makeSolidPNG(200, 40, 40)
        let scheduler = ManualMediaTimerScheduler()
        let provider = AppleScriptMediaProvider(runner: runner, scheduler: scheduler)
        var covers: [SystemMediaThumbnail] = []
        provider.onThumbnailChanged = { covers.append($0) }
        provider.addConsumer()
        defer { provider.removeConsumer() }
        try await poll { covers.count == 1 }
        var next = Self.track(.music, title: "No cover", durationSeconds: 100)
        next.trackIdentity = "music\u{1F}2"
        runner.answers[.music] = next
        runner.artwork = nil
        try await poll(after: { scheduler.fireRepeating() }) { covers.count == 2 }
        XCTAssertEqual(covers.last, .empty)
    }

    /// A wallpaper must never start the user's music player, and asking an
    /// application that is not running over Apple Events does exactly that.
    func testOnlyRunningPlayersAreContacted() async throws {
        let runner = FakeAppleScriptRunner()
        runner.running = [.spotify]
        runner.answers[.spotify] = Self.track(.spotify, title: "Spotify track", durationSeconds: 200)
        let scheduler = ManualMediaTimerScheduler()
        let provider = AppleScriptMediaProvider(runner: runner, scheduler: scheduler)

        provider.addConsumer()
        try await poll { runner.queries[.spotify] == 1 }

        XCTAssertNil(runner.queries[.music], "Music was not running and must not be contacted")
    }

    func testFirstAnsweringPlayerWins() async throws {
        let runner = FakeAppleScriptRunner()
        runner.running = [.music, .spotify]
        runner.answers[.spotify] = Self.track(.spotify, title: "Spotify track", durationSeconds: 200)
        var titles: [String] = []
        let scheduler = ManualMediaTimerScheduler()
        let provider = AppleScriptMediaProvider(runner: runner, scheduler: scheduler)
        provider.onPropertiesChanged = { titles.append($0.title) }

        provider.addConsumer()
        try await poll { titles == ["Spotify track"] }

        XCTAssertEqual(runner.queries[.music], 1, "A silent Music is asked before Spotify")
        runner.answers[.music] = Self.track(.music, title: "Music track", durationSeconds: 90)
        runner.answers[.spotify] = nil
        try await poll(after: { scheduler.fireRepeating() }) { titles.count == 2 }

        XCTAssertEqual(titles.last, "Music track")
        XCTAssertEqual(runner.queries[.spotify], 1, "Music answering means Spotify is not asked")
    }

    /// Spotify reports a track length in milliseconds and a position in
    /// seconds; a wallpaper drawing a progress bar from both would be off by
    /// three orders of magnitude. Music reports both in seconds.
    func testPlayerDurationUnitsAreNormalisedToSeconds() throws {
        let reply = Self.reply(
            state: "playing", name: "Long one", artist: "Queen", album: "Opera",
            albumArtist: "Queen", position: 71.5, duration: 354_000, identity: "spotify:1",
            artworkURL: "https://i.example/cover.jpg")

        let spotify = try XCTUnwrap(
            NSAppleScriptNowPlayingRunner.parse(reply, player: .spotify))
        XCTAssertEqual(spotify.duration, 354)
        XCTAssertEqual(spotify.position, 71.5)
        XCTAssertEqual(spotify.properties.title, "Long one")
        XCTAssertEqual(spotify.properties.albumArtist, "Queen")
        XCTAssertEqual(spotify.artworkURL?.absoluteString, "https://i.example/cover.jpg")
        XCTAssertEqual(
            spotify.trackIdentity, "spotify\u{1F}spotify:1",
            "the identity is namespaced so switching players counts as a new track")

        let music = try XCTUnwrap(NSAppleScriptNowPlayingRunner.parse(reply, player: .music))
        XCTAssertEqual(music.duration, 354_000, "Music already reports seconds")
    }

    /// Music's script has no artwork URL to report and returns an empty string
    /// in that field. `URL(string: "")` is not nil, so an unguarded parse
    /// hands back a URL, the provider takes the download path, and Music's own
    /// cover is never read.
    func testMusicReportsNoArtworkURLSoItsOwnCoverIsUsed() async throws {
        let reply = Self.reply(
            state: "playing", name: "Track", artist: "Someone", album: "LP",
            albumArtist: "Someone", position: 3, duration: 180, identity: "4321",
            artworkURL: "")
        let music = try XCTUnwrap(NSAppleScriptNowPlayingRunner.parse(reply, player: .music))
        XCTAssertNil(music.artworkURL)

        let runner = FakeAppleScriptRunner()
        runner.running = [.music]
        runner.answers[.music] = music
        runner.artwork = try makeSolidPNG(200, 40, 40)
        var covers: [SystemMediaThumbnail] = []
        let provider = AppleScriptMediaProvider(
            runner: runner, scheduler: ManualMediaTimerScheduler())
        provider.onThumbnailChanged = { covers.append($0) }

        provider.addConsumer()
        try await poll { covers.count == 1 }

        XCTAssertEqual(
            runner.appleEventArtworkFetches, 1,
            "Music's cover is read over Apple Events, not downloaded")
        XCTAssertEqual(runner.urlArtworkFetches, 0)
    }

    /// A player with nothing loaded answers with an empty list; that is not a
    /// track with empty fields.
    func testEmptyReplyIsNotATrack() {
        let empty = NSAppleEventDescriptor.list()
        XCTAssertNil(NSAppleScriptNowPlayingRunner.parse(empty, player: .music))
        XCTAssertNil(NSAppleScriptNowPlayingRunner.parse(nil, player: .music))
    }

    /// Cover art is the one expensive thing either player can be asked for.
    func testArtworkIsLoadedOncePerTrack() async throws {
        let runner = FakeAppleScriptRunner()
        runner.running = [.music]
        runner.answers[.music] = Self.track(.music, title: "First", durationSeconds: 100)
        runner.artwork = try makeSolidPNG(200, 40, 40)
        var covers: [SystemMediaThumbnail] = []
        let scheduler = ManualMediaTimerScheduler()
        let provider = AppleScriptMediaProvider(runner: runner, scheduler: scheduler)
        provider.onThumbnailChanged = { covers.append($0) }

        provider.addConsumer()
        try await poll { covers.count == 1 }

        try await poll(after: { scheduler.fireRepeating() }) { runner.queries[.music] == 2 }
        XCTAssertEqual(runner.artworkFetches, 1, "The same track must not be re-fetched")

        var next = Self.track(.music, title: "Second", durationSeconds: 100)
        next.trackIdentity = "music\u{1F}2"
        runner.answers[.music] = next
        runner.artwork = try makeSolidPNG(40, 200, 40)
        try await poll(after: { scheduler.fireRepeating() }) { runner.artworkFetches == 2 }
        XCTAssertEqual(covers.count, 2, "A new track publishes its own cover")
    }

    /// The fallback asks once a second; compiling its script (parsing it and loading the
    /// player's scripting terminology) happens once per script, not once per question.
    /// The compiler stands in a script that contacts no application.
    func testEachScriptIsCompiledOnceHoweverOftenItRuns() async {
        let compiled = CompiledSources()
        let runner = NSAppleScriptNowPlayingRunner { source in
            compiled.record(source)
            return NSAppleScriptNowPlayingRunner.compile("return {}")
        }
        for _ in 0..<5 {
            let answer = await runner.query(.music)
            XCTAssertNil(answer, "an empty reply is not a track")
        }
        _ = await runner.query(.spotify)
        _ = await runner.query(.music)
        XCTAssertEqual(compiled.counts.count, 2, "one script per player")
        XCTAssertEqual(Set(compiled.counts.values), [1], "each compiled once: \(compiled.counts)")
    }

    /// A script that does not compile is not kept: the next question compiles it again,
    /// as every question did before scripts were kept.
    func testAScriptThatDidNotCompileIsCompiledAgain() {
        var attempts = 0
        let cache = AppleScriptCache<Int> { _ in
            attempts += 1
            return attempts < 3 ? nil : attempts
        }
        XCTAssertNil(cache.script(for: "a"))
        XCTAssertNil(cache.script(for: "a"))
        XCTAssertEqual(cache.script(for: "a"), 3)
        XCTAssertEqual(cache.script(for: "a"), 3)
        XCTAssertEqual(attempts, 3)
    }

    private static func track(
        _ player: AppleScriptPlayer, title: String, durationSeconds: Double
    ) -> AppleScriptNowPlaying {
        var properties = SystemMediaProperties()
        properties.title = title
        properties.artist = "Someone"
        properties.albumTitle = "LP"
        return AppleScriptNowPlaying(
            player: player, playback: .playing, properties: properties, position: 12,
            duration: durationSeconds, trackIdentity: "\(player.rawValue)\u{1F}1")
    }

    /// The reply list both scripts return, in the order they build it.
    private static func reply(
        state: String, name: String, artist: String, album: String, albumArtist: String,
        position: Double, duration: Double, identity: String, artworkURL: String
    ) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, text) in [state, name, artist, album, albumArtist].enumerated() {
            list.insert(NSAppleEventDescriptor(string: text), at: index + 1)
        }
        list.insert(NSAppleEventDescriptor(double: position), at: 6)
        list.insert(NSAppleEventDescriptor(double: duration), at: 7)
        list.insert(NSAppleEventDescriptor(string: identity), at: 8)
        list.insert(NSAppleEventDescriptor(string: artworkURL), at: 9)
        return list
    }

    /// Waits for work the provider does in its own task rather than sleeping
    /// for a guessed interval.
    private func poll(
        after start: () -> Void = {}, timeout: TimeInterval = 2,
        until condition: () -> Bool
    ) async throws {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition not reached within \(timeout)s") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
final class RecordingSystemMediaProvider: SystemMediaProvider {
    var availability: SystemMediaAvailability
    var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?
    var properties = SystemMediaProperties()
    private(set) var addCount = 0
    private(set) var removeCount = 0

    init(availability: SystemMediaAvailability) {
        self.availability = availability
    }

    func addConsumer() { addCount += 1 }
    func removeConsumer() { removeCount += 1 }
    func replayCurrentState() {}
    func emitProperties() { onPropertiesChanged?(properties) }

    /// Commands this provider was asked to carry out, in order.
    private(set) var commands: [SystemMediaCommand] = []
    func send(_ command: SystemMediaCommand) async -> Bool {
        commands.append(command)
        return true
    }
}

@MainActor
final class FakeAppleScriptRunner: AppleScriptRunning {
    var running: [AppleScriptPlayer] = []
    var answers: [AppleScriptPlayer: AppleScriptNowPlaying] = [:]
    var artwork: Data?
    private(set) var queries: [AppleScriptPlayer: Int] = [:]
    private(set) var appleEventArtworkFetches = 0
    private(set) var urlArtworkFetches = 0
    var artworkFetches: Int { appleEventArtworkFetches + urlArtworkFetches }

    func runningPlayers() -> [AppleScriptPlayer] { running }

    /// Players told to do something, and what.
    private(set) var controls: [(AppleScriptPlayer, SystemMediaCommand)] = []
    var acceptsControl = true
    func control(_ player: AppleScriptPlayer, _ command: SystemMediaCommand) async -> Bool {
        controls.append((player, command))
        return acceptsControl
    }

    func query(_ player: AppleScriptPlayer) async -> AppleScriptNowPlaying? {
        queries[player, default: 0] += 1
        return answers[player]
    }

    func fetchArtwork(from player: AppleScriptPlayer) async -> Data? {
        appleEventArtworkFetches += 1
        return artwork
    }

    func fetchArtwork(at url: URL) async -> Data? {
        urlArtworkFetches += 1
        return artwork
    }
}

/// Sources a script runner compiled, counted on whatever queue it compiles on.
final class CompiledSources: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String: Int] = [:]

    func record(_ source: String) { lock.withLock { recorded[source, default: 0] += 1 } }
    var counts: [String: Int] { lock.withLock { recorded } }
}
