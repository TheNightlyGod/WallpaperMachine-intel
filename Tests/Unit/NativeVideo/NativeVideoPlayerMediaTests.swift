import AVFoundation
import AppKit
import XCTest

@testable import WallpaperMachine

/// The real `NativeVideoPlayer` against real media.
///
/// **Opt-in.** These cases drive `AVQueuePlayer`, `AVPlayerLooper`,
/// `AVPlayerLayer`, `AVPlayerItemVideoOutput` and the poster path, which means
/// real video decoding on this machine's media hardware. They are skipped
/// unless `WALLPAPER_MACHINE_MEDIA_TESTS=1` is set, so the routine gate
/// stays a metadata-and-logic suite:
///
/// ```
/// WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py
/// ```
///
/// They still open no window and touch no desktop: an `AVPlayerLayer` that is
/// never added to a window's layer tree presents nothing. Nor is any audio
/// session configured — every fixture is silent, and the one clip with an
/// audio track is routed to an output device that does not exist.
///
/// **Evidence discipline.** `readyForDisplay` means the layer has a frame it
/// could show. It is not a presented frame. Each case below records which of
/// these it established, and on-screen presentation is recorded as
/// unavailable, never inferred:
///
/// | asset loaded | item ready | time advanced | pixel obtained | layer ready | on screen |
@MainActor
final class NativeVideoPlayerMediaTests: XCTestCase {
    private var directory: URL!
    private var counters: RuntimeCounters!
    private var surface: RuntimeSurfaceKey!
    private var player: NativeVideoPlayer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_MEDIA_TESTS"] == "1",
            "media/device integration tests are opt-in; set WALLPAPER_MACHINE_MEDIA_TESTS=1")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-video-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        counters = RuntimeCounters()
        counters.startSession(duration: .seconds(120))
        surface = RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 1, generation: 1)
    }

    override func tearDown() async throws {
        player?.stop()
        player = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    /// A one-second 30 fps clip: long enough to observe time advancing, short
    /// enough that two loops take two seconds.
    private func makeClip(name: String, frames: Int = 30) async throws -> URL {
        try await SyntheticVideoFixture.write(
            .constantRate(name: name, numerator: 30, denominator: 1, frames: frames),
            into: directory)
    }

    private func makePlayer(
        url: URL, paused: Bool = false, viewSize: CGSize = CGSize(width: 64, height: 36)
    ) -> NativeVideoPlayer {
        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: paused)
        // A layer with no window shows nothing, but it still has to be the
        // production object: the poster path reads the item the layer's player
        // is playing.
        let view = NSView(frame: NSRect(origin: .zero, size: viewSize))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: url)
        self.player = player
        return player
    }

    private func makeRotatedClip(name: String, degrees: Int) async throws -> URL {
        var request = SyntheticVideoFixture.Request.constantRate(
            name: name, numerator: 30, denominator: 1, frames: 30)
        request.rotationDegrees = degrees
        return try await SyntheticVideoFixture.write(request, into: directory)
    }

    /// A frame the way the platform shows the clip: the generator applies the
    /// track's display matrix, as the layer does.
    private func uprightReferenceFrame(of url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try await generator.image(at: .zero).image
    }

    /// The four corners of `image`, a few pixels in from the edge so codec
    /// edge handling does not matter, as 8-bit sRGB: top-left, top-right,
    /// bottom-left, bottom-right. Only red and green are meaningful for the
    /// fixture, whose blue changes per frame.
    private static func corners(of image: CGImage) -> [(red: Int, green: Int, blue: Int)] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        let inset = 3
        return [(inset, inset), (width - 1 - inset, inset),
            (inset, height - 1 - inset), (width - 1 - inset, height - 1 - inset)
        ].map { x, y in
            let offset = (y * width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }
    }

    /// Waits for `condition`, polling, up to `timeout`. Returns whether it
    /// became true, so a caller reports a timeout rather than asserting on a
    /// value it never waited for.
    private func wait(
        upTo timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testTheRealPlayerReachesReadinessAndAdvancesPlaybackTime() async throws {
        let url = try await makeClip(name: "advance")
        let player = makePlayer(url: url)

        let ready = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(ready, "the item never became readyToPlay")

        let first = player.playbackTimeForTest
        let advanced = await wait {
            CMTimeCompare(player.playbackTimeForTest, first) > 0
        }
        XCTAssertTrue(advanced, "playback time never advanced")
        XCTAssertTrue(player.isPlaying)

        let layerReady = await wait(upTo: .seconds(3)) { player.layerIsReadyForDisplayForTest }
        print(
            "[media] advance: asset loaded=yes item ready=yes time advanced=yes "
                + "layer ready=\(layerReady) on screen=unavailable (no presentation feedback)")
    }

    func testItKeepsPlayingAcrossAtLeastTwoLoopBoundaries() async throws {
        // One second of content; the looper has to restart it. A wrap shows up
        // as the playback time going backwards.
        let url = try await makeClip(name: "loop")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")

        var wraps = 0
        var previous = player.playbackTimeForTest
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline && wraps < 2 {
            try? await Task.sleep(for: .milliseconds(50))
            let now = player.playbackTimeForTest
            if now.isValid && previous.isValid && CMTimeCompare(now, previous) < 0 {
                wraps += 1
            }
            previous = now
        }

        XCTAssertGreaterThanOrEqual(wraps, 2, "the clip did not loop twice")
        XCTAssertNotNil(player.currentItemForTest, "the queue must not run dry across a loop")
        XCTAssertTrue(player.isPlaying)
        print("[media] loop: wraps=\(wraps) queued items=\(player.queuedItemCount)")
    }

    func testAPosterIsProducedFromTheItemPlayingAfterTwoLoops() async throws {
        let url = try await makeClip(name: "poster-loop")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")

        var wraps = 0
        var previous = player.playbackTimeForTest
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline && wraps < 2 {
            try? await Task.sleep(for: .milliseconds(50))
            let now = player.playbackTimeForTest
            if now.isValid && previous.isValid && CMTimeCompare(now, previous) < 0 { wraps += 1 }
            previous = now
        }
        XCTAssertGreaterThanOrEqual(wraps, 2, "needed two loop boundaries to make the point")

        let image = await player.posterImage()
        XCTAssertNotNil(image, "the poster path must survive the item being replaced by a loop")
        XCTAssertEqual(image?.width, 64)
        XCTAssertEqual(image?.height, 36)
        XCTAssertFalse(
            player.posterOutputIsAttachedForTest,
            "the video output must not stay attached; that would be a continuous readback")
        let fallbacks = counters.snapshot().value(.nativeVideoPosterFallback, for: surface)
        print(
            "[media] poster after \(wraps) loops: pixel obtained=yes fallbacks=\(fallbacks) "
                + "on screen=unavailable")
    }

    func testConcurrentPosterRequestsCoalesceIntoOne() async throws {
        let url = try await makeClip(name: "poster-concurrent")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")
        _ = await wait(upTo: .seconds(3)) { player.layerIsReadyForDisplayForTest }

        async let a = player.posterImage()
        async let b = player.posterImage()
        async let c = player.posterImage()
        let images = await [a, b, c]

        XCTAssertEqual(images.count, 3)
        XCTAssertNotNil(images[0])
        for image in images.dropFirst() {
            XCTAssertTrue(
                image === images[0],
                "overlapping requests must share one read, not open three")
        }
        XCTAssertFalse(player.posterOutputIsAttachedForTest)
    }

    func testAPausedPlayerAnswersAPosterWithoutResuming() async throws {
        let url = try await makeClip(name: "poster-paused")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")
        // Produce one frame, then stop on the user's behalf.
        _ = await player.posterImage()
        player.setUserPaused(true)
        XCTAssertFalse(player.isPlaying)

        let image = await player.posterImage()

        XCTAssertNotNil(image, "a paused player still has the last frame it produced")
        XCTAssertFalse(
            player.isPlaying,
            "a screenshot request must never restart playback the user stopped")
    }

    func testAPosterOfAnUprightClipStillUsesTheVideoOutput() async throws {
        // The generator is a second decode. A clip whose picture and frames
        // agree must keep reading the frame that is already playing.
        let url = try await makeClip(name: "poster-upright")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")
        _ = await wait(upTo: .seconds(3)) { player.layerIsReadyForDisplayForTest }
        let first = player.playbackTimeForTest
        let advanced = await wait { CMTimeCompare(player.playbackTimeForTest, first) > 0 }
        XCTAssertTrue(advanced, "playback time never advanced")

        let image = await player.posterImage()

        XCTAssertEqual(image?.width, 64)
        XCTAssertEqual(image?.height, 36)
        XCTAssertEqual(
            counters.snapshot().value(.nativeVideoPosterFallback, for: surface), 0,
            "an upright clip must not pay for a second decode")
    }

    func testAPosterOfARotatedClipIsUpright() async throws {
        // The item's presentation size and the layer follow the display
        // matrix; the frames a video output returns do not. The poster has to
        // match the picture, not the stored frames.
        let url = try await makeRotatedClip(name: "poster-rotated", degrees: 90)
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")
        let sized = await wait {
            (player.currentItemForTest?.presentationSize ?? .zero) != .zero
        }
        XCTAssertTrue(sized, "the item never reported a presentation size")
        let presentation = try XCTUnwrap(player.currentItemForTest).presentationSize
        XCTAssertEqual(presentation, CGSize(width: 36, height: 64), "the fixture is not rotated")
        _ = await wait(upTo: .seconds(3)) { player.layerIsReadyForDisplayForTest }

        let poster = await player.posterImage()
        let image = try XCTUnwrap(poster)

        XCTAssertEqual(CGSize(width: image.width, height: image.height), presentation)
        XCTAssertFalse(player.posterOutputIsAttachedForTest)
        XCTAssertEqual(
            counters.snapshot().value(.nativeVideoPosterFallback, for: surface), 1,
            "a rotated clip's poster is the one-shot generator's, and it is counted")
        let reference = try await uprightReferenceFrame(of: url)
        XCTAssertEqual(image.width, reference.width)
        XCTAssertEqual(image.height, reference.height)
        let got = Self.corners(of: image), want = Self.corners(of: reference)
        XCTAssertEqual(got.count, 4)
        XCTAssertEqual(want.count, 4)
        for (index, (a, b)) in zip(got, want).enumerated() {
            XCTAssertLessThan(abs(a.red - b.red), 24, "corner \(index) red \(a) vs \(b)")
            XCTAssertLessThan(abs(a.green - b.green), 24, "corner \(index) green \(a) vs \(b)")
        }
        // Independent of the reference: the fixture's green grows with the
        // stored row, and a clockwise quarter turn carries the stored top row
        // to the right-hand edge. Left corners are therefore much greener
        // than right ones, and a counter-clockwise or unturned picture is not.
        if got.count == 4 {
            XCTAssertGreaterThan(got[0].green, got[1].green + 60, "top row: \(got)")
            XCTAssertGreaterThan(got[2].green, got[3].green + 60, "bottom row: \(got)")
        }
    }

    func testAPausedRotatedClipAnswersAnUprightPosterWithoutResuming() async throws {
        let url = try await makeRotatedClip(name: "poster-rotated-paused", degrees: 90)
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")
        player.setUserPaused(true)
        XCTAssertFalse(player.isPlaying)

        let poster = await player.posterImage()
        let image = try XCTUnwrap(poster)

        XCTAssertEqual(image.width, 36)
        XCTAssertEqual(image.height, 64)
        XCTAssertFalse(
            player.isPlaying,
            "a screenshot request must never restart playback the user stopped")
    }

    func testStoppingReleasesTheItemAndLeavesNothingAttached() async throws {
        let url = try await makeClip(name: "release")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")
        _ = await player.posterImage()

        player.stop()

        let snapshot = counters.snapshot()
        XCTAssertEqual(
            snapshot.value(.nativeVideoItemCreated, for: surface),
            snapshot.value(.nativeVideoItemReleased, for: surface),
            "a created item that is never released is a leaked player")
        XCTAssertFalse(player.posterOutputIsAttachedForTest)
        XCTAssertFalse(player.isPlaying)
        let afterStop = await player.posterImage()
        XCTAssertNil(afterStop, "a stopped surface must not deliver a frame to whatever is next")
    }

    func testTheRealPlayerReportsAFailureFromTheItemItActuallyPlays() async throws {
        // The producer half of the playback-failure hand-off, which no fake
        // surface can cover. It also pins the fault this test was written
        // after: `AVPlayerLooper` does not play its template item, so an
        // observer attached to the template watches an object that never
        // fails, and the host would never be told.
        let good = try await makeClip(name: "fail-source")
        let broken = directory.appendingPathComponent("fail-truncated.mov")
        let bytes = try Data(contentsOf: good)
        // Keep enough of the container to be openable, lose the media data.
        try bytes.prefix(bytes.count / 3).write(to: broken)

        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: false)
        var reported: (generation: UInt64, detail: String, settled: Bool)?
        player.onPreparationFailure = { generation, detail, settled in
            reported = (generation, detail, settled)
        }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: broken)
        self.player = player

        let failed = await wait(upTo: .seconds(10)) { reported != nil }

        XCTAssertTrue(failed, "a truncated asset must reach the failure callback")
        XCTAssertEqual(reported?.generation, surface.generation)
        XCTAssertEqual(reported?.settled, true, "a clip that cannot be decoded is a fact about the file")
        print("[media] playback failure -> \(reported?.detail ?? "none")")
    }

    func testAFailureRaisedBeforeTheCallbackIsInstalledIsStillDelivered() async throws {
        // The host builds the surface and installs its callback afterwards, so
        // a synchronous failure at load would be dropped on the floor — the
        // one case that ends with a black display and no hand-off.
        let good = try await makeClip(name: "fail-late-observer")
        let broken = directory.appendingPathComponent("fail-late-truncated.mov")
        let bytes = try Data(contentsOf: good)
        try bytes.prefix(bytes.count / 3).write(to: broken)

        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: broken)
        self.player = player
        // Let the failure land with nobody listening.
        try? await Task.sleep(for: .milliseconds(500))

        var reported: String?
        player.onPreparationFailure = { _, detail, _ in reported = detail }
        let delivered = await wait(upTo: .seconds(10)) { reported != nil }

        XCTAssertTrue(delivered, "a failure seen before the callback existed must be held")
    }

    func testAClipWhoseAudioCannotStartKeepsPlayingItsPicture() async throws {
        // Issue 31: an audio output that will not start fails the whole item
        // with AVErrorUnknown, muted or not, and the wallpaper went to the
        // scene engine for the session although its picture plays. A missing
        // output device reproduces that without opening a real one.
        var request = SyntheticVideoFixture.Request.constantRate(
            name: "audio-cannot-start", numerator: 30, denominator: 1, frames: 30)
        request.withAudio = true
        let url = try await SyntheticVideoFixture.write(request, into: directory)

        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: false)
        var failure: String?
        var dropped: String?
        player.onPreparationFailure = { _, detail, _ in failure = detail }
        player.onAudioDropped = { dropped = $0 }
        player.setAudioOutputDeviceForTest("org.wallpapermachine.tests.missing-output")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: url)
        self.player = player

        let recovered = await wait(upTo: .seconds(20)) { dropped != nil }
        XCTAssertTrue(recovered, "the clip with its audio must fail and be rebuilt without it")
        let ready = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(ready, "the video-only item never became readyToPlay")
        let first = player.playbackTimeForTest
        let advanced = await wait { CMTimeCompare(player.playbackTimeForTest, first) > 0 }
        XCTAssertTrue(advanced, "the picture must keep playing")
        XCTAssertNil(failure, "nothing is handed to the scene engine")
        let current = try XCTUnwrap(player.currentItemForTest)
        let audio = try await current.asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)

        player.stop()
        let snapshot = counters.snapshot()
        XCTAssertEqual(snapshot.value(.nativeVideoItemCreated, for: surface), 2)
        XCTAssertEqual(
            snapshot.value(.nativeVideoItemReleased, for: surface), 2,
            "the item that failed with its audio must be released, not leaked")
        print("[media] audio cannot start -> \(dropped ?? "none")")
    }

    func testEveryLoopPassStopsAtTheEndOfThePicture() async throws {
        // Issue 76: an unbounded looper waited for the audio at every seam and
        // held the last frame meanwhile. Paused, with the audio sent to an
        // output that does not exist, so nothing plays or opens a device.
        var request = SyntheticVideoFixture.Request.constantRate(
            name: "loop-ends-with-picture", numerator: 30, denominator: 1, frames: 30)
        request.withAudio = true
        request.audioSeconds = 1.5
        let url = try await SyntheticVideoFixture.write(request, into: directory)

        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: true)
        player.setAudioOutputDeviceForTest("org.wallpapermachine.tests.missing-output")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: url)
        self.player = player

        let queued = await wait { player.queuedItemCount > 0 }
        XCTAssertTrue(queued, "the looper never queued a copy of the clip")
        let ends = player.queuedItemEndTimesForTest
        XCTAssertFalse(ends.isEmpty)
        for end in ends {
            XCTAssertEqual(end, CMTime(value: 1, timescale: 1), "a pass must end with the picture")
        }
    }

    /// A 64x36 clip, or its quarter-turned twin, playing in a 40x40 point view
    /// whose picture size the item has reported.
    private func sizedPlayer(
        name: String, degrees: Int = 0, view: CGSize = CGSize(width: 40, height: 40)
    ) async throws -> NativeVideoPlayer {
        let url = degrees == 0
            ? try await makeClip(name: name)
            : try await makeRotatedClip(name: name, degrees: degrees)
        let player = makePlayer(url: url, viewSize: view)
        let sized = await wait { player.presentationSizeForTest != nil }
        XCTAssertTrue(sized, "the item never reported a presentation size")
        return player
    }

    private func assertRect(
        _ actual: CGRect, _ expected: CGRect, accuracy: CGFloat, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (name, a, e) in [
            ("x", actual.minX, expected.minX), ("y", actual.minY, expected.minY),
            ("width", actual.width, expected.width), ("height", actual.height, expected.height),
        ] {
            XCTAssertEqual(
                a, e, accuracy: accuracy, "\(message): \(name) of \(actual) vs \(expected)",
                file: file, line: line)
        }
    }

    func testThePlayerLayerLandsWhereTheLayoutSays() async throws {
        let player = try await sizedPlayer(name: "layout")
        XCTAssertEqual(player.presentationSizeForTest, CGSize(width: 64, height: 36))
        let bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        _ = await wait(upTo: .seconds(3)) { player.layerIsReadyForDisplayForTest }

        // The three plain modes leave the layer on the display and let
        // AVFoundation place the picture; where it puts it is the layout's
        // rectangle, within the whole-pixel rounding of the layout.
        player.relayout(bounds: bounds, backingScale: 1)
        player.setScaling(.match, factor: 1)
        XCTAssertEqual(player.layerFrameForTest, bounds)
        assertRect(player.layerVideoRectForTest, CGRect(x: 0, y: 9, width: 40, height: 23),
            accuracy: 0.75, "fit")
        player.setScaling(.fill, factor: 1)
        XCTAssertEqual(player.layerFrameForTest, bounds)
        // `videoRect` of an aspect-fill layer is the visible part, clipped to
        // the layer, so the crop itself is not observable here; the gravity is.
        XCTAssertEqual(player.layerGravityForTest, .resizeAspectFill)
        player.setScaling(.stretch, factor: 1)
        XCTAssertEqual(player.layerFrameForTest, bounds)
        assertRect(player.layerVideoRectForTest, bounds, accuracy: 0.75, "stretch")

        // Original size is one video pixel per point: the 64x36 picture,
        // centred, larger than the 40x40 display.
        player.setScaling(.none, factor: 1)
        assertRect(player.layerFrameForTest, CGRect(x: -12, y: 2, width: 64, height: 36),
            accuracy: 0, "original size")
        assertRect(player.layerVideoRectForTest, CGRect(x: 0, y: 0, width: 64, height: 36),
            accuracy: 0.75, "the picture fills its own layer")

        // A scale factor on Fit: 60 points wide on a 40 point display.
        player.setScaling(.match, factor: 1.5)
        assertRect(player.layerFrameForTest, CGRect(x: -10, y: 3, width: 60, height: 34),
            accuracy: 0, "fit x1.5")
        assertRect(player.layerVideoRectForTest, CGRect(origin: .zero, size: player.layerFrameForTest.size),
            accuracy: 0.75, "fit x1.5 picture")

        // Back to a plain mode: the layer returns to the display.
        player.setScaling(.fill, factor: 1)
        XCTAssertEqual(player.layerFrameForTest, bounds)
    }

    func testThePositionMovesThePictureWithinTheRoomAroundIt() async throws {
        let player = try await sizedPlayer(name: "layout-position")
        _ = await wait(upTo: .seconds(3)) { player.layerIsReadyForDisplayForTest }
        player.relayout(bounds: CGRect(x: 0, y: 0, width: 100, height: 50), backingScale: 1)

        // Original size: the 64x36 picture leaves 36 points across and 14 down.
        player.setScaling(.none, factor: 1, pan: .centered)
        assertRect(player.layerFrameForTest, CGRect(x: 18, y: 7, width: 64, height: 36),
            accuracy: 0, "centred")
        player.setScaling(.none, factor: 1, pan: .init(x: 0, y: 0))
        assertRect(player.layerFrameForTest, CGRect(x: 0, y: 14, width: 64, height: 36),
            accuracy: 0, "top left: y grows upward in the layer, so the top edge is the last 14")
        player.setScaling(.none, factor: 1, pan: .init(x: 1, y: 1))
        assertRect(player.layerFrameForTest, CGRect(x: 36, y: 0, width: 64, height: 36),
            accuracy: 0, "bottom right")

        // A plain mode with a position is placed by the layout, not by gravity, which centres:
        // Fit of 64x36 into 100x50 is 88.9x50 (rounded), with 11 points of room across.
        player.setScaling(.match, factor: 1, pan: .init(x: 0, y: 0.5))
        XCTAssertEqual(player.layerFrameForTest.minX, 0, accuracy: 0.01, "fit, flush left")
        XCTAssertEqual(player.layerGravityForTest, .resize,
            "the layer is the picture, stretched to the layout's own rectangle")

        // Back to the middle: AVFoundation places the picture again.
        player.setScaling(.match, factor: 1, pan: .centered)
        XCTAssertEqual(player.layerFrameForTest, CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(player.layerGravityForTest, .resizeAspect)

        // A position that is not a position is held to the edge, or the middle.
        player.setScaling(.none, factor: 1, pan: .init(x: .nan, y: 7))
        assertRect(player.layerFrameForTest, CGRect(x: 18, y: 0, width: 64, height: 36),
            accuracy: 0, "not a number is the middle, past the edge is the edge")
    }

    func testAResizedOrDenserDisplayMovesThePictureAtOnce() async throws {
        let player = try await sizedPlayer(name: "resize")
        player.setScaling(.none, factor: 1)
        assertRect(player.layerFrameForTest, CGRect(x: -12, y: 2, width: 64, height: 36),
            accuracy: 0, "before")

        // A larger display: the same 64x36 picture stays 64x36 points, centred.
        player.relayout(bounds: CGRect(x: 0, y: 0, width: 100, height: 50), backingScale: 1)
        assertRect(player.layerFrameForTest, CGRect(x: 18, y: 7, width: 64, height: 36),
            accuracy: 0, "after a resize")

        // A denser display shows it at the same size in points: Original size is
        // not tied to the pixel density.
        player.relayout(bounds: CGRect(x: 0, y: 0, width: 100, height: 50), backingScale: 2)
        assertRect(player.layerFrameForTest, CGRect(x: 18, y: 7, width: 64, height: 36),
            accuracy: 0, "after a density change")

        // Fit follows the display's size.
        player.setScaling(.match, factor: 0.5)
        player.relayout(bounds: CGRect(x: 0, y: 0, width: 128, height: 72), backingScale: 1)
        assertRect(player.layerFrameForTest, CGRect(x: 32, y: 18, width: 64, height: 36),
            accuracy: 0, "fit x0.5 on 128x72")
    }

    func testARotatedClipIsLaidOutByItsUprightSize() async throws {
        // presentationSize and the layer both apply the display matrix, so the
        // picture the layout places is the turned one: 36x64, not 64x36.
        let player = try await sizedPlayer(name: "layout-rotated", degrees: 90)
        XCTAssertEqual(player.presentationSizeForTest, CGSize(width: 36, height: 64))
        _ = await wait(upTo: .seconds(3)) { player.layerIsReadyForDisplayForTest }
        player.relayout(bounds: CGRect(x: 0, y: 0, width: 40, height: 40), backingScale: 1)

        player.setScaling(.match, factor: 1)
        assertRect(player.layerVideoRectForTest, CGRect(x: 9, y: 0, width: 23, height: 40),
            accuracy: 0.75, "fit, turned clip")
        player.setScaling(.none, factor: 1)
        assertRect(player.layerFrameForTest, CGRect(x: 2, y: -12, width: 36, height: 64),
            accuracy: 0, "original size, turned clip")
    }

    func testTheContainerViewRelaysOutThePlayerWhenItsSizeChanges() async throws {
        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: true)
        self.player = player
        let container = NativeVideoContainerView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        container.wantsLayer = true
        container.player = player
        player.attach(to: container)
        XCTAssertEqual(player.layerFrameForTest, CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertTrue(container.layer?.masksToBounds ?? false,
            "a picture larger than the display must be cropped to it")

        // Through the frame setter, the way a window resizes its content view.
        container.frame = NSRect(x: 0, y: 0, width: 80, height: 60)

        XCTAssertEqual(player.layerFrameForTest, CGRect(x: 0, y: 0, width: 80, height: 60))
    }

    func testAWindowFollowsItsScreenFrameWithoutBeingShown() async throws {
        // Built and resized, never ordered onto the desktop.
        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: true)
        self.player = player
        let window = NativeVideoWallpaperWindow(
            frame: NSRect(x: 0, y: 0, width: 40, height: 40), player: player)
        defer { window.stop() }
        XCTAssertEqual(player.layerFrameForTest, CGRect(x: 0, y: 0, width: 40, height: 40))

        window.setScreenFrame(NSRect(x: 0, y: 0, width: 90, height: 50))

        XCTAssertEqual(player.layerFrameForTest, CGRect(x: 0, y: 0, width: 90, height: 50),
            "the picture must not wait for the window to be laid out or shown")
    }

    func testABrokenClipWithSoundStillReachesTheHostOnce() async throws {
        // Leaving the audio out is one attempt, not a way to hide a clip whose
        // picture cannot play either.
        var request = SyntheticVideoFixture.Request.constantRate(
            name: "broken-with-audio", numerator: 30, denominator: 1, frames: 30)
        request.withAudio = true
        let good = try await SyntheticVideoFixture.write(request, into: directory)
        let broken = directory.appendingPathComponent("broken-with-audio-truncated.mov")
        let bytes = try Data(contentsOf: good)
        try bytes.prefix(bytes.count / 3).write(to: broken)

        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: false)
        var failures: [String] = []
        player.onPreparationFailure = { _, detail, _ in failures.append(detail) }
        player.setAudioOutputDeviceForTest("org.wallpapermachine.tests.missing-output")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: broken)
        self.player = player

        let failed = await wait(upTo: .seconds(20)) { !failures.isEmpty }
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(failed, "a clip that cannot play at all must still reach the host")
        XCTAssertEqual(failures.count, 1)
        print("[media] broken clip with sound -> \(failures.first ?? "none")")
    }

    func testAnAssetWithNoUsableRateNeverReachesThePlayer() async throws {
        // End to end through the production entry point: admission refuses and
        // the player is never constructed for it.
        let url = try SyntheticVideoFixture.writeCorrupt(name: "corrupt-media", into: directory)
        let refusal = await NativeVideoAdmission.evaluate(url: url)
        XCTAssertNotNil(refusal)
        print("[media] corrupt -> \(refusal?.reason ?? "ACCEPTED")")
    }

    // MARK: Restart

    /// The number of items this player has created, and released.
    private func itemCounts() -> (created: UInt64, released: UInt64) {
        let snapshot = counters.snapshot()
        return (
            snapshot.value(.nativeVideoItemCreated, for: surface),
            snapshot.value(.nativeVideoItemReleased, for: surface))
    }

    func testAReadyButFrameLessItemIsRestartedWithinBudget() async throws {
        // The stall the first-frame watchdog exists for. An `hev1` clip is not
        // decodable here: the item reaches readyToPlay and its clock runs, but
        // the picture size stays zero and the layer never becomes ready, and
        // no failure is delivered. The player can only be rebuilt, and only so
        // often.
        let url = try Hev1Fixture.write(name: "hev1", into: directory)
        let player = makePlayer(url: url)
        var failures: [String] = []
        player.onPreparationFailure = { _, detail, _ in failures.append(detail) }
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        guard itemReady, failures.isEmpty else {
            throw XCTSkip("this OS rejects an hev1 item outright (\(failures)); nothing to restart")
        }
        let shown = await wait(upTo: .seconds(2)) { player.layerIsReadyForDisplayForTest }
        try XCTSkipIf(shown, "this OS decodes hev1, so the clip is no longer frame-less")
        XCTAssertEqual(player.presentationSizeForTest ?? .zero, .zero, "no picture size either")
        XCTAssertEqual(itemCounts().created, 1)

        XCTAssertTrue(player.restartPlayback(reason: "first restart"))
        XCTAssertFalse(
            player.restartPlayback(reason: "while the first is pending"),
            "a second rebuild does not start while one is pending")
        let first = await wait { itemCounts().created == 2 }
        XCTAssertTrue(first, "the first restart never built its item")
        XCTAssertTrue(player.restartPlayback(reason: "second restart"))
        let second = await wait { itemCounts().created == 3 }
        XCTAssertTrue(second, "the second restart never built its item")

        XCTAssertFalse(
            player.restartPlayback(reason: "third restart"),
            "two rebuilds inside the window is all the player gets")
        let counts = itemCounts()
        XCTAssertEqual(counts.created, 3)
        XCTAssertEqual(counts.released, counts.created - 1, "every replaced item was released")
        XCTAssertTrue(failures.isEmpty, "a restart is not a failure: \(failures)")
        XCTAssertFalse(player.layerIsReadyForDisplayForTest)
        print("[media] hev1 stall: restarts=2 then refused, state: \(player.stateSummary)")
    }

    func testARestartKeepsAHealthyClipPlayingAndAStableRunEarnsTheBudgetBack() async throws {
        // Time is the test's: the budget reads the player's injected clock, so
        // a minute of healthy playback is one assignment.
        let url = try await makeClip(name: "restart-healthy")
        var clock = ContinuousClock.now
        let player = NativeVideoPlayer(
            surface: surface, counters: counters, paused: false, now: { clock })
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        var frames = 0
        player.onReadyForDisplay = { frames += 1 }
        player.load(url: url)
        self.player = player
        let firstFrame = await wait { frames >= 1 }
        XCTAssertTrue(firstFrame, "the clip never showed a frame")

        for round in 1...2 {
            let framesBefore = frames
            XCTAssertTrue(player.restartPlayback(reason: "round \(round)"))
            let rebuilt = await wait { itemCounts().created == UInt64(round + 1) }
            XCTAssertTrue(rebuilt, "round \(round) never built its item")
            let shown = await wait { frames > framesBefore }
            XCTAssertTrue(shown, "round \(round): the rebuilt clip never showed a frame")
            let advanced = await wait { player.isPlaying }
            XCTAssertTrue(advanced, "round \(round): the rebuilt clip is not playing")
        }
        XCTAssertFalse(
            player.restartPlayback(reason: "too soon"),
            "frames that arrived a moment ago do not forgive two rebuilds")

        clock = clock + .seconds(61)
        XCTAssertTrue(
            player.restartPlayback(reason: "after a minute of frames"),
            "a run that long proves the pipeline works, so the allowance is back")
        let again = await wait { itemCounts().created == 4 }
        XCTAssertTrue(again, "the restart after the stable run never built its item")
        let counts = itemCounts()
        XCTAssertEqual(counts.released, counts.created - 1)
    }

    func testARestartNeverStartsAClipTheUserPaused() async throws {
        let url = try await makeClip(name: "restart-paused")
        let player = makePlayer(url: url, paused: true)
        let ready = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(ready)

        XCTAssertTrue(player.restartPlayback(reason: "test"))
        let rebuilt = await wait { itemCounts().created == 2 }
        XCTAssertTrue(rebuilt)
        let readyAgain = await wait { player.itemStatusForTest == .readyToPlay }

        XCTAssertTrue(readyAgain)
        XCTAssertFalse(player.isPlaying, "a restart never starts a clip the user paused")
    }

    func testAStoppedPlayerCannotBeRestarted() async throws {
        let url = try await makeClip(name: "restart-stopped")
        let player = makePlayer(url: url)
        let ready = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(ready)
        player.stop()

        XCTAssertFalse(player.restartPlayback(reason: "after stop"))
        XCTAssertEqual(itemCounts().created, 1)
    }

    func testARestartAfterAFailureHasBeenReportedIsRefused() async throws {
        // A reported failure is the host's to act on. Rebuilding underneath it
        // would resurrect a clip the host is already handing over.
        let good = try await makeClip(name: "restart-failed-source")
        let broken = directory.appendingPathComponent("restart-failed.mov")
        let bytes = try Data(contentsOf: good)
        try bytes.prefix(bytes.count / 3).write(to: broken)
        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: false)
        var reported = false
        player.onPreparationFailure = { _, _, _ in reported = true }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: broken)
        self.player = player
        let failed = await wait(upTo: .seconds(10)) { reported }
        XCTAssertTrue(failed)

        XCTAssertFalse(player.restartPlayback(reason: "after the failure"))
    }

    // MARK: Health checks

    /// A player on injected clocks, attached to a view the way `makePlayer`
    /// does. `clock` decides how long it was paused; `sleep` runs the check's
    /// timers.
    private func makeCheckedPlayer(
        url: URL, health: NativeVideoHealthSupervisor.Policy = .init(),
        now: @escaping @MainActor () -> ContinuousClock.Instant,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> NativeVideoPlayer {
        let player = NativeVideoPlayer(
            surface: surface, counters: counters, paused: false, health: health, now: now,
            sleep: sleep)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: url)
        self.player = player
        return player
    }

    func testAHealthyClipIsReportedAdvancingAfterAResume() async throws {
        let url = try await makeClip(name: "health-healthy")
        var clock = ContinuousClock.now
        let player = makeCheckedPlayer(
            url: url,
            health: .init(
                minimumPause: .seconds(5), settle: .milliseconds(50), window: .seconds(2),
                step: .milliseconds(50)),
            now: { clock })
        var events: [NativeVideoHealthEvent] = []
        player.onHealthEvent = { events.append($0) }
        let shown = await wait { player.isEligibleForCheck }
        XCTAssertTrue(shown, "the clip never showed a frame")

        player.setUserPaused(true)
        clock = clock + .seconds(6)
        player.setUserPaused(false)
        let reported = await wait(upTo: .seconds(10)) { !events.isEmpty }

        XCTAssertTrue(reported, "no check followed the resume")
        XCTAssertEqual(events.first?.verdict, .advancing)
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(
            player.livenessOutputIsAttachedForTest, "a finished check leaves nothing attached")
        XCTAssertEqual(itemCounts().created, 1, "a healthy clip is not rebuilt")
    }

    func testOnlyALongPauseIsFollowedByACheckAndAnotherPauseEndsIt() async throws {
        let url = try await makeClip(name: "health-rules")
        var clock = ContinuousClock.now
        let sleeper = ManualSleeper()
        let player = makeCheckedPlayer(url: url, now: { clock }, sleep: sleeper.closure)
        let shown = await wait { player.isEligibleForCheck }
        XCTAssertTrue(shown, "the clip never showed a frame")

        // A flick of the occlusion state is not worth a look.
        player.setUserPaused(true)
        clock = clock + .seconds(2)
        player.setUserPaused(false)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(sleeper.requested.isEmpty, "a short pause starts no check")

        // A long one is, whichever way the clip was stopped.
        player.setUserPaused(true)
        clock = clock + .seconds(6)
        player.setUserPaused(false)
        await sleeper.waitUntilPending()
        XCTAssertEqual(sleeper.requested.count, 1, "the check is waiting out its settle")

        // Pausing again ends it: what it would conclude no longer holds.
        player.setPresentationSuspended(true)
        XCTAssertEqual(sleeper.cancelledCount, 1)
        XCTAssertFalse(player.livenessOutputIsAttachedForTest)
        clock = clock + .seconds(6)
        player.setPresentationSuspended(false)
        await sleeper.waitUntilPending()
        XCTAssertEqual(sleeper.requested.count, 2, "a hidden display counts as a pause too")

        // A resume that leaves the clip paused starts nothing.
        player.setUserPaused(true)
        player.setPresentationSuspended(true)
        clock = clock + .seconds(6)
        player.setPresentationSuspended(false)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(sleeper.requested.count, 2)
        XCTAssertFalse(player.isPlaying)
    }

    func testAClipThatNeverShowedAFrameIsNotChecked() async throws {
        // That is the first-frame watch's to judge; a check would only ever
        // find the stall that watch already knows about.
        let url = try Hev1Fixture.write(name: "health-hev1", into: directory)
        var clock = ContinuousClock.now
        let sleeper = ManualSleeper()
        let player = makeCheckedPlayer(url: url, now: { clock }, sleep: sleeper.closure)
        let ready = await wait { player.itemStatusForTest == .readyToPlay }
        try XCTSkipUnless(ready, "this OS does not get an hev1 item as far as ready")
        let shown = await wait(upTo: .seconds(2)) { player.layerIsReadyForDisplayForTest }
        try XCTSkipIf(shown, "this OS decodes hev1, so the clip is no longer frame-less")

        player.setUserPaused(true)
        clock = clock + .seconds(6)
        player.setUserPaused(false)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertFalse(player.isEligibleForCheck)
        XCTAssertTrue(sleeper.requested.isEmpty)
    }

    func testAFrameLessItemIsStalledEvenThoughItsClockRuns() async throws {
        // The signature that makes frame evidence necessary: the item reports
        // that it is playing and its position moves, and nothing is decoded.
        let url = try Hev1Fixture.write(name: "health-stall", into: directory)
        let player = makePlayer(url: url)
        var failures: [String] = []
        player.onPreparationFailure = { _, detail, _ in failures.append(detail) }
        let ready = await wait { player.itemStatusForTest == .readyToPlay }
        guard ready, failures.isEmpty else {
            throw XCTSkip("this OS rejects an hev1 item outright (\(failures))")
        }
        let shown = await wait(upTo: .seconds(2)) { player.layerIsReadyForDisplayForTest }
        try XCTSkipIf(shown, "this OS decodes hev1, so the clip is no longer frame-less")

        var evaluator = NativeVideoLivenessEvaluator()
        var readings: Set<Int> = []
        var frames = 0
        for _ in 0..<20 {
            if let sample = player.liveSample() {
                evaluator.record(sample)
                readings.insert(Int(sample.time.seconds * 1_000))
                if sample.producedFrame { frames += 1 }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        player.finishSampling()

        XCTAssertGreaterThan(readings.count, 1, "the clock ran, so a time-only check would pass")
        XCTAssertEqual(frames, 0)
        XCTAssertNil(evaluator.verdict)
        guard case .stalled = evaluator.timedOut() else {
            return XCTFail("a pipeline that decodes nothing is stalled: \(evaluator.timedOut())")
        }
        XCTAssertFalse(player.livenessOutputIsAttachedForTest)
    }

    func testSamplingProvesAHealthyClipAndFollowsTheLoopToItsNextCopy() async throws {
        let url = try await makeClip(name: "health-loop")
        let player = makePlayer(url: url)
        let shown = await wait { player.layerIsReadyForDisplayForTest }
        XCTAssertTrue(shown, "the clip never showed a frame")

        var evaluator = NativeVideoLivenessEvaluator()
        var itemsThatProducedFrames: Set<ObjectIdentifier> = []
        let deadline = ContinuousClock.now + .seconds(6)
        // The clip is one second long, so a boundary is crossed within a few.
        while ContinuousClock.now < deadline, itemsThatProducedFrames.count < 2 {
            if let sample = player.liveSample() {
                evaluator.record(sample)
                if sample.producedFrame { itemsThatProducedFrames.insert(sample.item) }
            }
            try? await Task.sleep(for: .milliseconds(30))
        }

        XCTAssertEqual(evaluator.verdict, .advancing)
        XCTAssertGreaterThanOrEqual(
            itemsThatProducedFrames.count, 2,
            "an output left on the retired copy would never see another frame")
        player.finishSampling()
        XCTAssertFalse(player.livenessOutputIsAttachedForTest)
    }

    func testAFrozenPipelineStopsAnsweringThatItProducedAFrame() async throws {
        // A frame is reported once and has to be read to be consumed. If a
        // sample left it unread, a pipeline that died after one picture would
        // be reported healthy for ever.
        let url = try await makeClip(name: "health-frozen")
        let player = makePlayer(url: url)
        let shown = await wait { player.layerIsReadyForDisplayForTest }
        XCTAssertTrue(shown, "the clip never showed a frame")
        player.setUserPaused(true)
        // An output attached to a paused item may be handed the picture that is
        // on screen once, a moment later. That one is not the point.
        for _ in 0..<10 {
            _ = player.liveSample()
            try? await Task.sleep(for: .milliseconds(50))
        }

        var produced = 0
        for _ in 0..<10 {
            if player.liveSample()?.producedFrame == true { produced += 1 }
            try? await Task.sleep(for: .milliseconds(20))
        }
        player.finishSampling()

        XCTAssertEqual(produced, 0, "a paused clip has no new pictures to report")
    }

    func testAStoppedPlayerCannotBeSampled() async throws {
        let url = try await makeClip(name: "health-stopped")
        let player = makePlayer(url: url)
        let ready = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(ready)
        _ = player.liveSample()
        XCTAssertTrue(player.livenessOutputIsAttachedForTest)
        player.stop()

        XCTAssertNil(player.liveSample())
        XCTAssertFalse(player.livenessOutputIsAttachedForTest, "stopping releases the output")
        XCTAssertFalse(player.isEligibleForCheck)
    }

    // MARK: Repair

    /// Short windows keep a real-time run to a couple of seconds. They are the
    /// policy's numbers, not waits in the test.
    private let quickChecks = NativeVideoHealthSupervisor.Policy(
        minimumPause: .seconds(5), settle: .milliseconds(50), window: .milliseconds(400),
        step: .milliseconds(50), rebuildWindow: .milliseconds(600))

    /// A player on an `hev1` clip that is told it showed a picture once: the
    /// pipeline a decoder reclaimed after a sleep leaves behind, which reports
    /// that it plays and produces nothing. Skips where this OS does not
    /// produce that.
    private func makeDeadPipeline(
        name: String, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> NativeVideoPlayer {
        let url = try Hev1Fixture.write(name: name, into: directory)
        let player = makeCheckedPlayer(url: url, health: quickChecks, now: { .now }, sleep: sleep)
        let ready = await wait { player.itemStatusForTest == .readyToPlay }
        try XCTSkipUnless(ready, "this OS does not get an hev1 item as far as ready")
        let shown = await wait(upTo: .seconds(2)) { player.layerIsReadyForDisplayForTest }
        try XCTSkipIf(shown, "this OS decodes hev1, so the clip is no longer frame-less")
        player.markPictureShownForTest()
        XCTAssertTrue(player.isEligibleForCheck)
        return player
    }

    private func count(_ counter: RuntimeCounter) -> UInt64 {
        counters.snapshot().value(counter, for: surface)
    }

    func testAFrameLessPipelineIsKickedRebuiltThenReported() async throws {
        let player = try await makeDeadPipeline(name: "ladder-dead")
        var failures: [String] = []
        var settled: [Bool] = []
        var events: [NativeVideoHealthEvent] = []
        player.onPreparationFailure = { _, detail, isSettled in
            failures.append(detail)
            settled.append(isSettled)
        }
        player.onHealthEvent = { events.append($0) }

        player.verifyPlayback(reason: "the displays woke")
        let reported = await wait(upTo: .seconds(30)) { !failures.isEmpty }

        XCTAssertTrue(reported, "the ladder never ended: \(events.map(\.stage))")
        XCTAssertEqual(failures.count, 1, "the host hears of it once")
        XCTAssertEqual(settled, [false], "a stall the repairs could not clear is no verdict on the file")
        XCTAssertTrue(failures.first?.contains("the displays woke") == true, "the report names the trigger: \(failures)")
        XCTAssertEqual(events.map(\.stage), [.initial, .afterKick, .afterRebuild])
        XCTAssertTrue(events.allSatisfy { if case .stalled = $0.verdict { return true } else { return false } })
        XCTAssertEqual(count(.nativeVideoPlaybackKick), 1)
        XCTAssertEqual(count(.nativeVideoPlaybackRebuild), 1)
        let items = itemCounts()
        XCTAssertEqual(items.created, 2, "the rebuild made one new item")
        XCTAssertEqual(items.created, items.released + 1, "and released the one it replaced")
        XCTAssertFalse(player.livenessOutputIsAttachedForTest, "the check leaves nothing attached")
        print("[media] hev1 ladder: \(failures.first ?? "")")
    }

    func testAFrameLessPipelineWithNoRebuildLeftIsReportedAfterTheKick() async throws {
        // The allowance is shared with the first-frame restart: two rebuilds in
        // ten minutes for the surface, whoever asked for them.
        let player = try await makeDeadPipeline(name: "ladder-budget")
        var failures: [String] = []
        var settled: [Bool] = []
        var events: [NativeVideoHealthEvent] = []
        player.onPreparationFailure = { _, detail, isSettled in
            failures.append(detail)
            settled.append(isSettled)
        }
        player.onHealthEvent = { events.append($0) }
        for round in 1...2 {
            XCTAssertTrue(player.restartPlayback(reason: "spend \(round)"))
            let rebuilt = await wait { itemCounts().created == UInt64(round + 1) }
            XCTAssertTrue(rebuilt, "restart \(round) never built its item")
        }
        XCTAssertFalse(player.canRebuildPlayback())

        player.verifyPlayback(reason: "the session became active")
        let reported = await wait(upTo: .seconds(30)) { !failures.isEmpty }

        XCTAssertTrue(reported, "the ladder never ended")
        XCTAssertEqual(events.map(\.stage), [.initial, .afterKick])
        XCTAssertEqual(settled, [false])
        XCTAssertEqual(count(.nativeVideoPlaybackKick), 1)
        XCTAssertEqual(count(.nativeVideoPlaybackRebuild), 0, "a rebuild the budget refuses is not made")
        XCTAssertEqual(itemCounts().created, 3, "and nothing was rebuilt behind its back")
    }

    func testARestartFromElsewhereEndsTheCheckInFlight() async throws {
        // The host's first-frame restart and the health check both rebuild. When
        // the host's lands first, the check is about an item that is going away
        // and must not go on to kick or rebuild the new one.
        let sleeper = ManualSleeper()
        let player = try await makeDeadPipeline(name: "ladder-restart", sleep: sleeper.closure)
        var failures: [String] = []
        var events: [NativeVideoHealthEvent] = []
        player.onPreparationFailure = { _, detail, _ in failures.append(detail) }
        player.onHealthEvent = { events.append($0) }

        player.verifyPlayback(reason: "the displays woke")
        await sleeper.waitUntilPending()  // the settle
        for _ in 0..<quickChecks.sampleLimit {
            sleeper.fireNext()
            await sleeper.waitUntilPending()
        }
        XCTAssertEqual(count(.nativeVideoPlaybackKick), 1, "the check found the stall and kicked")
        let cancelled = sleeper.cancelledCount

        XCTAssertTrue(player.restartPlayback(reason: "the first-frame wait ran out"))
        XCTAssertEqual(sleeper.cancelledCount, cancelled + 1, "the check's timer is cancelled at once")
        let rebuilt = await wait { itemCounts().created == 2 }
        XCTAssertTrue(rebuilt)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(events.count, 1, "the check says nothing more")
        XCTAssertEqual(count(.nativeVideoPlaybackRebuild), 0, "and the check rebuilt nothing")
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertFalse(player.livenessOutputIsAttachedForTest)
    }

    func testAHealthyPlayerIsNeitherKickedNorRebuiltByAWake() async throws {
        let url = try await makeClip(name: "ladder-healthy")
        let player = makeCheckedPlayer(url: url, health: quickChecks, now: { .now })
        var events: [NativeVideoHealthEvent] = []
        player.onHealthEvent = { events.append($0) }
        let shown = await wait { player.isEligibleForCheck }
        XCTAssertTrue(shown, "the clip never showed a frame")

        player.verifyPlayback(reason: "the displays woke")
        let reported = await wait(upTo: .seconds(10)) { !events.isEmpty }

        XCTAssertTrue(reported, "no check followed the wake")
        XCTAssertEqual(
            events, [NativeVideoHealthEvent(trigger: "the displays woke", verdict: .advancing)])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(count(.nativeVideoPlaybackKick), 0)
        XCTAssertEqual(count(.nativeVideoPlaybackRebuild), 0)
        let items = itemCounts()
        XCTAssertEqual(items.created, 1, "the item was never replaced")
        XCTAssertEqual(items.released, 0)
        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(player.livenessOutputIsAttachedForTest)
    }

    func testAWakeDoesNotCheckAClipThatIsPausedOrHidden() async throws {
        let url = try await makeClip(name: "ladder-paused")
        let sleeper = ManualSleeper()
        let player = makeCheckedPlayer(url: url, health: quickChecks, now: { .now }, sleep: sleeper.closure)
        let shown = await wait { player.isEligibleForCheck }
        XCTAssertTrue(shown, "the clip never showed a frame")

        player.setUserPaused(true)
        player.verifyPlayback(reason: "the displays woke")
        player.setUserPaused(false)
        player.setPresentationSuspended(true)
        player.verifyPlayback(reason: "the Mac woke")
        for _ in 0..<50 { await Task.yield() }

        XCTAssertTrue(sleeper.requested.isEmpty, "nothing that is not playing is looked at")
        XCTAssertFalse(player.isPlaying)
    }

    func testAKickKeepsAHealthyClipPlayingAndNeverStartsAPausedOne() async throws {
        let url = try await makeClip(name: "kick-healthy")
        let player = makePlayer(url: url)
        let shown = await wait { player.layerIsReadyForDisplayForTest }
        XCTAssertTrue(shown, "the clip never showed a frame")

        player.kickPlayback()
        XCTAssertEqual(count(.nativeVideoPlaybackKick), 1)
        let anchor = player.playbackTimeForTest.seconds
        let moved = await wait {
            // A loop wraps the position back, which is also movement.
            abs(player.playbackTimeForTest.seconds - anchor) > 0.2
        }
        XCTAssertTrue(moved, "the clip stopped after the kick")
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(itemCounts().created, 1, "a kick does not replace the item")

        player.setUserPaused(true)
        player.kickPlayback()
        XCTAssertEqual(count(.nativeVideoPlaybackKick), 1, "a pause the user chose is not kicked out of")
        XCTAssertFalse(player.isPlaying)
    }
}
