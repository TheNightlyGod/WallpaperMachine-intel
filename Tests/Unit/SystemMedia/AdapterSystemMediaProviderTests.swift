import XCTest
@testable import WallpaperMachine

@MainActor
private final class TestMediaStream: SystemMediaStreaming {
    var receive: ((Data) -> Void)?
    var ended: (() -> Void)?
    var starts = 0
    var stops = 0
    func start(receive: @escaping (Data) -> Void, ended: @escaping () -> Void) throws {
        starts += 1
        self.receive = receive
        self.ended = ended
    }
    func stop() { stops += 1 }
    /// Transport commands this stream was asked to carry out, in order.
    private(set) var commands: [Int] = []
    var acceptsCommands = true
    var snapshotRequests = 0
    var snapshotData: Data?
    var holdSnapshot = false
    var snapshotContinuation: CheckedContinuation<Data?, Never>?
    var onSnapshot: (() -> Void)?
    func snapshot() async -> Data? {
        snapshotRequests += 1
        onSnapshot?()
        if holdSnapshot {
            return await withCheckedContinuation { snapshotContinuation = $0 }
        }
        return snapshotData
    }
    func send(command: Int) async -> Bool {
        commands.append(command)
        return acceptsCommands
    }
    func send(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": payload])
        data.append(10)
        receive?(data)
    }
}

final class AdapterSystemMediaProviderTests: XCTestCase {
    @MainActor
    func testFragmentedMessagesDeliverMetadataAndInterpolateTimeline() throws {
        let stream = TestMediaStream()
        let timer = ManualMediaTimerScheduler()
        var now = Date(timeIntervalSince1970: 100)
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: timer, now: { now })
        var properties: SystemMediaProperties?
        var timeline: SystemMediaTimeline?
        provider.onPropertiesChanged = { properties = $0 }
        provider.onTimelineChanged = { timeline = $0 }
        XCTAssertEqual(stream.starts, 0)
        provider.addConsumer()
        let line = Data("{\"type\":\"data\",\"diff\":false,\"payload\":{\"title\":\"Track\",\"artist\":\"Artist\",\"playing\":true,\"duration\":120,\"elapsedTime\":10,\"timestamp\":100}}\n".utf8)
        stream.receive?(line.prefix(35))
        XCTAssertNil(properties)
        stream.receive?(line.dropFirst(35))
        XCTAssertEqual(properties?.title, "Track")
        XCTAssertEqual(properties?.artist, "Artist")
        XCTAssertEqual(timeline?.position, 10)
        now.addTimeInterval(5)
        timer.fireRepeating()
        XCTAssertEqual(timeline?.position, 15)
        try stream.send(["title": "Track", "playing": false])
        XCTAssertNil(timeline)
        XCTAssertTrue(timer.liveRepeating.isEmpty)
        provider.removeConsumer()
    }

    @MainActor
    func testTrackChangeWithoutArtworkAndEmptyPlayerClearPreviousData() throws {
        let stream = TestMediaStream()
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: ManualMediaTimerScheduler())
        var covers: [String] = []
        var title = ""
        var playback = SystemMediaPlaybackState.stopped
        provider.onThumbnailChanged = { covers.append($0.pngBase64DataURL) }
        provider.onPropertiesChanged = { title = $0.title }
        provider.onPlaybackChanged = { playback = $0 }
        provider.addConsumer()
        let png = try makeSyntheticPNG(width: 2, height: 2) { _, _ in (255, 0, 0) }
        try stream.send(["title": "First", "playing": true, "artworkData": png.base64EncodedString()])
        XCTAssertTrue(covers.last?.hasPrefix("data:image/png;base64,") == true)
        try stream.send(["title": "First", "playing": true, "artworkData": ""])
        XCTAssertEqual(covers.last, "", "An explicit withdrawal clears artwork even before the title changes")
        provider.replayCurrentState()
        XCTAssertEqual(covers.last, "")
        try stream.send(["title": "First", "playing": true, "artworkData": png.base64EncodedString()])
        XCTAssertTrue(covers.last?.hasPrefix("data:image/png;base64,") == true)
        try stream.send(["title": "Second", "playing": true])
        XCTAssertEqual(covers.last, "")
        try stream.send([:])
        XCTAssertEqual(title, "")
        XCTAssertEqual(playback, .stopped)
        provider.removeConsumer()
    }

    @MainActor
    func testLastConsumerStopsStreamAndLateCallbacksCannotReviveIt() throws {
        let stream = TestMediaStream()
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: ManualMediaTimerScheduler())
        var titles: [String] = []
        provider.onPropertiesChanged = { titles.append($0.title) }
        provider.addConsumer()
        provider.addConsumer()
        XCTAssertEqual(stream.starts, 1)
        provider.removeConsumer()
        XCTAssertEqual(stream.stops, 0)
        provider.removeConsumer()
        XCTAssertEqual(stream.stops, 1)
        try stream.send(["title": "Late", "playing": true])
        XCTAssertTrue(titles.isEmpty)
    }

    @MainActor
    func testRepeatedArtworkKeepsPlaybackAndTimelineUpdates() throws {
        let stream = TestMediaStream()
        let timer = ManualMediaTimerScheduler()
        var now = Date(timeIntervalSince1970: 100)
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: timer, now: { now })
        let coverA = try makeSyntheticPNG(width: 2, height: 2) { _, _ in (255, 0, 0) }.base64EncodedString()
        let coverB = try makeSyntheticPNG(width: 2, height: 2) { _, _ in (0, 0, 255) }.base64EncodedString()
        var covers: [SystemMediaThumbnail] = []
        var playback: [SystemMediaPlaybackState] = []
        var properties: SystemMediaProperties?
        var timeline: SystemMediaTimeline?
        provider.onThumbnailChanged = { covers.append($0) }
        provider.onPlaybackChanged = { playback.append($0) }
        provider.onPropertiesChanged = { properties = $0 }
        provider.onTimelineChanged = { timeline = $0 }
        provider.addConsumer()
        defer { provider.removeConsumer() }

        try stream.send(["title": "One", "playing": true, "artworkData": coverA,
                         "duration": 120, "elapsedTime": 10, "timestamp": 100])
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(timeline?.position, 10)
        try stream.send(["title": "One", "artist": "Artist", "playing": false, "artworkData": coverA,
                         "duration": 120, "elapsedTime": 20, "timestamp": 100])
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(properties?.artist, "Artist")
        XCTAssertEqual(playback, [.playing, .paused])
        XCTAssertNil(timeline)
        XCTAssertTrue(timer.liveRepeating.isEmpty)

        try stream.send(["title": "One", "artist": "Artist", "playing": true, "artworkData": coverA,
                         "duration": 180, "elapsedTime": 30, "timestamp": 98, "playbackRate": 2])
        XCTAssertEqual(timeline, SystemMediaTimeline(position: 34, duration: 180))
        now.addTimeInterval(1)
        timer.fireRepeating()
        XCTAssertEqual(timeline?.position, 36)
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(playback, [.playing, .paused, .playing])

        provider.addConsumer()
        provider.replayCurrentState()
        XCTAssertEqual(covers.count, 2)
        XCTAssertEqual(covers[0], covers[1])
        XCTAssertEqual(timeline?.position, 36)
        XCTAssertEqual(playback.last, .playing)
        provider.removeConsumer()
        try stream.send(["title": "One", "artist": "Artist", "playing": true, "artworkData": coverB,
                         "duration": 180, "elapsedTime": 40, "timestamp": 101])
        XCTAssertEqual(covers.count, 3)
        XCTAssertNotEqual(covers.first, covers.last)
        XCTAssertEqual(timeline?.position, 40)
    }

    @MainActor
    func testArtworkReturnsAfterClearWithoutCrossingStreamGeneration() throws {
        let stream = TestMediaStream()
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: ManualMediaTimerScheduler())
        let coverA = try makeSyntheticPNG(width: 2, height: 2) { _, _ in (255, 0, 0) }.base64EncodedString()
        var covers: [String] = []
        var title = ""
        provider.onThumbnailChanged = { covers.append($0.pngBase64DataURL) }
        provider.onPropertiesChanged = { title = $0.title }
        provider.addConsumer()
        try stream.send(["title": "One", "playing": true, "artworkData": coverA])
        let first = try XCTUnwrap(covers.last)
        XCTAssertTrue(first.hasPrefix("data:image/png;base64,"))
        try stream.send(["title": "One", "playing": true])
        XCTAssertEqual(covers, [first], "Same-track artwork omission retains the published cover")
        try stream.send(["title": "Two", "playing": true])
        XCTAssertEqual(covers, [first, ""])
        try stream.send(["title": "Two", "playing": true, "artworkData": coverA])
        XCTAssertEqual(covers, [first, "", first])

        let oldReceive = try XCTUnwrap(stream.receive)
        let oldEnded = try XCTUnwrap(stream.ended)
        var stale = try JSONSerialization.data(withJSONObject: ["type": "data", "diff": false,
            "payload": ["title": "Old generation", "playing": true, "artworkData": coverA]])
        stale.append(10)
        provider.removeConsumer()
        provider.addConsumer()
        defer { provider.removeConsumer() }
        provider.replayCurrentState()
        XCTAssertEqual(title, "")
        XCTAssertEqual(covers, [first, "", first], "A new stream must not replay the previous cover")
        oldReceive(stale)
        oldEnded()
        XCTAssertEqual(title, "")
        XCTAssertEqual(covers, [first, "", first])

        for _ in 0..<2 {
            try stream.send(["title": "Three", "playing": true, "artworkData": "not-base64!"])
        }
        XCTAssertEqual(covers.last, "")
        try stream.send(["title": "Three", "playing": true, "artworkData": coverA])
        XCTAssertEqual(covers, [first, "", first, "", first])
        oldReceive(stale)
        oldEnded()
        XCTAssertEqual(title, "Three")
        XCTAssertEqual(covers.last, first)
        XCTAssertEqual(provider.availability, .available)
        stream.ended?()
        provider.replayCurrentState()
        XCTAssertEqual(covers.last, "")
        XCTAssertEqual(title, "")
    }

    @MainActor
    func testUnexpectedExitClearsStateAndReportsUnavailableWithoutRestartLoop() throws {
        let stream = TestMediaStream()
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: ManualMediaTimerScheduler())
        var title = ""
        provider.onPropertiesChanged = { title = $0.title }
        provider.addConsumer()
        try stream.send(["title": "Playing", "playing": true])
        stream.ended?()
        XCTAssertEqual(title, "")
        guard case .unavailable = provider.availability else { return XCTFail("exit must report unavailable") }
        XCTAssertEqual(stream.starts, 1)
        provider.removeConsumer()
    }
}

@MainActor
final class SystemMediaRecoveryTests: XCTestCase {
    private func payload(_ title: String, elapsed: Double = 0, timestamp: Double = 100,
                         playing: Bool = true, duration: Double = 10) -> [String: Any] {
        ["title": title, "artist": "Artist", "album": "Album", "contentItemIdentifier": title,
         "processIdentifier": 123, "playing": playing, "duration": duration,
         "elapsedTime": elapsed, "timestamp": timestamp, "playbackRate": playing ? 1 : 0]
    }

    func testMissedTrackChangeRecoversFromSystemWithoutPollingDuringNormalPlayback() async throws {
        let stream = TestMediaStream()
        let timer = ManualMediaTimerScheduler()
        var now = Date(timeIntervalSince1970: 100)
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: timer, now: { now })
        let recovered = expectation(description: "second track delivered without its stream event")
        var title = ""
        var position: Double?
        var covers: [String] = []
        provider.onThumbnailChanged = { covers.append($0.pngBase64DataURL) }
        provider.onPropertiesChanged = { value in
            title = value.title
            if title == "Second" { recovered.fulfill() }
        }
        provider.onTimelineChanged = { position = $0?.position }
        provider.addConsumer()
        defer { provider.removeConsumer() }
        var first = payload("First")
        first["artworkData"] = try makeSyntheticPNG(width: 2, height: 2) { _, _ in (255, 0, 0) }.base64EncodedString()
        try stream.send(first)
        now = Date(timeIntervalSince1970: 109)
        timer.fireRepeating()
        await Task.yield()
        XCTAssertEqual(stream.snapshotRequests, 0)
        XCTAssertEqual(title, "First")
        var second = payload("Second", timestamp: 110)
        second["artworkData"] = try makeSyntheticPNG(width: 2, height: 2) { _, _ in (0, 0, 255) }.base64EncodedString()
        stream.snapshotData = try JSONSerialization.data(withJSONObject: second)
        now = Date(timeIntervalSince1970: 113)
        timer.fireRepeating()
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(title, "Second")
        XCTAssertEqual(position, 3)
        XCTAssertEqual(covers.count, 2)
        XCTAssertNotEqual(covers.first, covers.last)
        XCTAssertEqual(stream.snapshotRequests, 1)
    }

    func testLateRecoveryCannotReplaceNewerStreamMetadataOrReviveStoppedSubscription() async throws {
        let stream = TestMediaStream()
        stream.holdSnapshot = true
        let timer = ManualMediaTimerScheduler()
        var now = Date(timeIntervalSince1970: 100)
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: timer, now: { now })
        var title = ""
        provider.onPropertiesChanged = { title = $0.title }
        provider.addConsumer()
        try stream.send(payload("First"))
        let requested = expectation(description: "snapshot held")
        stream.onSnapshot = { requested.fulfill() }
        now = Date(timeIntervalSince1970: 113)
        timer.fireRepeating()
        await fulfillment(of: [requested], timeout: 2)
        try stream.send(payload("Third", timestamp: 112))
        stream.snapshotContinuation?.resume(returning: try JSONSerialization.data(withJSONObject: payload("Second", timestamp: 110)))
        stream.snapshotContinuation = nil
        await Task.yield()
        provider.replayCurrentState()
        XCTAssertEqual(title, "Third")

        let secondRequest = expectation(description: "next boundary query held")
        stream.onSnapshot = { secondRequest.fulfill() }
        now = Date(timeIntervalSince1970: 125)
        timer.fireRepeating()
        await fulfillment(of: [secondRequest], timeout: 2)
        provider.removeConsumer()
        provider.addConsumer()
        defer { provider.removeConsumer() }
        stream.snapshotContinuation?.resume(returning: try JSONSerialization.data(withJSONObject: payload("Old subscription")))
        stream.snapshotContinuation = nil
        await Task.yield()
        provider.replayCurrentState()
        XCTAssertEqual(title, "")
        XCTAssertTrue(timer.liveRepeating.isEmpty)
    }

    func testStaleOrFailedSnapshotHasOnlyOneBoundedRetry() async throws {
        let stream = TestMediaStream()
        let timer = ManualMediaTimerScheduler()
        var now = Date(timeIntervalSince1970: 100)
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: timer, now: { now })
        provider.addConsumer()
        defer { provider.removeConsumer() }
        try stream.send(payload("First"))
        stream.snapshotData = try JSONSerialization.data(withJSONObject: payload("First"))
        let firstRequest = expectation(description: "first stale snapshot")
        stream.onSnapshot = { firstRequest.fulfill() }
        now = Date(timeIntervalSince1970: 113)
        timer.fireRepeating()
        await fulfillment(of: [firstRequest], timeout: 2)
        await Task.yield()
        now = Date(timeIntervalSince1970: 114)
        timer.fireRepeating()
        await Task.yield()
        XCTAssertEqual(stream.snapshotRequests, 1)
        let retry = expectation(description: "one recovery retry")
        stream.onSnapshot = { retry.fulfill() }
        stream.snapshotData = Data("invalid JSON".utf8)
        now = Date(timeIntervalSince1970: 119)
        timer.fireRepeating()
        await fulfillment(of: [retry], timeout: 2)
        await Task.yield()
        for second in 120...140 {
            now = Date(timeIntervalSince1970: Double(second))
            try stream.send(payload("First"))
            timer.fireRepeating()
            await Task.yield()
        }
        XCTAssertEqual(stream.snapshotRequests, 2, "a silent or wedged source must not cause indefinite polling")
    }

    func testRecoveryWithdrawsMetadataWhenSystemHasNoPlayer() async throws {
        let stream = TestMediaStream()
        let timer = ManualMediaTimerScheduler()
        var now = Date(timeIntervalSince1970: 100)
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: timer, now: { now })
        var title = ""
        var playback = SystemMediaPlaybackState.stopped
        var timeline: SystemMediaTimeline?
        provider.onPropertiesChanged = { title = $0.title }
        provider.onPlaybackChanged = { playback = $0 }
        provider.onTimelineChanged = { timeline = $0 }
        provider.addConsumer()
        defer { provider.removeConsumer() }
        try stream.send(payload("First"))
        let cleared = expectation(description: "stopped session withdrawn")
        provider.onPropertiesChanged = { value in title = value.title; if title.isEmpty { cleared.fulfill() } }
        stream.snapshotData = Data("{}".utf8)
        now = Date(timeIntervalSince1970: 113)
        timer.fireRepeating()
        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertEqual(title, "")
        XCTAssertEqual(playback, .stopped)
        XCTAssertNil(timeline)
        XCTAssertTrue(timer.liveRepeating.isEmpty)
    }

    func testPauseUnknownDurationAndNoConsumersDoNotQuery() async throws {
        let stream = TestMediaStream()
        let timer = ManualMediaTimerScheduler()
        var now = Date(timeIntervalSince1970: 100)
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: timer, now: { now })
        provider.addConsumer()
        try stream.send(payload("Paused", playing: false))
        now = Date(timeIntervalSince1970: 1000)
        timer.fireRepeating()
        try stream.send(payload("Live", duration: 0))
        timer.fireRepeating()
        provider.removeConsumer()
        timer.fireRepeating()
        await Task.yield()
        XCTAssertEqual(stream.snapshotRequests, 0)
        XCTAssertTrue(timer.liveRepeating.isEmpty)
    }
}

@MainActor
final class SystemMediaTransportTests: XCTestCase {
    /// The wallpaper's user binds a button to an action; this is the only
    /// place the action becomes a MediaRemote command, so the mapping has to
    /// be the one the adapter's own header documents.
    func testBoundActionsReachTheAdapterAsTheirMediaRemoteCommands() async {
        let stream = TestMediaStream()
        let provider = AdapterSystemMediaProvider(stream: stream)

        for (command, identifier) in [
            (SystemMediaCommand.togglePlayPause, 2),
            (SystemMediaCommand.nextTrack, 4),
            (SystemMediaCommand.previousTrack, 5),
        ] {
            let sent = await provider.send(command)
            XCTAssertTrue(sent)
            XCTAssertEqual(stream.commands.last, identifier)
        }
        XCTAssertEqual(stream.commands.count, 3, "a press was dropped or duplicated")
    }

    func testAPlayerThatRefusesIsReportedRatherThanAssumed() async {
        let stream = TestMediaStream()
        stream.acceptsCommands = false
        let provider = AdapterSystemMediaProvider(stream: stream)

        let sent = await provider.send(.nextTrack)
        XCTAssertFalse(sent, "a command nothing took was reported as delivered")
    }

    /// A command aimed at Music while Spotify is playing changes the wrong
    /// thing, so it has to follow whichever provider is answering.
    func testTheCommandFollowsTheProviderThatIsAnswering() async {
        let primary = RecordingSystemMediaProvider(
            availability: .unavailable(reason: "nothing to read"))
        let fallback = RecordingSystemMediaProvider(availability: .available)
        let scheduler = ManualMediaTimerScheduler()
        let provider = FallbackSystemMediaProvider(
            primary: primary, fallback: fallback, scheduler: scheduler)

        provider.addConsumer()
        scheduler.fireDelayed()
        let sent = await provider.send(.togglePlayPause)

        XCTAssertTrue(sent)
        XCTAssertEqual(fallback.commands, [.togglePlayPause])
        XCTAssertTrue(primary.commands.isEmpty, "the command went to the silent provider")
    }
}
