import XCTest

@testable import WallpaperMachine

@MainActor
final class SceneMediaSinkTests: XCTestCase {
    func testClearedCoverIsAppliedBeforeMetadataAndReplayedToNewScenes() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        var deliveries: [String] = []
        var handles: Set<UInt64> = [11]
        let sink = SceneMediaSink(session: session, submit: { deliveries.append($0) },
            applyArtwork: { width, height, data in
                deliveries.append("pixels:\(width)x\(height):\(data.count)")
            }, fetchHandles: { handles })
        defer { sink.shutdown() }
        sink.reconcile()
        try await poll { provider.consumers == 1 }
        provider.emitThumbnail(marker: 42)
        try await poll { deliveries.contains { $0.contains("\"hasThumbnail\":true") } }
        deliveries.removeAll()
        provider.clearThumbnail()
        try await poll { deliveries.contains { $0.contains("\"hasThumbnail\":false") } }
        XCTAssertEqual(deliveries.first, "pixels:0x0:0")
        deliveries.removeAll()
        handles = [12, 13]
        sink.reconcile()
        try await poll { deliveries.contains { $0.contains("\"hasThumbnail\":false") } }
        XCTAssertTrue(deliveries.contains("pixels:0x0:0"))
        XCTAssertFalse(deliveries.contains("pixels:1x1:4"))
        provider.emitThumbnail(marker: 99)
        try await poll { deliveries.contains("pixels:1x1:4") }
    }

    /// Swapping one opted-in Scene for another, or lighting a second display,
    /// hands the engine a scene that has been told nothing. The track has not
    /// changed, so no provider callback will fire; without a replay keyed on
    /// the new handle the new instance stays blank until the song does change.
    func testAReplacementSceneIsToldTheUnchangedTrack() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        var submitted: [String] = []
        var artwork: [(UInt32, UInt32, Int)] = []
        var handles: Set<UInt64> = [11]
        let sink = SceneMediaSink(
            session: session,
            submit: { submitted.append($0) },
            applyArtwork: { width, height, data in artwork.append((width, height, data.count)) },
            fetchHandles: { handles })

        sink.reconcile()
        try await poll { !submitted.isEmpty }
        provider.emitPlaying(title: "Bohemian Rhapsody")
        try await poll { submitted.contains { $0.contains("Bohemian Rhapsody") } }

        submitted.removeAll()
        artwork.removeAll()
        handles = [12]
        sink.reconcile()
        try await poll { submitted.contains { $0.contains("Bohemian Rhapsody") } }

        let playing = SystemMediaEventCodec.sceneScriptPlaybackState(.playing)
        XCTAssertTrue(
            submitted.contains { $0.contains("\"state\":\(playing)") },
            "the replacement is told playback too, not only the title")
        XCTAssertEqual(artwork.first?.2, 4, "the cover pixels are re-uploaded for the new scene")

        submitted.removeAll()
        sink.reconcile()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(submitted.isEmpty, "a handle already fed is not replayed to again")
    }

    /// Consent gone means the source stops; nothing is read and nothing is sent.
    func testNoConsentingSceneStopsTheProvider() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        var handles: Set<UInt64> = [11]
        let sink = SceneMediaSink(
            session: session, submit: { _ in }, applyArtwork: { _, _, _ in },
            fetchHandles: { handles })

        sink.reconcile()
        try await poll { provider.consumers == 1 }

        handles = []
        sink.reconcile()
        try await poll { provider.consumers == 0 }
    }

    /// A pause and a resume each start a reconcile, and each awaits the bridge.
    /// The answers can come back in the other order, and the older one must not
    /// re-open the provider the newer one closed.
    func testAStaleReconcileCannotReopenTheProviderALaterOneClosed() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        var answers: [Set<UInt64>] = [[11], [], [11]]
        let sink = SceneMediaSink(
            session: session, submit: { _ in }, applyArtwork: { _, _, _ in },
            fetchHandles: {
                calls += 1
                let answer = answers.isEmpty ? Set<UInt64>() : answers.removeFirst()
                // Only the first call is slow, so it answers last.
                if calls == 1 { await withCheckedContinuation { release = $0 } }
                return answer
            })

        sink.reconcile() // parks: "still presenting"
        try await poll { release != nil }
        sink.reconcile() // lands first: "nothing is presenting"
        try await poll { calls == 2 }

        release?.resume() // the stale answer arrives now
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            provider.consumers, 0,
            "a stale reconcile re-opened the provider a later one had closed")

        // Control: the sink is not simply stuck — a current answer still works.
        sink.reconcile()
        try await poll { provider.consumers == 1 }
    }

    /// A visible web wallpaper keeps the shared provider running. A scene that
    /// stopped presenting must not still be handed every event through it:
    /// that is artwork copied, JSON serialised and a bridge call made for a
    /// surface nobody can see.
    func testASceneThatStoppedConsumingIsNotFedThroughAProviderWebKeepsAlive() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        var submitted: [String] = []
        var handles: Set<UInt64> = [11]
        let sink = SceneMediaSink(
            session: session, submit: { submitted.append($0) }, applyArtwork: { _, _, _ in },
            fetchHandles: { handles })

        sink.reconcile()
        try await poll { provider.consumers == 1 }

        // Something else — a web wallpaper still on screen — holds the relay.
        final class WebConsumer {}
        let web = WebConsumer()
        session.relay.setConsuming(true, for: ObjectIdentifier(web))
        try await poll { provider.consumers == 2 }

        handles = []
        sink.reconcile()
        try await poll { provider.consumers == 1 }

        submitted.removeAll()
        provider.emitPlaying(title: "Under Pressure")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(
            submitted.isEmpty,
            "a scene that stopped presenting was still fed \(submitted.count) event(s)")
        XCTAssertEqual(provider.consumers, 1, "the web consumer still holds the provider")
    }

    /// A cover the engine is slow with must not be overtaken by the one that
    /// replaced it.
    ///
    /// The engine shows whatever arrives last, so two deliveries racing would
    /// leave the previous track's cover on screen — and the slower a cover is
    /// to apply, the likelier it wins.
    func testASlowCoverIsNotOvertakenByTheOneThatReplacedIt() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        var appliedCovers: [UInt8] = []
        var holdFirstCover: CheckedContinuation<Void, Never>?
        var coverCalls = 0
        let sink = SceneMediaSink(
            session: session, submit: { _ in },
            applyArtwork: { _, _, data in
                coverCalls += 1
                if coverCalls == 1 { await withCheckedContinuation { holdFirstCover = $0 } }
                appliedCovers.append(data.first ?? 0)
            },
            fetchHandles: { [11] })

        sink.reconcile()
        try await poll("initial consumer") { provider.consumers == 1 }
        provider.emitThumbnail(marker: 1)
        try await poll("first cover reached the engine") { holdFirstCover != nil }

        provider.emitThumbnail(marker: 2)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(
            appliedCovers.isEmpty,
            "a later cover overtook the one still being applied: \(appliedCovers)")

        holdFirstCover?.resume()
        try await poll("both covers applied") { appliedCovers.count >= 2 }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            appliedCovers.last, 2,
            "the cover left on screen is not the one published last: \(appliedCovers)")
        XCTAssertEqual(
            appliedCovers.firstIndex(of: 2), appliedCovers.count - 1,
            "a later cover was applied before an earlier one finished: \(appliedCovers)")
    }

    /// A delivery already inside the engine when the scene pauses must not
    /// report itself afterwards.
    ///
    /// The call in flight cannot be taken back, but everything after its await
    /// belongs to a scene that has stopped presenting. A boolean cannot decide
    /// that — a resume would set it true again — so the check is an epoch that
    /// only moves forward.
    func testADeliveryRetiredByAPauseDoesNotReportItselfWhenItReturns() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        var submitted: [String] = []
        var holdCover: CheckedContinuation<Void, Never>?
        var coverCalls = 0
        var handles: Set<UInt64> = [11]
        let sink = SceneMediaSink(
            session: session, submit: { submitted.append($0) },
            applyArtwork: { _, _, _ in
                coverCalls += 1
                if coverCalls == 1 { await withCheckedContinuation { holdCover = $0 } }
            },
            fetchHandles: { handles })

        sink.reconcile()
        try await poll("initial consumer") { provider.consumers == 1 }
        provider.emitThumbnail(marker: 1)
        try await poll("cover reached the engine") { holdCover != nil }

        handles = []
        sink.reconcile()
        try await poll("pause removed the consumer") { provider.consumers == 0 }
        submitted.removeAll()

        holdCover?.resume()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(
            submitted.isEmpty,
            "a delivery retired by a pause still reported itself: \(submitted)")
    }

    /// A press is only worth reporting if something carries it out. The whole
    /// chain existed once before with nothing at its end -- the object that
    /// waited for presses was never constructed -- so every button resolved
    /// correctly, reported correctly and then did nothing at all.
    func testAPressReachesThePlayer() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        let presses = AsyncPresses([
            BridgeUserShortcut(sceneHandle: 11, property: "nextsongbutton", value: "media:next"),
            BridgeUserShortcut(sceneHandle: 11, property: "mystery", value: ""),
            BridgeUserShortcut(
                sceneHandle: 11, property: "playpausebutton", value: "media:playpause"),
        ])
        let sink = SceneMediaSink(
            session: session, submit: { _ in }, applyArtwork: { _, _, _ in },
            fetchHandles: { [11] },
            nextShortcut: { try await presses.next() })

        try await poll { provider.sentCommands.count == 2 }
        XCTAssertEqual(provider.sentCommands, [.nextTrack, .togglePlayPause],
                       "a binding the host cannot carry out must not reach the player")
        sink.shutdown()
    }

    private func poll(
        _ label: String = "", timeout: TimeInterval = 2, until condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return XCTFail("condition \(label.isEmpty ? "" : "'\(label)' ")not reached within \(timeout)s")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A provider whose state a test writes directly. Nothing here loads
/// MediaRemote, runs a script or reads what the machine is playing.
@MainActor
final class ScriptedSystemMediaProvider: SystemMediaProvider {
    var availability: SystemMediaAvailability = .available
    var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?
    private(set) var consumers = 0
    private(set) var sentCommands: [SystemMediaCommand] = []
    private var properties = SystemMediaProperties()
    private var thumbnail: SystemMediaThumbnail?
    private var playback = SystemMediaPlaybackState.stopped

    func send(_ command: SystemMediaCommand) async -> Bool {
        sentCommands.append(command)
        return true
    }

    func addConsumer() { consumers += 1 }
    func removeConsumer() { consumers = max(0, consumers - 1) }

    func replayCurrentState() {
        onPropertiesChanged?(properties)
        if let thumbnail { onThumbnailChanged?(thumbnail) }
        onPlaybackChanged?(playback)
    }

    func emitPlaying(title: String) {
        properties.title = title
        playback = .playing
        thumbnail = SystemMediaThumbnail(
            pngBase64DataURL: "data:image/png;base64,",
            primaryColor: "rgb(232, 80, 58)", secondaryColor: "rgb(30, 22, 21)",
            tertiaryColor: "rgb(190, 150, 100)", textColor: "rgb(255, 255, 255)",
            highContrastColor: "rgb(0, 0, 0)", rgba: [232, 80, 58, 255], width: 1, height: 1)
        replayCurrentState()
    }

    /// A distinguishable cover: `marker` is the first RGBA byte, so a test can
    /// tell which publication a delivery carried.
    func emitThumbnail(marker: UInt8) {
        thumbnail = SystemMediaThumbnail(
            pngBase64DataURL: "data:image/png;base64,\(marker)",
            primaryColor: "rgb(\(marker), 0, 0)", secondaryColor: "rgb(0, 0, 0)",
            tertiaryColor: "rgb(0, 0, 0)", textColor: "rgb(255, 255, 255)",
            highContrastColor: "rgb(0, 0, 0)", rgba: [marker, 0, 0, 255], width: 1, height: 1)
        onThumbnailChanged?(thumbnail!)
    }

    func clearThumbnail() {
        thumbnail = .empty
        onThumbnailChanged?(.empty)
    }
}

/// Hands out a scripted run of presses, then waits forever -- which is what a
/// real long poll does between presses.
@MainActor
final class AsyncPresses {
    private var pending: [BridgeUserShortcut]

    init(_ presses: [BridgeUserShortcut]) { pending = presses }

    func next() async throws -> BridgeUserShortcut {
        if pending.isEmpty {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        return pending.removeFirst()
    }
}
