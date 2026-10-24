import AppKit
import ImageIO
import XCTest

@testable import WallpaperMachine

/// The routing and fallback contract of the experimental native video backend.
///
/// Three properties decide whether this backend is safe to ship switched off:
/// a wallpaper it cannot honour goes back to the scene engine exactly once, a
/// display's own visibility never overrides the user's own pause, and a
/// refusal stops applying once the configuration it described has changed.
@MainActor
final class NativeVideoWallpaperHostTests: XCTestCase {
    private func wallpaper(
        displayID: UInt32 = 7,
        id: String = "300",
        paused: Bool = false,
        volume: Float = 1.0,
        muted: Bool = false,
        admissionKey: UInt64 = 1,
        scalingMode: BridgeScalingMode = .fill,
        scalingFactor: Double = 1.0,
        mediaPath: String = "/tmp/does-not-need-to-exist/clip.mp4",
        framing: BridgeFraming = BridgeFraming(panX: 0.5, panY: 0.5)
    ) -> BridgeNativeVideoWallpaper {
        BridgeNativeVideoWallpaper(
            displayId: displayID,
            startupRevision: 0,
            wallpaperId: id,
            title: "Clip",
            mediaPath: mediaPath,
            admissionKey: admissionKey,
            framing: framing,
            paused: paused,
            volume: volume,
            muted: muted,
            scalingMode: scalingMode,
            scalingFactor: scalingFactor)
    }

    /// A clip the injected admission refuses, where a test needs one wallpaper refused and another not.
    private static let refusedPath = "/tmp/does-not-need-to-exist/refused.mp4"

    private final class Recorder {
        /// Every state the host reported, in order. A display the host could not play is reported
        /// as failed (with the reason and the key of the file), which is all the host says: nothing
        /// takes a failed clip over, so there is no hand-off to count.
        var states: [HostWallpaperState] = []
        /// The failures among `states`, as the host stated them. Identical consecutive states of a
        /// display are reported once, so a failure repeated for the same offer reads as one.
        var rejected: [(id: String, key: UInt64, reason: String)] {
            states.filter { $0.phase == .failed }.map {
                (id: $0.wallpaperID, key: $0.nativeAdmissionKey ?? 0, reason: $0.message ?? "")
            }
        }
        var fetched = 0
        var presented = 0
        var stopped = 0
        var admissionProbes: [String] = []
        var refusalSequence: [NativeVideoRefusal?] = []
        /// Files whose metadata read never returns until the gate opens, from
        /// the probe numbered `gateFromProbe` (1 is the first) onward.
        var probeGates: [String: AsyncGate] = [:]
        var gateFromProbe = 1
        /// When set, what the bridge offers on the next fetch.
        var offered: [BridgeNativeVideoWallpaper]?
        /// Where each probed file was said to live, in the order it was asked.
        var storageQueries: [String] = []
        /// Every surface the host built, by the media path it was built for. A
        /// window that was built and closed again still counts: it was on the
        /// desktop for a moment, and that is what a superseded open must avoid.
        var made: [String] = []
        /// When set, the bridge cannot be read.
        var fetchFailure: Error?
        /// What happened, in order: a metadata read (`probe`), a window built (`make`), a surface
        /// stopped (`stop`) and a window put on the desktop (`present`, with `+veil` when the held
        /// picture was already over it).
        var events: [String] = []
    }

    private struct BridgeUnreachable: Error {}

    /// Stands in for the desktop window. The controller's rules are what these
    /// tests are about, and an automated run has no authorization to put a
    /// window on the desktop. The real window and player are covered by
    /// `NativeVideoPlayerMediaTests`, which is opt-in.
    @MainActor
    private final class FakeSurface: NativeVideoSurface {
        private let recorder: Recorder
        private var userPaused: Bool
        private var suspended = false
        private(set) var isStopped = false
        var isReadyForDisplay = false
        /// Like the real player, reports a picture it already has the moment the callback is
        /// installed.
        var onReadyForDisplay: (@MainActor () -> Void)? {
            didSet { if isReadyForDisplay, onReadyForDisplay != nil { onReadyForDisplay?() } }
        }
        var volume: Float = 1
        var muted = false
        var posterLayer: CALayer? = CALayer()
        var windowNumber: Int { Int(generation) + 1_000 }
        private(set) var frame = NSRect.zero
        func setScreenFrame(_ frame: NSRect) { self.frame = frame }
        /// Poster answer, and how long it takes. The delay is what lets a test
        /// replace the surface while a request is still in flight.
        var poster: CGImage?
        var posterDelay: Duration = .zero
        /// Delivered synchronously the moment a callback is installed, which
        /// is what the real player does when it was already holding a failure.
        var failureOnInstall: String?
        var onPreparationFailure: (@MainActor (UInt64, String, Bool) -> Void)? {
            didSet {
                guard let failureOnInstall, onPreparationFailure != nil else { return }
                self.failureOnInstall = nil
                onPreparationFailure?(generation, failureOnInstall, true)
            }
        }
        var onAudioDropped: (@MainActor (String) -> Void)?
        var onHealthEvent: (@MainActor (NativeVideoHealthEvent) -> Void)?
        /// The generation this surface was opened with, so a test can report a
        /// failure as either this surface's or a stale one's.
        let generation: UInt64

        init(recorder: Recorder, paused: Bool, generation: UInt64) {
            self.recorder = recorder
            self.userPaused = paused
            self.generation = generation
        }

        /// Stands in for `AVPlayerItem.status` becoming `.failed`, or, with
        /// `settled: false`, for the health ladder giving up on a stalled pipeline.
        func failPreparation(_ detail: String, generation: UInt64? = nil, settled: Bool = true) {
            onPreparationFailure?(generation ?? self.generation, detail, settled)
        }

        /// Every volume the surface was given, in order: the first is the one
        /// it started with.
        private(set) var volumeHistory: [Float] = []
        func setVolume(_ volume: Float, muted: Bool) {
            self.volume = volume
            self.muted = muted
            volumeHistory.append(volume)
        }
        /// Every scaling choice the host handed this surface, in order.
        private(set) var scalingCalls: [(mode: BridgeScalingMode, factor: Double, pan: NativeVideoLayout.Pan)] = []
        func setScaling(_ mode: BridgeScalingMode, factor: Double, pan: NativeVideoLayout.Pan) {
            scalingCalls.append((mode: mode, factor: factor, pan: pan))
        }
        /// Every restart the host asked this surface for, with its reason.
        private(set) var restartReasons: [String] = []
        /// What a restart answers: false is a player with no rebuild left.
        var restartResult = true
        var stateSummary = "fake pipeline state"
        func restartPlayback(reason: String) -> Bool {
            restartReasons.append(reason)
            return restartResult
        }
        /// Every health check the host asked this surface for, with its reason.
        private(set) var verifyReasons: [String] = []
        func verifyPlayback(reason: String) { verifyReasons.append(reason) }
        func setUserPaused(_ paused: Bool) { userPaused = paused }
        func setPresentationSuspended(_ suspended: Bool) { self.suspended = suspended }
        var isPlaying: Bool { !isStopped && !userPaused && !suspended }
        func posterImage() async -> CGImage? {
            if posterDelay != .zero { try? await Task.sleep(for: posterDelay) }
            return poster
        }
        func present() {
            recorder.presented += 1
            let veiled = posterLayer?.sublayers?.contains { $0.name == SwitchHoldVeil.layerName } == true
            recorder.events.append(veiled ? "present+veil" : "present")
        }
        func stop() {
            isStopped = true
            recorder.stopped += 1
            recorder.events.append("stop")
        }
    }

    private static func makeImage() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    private var surfacesMade: [UInt32: FakeSurface] = [:]
    private let counters = RuntimeCounters()
    private let sleeper = ManualSleeper()
    /// Gates a test left closed, opened again when it ends so no probe task is
    /// left suspended.
    private var openedAtTeardown: [AsyncGate] = []
    private var screenFrames: [(id: UInt32, frame: NSRect)] = []
    /// Makes every surface this factory builds fail as its callback is installed.
    private var surfaceFailureOnInstall: String?
    /// Makes every surface this factory builds already have its picture when it is built.
    private var surfaceReadyAtBirth = false

    private func makeHost(
        wallpapers: [BridgeNativeVideoWallpaper],
        refusal: NativeVideoRefusal? = nil,
        refusalByPath: [String: NativeVideoRefusal] = [:],
        /// Consumed one entry per probe, so a transient failure that clears on
        /// a retry can be expressed. Falls through to the other two once empty.
        refusalSequence: [NativeVideoRefusal?] = [],
        recorder: Recorder,
        frameCenter: NotificationCenter = NotificationCenter(),
        /// Where wake notifications are posted. Never the system's, so a real
        /// wake during a test run reaches no host.
        workspaceCenter: NotificationCenter = NotificationCenter(),
        /// Where the stub says each file lives. Defaults to the internal
        /// drive so a test never asks the real file system about a path.
        storage: @escaping @MainActor (URL) -> NativeVideoStoragePolicy.Location = { _ in
            .internalVolume
        },
        /// Fires the metadata read limit by hand (`sleeper`). Tests that do not
        /// need it get the real clock, whose timer is cancelled as each read
        /// returns.
        manualLimits: Bool = false,
        switchHold: WallpaperSwitchHold? = nil
    ) -> NativeVideoWallpaperHost {
        recorder.refusalSequence = refusalSequence
        let limits: @Sendable (Duration) async throws -> Void
        if manualLimits {
            limits = sleeper.closure
        } else {
            limits = { try await Task.sleep(for: $0) }
        }
        let host = NativeVideoWallpaperHost(
            fetch: {
                recorder.fetched += 1
                if let failure = recorder.fetchFailure { throw failure }
                return recorder.offered ?? wallpapers
            },
            screens: { [weak self] in self?.screenFrames ?? [] },
            refusal: { url in
                recorder.events.append("probe")
                // The injected decision stands in for the asset probe, which
                // reads the file and nothing else.
                recorder.admissionProbes.append(url.path)
                if recorder.admissionProbes.count >= recorder.gateFromProbe,
                    let gate = recorder.probeGates[url.path]
                {
                    await gate.wait()
                }
                if !recorder.refusalSequence.isEmpty {
                    return recorder.refusalSequence.removeFirst()
                }
                return refusalByPath[url.path] ?? refusal
            },
            makeSurface: { [weak self] url, frame, key, paused in
                recorder.made.append(url.path)
                recorder.events.append("make")
                let surface = FakeSurface(
                    recorder: recorder, paused: paused, generation: key.generation)
                surface.setScreenFrame(frame)
                surface.isReadyForDisplay = self?.surfaceReadyAtBirth ?? false
                surface.failureOnInstall = self?.surfaceFailureOnInstall
                self?.surfacesMade[key.displayID] = surface
                return surface
            },
            frameCenter: frameCenter,
            workspaceCenter: workspaceCenter,
            counters: counters,
            sleep: limits,
            storage: { url in
                recorder.storageQueries.append(url.path)
                return storage(url)
            },
            switchHold: switchHold)
        host.onStateChanged = { recorder.states.append($0) }
        return host
    }

    func testStartupWaitsForSurfaceReadinessAndAcknowledgesNewRevisions() async throws {
        screenFrames = [(7, NSRect(x: 0, y: 0, width: 80, height: 60))]
        var descriptor = wallpaper()
        descriptor.startupRevision = 4
        let host = makeHost(wallpapers: [], recorder: Recorder())
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }
        defer { host.shutdown() }
        await host.apply([descriptor])
        XCTAssertEqual(states.map(\.phase), [.loading])
        let surface = try XCTUnwrap(surfacesMade[7])
        surface.isReadyForDisplay = true
        surface.onReadyForDisplay?()
        XCTAssertEqual(states.last?.phase, .ready)
        XCTAssertEqual(states.last?.startupRevision, 4)
        descriptor.startupRevision = 5
        await host.apply([descriptor])
        XCTAssertTrue(surfacesMade[7] === surface)
        XCTAssertEqual(states.last?.startupRevision, 5)
        XCTAssertEqual(states.last?.phase, .ready)
        let count = states.count
        await host.apply([descriptor])
        XCTAssertEqual(states.count, count)
        var replacement = wallpaper(id: "replacement", admissionKey: 2)
        replacement.startupRevision = 6
        await host.apply([replacement])
        let afterReplacement = states.count
        surface.onReadyForDisplay?()
        surface.failPreparation("late failure")
        XCTAssertEqual(states.count, afterReplacement)
        XCTAssertEqual(states.last?.wallpaperID, "replacement")
        XCTAssertEqual(states.last?.phase, .loading)
    }

    // MARK: Clips kept paused for another desktop

    func testAClipTheDisplayKeepsIsPausedWhenItsDesktopIsLeftAndRunsOnWhenItComesBack() async throws {
        let recorder = Recorder()
        surfaceReadyAtBirth = true
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        host.setKeptWallpapers([7: ["300", "301"]])
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        let first = try XCTUnwrap(surfacesMade[7])
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        let second = try XCTUnwrap(surfacesMade[7])

        XCTAssertFalse(first === second, "the next desktop's clip has a window of its own")
        XCTAssertFalse(first.isStopped, "the clip left behind is kept")
        XCTAssertFalse(first.isPlaying, "and paused")
        XCTAssertEqual(host.keptWallpapers(on: 7), ["300"])
        XCTAssertEqual(host.keptWindowNumbers, [first.windowNumber])

        let made = recorder.made.count
        let probes = recorder.admissionProbes.count
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        XCTAssertEqual(recorder.made.count, made, "nothing opens again")
        XCTAssertEqual(recorder.admissionProbes.count, probes, "and no file is read")
        XCTAssertTrue(first.isPlaying, "the kept clip runs on from where it stopped")
        XCTAssertFalse(second.isStopped)
        XCTAssertFalse(second.isPlaying, "the one left now is kept in its turn")
        XCTAssertEqual(host.windowWallpapers, [first.windowNumber: "300", second.windowNumber: "301"])
        XCTAssertEqual(recorder.states.last?.wallpaperID, "300")
        XCTAssertEqual(recorder.states.last?.phase, .ready)
    }

    func testAClipTheDisplayMayNotKeepOrThatHasNoPictureIsClosedAsBefore() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        host.setKeptWallpapers([7: ["300"]])
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        let loading = try XCTUnwrap(surfacesMade[7])
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        XCTAssertTrue(loading.isStopped, "a clip with no picture yet would leave its desktop black")

        surfaceReadyAtBirth = true
        await host.apply([wallpaper(id: "302", admissionKey: 3)])
        let unlisted = try XCTUnwrap(surfacesMade[7])
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        XCTAssertTrue(unlisted.isStopped, "a wallpaper the display may not keep is closed")
        XCTAssertTrue(host.keptWindowNumbers.isEmpty)
    }

    func testKeptClipsCloseWhenThePlanDropsThemOrTheFileChanged() async throws {
        let recorder = Recorder()
        surfaceReadyAtBirth = true
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        host.setKeptWallpapers([7: ["300", "301"]])
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        let first = try XCTUnwrap(surfacesMade[7])
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        let second = try XCTUnwrap(surfacesMade[7])
        // The file behind the kept wallpaper was replaced meanwhile.
        await host.apply([wallpaper(id: "300", admissionKey: 9)])
        XCTAssertTrue(first.isStopped, "a kept clip of another file is not run")
        XCTAssertFalse(try XCTUnwrap(surfacesMade[7]) === first)
        XCTAssertFalse(second.isStopped)

        host.setKeptWallpapers([:])
        XCTAssertTrue(second.isStopped, "memory pressure or the mode turned off lets go of it")
        XCTAssertTrue(host.keptWindowNumbers.isEmpty)
    }

    func testShutdownClosesKeptClips() async throws {
        let recorder = Recorder()
        surfaceReadyAtBirth = true
        let host = makeHost(wallpapers: [], recorder: recorder)
        host.setKeptWallpapers([7: ["300", "301"]])
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        let first = try XCTUnwrap(surfacesMade[7])
        await host.apply([])
        XCTAssertFalse(first.isStopped, "a display that moved to a scene keeps the clip too")

        host.shutdown()
        XCTAssertTrue(first.isStopped)
    }

    func testPreparationFailureEndsStartupWithoutReportingReady() async throws {
        screenFrames = [(7, NSRect(x: 0, y: 0, width: 80, height: 60))]
        let host = makeHost(wallpapers: [], recorder: Recorder())
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }
        defer { host.shutdown() }
        await host.apply([wallpaper()])
        try XCTUnwrap(surfacesMade[7]).failPreparation("synthetic unavailable media")
        XCTAssertEqual(states.last?.phase, .failed)
        XCTAssertNotNil(states.last?.message)
        XCTAssertFalse(states.contains { $0.phase == .ready })
    }

    override func setUp() {
        super.setUp()
        surfacesMade = [:]
        screenFrames = [
            (id: 7, frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
            (id: 9, frame: NSRect(x: 200, y: 0, width: 200, height: 100)),
        ]
        surfaceFailureOnInstall = nil
        surfaceReadyAtBirth = false
        openedAtTeardown = []
    }

    override func tearDown() async throws {
        // A probe still suspended on its gate belongs to a task that would
        // otherwise outlive the test.
        openedAtTeardown.forEach { $0.open() }
        sleeper.fireAll()
        try await super.tearDown()
    }

    func testAWallpaperTheBackendCannotHonourIsHandedBack() async {
        // A file the player cannot open has to be taken by the scene engine.
        //
        // This deliberately does NOT assert "exactly once across two offers".
        // That was the old local skip list, and it is what left a display with
        // no backend when the bridge legitimately re-offered a key. Not
        // oscillating between backends is the bridge's guarantee, pinned by
        // `a_refused_wallpaper_goes_back_to_the_engine_and_stays_there`: it
        // records the refusal and stops offering. The host's job is to answer
        // what it is actually offered.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper()],
            refusal: .notPlayable("asset reports itself unplayable"),
            recorder: recorder)

        await host.apply([wallpaper()])

        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.id, "300")
        XCTAssertTrue(recorder.rejected.first?.reason.contains("not playable") == true)
        XCTAssertTrue(host.isEmpty, "a refused wallpaper must not leave a window behind")
        host.shutdown()
    }

    func testTheRefusalTravelsWithTheKeyItWasDecidedAgainst() async {
        // A verdict that arrives after the user replaced the file describes a
        // configuration that no longer exists. The bridge can only tell that if
        // the key is reported with the refusal.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(admissionKey: 0xBEEF)],
            refusal: .playbackFailed("decoder error"),
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 0xBEEF)])

        XCTAssertEqual(recorder.rejected.first?.key, 0xBEEF)
        host.shutdown()
    }

    func testANewKeyIsEvaluatedAgainRatherThanStayingRefused() async {
        // Once refused, refused for the session, for that key. A replaced file
        // is a new key, and it has to be judged on its own bytes.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalSequence: [.notPlayable("no video track"), nil],
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 30)])
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(recorder.rejected.count, 1)

        await host.apply([wallpaper(admissionKey: 60)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the new configuration must be evaluated")
        XCTAssertEqual(recorder.rejected.count, 1, "and must not inherit the old verdict")
        host.shutdown()
    }

    func testANewKeyUnderARunningClipReEvaluatesIt() async {
        // The wallpaper id does not change, so an early version kept the player
        // and only pushed the new descriptor at it, and a replaced file carried
        // on playing the old one. A changed admission key has to go through
        // admission again.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalSequence: [nil, .notPlayable("no video track")],
            recorder: recorder)
        await host.apply([wallpaper(admissionKey: 60)])
        XCTAssertEqual(host.activeDisplayIDs, [7])

        await host.apply([wallpaper(admissionKey: 30)])

        XCTAssertTrue(
            host.isEmpty, "the accepted player must not survive a file it was never admitted for")
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.key, 30)
        XCTAssertEqual(recorder.stopped, 1, "and it must be stopped, not merely dropped")
        host.shutdown()
    }

    func testReplacingTheMediaAtTheSamePathReloadsTheSurface() async {
        // Same id, same path, different bytes — which the key covers through
        // the file's length and mtime. Keeping the player would go on showing
        // the file that is no longer there.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(admissionKey: 1)])
        let first = host.surfaceGenerationForTest

        await host.apply([wallpaper(admissionKey: 2)])

        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertNotEqual(
            host.surfaceGenerationForTest, first, "new media identity is a new surface")
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(recorder.admissionProbes.count, 2, "and it is admitted again, not assumed")
        host.shutdown()
    }

    func testAnAssetThatFailsToPlayAfterAdmissionIsHandedToTheSceneEngine() async {
        // Metadata loading and playback are different things. A clip whose
        // track properties read cleanly can still fail to decode, and only the
        // player sees that. Without a hand-off the display shows black with
        // the scene engine excluded — both backends off one display.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(admissionKey: 9)])
        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertTrue(recorder.rejected.isEmpty, "admission accepted it")

        surfacesMade[7]?.failPreparation("decoder could not open the track")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(host.isEmpty, "the failed player must stop")
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.key, 9)
        XCTAssertTrue(
            recorder.rejected.first?.reason.contains("could not play") == true,
            "the reason must say playback failed, not that the metadata was refused")
        host.shutdown()
    }

    func testAClipThatKeepsPlayingWithoutItsAudioStaysNative() async {
        // An audio output that will not start fails the whole item, and the
        // player answers by playing the picture alone. That is the player
        // recovering, not failing: handing it back here would put the clip on
        // the scene engine for the session, which is how issue 31 ended up
        // with a black desktop.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(admissionKey: 5)])
        let surface = surfacesMade[7]

        surface?.onAudioDropped?("audio output could not start")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertTrue(host.isPlaying(displayID: 7) == true)
        XCTAssertEqual(recorder.stopped, 0)
        XCTAssertTrue(recorder.rejected.isEmpty, "nothing is handed to the scene engine")
        host.shutdown()
    }

    func testAFailureOnTheFirstDisplayIsNotDiscardedBecauseASecondOpened() async {
        // `surfaceGeneration` is host-wide, so comparing a failure against it
        // discarded display 7's real failure the moment display 9 opened: that
        // display stayed native-selected with the scene engine excluded and
        // showed black. Staleness has to be surface identity, not a counter.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([
            wallpaper(displayID: 7, id: "300", admissionKey: 1),
            wallpaper(displayID: 9, id: "301", admissionKey: 2),
        ])
        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        let first = surfacesMade[7]

        first?.failPreparation("decoder could not open the track")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            host.activeDisplayIDs, [9],
            "the failing display must hand over; the other must keep playing")
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.key, 1)
        host.shutdown()
    }

    func testASurfaceThatFailsWhileItsCallbackIsInstalledIsNeverPresented() async {
        // The player can already be holding a failure when the host installs
        // its callback, and installing delivers it synchronously — so the
        // hand-off closes this surface in the middle of opening it. Carrying on
        // to present() would order a stopped, unregistered window onto the
        // desktop: an orphan nothing owns and nothing can close.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        surfaceFailureOnInstall = "decoder could not open the track"

        await host.apply([wallpaper(admissionKey: 12)])
        // The hand-off is spawned from the failure callback, so let it drain.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.presented, 0, "a surface that failed on install must not be shown")
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(recorder.stopped, 1, "and it must have been stopped")
        XCTAssertEqual(recorder.rejected.count, 1, "the scene engine takes it")
        host.shutdown()
    }

    func testAPlaybackFailureFromAReplacedSurfaceIsIgnored() async {
        // The asynchronous twin of the poster case: a failure that arrives
        // after this display moved on must not condemn whatever is playing now.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        let stale = surfacesMade[7]
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        XCTAssertEqual(host.activeDisplayIDs, [7])

        stale?.failPreparation("late failure", generation: 1)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            host.activeDisplayIDs, [7], "the current wallpaper must still be playing")
        XCTAssertTrue(recorder.rejected.isEmpty, "and nothing may be handed back for it")
        host.shutdown()
    }

    func testATransientMetadataFailureIsRetriedRatherThanDemotingTheWallpaper() async {
        // A file still being written, or a busy volume, says nothing about
        // whether this backend can honour the content. Treating it as a
        // refusal would hand the wallpaper away for the whole session.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalSequence: [.preparationFailed("resource temporarily unavailable"), nil],
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 5)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the retry has to be allowed to succeed")
        XCTAssertTrue(recorder.rejected.isEmpty, "a transient failure is not a refusal")
        XCTAssertEqual(recorder.admissionProbes.count, 2)
        host.shutdown()
    }

    func testAPersistentMetadataFailureStopsRetryingAndIsReportedAsFailed() async {
        // The other half of the bound: a file that never loads is reported as
        // failed, and must not be re-read forever.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusal: .preparationFailed("input/output error"),
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 6)])
        await host.apply([wallpaper(admissionKey: 6)])

        XCTAssertEqual(
            recorder.admissionProbes.count, NativeVideoWallpaperHost.admissionAttemptLimit,
            "retries are bounded and the failure is remembered for the offer, so the second "
                + "offer costs no further file reads")
        XCTAssertEqual(recorder.rejected.count, 1, "the second offer restates the same failed state")
        XCTAssertTrue(host.isEmpty)
        host.shutdown()
    }

    /// Counts finished reconcile passes and lets a test wait for the nth one
    /// without polling.
    @MainActor
    private final class PassCounter {
        private(set) var count = 0
        private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        func record() {
            count += 1
            let ready = waiters.filter { $0.target <= count }
            waiters.removeAll { $0.target <= count }
            ready.forEach { $0.continuation.resume() }
        }
        func wait(for target: Int) async {
            if count >= target { return }
            await withCheckedContinuation { waiters.append((target, $0)) }
        }
    }

    /// Lets a probe that was given up on, and then released, run to its end.
    private func letOrphanedProbesReturn(
        _ host: NativeVideoWallpaperHost, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<1_000 where host.outstandingProbeCountForTest > 0 { await Task.yield() }
        XCTAssertEqual(host.outstandingProbeCountForTest, 0, file: file, line: line)
    }

    private func stuckFile(_ recorder: Recorder, path: String = "/tmp/does-not-need-to-exist/clip.mp4")
        -> AsyncGate
    {
        let gate = AsyncGate()
        recorder.probeGates[path] = gate
        openedAtTeardown.append(gate)
        return gate
    }

    func testAProbeThatNeverReturnsIsAbandonedAndHandedOver() async {
        // A disk that will not spin up, a share that went away, an evicted
        // cloud file: the metadata read does not fail, it just never ends.
        // Without a bound the reconcile pass never ends either, and every
        // other display's open, close and pause queues behind it.
        let recorder = Recorder()
        _ = stuckFile(recorder)
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        counters.startSession(duration: .seconds(60))

        let pass = Task { await host.apply([wallpaper(admissionKey: 5)]) }
        await sleeper.waitUntilPending()
        XCTAssertTrue(recorder.rejected.isEmpty, "the read is still inside its limit")
        XCTAssertEqual(recorder.presented, 0)

        sleeper.fireNext()
        await pass.value

        XCTAssertEqual(recorder.rejected.count, 1, "the scene engine takes it")
        XCTAssertEqual(recorder.rejected.first?.key, 5)
        XCTAssertTrue(host.isEmpty, "and no window is left behind")
        XCTAssertEqual(counters.snapshot().total(.nativeVideoProbeTimeout), 1)
    }

    func testTheTimeLimitFollowsWhereTheFileLives() async {
        // The reason a single fixed limit would be wrong: 8 seconds hands a
        // healthy clip on a sleeping external drive to the other backend, and
        // 60 seconds lets a dead share hold the host for a minute.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [], recorder: recorder,
            storage: { url in
                switch url.deletingPathExtension().lastPathComponent {
                case "internal": return .internalVolume
                case "external": return .removableVolume
                case "share": return .networkVolume
                case "cloud": return .dataless
                default: return .unknown
                }
            },
            manualLimits: true)
        defer { host.shutdown() }
        var expected: [Duration] = []
        for (name, limit) in [
            ("internal", 8), ("external", 30), ("share", 60), ("cloud", 60), ("unreadable", 30),
        ] {
            let path = "/tmp/does-not-need-to-exist/\(name).mp4"
            _ = stuckFile(recorder, path: path)
            let pass = Task {
                await host.apply([wallpaper(admissionKey: UInt64(expected.count + 1), mediaPath: path)])
            }
            await sleeper.waitUntilPending()
            expected.append(.seconds(limit))
            XCTAssertEqual(sleeper.requested, expected, name)
            sleeper.fireNext()
            await pass.value
        }
        XCTAssertEqual(recorder.rejected.count, 5)
    }

    func testATimedOutProbeIsNotRetriedInPassAndNotCached() async {
        // The retry loop exists for a read that fails. A read that used its
        // whole budget has nothing left to retry with, and its refusal is not
        // a verdict about the file: remembering it would make a disk that was
        // asleep once this host's answer whenever the bridge offers the key
        // again. (For the offer it failed, the host restates the failure
        // without reading; a newer offer, from any apply or reconcile, reads
        // the file afresh.)
        let recorder = Recorder()
        let gate = stuckFile(recorder)
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let pass = Task { await host.apply([wallpaper(admissionKey: 5)]) }
        await sleeper.waitUntilPending()
        sleeper.fireNext()
        await pass.value
        XCTAssertEqual(
            recorder.admissionProbes.count, 1,
            "a retry would have made it \(NativeVideoWallpaperHost.admissionAttemptLimit)")

        // The disk wakes: the orphaned read returns, and the same offer is
        // read again instead of being answered from a remembered refusal.
        gate.open()
        await letOrphanedProbesReturn(host)
        await host.apply([wallpaper(admissionKey: 5)])
        XCTAssertEqual(recorder.admissionProbes.count, 1, "the same offer is answered as it was")
        var newer = wallpaper(admissionKey: 5)
        newer.startupRevision = 1
        await host.apply([newer])

        XCTAssertEqual(recorder.admissionProbes.count, 2, "a newer offer reads the file again")
        XCTAssertEqual(host.activeDisplayIDs, [7], "and this time the clip plays")
        XCTAssertEqual(recorder.rejected.count, 1, "only the timeout was reported")
    }

    func testAStuckFileHasAtMostOneOrphanedProbe() async {
        // The orphaned read is still blocked on the volume. Another read of
        // the same file would only add a second blocked call to it, so a new
        // offer is answered at once with the same unsettled refusal.
        let recorder = Recorder()
        let gate = stuckFile(recorder)
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        let pass = Task { await host.apply([wallpaper(admissionKey: 5)]) }
        await sleeper.waitUntilPending()
        sleeper.fireNext()
        await pass.value
        XCTAssertEqual(host.outstandingProbeCountForTest, 1)

        await host.apply([wallpaper(admissionKey: 6)])

        XCTAssertEqual(recorder.admissionProbes.count, 1, "no second read of the stuck file")
        XCTAssertEqual(sleeper.requested.count, 1, "and no second timer to wait out")
        XCTAssertEqual(gate.waitingCount, 1)
        XCTAssertEqual(
            recorder.rejected.map(\.key), [5, 6], "but each offer is still answered, not ignored")
        XCTAssertEqual(host.outstandingProbeCountForTest, 1)

        host.shutdown()
        XCTAssertEqual(
            host.outstandingProbeCountForTest, 0, "a shut-down host remembers no reads")
    }

    func testACallerCancelledBeforeARetryReadStartsLeavesNoReadOutstanding() async {
        // The retry loop swallows the cancellation of its pause and goes on to
        // the next read, which a cancelled caller is never allowed to start. A
        // file entered as being read before that would stay so for the session,
        // and every later offer of it would be refused as still unread.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [], refusalSequence: [.preparationFailed("resource busy")],
            recorder: recorder)
        defer { host.shutdown() }
        let pass = Task { await host.apply([wallpaper(admissionKey: 5)]) }
        for _ in 0..<1_000 where recorder.admissionProbes.isEmpty { await Task.yield() }
        XCTAssertEqual(recorder.admissionProbes.count, 1, "the first read has returned its failure")

        pass.cancel()
        await pass.value

        XCTAssertEqual(host.outstandingProbeCountForTest, 0, "no read began, so none is outstanding")
        XCTAssertTrue(recorder.rejected.isEmpty, "and an abandoned pass is not a refusal")

        await host.apply([wallpaper(admissionKey: 5)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the next offer reads the file and plays it")
        XCTAssertEqual(recorder.admissionProbes.count, 2)
        XCTAssertTrue(recorder.rejected.isEmpty)
    }

    func testAHungProbeOnOneDisplayDoesNotKeepTheClosesOfOthersWaitingForever() async {
        // The wedge the bound exists for: display 9's file never answers, and
        // display 7's wallpaper has meanwhile left the backend. Its player
        // keeps running behind the read, which is why the wait has a limit,
        // and it is closed by the very next pass once the limit has passed.
        let recorder = Recorder()
        let slow = "/tmp/does-not-need-to-exist/slow.mp4"
        _ = stuckFile(recorder, path: slow)
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let passes = PassCounter()
        host.onSurfacesChanged = { passes.record() }
        let playing = wallpaper(displayID: 7, id: "300", admissionKey: 1)
        let stuck = wallpaper(displayID: 9, id: "301", admissionKey: 2, mediaPath: slow)
        await host.apply([playing])
        XCTAssertEqual(host.activeDisplayIDs, [7])
        // Display 7 has its picture, so the only timer left is the stuck read's.
        let shown = surfacesMade[7]
        shown?.isReadyForDisplay = true
        shown?.onReadyForDisplay?()

        recorder.offered = [playing, stuck]
        host.reconcile()
        await sleeper.waitUntilPending()
        recorder.offered = [stuck]
        host.reconcile()
        XCTAssertEqual(
            host.activeDisplayIDs, [7],
            "while the read is inside its limit the pass is occupied, and that is bounded")

        sleeper.fireNext()
        await passes.wait(for: 3)

        XCTAssertTrue(host.isEmpty, "the player of the wallpaper that left is closed")
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(recorder.rejected.map(\.key), [2], "display 9 is reported as failed, once")
        XCTAssertEqual(
            recorder.admissionProbes.count, 2,
            "the file was read once and not again by the trailing pass")
    }

    func testARetryThatHangsIsBoundedToo() async {
        // Every read in the loop is bounded, not just the first: a read that
        // fails and a second that hangs must not wedge the pass either.
        let recorder = Recorder()
        _ = stuckFile(recorder)
        recorder.gateFromProbe = 2
        let host = makeHost(
            wallpapers: [], refusalSequence: [.preparationFailed("resource busy")],
            recorder: recorder, manualLimits: true)
        defer { host.shutdown() }

        let pass = Task { await host.apply([wallpaper(admissionKey: 5)]) }
        await sleeper.waitUntilPending()
        sleeper.fireNext()
        await pass.value

        XCTAssertEqual(recorder.admissionProbes.count, 2, "the hung retry is not retried again")
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertTrue(host.isEmpty)
    }

    func testTheStorageIsNotClassifiedAgainForAnOfferThatOpensNothing() async {
        // Classifying looks at the file system. A reconcile storm that is
        // answered from the cache, or by a surface that is already playing,
        // must not touch it: a volume is looked at when a file is read and when
        // a surface starts waiting for its first picture, and not otherwise.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }

        await host.apply([wallpaper(admissionKey: 11)])
        await sleeper.waitUntilPending()
        let afterOpen = recorder.storageQueries.count
        for _ in 0..<3 { await host.apply([wallpaper(admissionKey: 11)]) }

        XCTAssertEqual(recorder.admissionProbes.count, 1)
        XCTAssertEqual(recorder.storageQueries.count, afterOpen)

        // Closed and offered again, the decision is still the cached one.
        await host.apply([])
        await host.apply([wallpaper(admissionKey: 11)])
        XCTAssertEqual(recorder.admissionProbes.count, 1, "no second read of the file")
    }

    // MARK: Superseded passes

    private static let pathA = "/tmp/does-not-need-to-exist/a.mp4"
    private static let pathB = "/tmp/does-not-need-to-exist/b.mp4"
    private static let pathC = "/tmp/does-not-need-to-exist/c.mp4"

    /// A host whose reconcile is held inside the metadata read of `pathA`
    /// until the returned gate opens, which is the window a newer snapshot has
    /// to arrive in.
    private func hostHeldInTheReadOfA(
        _ recorder: Recorder
    ) -> (host: NativeVideoWallpaperHost, gate: AsyncGate, passes: PassCounter) {
        let gate = stuckFile(recorder, path: Self.pathA)
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        let passes = PassCounter()
        host.onSurfacesChanged = { passes.record() }
        return (host, gate, passes)
    }

    func testASupersededWallpaperIsNeverPresented() async {
        // A rapid A, then B: while A's file is read the bridge commits B. The
        // reconcile that is running coalesces it into one trailing pass, which
        // would close what the first pass opened. Building A anyway puts a
        // decoder and a visible window on the desktop for a wallpaper that was
        // already replaced.
        let recorder = Recorder()
        let (host, gate, passes) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }
        let a = wallpaper(id: "300", admissionKey: 1, mediaPath: Self.pathA)
        let b = wallpaper(id: "301", admissionKey: 2, mediaPath: Self.pathB)

        recorder.offered = [a]
        host.reconcile()
        await gate.waitUntilWaiting()
        recorder.offered = [b]
        host.reconcile()
        gate.open()
        await passes.wait(for: 2)

        XCTAssertEqual(recorder.made, [Self.pathB], "A was never built, not even briefly")
        XCTAssertEqual(recorder.presented, 1)
        XCTAssertEqual(recorder.stopped, 0, "so there was nothing to close either")
        XCTAssertTrue(recorder.rejected.isEmpty)
        XCTAssertEqual(host.activeDisplayIDs, [7])
    }

    func testAWallpaperThatLeftTheBackendWhileItsFileWasReadIsNotPresented() async {
        // The user went back to a scene wallpaper: the display is no longer in
        // the bridge's native list at all.
        let recorder = Recorder()
        let (host, gate, passes) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }

        recorder.offered = [wallpaper(admissionKey: 1, mediaPath: Self.pathA)]
        host.reconcile()
        await gate.waitUntilWaiting()
        recorder.offered = []
        host.reconcile()
        gate.open()
        await passes.wait(for: 2)

        XCTAssertTrue(recorder.made.isEmpty)
        XCTAssertEqual(recorder.presented, 0)
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(
            states.last?.phase, .closed,
            "the startup the abandoned open began is ended, not left at loading")
    }

    func testAMediaChangeAtTheSamePathWhileItsFileWasReadIsOpenedOnceUnderTheNewKey() async {
        // The admission key is what the decision was taken for. A snapshot that
        // changed it describes a different file, so the old key's open is
        // dropped even though the wallpaper id and path are the same.
        let recorder = Recorder()
        let (host, gate, passes) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }

        recorder.offered = [wallpaper(admissionKey: 1, mediaPath: Self.pathA)]
        host.reconcile()
        await gate.waitUntilWaiting()
        recorder.offered = [wallpaper(admissionKey: 2, mediaPath: Self.pathA)]
        host.reconcile()
        gate.open()
        await passes.wait(for: 2)

        XCTAssertEqual(recorder.made, [Self.pathA], "one surface, for the key that is current")
        XCTAssertEqual(recorder.stopped, 0)
        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertTrue(recorder.rejected.isEmpty)
    }

    func testARepeatedOfferOfTheSameWallpaperDoesNotAbandonTheOpen() async {
        // A volume slider being dragged commits a snapshot per step, every one
        // of them offering the same wallpaper. Abandoning whenever a newer pass
        // is queued would abandon every pass in turn, and the clip would never
        // open for as long as the drag lasted.
        let recorder = Recorder()
        let (host, gate, passes) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }
        let a = wallpaper(id: "300", volume: 0.9, admissionKey: 1, mediaPath: Self.pathA)

        recorder.offered = [a]
        host.reconcile()
        await gate.waitUntilWaiting()
        for volume: Float in [0.8, 0.6, 0.25] {
            var dragged = a
            dragged.volume = volume
            recorder.offered = [dragged]
            host.reconcile()
        }
        gate.open()
        await passes.wait(for: 2)

        XCTAssertEqual(recorder.made, [Self.pathA], "opened once")
        XCTAssertEqual(recorder.presented, 1)
        XCTAssertEqual(recorder.stopped, 0)
        XCTAssertTrue(recorder.rejected.isEmpty)
        XCTAssertEqual(
            surfacesMade[7]?.volumeHistory.first, 0.25,
            "and it starts at the volume the bridge holds now, not the one it was offered at")
    }

    func testAnOverlappingDirectApplyDropsTheOlderOne() async {
        // Two passes in flight at once. The newer one has the final list, so
        // the older one must neither build what it was waiting on nor go on to
        // read and build the rest of its own list: C was dropped by the newer
        // list, and reading its file would be work for a wallpaper nobody wants.
        let recorder = Recorder()
        let (host, gate, _) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }
        let a = wallpaper(displayID: 7, id: "300", admissionKey: 1, mediaPath: Self.pathA)
        let b = wallpaper(displayID: 7, id: "301", admissionKey: 2, mediaPath: Self.pathB)
        let c = wallpaper(displayID: 9, id: "302", admissionKey: 3, mediaPath: Self.pathC)

        let older = Task { await host.apply([a, c]) }
        await gate.waitUntilWaiting()
        await host.apply([b])
        XCTAssertEqual(recorder.made, [Self.pathB])
        gate.open()
        await older.value

        XCTAssertEqual(recorder.made, [Self.pathB], "neither A nor C was built")
        XCTAssertEqual(recorder.admissionProbes.count, 2, "C's file was not read for a list that was replaced")
        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertEqual(recorder.presented, 1)
        XCTAssertEqual(recorder.stopped, 0)
    }

    func testAnOlderPassDoesNotPutItsStaleSettingsOverANewerOne() async {
        // Display 9 already plays. The older pass waits on display 7's file,
        // and by the time it reaches display 9 a newer pass has applied a newer
        // volume to it; carrying on would put the old volume back.
        let recorder = Recorder()
        let (host, gate, _) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }
        let c = wallpaper(displayID: 9, id: "302", volume: 1, admissionKey: 3, mediaPath: Self.pathC)
        await host.apply([c])
        let playing = surfacesMade[9]
        var quieter = c
        quieter.volume = 0.2

        let older = Task {
            await host.apply([wallpaper(displayID: 7, id: "300", admissionKey: 1, mediaPath: Self.pathA), c])
        }
        await gate.waitUntilWaiting()
        await host.apply([quieter])
        gate.open()
        await older.value

        XCTAssertEqual(playing?.volume, 0.2)
        XCTAssertEqual(playing?.volumeHistory.last, 0.2, "the older pass did not touch it afterwards")
    }

    func testADisplayThatVanishedDuringAdmissionGetsNoSurface() async {
        // The frame was read when the pass began. A display unplugged while an
        // earlier file was being read would be given a window anyway, at a
        // frame that no longer exists.
        let recorder = Recorder()
        let (host, gate, _) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }
        let a = wallpaper(id: "300", admissionKey: 1, mediaPath: Self.pathA)
        let present = screenFrames

        let pass = Task { await host.apply([a]) }
        await gate.waitUntilWaiting()
        screenFrames = present.filter { $0.id != 7 }
        gate.open()
        await pass.value

        XCTAssertTrue(recorder.made.isEmpty, "no surface for a display that is not there")
        XCTAssertEqual(recorder.presented, 0)
        XCTAssertTrue(host.isEmpty)
        XCTAssertTrue(recorder.rejected.isEmpty, "and the wallpaper was not refused for it")

        await host.apply([])
        XCTAssertEqual(states.last?.phase, .closed, "the startup it began is swept by the next pass")

        // The display returns: the kept verdict opens it without a second read.
        screenFrames = present
        await host.apply([a])
        XCTAssertEqual(recorder.made, [Self.pathA])
        XCTAssertEqual(recorder.admissionProbes.count, 1, "the file was not read again")
        XCTAssertEqual(host.activeDisplayIDs, [7])
    }

    func testASurfaceOpensOnTheFrameItsDisplayHasNow() async {
        let recorder = Recorder()
        let (host, gate, _) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }
        let moved = NSRect(x: 0, y: 0, width: 300, height: 150)

        let pass = Task {
            await host.apply([wallpaper(id: "300", admissionKey: 1, mediaPath: Self.pathA)])
        }
        await gate.waitUntilWaiting()
        screenFrames = [(id: 7, frame: moved), (id: 9, frame: NSRect(x: 300, y: 0, width: 200, height: 100))]
        gate.open()
        await pass.value

        XCTAssertEqual(surfacesMade[7]?.frame, moved)
    }

    func testAPassThatWaitedPlacesALaterDisplayAtItsCurrentFrame() async {
        // The same staleness on the other branch: display 9 already plays, and
        // the pass reaches it after waiting on display 7's file.
        let recorder = Recorder()
        let (host, gate, _) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }
        let c = wallpaper(displayID: 9, id: "302", admissionKey: 3, mediaPath: Self.pathC)
        await host.apply([c])
        let moved = NSRect(x: 200, y: 0, width: 640, height: 360)

        let pass = Task {
            await host.apply([wallpaper(displayID: 7, id: "300", admissionKey: 1, mediaPath: Self.pathA), c])
        }
        await gate.waitUntilWaiting()
        screenFrames = [(id: 7, frame: NSRect(x: 0, y: 0, width: 200, height: 100)), (id: 9, frame: moved)]
        gate.open()
        await pass.value

        XCTAssertEqual(surfacesMade[9]?.frame, moved)
    }

    func testAFetchFailureWhileCheckingStillPresents() async {
        // Asking the bridge again is a courtesy to the user: if it cannot
        // answer, the wallpaper is presented as it was offered rather than
        // left off the desktop, and the trailing pass puts right whatever that
        // got wrong.
        let recorder = Recorder()
        let (host, gate, _) = hostHeldInTheReadOfA(recorder)
        defer { host.shutdown() }
        var errors: [String] = []
        host.onError = { errors.append($0) }

        recorder.offered = [wallpaper(id: "300", admissionKey: 1, mediaPath: Self.pathA)]
        host.reconcile()
        await gate.waitUntilWaiting()
        recorder.fetchFailure = BridgeUnreachable()
        host.reconcile()
        gate.open()
        // The trailing pass cannot read the bridge either, and says so.
        await settle(until: { !errors.isEmpty })

        XCTAssertEqual(recorder.made, [Self.pathA])
        XCTAssertEqual(recorder.presented, 1)
        XCTAssertEqual(recorder.stopped, 0)
        XCTAssertEqual(host.activeDisplayIDs, [7], "and the failed trailing pass closes nothing")
    }

    // MARK: A display the host cannot see

    /// The bridge reads CoreGraphics' active displays and this host reads
    /// AppKit's screens. Where they disagree (a mirror set, an AirPlay screen, a
    /// closed lid) the offer for the missing display used to vanish without a
    /// trace, which left a wallpaper that never appeared and nothing to look at.
    func testAWantedDisplayTheHostCannotSeeIsReportedNotSilentlyDropped() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        screenFrames = screenFrames.filter { $0.id == 7 }

        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the display it can see plays")
        XCTAssertNil(surfacesMade[9], "no window is built for a screen that is not there")
        XCTAssertEqual(host.offeredButUnseenDisplayIDsForTest, [9])
        XCTAssertEqual(host.unseenWarningCountForTest, 1)
        XCTAssertTrue(recorder.rejected.isEmpty, "a display the host cannot see is not a verdict on the clip")
        XCTAssertEqual(recorder.admissionProbes.count, 1, "and its file is not read for nothing")
    }

    func testTheUnseenDisplayIsOpenedOnceItAppears() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        let both = screenFrames
        screenFrames = both.filter { $0.id == 7 }
        let offer = [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")]
        await host.apply(offer)
        XCTAssertEqual(host.offeredButUnseenDisplayIDsForTest, [9])

        screenFrames = both
        await host.apply(offer)

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertTrue(host.offeredButUnseenDisplayIDsForTest.isEmpty)
        XCTAssertTrue(recorder.rejected.isEmpty)
    }

    func testTheWarningIsNotRepeatedEveryPass() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        screenFrames = screenFrames.filter { $0.id == 7 }
        let offer = [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")]

        for _ in 0..<5 { await host.apply(offer) }

        XCTAssertEqual(host.offeredButUnseenDisplayIDsForTest, [9], "the disagreement is still on record")
        XCTAssertEqual(host.unseenWarningCountForTest, 1, "and said once, not on every snapshot")
    }

    func testADisagreementThatComesBackOrChangesIsReportedAgain() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        let both = screenFrames
        let onlySeven = both.filter { $0.id == 7 }
        let nine = wallpaper(displayID: 9, id: "301")

        screenFrames = onlySeven
        await host.apply([nine])
        XCTAssertEqual(host.unseenWarningCountForTest, 1)

        // Another wallpaper offered for the same missing display is a new fact.
        await host.apply([wallpaper(displayID: 9, id: "302", admissionKey: 2)])
        XCTAssertEqual(host.unseenWarningCountForTest, 2)

        // The bridge stops offering it, and offers it again later.
        await host.apply([])
        XCTAssertTrue(host.offeredButUnseenDisplayIDsForTest.isEmpty)
        await host.apply([nine])
        XCTAssertEqual(host.unseenWarningCountForTest, 3, "an offer that went away and returned is news again")

        // The display shows up, plays, and goes missing again.
        screenFrames = both
        await host.apply([nine])
        XCTAssertEqual(host.activeDisplayIDs, [9])
        XCTAssertEqual(host.unseenWarningCountForTest, 3)
        screenFrames = onlySeven
        await host.apply([nine])
        XCTAssertEqual(host.unseenWarningCountForTest, 4, "a disagreement that comes back is not already known")
    }

    func testADisplayMissingForAMomentIsClosedAndOpensAgainWhenItReturns() async throws {
        // A display that drops out of the screen list for a moment (the refresh
        // that would follow is held back by the settle) is a disagreement, not a
        // verdict: its window goes and the same offer brings it back. What asks
        // for that offer again is the next test.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        let both = screenFrames
        let offer = [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")]
        await host.apply(offer)
        let first = try XCTUnwrap(surfacesMade[9])

        screenFrames = both.filter { $0.id == 7 }
        await host.apply(offer)
        XCTAssertTrue(first.isStopped, "there is nothing to draw on")
        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertEqual(host.offeredButUnseenDisplayIDsForTest, [9])
        XCTAssertTrue(recorder.rejected.isEmpty)

        screenFrames = both
        await host.apply(offer)
        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertFalse(try XCTUnwrap(surfacesMade[9]).isStopped)
        XCTAssertTrue(host.offeredButUnseenDisplayIDsForTest.isEmpty)
        XCTAssertTrue(recorder.rejected.isEmpty)
    }

    /// The host and the refresh filter as the app wires them. A snapshot applied while a
    /// display is missing closes its window, and a display that is back before the settle ends
    /// causes no refresh, so no snapshot follows. The coalescer's announcement of the return is
    /// what brings the window back; without it the display stays dark until some unrelated
    /// snapshot arrives.
    func testADisplayThatReturnsInsideTheSettleHasItsWindowBackWithoutARefresh() async throws {
        let recorder = Recorder()
        let offer = [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")]
        let host = makeHost(wallpapers: offer, recorder: recorder)
        defer { host.shutdown() }
        let both = screenFrames
        var refreshes = 0
        let settleTimer = ManualSleeper()
        let coalescer = DisplayRefreshCoalescer(
            configuration: { [unowned self] in self.displayConfiguration() }, sleep: settleTimer.closure,
            displayReturned: { host.reconcile() }
        ) {
            refreshes += 1
            return true
        }
        defer { coalescer.cancel() }
        coalescer.request()
        await coalescer.waitUntilIdleForTest()
        await host.apply(offer)
        XCTAssertEqual(host.activeDisplayIDs, [7, 9])

        screenFrames = both.filter { $0.id == 7 }
        coalescer.request()
        await settleTimer.waitUntilPending()
        // Any snapshot applied inside the wait runs a pass over the shorter list.
        host.reconcile()
        await settle(until: { host.activeDisplayIDs == [7] })
        XCTAssertEqual(host.offeredButUnseenDisplayIDsForTest, [9])

        screenFrames = both
        coalescer.request()
        await settle(until: { host.activeDisplayIDs == [7, 9] })

        XCTAssertEqual(refreshes, 1, "the display never stayed away long enough to be refreshed for")
        XCTAssertTrue(host.offeredButUnseenDisplayIDsForTest.isEmpty)
        XCTAssertFalse(try XCTUnwrap(surfacesMade[9]).isStopped)
        XCTAssertTrue(recorder.rejected.isEmpty)
    }

    private func displayConfiguration() -> DisplayConfiguration {
        DisplayConfiguration(displays: screenFrames.map {
            .init(id: $0.id, frame: $0.frame, scale: 2, refreshRate: 60)
        })
    }

    func testShuttingDownForgetsWhatWasUnseen() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        screenFrames = screenFrames.filter { $0.id == 7 }
        await host.apply([wallpaper(displayID: 9, id: "301")])
        XCTAssertEqual(host.offeredButUnseenDisplayIDsForTest, [9])

        host.shutdown()

        XCTAssertTrue(host.offeredButUnseenDisplayIDsForTest.isEmpty)
    }

    // MARK: First frame

    /// Lets work the host started on its own turn reach `condition`, without
    /// sleeping: each yield gives the main actor to whatever is queued.
    private func settle(
        until condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "never settled", file: file, line: line)
    }

    /// Opens display 7 and waits until its first-frame countdown is running.
    private func openAndWaitForTheCountdown(
        _ host: NativeVideoWallpaperHost, _ descriptor: BridgeNativeVideoWallpaper? = nil
    ) async throws -> FakeSurface {
        await host.apply([descriptor ?? wallpaper(admissionKey: 5)])
        await sleeper.waitUntilPending()
        return try XCTUnwrap(surfacesMade[7])
    }

    func testASurfaceThatNeverShowsAFrameIsRestartedOnceThenReportedAsFailed() async throws {
        // A clip the platform calls playable can reach readyToPlay with its
        // clock running and never produce a picture; nothing reports a failure.
        // Without a deadline the display stays black and the wallpaper's state
        // stuck at loading.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        counters.startSession(duration: .seconds(60))
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }
        let surface = try await openAndWaitForTheCountdown(host)
        XCTAssertEqual(recorder.presented, 1)
        XCTAssertTrue(surface.restartReasons.isEmpty, "the deadline has not passed")
        XCTAssertEqual(states.last?.phase, .loading)

        sleeper.fireNext()
        await sleeper.waitUntilPending()

        XCTAssertEqual(surface.restartReasons.count, 1, "the first miss rebuilds the pipeline")
        XCTAssertTrue(recorder.rejected.isEmpty, "and gives the rebuilt clip its own deadline")
        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertEqual(recorder.stopped, 0)
        let passes = PassCounter()
        host.onSurfacesChanged = { passes.record() }

        sleeper.fireNext()
        await passes.wait(for: 1)

        XCTAssertEqual(states.filter { $0.phase == .failed }.count, 1, "the display is reported as failed")
        XCTAssertEqual(states.last?.nativeAdmissionKey, 5)
        XCTAssertEqual(surface.restartReasons.count, 1, "one restart and no more")
        XCTAssertTrue(host.isEmpty, "no window is left behind")
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(states.last?.phase, .failed, "and the wallpaper's startup ends")
        XCTAssertEqual(counters.snapshot().total(.nativeVideoFirstFrameTimeout), 2)
    }

    func testTheRestartedClipGetsADeadlineOfTheSameLength() async throws {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [], recorder: recorder, storage: { _ in .networkVolume },
            manualLimits: true)
        defer { host.shutdown() }
        _ = try await openAndWaitForTheCountdown(host)

        sleeper.fireNext()
        await sleeper.waitUntilPending()

        let waits = sleeper.requested.suffix(2)
        XCTAssertEqual(Array(waits), [.seconds(90), .seconds(90)])
    }

    func testAFrameBeforeTheDeadlineCancelsTheWatch() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let surface = try await openAndWaitForTheCountdown(host)
        XCTAssertEqual(host.armedFirstFrameWatchCountForTest, 1)
        let cancelled = sleeper.cancelledCount

        surface.isReadyForDisplay = true
        surface.onReadyForDisplay?()

        XCTAssertEqual(host.armedFirstFrameWatchCountForTest, 0)
        XCTAssertEqual(sleeper.cancelledCount, cancelled + 1, "the countdown is stopped, not left to expire")
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertFalse(sleeper.fireNext(), "nothing is left to fire")
        XCTAssertTrue(surface.restartReasons.isEmpty)
        XCTAssertTrue(recorder.rejected.isEmpty)
        XCTAssertEqual(host.activeDisplayIDs, [7])
    }

    func testALateFrameAfterTheHandOffIsIgnored() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }
        let surface = try await openAndWaitForTheCountdown(host)
        surface.restartResult = false
        let passes = PassCounter()
        host.onSurfacesChanged = { passes.record() }
        sleeper.fireNext()
        await passes.wait(for: 1)
        XCTAssertEqual(states.filter { $0.phase == .failed }.count, 1)

        surface.isReadyForDisplay = true
        surface.onReadyForDisplay?()
        await Task.yield()

        XCTAssertEqual(states.last?.phase, .failed, "a picture that arrives too late does not reopen startup")
        XCTAssertFalse(states.contains { $0.phase == .ready })
        XCTAssertEqual(states.filter { $0.phase == .failed }.count, 1, "and nothing is reported twice")
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertTrue(host.isEmpty)
    }

    func testAReplacedSurfaceIsNotJudgedByTheOldTimer() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let old = try await openAndWaitForTheCountdown(host, wallpaper(id: "300", admissionKey: 1))

        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        await sleeper.waitUntilPending()
        let new = try XCTUnwrap(surfacesMade[7])
        XCTAssertFalse(new === old)
        XCTAssertEqual(sleeper.pendingCount, 1, "the old countdown went with its surface")

        sleeper.fireNext()
        await sleeper.waitUntilPending()

        XCTAssertTrue(old.restartReasons.isEmpty, "the replaced surface is never touched again")
        XCTAssertEqual(new.restartReasons.count, 1)
        XCTAssertTrue(recorder.rejected.isEmpty)
    }

    func testTheDeadlineFollowsTheStorageClass() async throws {
        // The same clip takes longer to start from a share than from the
        // internal drive, and none of that is a fault. Each row is the metadata
        // read's limit followed by the first-frame deadline for that class.
        let recorder = Recorder()
        let rows: [(String, NativeVideoStoragePolicy.Location, Int, Int)] = [
            ("internal", .internalVolume, 8, 10),
            ("external", .removableVolume, 30, 30),
            ("share", .networkVolume, 60, 90),
            ("cloud", .dataless, 60, 90),
            ("unreadable", .unknown, 30, 30),
        ]
        for (name, storage, probe, frame) in rows {
            let host = makeHost(
                wallpapers: [], recorder: recorder, storage: { _ in storage }, manualLimits: true)
            let before = sleeper.requested.count
            await host.apply([wallpaper(admissionKey: 1)])
            await sleeper.waitUntilPending()
            XCTAssertEqual(
                Array(sleeper.requested.dropFirst(before)), [.seconds(probe), .seconds(frame)], name)
            host.shutdown()
        }
    }

    func testAHiddenDisplayIsNotHandedBackAndIsJudgedAgainWhenItReturns() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        counters.startSession(duration: .seconds(60))
        let surface = try await openAndWaitForTheCountdown(host)
        host.setPresentationSuspended(true, forDisplay: 7)

        sleeper.fireNext()
        await settle { host.parkedFirstFrameWatchCountForTest == 1 }

        XCTAssertTrue(surface.restartReasons.isEmpty, "a hidden display is not judged")
        XCTAssertTrue(recorder.rejected.isEmpty)
        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertEqual(counters.snapshot().total(.nativeVideoFirstFrameTimeout), 0)
        XCTAssertEqual(sleeper.pendingCount, 0, "and no timer runs while it is hidden")

        host.setPresentationSuspended(false, forDisplay: 7)
        await sleeper.waitUntilPending()
        XCTAssertEqual(host.parkedFirstFrameWatchCountForTest, 0)
        XCTAssertEqual(sleeper.requested.last, .seconds(10), "a full deadline, not the remainder")
        sleeper.fireNext()
        await sleeper.waitUntilPending()

        XCTAssertEqual(surface.restartReasons.count, 1, "judged now that it can be seen")
    }

    func testAParkedWatchWaitsForBothReasonsToEnd() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let surface = try await openAndWaitForTheCountdown(host)
        host.setPresentationSuspended(true)
        host.setPresentationSuspended(true, forDisplay: 7)
        sleeper.fireNext()
        await settle { host.parkedFirstFrameWatchCountForTest == 1 }

        // The display is still hidden on its own account, so the global
        // resume must not start the clock.
        host.setPresentationSuspended(false)
        XCTAssertEqual(host.parkedFirstFrameWatchCountForTest, 1)
        XCTAssertEqual(sleeper.pendingCount, 0)

        host.setPresentationSuspended(false, forDisplay: 7)
        await sleeper.waitUntilPending()
        XCTAssertEqual(host.armedFirstFrameWatchCountForTest, 1)
        XCTAssertTrue(surface.restartReasons.isEmpty)
    }

    func testAParkedWatchKeepsTheRestartItAlreadySpent() async throws {
        // Hidden after the restart: the clip is not given a second restart
        // when it returns, it is handed back if it still shows nothing.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let surface = try await openAndWaitForTheCountdown(host)
        sleeper.fireNext()
        await sleeper.waitUntilPending()
        XCTAssertEqual(surface.restartReasons.count, 1)
        host.setPresentationSuspended(true, forDisplay: 7)
        sleeper.fireNext()
        await settle { host.parkedFirstFrameWatchCountForTest == 1 }
        host.setPresentationSuspended(false, forDisplay: 7)
        await sleeper.waitUntilPending()
        let passes = PassCounter()
        host.onSurfacesChanged = { passes.record() }

        sleeper.fireNext()
        await passes.wait(for: 1)

        XCTAssertEqual(surface.restartReasons.count, 1, "no second restart for the same clip")
        XCTAssertEqual(recorder.rejected.count, 1)
    }

    func testATimeoutIsNotCachedAsAVerdict() async throws {
        // Slow storage or a one-off stall is not proof that the clip cannot
        // play, so an offer of the same key opens it again. (The bridge makes
        // that offer only once the key has changed or the backend was switched.)
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let surface = try await openAndWaitForTheCountdown(host)
        surface.restartResult = false
        let passes = PassCounter()
        host.onSurfacesChanged = { passes.record() }
        sleeper.fireNext()
        await passes.wait(for: 1)
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(recorder.rejected.count, 1)

        await host.apply([wallpaper(admissionKey: 5)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the same key plays again")
        XCTAssertEqual(recorder.presented, 2)
        XCTAssertEqual(recorder.rejected.count, 1, "and is not handed over a second time")
        XCTAssertEqual(recorder.admissionProbes.count, 1, "the file itself was not re-read")
    }

    func testAStalledPipelineTheRepairsGaveUpOnIsNotRememberedAsAVerdict() async throws {
        // The health ladder gives up on a pipeline that stopped delivering, for
        // instance after a long sleep took the decoder away. That is a fact about
        // the moment, not the file: the wallpaper goes to the scene engine now and
        // is offered to this backend again once the bridge offers the key again.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        await host.apply([wallpaper(admissionKey: 5)])
        let passes = PassCounter()
        host.onSurfacesChanged = { passes.record() }
        surfacesMade[7]?.failPreparation("playback stalled after the Mac woke", settled: false)
        await passes.wait(for: 1)
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertTrue(host.isEmpty)

        await host.apply([wallpaper(admissionKey: 5)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the same key plays natively again")
        XCTAssertEqual(recorder.presented, 2)
        XCTAssertEqual(recorder.rejected.count, 1, "and is not handed over a second time")
        XCTAssertEqual(recorder.admissionProbes.count, 1, "the file itself was not re-read")
    }

    func testADecoderFailureIsStillRememberedAsAVerdict() async throws {
        // The contrast: a decoder that could not open the track is a statement
        // about the file, so the same key is not opened again.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        await host.apply([wallpaper(admissionKey: 5)])
        let passes = PassCounter()
        host.onSurfacesChanged = { passes.record() }
        surfacesMade[7]?.failPreparation("decoder could not open the track")
        await passes.wait(for: 1)
        XCTAssertEqual(recorder.rejected.count, 1)

        await host.apply([wallpaper(admissionKey: 5)])

        XCTAssertTrue(host.isEmpty, "the same key is not opened again")
        XCTAssertEqual(recorder.rejected.count, 1, "the remembered verdict is restated, not reported anew")
        XCTAssertEqual(recorder.states.last?.phase, .failed)
        XCTAssertEqual(recorder.presented, 1)
    }

    func testARestartThatThePlayerRefusesHandsOffAtOnce() async throws {
        // The player's recovery allowance is spent: there is nothing to try, so
        // waiting a second deadline would only keep the display black longer.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let surface = try await openAndWaitForTheCountdown(host)
        surface.restartResult = false
        let passes = PassCounter()
        host.onSurfacesChanged = { passes.record() }

        sleeper.fireNext()
        await passes.wait(for: 1)

        XCTAssertEqual(surface.restartReasons.count, 1, "it was asked, and said no")
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(sleeper.pendingCount, 0, "and no second countdown is left running")
    }

    func testAUserPausedClipIsStillJudged() async throws {
        // A paused item that is ready still shows its first frame, so the
        // user's own pause is no reason to wait longer for it.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let surface = try await openAndWaitForTheCountdown(
            host, wallpaper(paused: true, admissionKey: 5))

        sleeper.fireNext()
        await sleeper.waitUntilPending()

        XCTAssertEqual(surface.restartReasons.count, 1)
    }

    func testOneDisplaysFrameDoesNotSettleAnothersWatch() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        await host.apply([
            wallpaper(displayID: 7, id: "300", admissionKey: 1),
            wallpaper(displayID: 9, id: "301", admissionKey: 2),
        ])
        await sleeper.waitUntilPending(2)
        let shown = try XCTUnwrap(surfacesMade[7])
        let black = try XCTUnwrap(surfacesMade[9])

        shown.isReadyForDisplay = true
        shown.onReadyForDisplay?()
        XCTAssertEqual(host.armedFirstFrameWatchCountForTest, 1)
        sleeper.fireNext()
        await sleeper.waitUntilPending()

        XCTAssertTrue(shown.restartReasons.isEmpty)
        XCTAssertEqual(black.restartReasons.count, 1)
    }

    func testClosingTheSurfaceOrShuttingDownStopsTheCountdown() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        _ = try await openAndWaitForTheCountdown(host)

        await host.apply([])
        XCTAssertEqual(sleeper.pendingCount, 0, "a wallpaper that left needs no deadline")
        XCTAssertEqual(host.armedFirstFrameWatchCountForTest, 0)

        let surface = try await openAndWaitForTheCountdown(host)
        host.shutdown()
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertFalse(sleeper.fireNext())
        XCTAssertTrue(surface.restartReasons.isEmpty)
        XCTAssertTrue(recorder.rejected.isEmpty)
    }

    // MARK: Health

    private let displaySevenKey = RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 7)

    /// Opens display 7 and gives it the picture a health check needs to have
    /// seen before it is worth running.
    private func openAShowingSurface(_ host: NativeVideoWallpaperHost) async throws -> FakeSurface {
        await host.apply([wallpaper(admissionKey: 5)])
        let surface = try XCTUnwrap(surfacesMade[7])
        surface.isReadyForDisplay = true
        surface.onReadyForDisplay?()
        return surface
    }

    func testAStalledReportIsCountedAndTheHostItselfDoesNothingAboutIt() async throws {
        // The surface repairs its own pipeline and reports its own failure.
        // The host only records what it is told, so a report can never rebuild
        // or hand over a wallpaper behind the surface's back.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        counters.startSession(duration: .seconds(60))
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }
        let surface = try await openAShowingSurface(host)
        let statesBefore = states

        for _ in 0..<2 {
            surface.onHealthEvent?(NativeVideoHealthEvent(
                trigger: "resumed after 2 h",
                verdict: .stalled("the clock advances but no frame is produced")))
        }

        XCTAssertEqual(counters.snapshot().value(.nativeVideoPlaybackStalled, for: displaySevenKey), 2)
        XCTAssertEqual(host.activeDisplayIDs, [7], "the surface stays open")
        XCTAssertEqual(recorder.stopped, 0)
        XCTAssertTrue(recorder.rejected.isEmpty, "and is not handed to the scene engine")
        XCTAssertTrue(surface.restartReasons.isEmpty, "nor rebuilt")
        XCTAssertEqual(host.isPlaying(displayID: 7), true)
        XCTAssertEqual(states, statesBefore, "the wallpaper's startup state is untouched")
    }

    func testOnlyTheFirstLookOfACheckCountsAsAStall() async throws {
        // One stall is a kick, a rebuild and a give-up, each followed by a look
        // that finds the same thing. The counter answers how often a long
        // pause costs the decoder, so it counts the stall, not the looks.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        counters.startSession(duration: .seconds(60))
        let surface = try await openAShowingSurface(host)
        let detail = "the clock advances but no frame is produced"

        surface.onHealthEvent?(NativeVideoHealthEvent(
            trigger: "the displays woke", verdict: .stalled(detail), stage: .initial, next: .kick))
        surface.onHealthEvent?(NativeVideoHealthEvent(
            trigger: "the displays woke", verdict: .stalled(detail), stage: .afterKick, next: .rebuild))
        surface.onHealthEvent?(NativeVideoHealthEvent(
            trigger: "the displays woke", verdict: .stalled(detail), stage: .afterRebuild,
            next: .giveUp(detail)))

        XCTAssertEqual(counters.snapshot().value(.nativeVideoPlaybackStalled, for: displaySevenKey), 1)
        XCTAssertEqual(host.activeDisplayIDs, [7], "the hand-off is the surface's own report, not this one")
        XCTAssertTrue(recorder.rejected.isEmpty)
    }

    func testAHealthyOrUnjudgedReportIsNotCountedAsAStall() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        counters.startSession(duration: .seconds(60))
        let surface = try await openAShowingSurface(host)

        surface.onHealthEvent?(NativeVideoHealthEvent(trigger: "resumed after 2 h", verdict: .advancing))
        surface.onHealthEvent?(NativeVideoHealthEvent(
            trigger: "resumed after 2 h", verdict: .waiting("the player was waiting for data throughout")))

        XCTAssertEqual(counters.snapshot().total(.nativeVideoPlaybackStalled), 0)
        XCTAssertEqual(host.activeDisplayIDs, [7])
    }

    func testAReportFromAReplacedSurfaceIsIgnored() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        counters.startSession(duration: .seconds(60))
        let old = try await openAShowingSurface(host)
        await host.apply([wallpaper(id: "replacement", admissionKey: 6)])
        let current = try XCTUnwrap(surfacesMade[7])
        XCTAssertFalse(old === current)
        let stalled = NativeVideoHealthEvent(trigger: "resumed after 2 h", verdict: .stalled("no frame"))

        old.onHealthEvent?(stalled)
        XCTAssertEqual(
            counters.snapshot().total(.nativeVideoPlaybackStalled), 0,
            "a surface that has since been replaced is not the display's pipeline")

        current.onHealthEvent?(stalled)
        XCTAssertEqual(counters.snapshot().value(.nativeVideoPlaybackStalled, for: displaySevenKey), 1)
    }

    // MARK: Wake

    private let wakeNotifications = [
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.didWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
    ]

    /// Opens a clip on each of `displays` and gives every surface the picture a
    /// health check needs to have seen, which also ends its first-frame wait.
    /// What is left pending on the sleeper afterwards is whatever the test
    /// starts next.
    private func openShowingSurfaces(
        _ host: NativeVideoWallpaperHost, displays: [UInt32], paused: Set<UInt32> = []
    ) async throws -> [UInt32: FakeSurface] {
        let frame = NSRect(x: 0, y: 0, width: 80, height: 60)
        screenFrames = displays.map { ($0, frame) }
        await host.apply(displays.map {
            wallpaper(
                displayID: $0, id: "wake-\($0)", paused: paused.contains($0),
                admissionKey: UInt64($0))
        })
        var opened: [UInt32: FakeSurface] = [:]
        for display in displays {
            let surface = try XCTUnwrap(surfacesMade[display])
            surface.isReadyForDisplay = true
            surface.onReadyForDisplay?()
            opened[display] = surface
        }
        await settle(until: { self.sleeper.pendingCount == 0 })
        return opened
    }

    func testAWakeAsksOnlyThePlayingSurfacesToCheckTheirPipelines() async throws {
        let workspace = NotificationCenter()
        let host = makeHost(
            wallpapers: [], recorder: Recorder(), workspaceCenter: workspace, manualLimits: true)
        host.start()
        defer { host.shutdown() }
        let surfaces = try await openShowingSurfaces(host, displays: [7, 8, 9], paused: [8])
        host.setPresentationSuspended(true, forDisplay: 9)
        XCTAssertEqual(host.isPlaying(displayID: 7), true)
        XCTAssertEqual(host.isPlaying(displayID: 8), false, "the user paused this one")
        XCTAssertEqual(host.isPlaying(displayID: 9), false, "and this one is hidden")

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await sleeper.waitUntilPending()
        XCTAssertTrue(
            surfaces.values.allSatisfy { $0.verifyReasons.isEmpty },
            "the system gets a moment to hand the decoder back first")
        sleeper.fireNext()
        await settle(until: { !(surfaces[7]?.verifyReasons.isEmpty ?? true) })

        XCTAssertEqual(surfaces[7]?.verifyReasons.count, 1)
        XCTAssertEqual(surfaces[8]?.verifyReasons.count, 0, "a pause the user chose is not undone by a wake")
        XCTAssertEqual(surfaces[9]?.verifyReasons.count, 0, "nor is a hidden display looked at")
    }

    func testEveryWayTheSystemComesBackAsksForACheck() async throws {
        for name in wakeNotifications {
            let workspace = NotificationCenter()
            let host = makeHost(
                wallpapers: [], recorder: Recorder(), workspaceCenter: workspace,
                manualLimits: true)
            host.start()
            let surfaces = try await openShowingSurfaces(host, displays: [7])

            workspace.post(name: name, object: nil)
            await sleeper.waitUntilPending()
            sleeper.fireNext()
            await settle(until: { !(surfaces[7]?.verifyReasons.isEmpty ?? true) })

            XCTAssertEqual(surfaces[7]?.verifyReasons.count, 1, "\(name.rawValue)")
            host.shutdown()
        }
    }

    func testASecondWakeSupersedesTheFirst() async throws {
        // The system announces a wake in a burst: the displays, the Mac, then
        // the session. One check for the burst, taken after the last of them.
        let workspace = NotificationCenter()
        let host = makeHost(
            wallpapers: [], recorder: Recorder(), workspaceCenter: workspace, manualLimits: true)
        host.start()
        defer { host.shutdown() }
        let surfaces = try await openShowingSurfaces(host, displays: [7])

        let cancelledBefore = sleeper.cancelledCount
        for name in wakeNotifications { workspace.post(name: name, object: nil) }
        await sleeper.waitUntilPending()
        XCTAssertEqual(sleeper.pendingCount, 1, "one settle is running, not three")
        XCTAssertEqual(sleeper.cancelledCount - cancelledBefore, 2, "the earlier ones were cancelled")
        sleeper.fireNext()
        await settle(until: { !(surfaces[7]?.verifyReasons.isEmpty ?? true) })
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(surfaces[7]?.verifyReasons.count, 1)
    }

    func testASurfaceThatStoppedPlayingDuringTheSettleIsNotAsked() async throws {
        let workspace = NotificationCenter()
        let host = makeHost(
            wallpapers: [], recorder: Recorder(), workspaceCenter: workspace, manualLimits: true)
        host.start()
        defer { host.shutdown() }
        let surfaces = try await openShowingSurfaces(host, displays: [7, 8])

        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await sleeper.waitUntilPending()
        host.setPresentationSuspended(true, forDisplay: 7)  // the display went back to sleep
        sleeper.fireNext()
        await settle(until: { !(surfaces[8]?.verifyReasons.isEmpty ?? true) })

        XCTAssertEqual(surfaces[8]?.verifyReasons.count, 1)
        XCTAssertEqual(surfaces[7]?.verifyReasons.count, 0, "who is playing is decided when the settle ends")
    }

    func testAWakeWithNoSurfaceOpenStartsNoTimer() async throws {
        // The default backend never opens a surface; a wake must cost it nothing.
        let workspace = NotificationCenter()
        let host = makeHost(
            wallpapers: [], recorder: Recorder(), workspaceCenter: workspace, manualLimits: true)
        host.start()
        defer { host.shutdown() }

        for name in wakeNotifications { workspace.post(name: name, object: nil) }
        for _ in 0..<50 { await Task.yield() }

        XCTAssertTrue(sleeper.requested.isEmpty, "no settle runs for a host with nothing to check")

        // Once a surface plays, the same wake does start its settle.
        let surfaces = try await openShowingSurfaces(host, displays: [7])
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await sleeper.waitUntilPending()
        sleeper.fireNext()
        await settle(until: { !(surfaces[7]?.verifyReasons.isEmpty ?? true) })
        XCTAssertEqual(surfaces[7]?.verifyReasons.count, 1)
    }

    func testAClosedHostIgnoresWakes() async throws {
        let workspace = NotificationCenter()
        let host = makeHost(
            wallpapers: [], recorder: Recorder(), workspaceCenter: workspace, manualLimits: true)
        host.start()
        let surfaces = try await openShowingSurfaces(host, displays: [7])
        let cancelledBefore = sleeper.cancelledCount
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await sleeper.waitUntilPending()

        host.shutdown()
        XCTAssertEqual(sleeper.cancelledCount - cancelledBefore, 1, "the settle in flight is cancelled")
        let timers = sleeper.requested.count
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(sleeper.requested.count, timers, "and no wake starts another")
        XCTAssertTrue(surfaces[7]?.verifyReasons.isEmpty == true)
    }

    func testAKeyRefusedThenSupersededThenOfferedAgainIsReportedAgain() async {
        // The bridge prunes a refusal whose key no longer matches any live
        // display slot. Going 30 -> 60 -> 30 therefore brings key 30 back as a
        // fresh offer. A permanent local skip list made the host ignore it
        // while the bridge had already excluded the scene engine for that
        // display: no native surface, no scene, nothing on screen.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalSequence: [.notPlayable("no video track"), nil],
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 30)])
        XCTAssertEqual(recorder.rejected.count, 1)

        await host.apply([wallpaper(admissionKey: 60)])
        XCTAssertEqual(host.activeDisplayIDs, [7], "60 is admissible")

        await host.apply([wallpaper(admissionKey: 30)])

        XCTAssertTrue(host.isEmpty, "30 is still not admissible")
        XCTAssertEqual(
            recorder.rejected.count, 2,
            "the offer must be answered again, not silently skipped")
        XCTAssertEqual(recorder.rejected.last?.key, 30)
        host.shutdown()
    }

    func testARepeatedOfferOfAStillRefusedKeyIsRestatedWithoutReadingTheFileAgain() async {
        // The bridge goes on offering a key the host failed on (it holds no record of failures).
        // The display's failed state is restated under each offer so the panel and the bridge's
        // wait for startup both see an answer, but the file is not read, nor reported, again.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusal: .notPlayable("no video track"),
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 77)])
        await host.apply([wallpaper(admissionKey: 77)])

        XCTAssertEqual(recorder.rejected.count, 1, "reported once: the second offer restates the same state")
        XCTAssertEqual(recorder.states.last?.phase, .failed)
        XCTAssertEqual(
            recorder.admissionProbes.count, 1,
            "the file is only read once, because the verdict is cached")
        host.shutdown()
    }

    func testAMirrorGroupIsJudgedOnceAndRefusedAsAUnit() async {
        // A source display and its mirror share one admission key, because the
        // mirror has no scene of its own to fall back to. The file is read once
        // for the pair, and one recorded refusal sends all of it back.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusal: .notPlayable("no video track"),
            recorder: recorder)

        await host.apply([
            wallpaper(displayID: 7, admissionKey: 99),
            wallpaper(displayID: 9, admissionKey: 99),
        ])

        XCTAssertEqual(recorder.admissionProbes.count, 1, "the group is probed once")
        XCTAssertTrue(host.isEmpty, "neither member may play a clip the group cannot")
        XCTAssertFalse(recorder.rejected.isEmpty)
        XCTAssertTrue(
            recorder.rejected.allSatisfy { $0.key == 99 },
            "one key covers the group, so one recorded refusal sends all of it back")
        host.shutdown()
    }

    func testAMirrorGroupOfAPlayableClipIsAdmitted() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)

        await host.apply([
            wallpaper(displayID: 7, admissionKey: 100),
            wallpaper(displayID: 9, admissionKey: 100),
        ])

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertEqual(recorder.admissionProbes.count, 1, "one probe covers the group")
        XCTAssertTrue(recorder.rejected.isEmpty)
        host.shutdown()
    }

    func testTheSameOfferIsProbedOnceEvenAcrossRepeatedPasses() async {
        // Reconcile runs on display changes, wallpaper changes and suspension
        // changes. Re-reading the media file on each of those would be a file
        // read per pass for a decision that cannot have changed.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)

        await host.apply([wallpaper(admissionKey: 11)])
        await host.apply([])
        await host.apply([wallpaper(admissionKey: 11)])

        XCTAssertEqual(recorder.admissionProbes.count, 1)
        host.shutdown()
    }

    func testAnUnplayableAssetIsHandedBackWithItsReason() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper()],
            refusal: .notPlayable("no video track"),
            recorder: recorder)

        await host.apply([wallpaper()])

        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertTrue(recorder.rejected.first?.reason.contains("no video track") == true)
        XCTAssertTrue(host.isEmpty)
        host.shutdown()
    }

    func testAFormatNothingCanPlayKeepsThePreviousPictureAndShowsItsMessage() async {
        // An already-assigned file in a format no player reads (a library item applied before,
        // or a migrated config): the scene engine is not asked either. The display keeps the
        // picture it had, the panel gets the message through the wallpaper's state, and the
        // bridge is told nothing, so nothing is handed back and forth.
        let recorder = Recorder()
        let message = "This video’s format isn’t supported (AVI), or the file is damaged."
        let host = makeHost(
            wallpapers: [wallpaper()],
            refusal: .unsupportedFormat(message),
            recorder: recorder)
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }

        await host.apply([wallpaper()])

        XCTAssertTrue(recorder.rejected.isEmpty, "the scene engine is not the answer for this file")
        XCTAssertTrue(recorder.made.isEmpty, "no window, so nothing covers the previous picture")
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(states.last?.phase, .failed, "the wallpaper's startup ends")
        XCTAssertEqual(states.last?.message, message, "and the panel can show why")
        XCTAssertFalse(states.contains { $0.phase == .ready })
        host.shutdown()
    }

    func testAnUnsupportedFormatIsReadOnceAndAnsweredEachTimeItIsOffered() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusal: .unsupportedFormat("not supported"),
            recorder: recorder)
        var states: [HostWallpaperState] = []
        host.onStateChanged = { states.append($0) }

        await host.apply([wallpaper(admissionKey: 5)])
        await host.apply([wallpaper(admissionKey: 5)])

        XCTAssertEqual(recorder.admissionProbes.count, 1, "the verdict is kept under the key")
        XCTAssertTrue(recorder.rejected.isEmpty)
        XCTAssertEqual(states.filter { $0.phase == .failed }.count, 1, "and the state is not repeated")
        host.shutdown()
    }

    func testAReplacedFileIsJudgedAgainAfterAnUnsupportedOne() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalSequence: [.unsupportedFormat("not supported"), nil],
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 5)])
        XCTAssertTrue(host.isEmpty)

        await host.apply([wallpaper(admissionKey: 6)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "a file that plays is opened as usual")
        XCTAssertEqual(recorder.rejected.count, 1, "only the first file failed")
        XCTAssertEqual(recorder.states.last?.phase, .loading)
        host.shutdown()
    }

    func testAnAcceptedWallpaperOpensExactlyOneSurfacePerDisplay() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")],
            recorder: recorder)

        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")])

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertTrue(recorder.rejected.isEmpty)
        XCTAssertEqual(recorder.presented, 2)
        host.shutdown()
        XCTAssertTrue(host.isEmpty, "shutdown must leave no player running")
        XCTAssertEqual(recorder.stopped, 2, "every surface has to be stopped, not just dropped")
    }

    func testHidingOneDisplayLeavesTheOtherPlaying() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")],
            recorder: recorder)
        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")])

        host.setPresentationSuspended(true, forDisplay: 9)

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertTrue(host.isPlaying(displayID: 7) == true)
        XCTAssertTrue(host.isPlaying(displayID: 9) == false)
        host.shutdown()
    }

    func testRevealingADisplayDoesNotStartAWallpaperTheUserPaused() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper(paused: true)], recorder: recorder)
        await host.apply([wallpaper(paused: true)])

        host.setPresentationSuspended(true, forDisplay: 7)
        host.setPresentationSuspended(false, forDisplay: 7)

        XCTAssertEqual(
            host.isPlaying(displayID: 7), false,
            "visibility must never clear the user's own pause")
        host.shutdown()
    }

    func testAGlobalResumeKeepsADisplayThatIsStillHiddenStopped() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper()])

        host.setPresentationSuspended(true, forDisplay: 7)
        host.setPresentationSuspended(true)
        host.setPresentationSuspended(false)

        XCTAssertEqual(host.isPlaying(displayID: 7), false)
        host.setPresentationSuspended(false, forDisplay: 7)
        XCTAssertEqual(host.isPlaying(displayID: 7), true)
        host.shutdown()
    }

    func testAClipStoppedByACoveredDesktopPlaysAgainWhenTheHostsReadTheBridgeAgain() async {
        // The bridge folds a covered desktop into the descriptor's `paused`, and
        // committing the change returns no snapshot. A pass that runs while it
        // holds (the status menu opening, the charger being plugged in) leaves
        // the clip user-paused by that reading, and uncovering the desktop only
        // lifts the host's own suspension: the reading stays until the hosts
        // are told to read again.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper(paused: false)], recorder: recorder)
        defer { host.shutdown() }
        await host.apply([wallpaper()])
        host.setPresentationSuspended(true)
        await host.apply([wallpaper(paused: true)])
        host.setPresentationSuspended(false)
        XCTAssertEqual(
            host.isPlaying(displayID: 7), false, "the covered reading is still what the clip holds")

        await reconcile(WallpaperHosts(web: nil, native: host), host)

        XCTAssertEqual(host.isPlaying(displayID: 7), true)
    }

    func testAClipOnADisplayThatWasHiddenPlaysAgainWhenTheHostsReadTheBridgeAgain() async {
        // The same for one display: its own suspension is part of that display's
        // `paused`, and showing it again returns no snapshot either. The other
        // display's reading is its own.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")],
            recorder: recorder)
        defer { host.shutdown() }
        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")])
        host.setPresentationSuspended(true, forDisplay: 9)
        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301", paused: true)])
        host.setPresentationSuspended(false, forDisplay: 9)
        XCTAssertEqual(host.isPlaying(displayID: 9), false)

        await reconcile(WallpaperHosts(web: nil, native: host), host)

        XCTAssertEqual(host.isPlaying(displayID: 9), true)
        XCTAssertEqual(host.isPlaying(displayID: 7), true, "and the display that never stopped plays on")
    }

    /// Reads the bridge again through `hosts` and waits for that pass to finish.
    private func reconcile(_ hosts: WallpaperHosts, _ host: NativeVideoWallpaperHost) async {
        let finished = expectation(description: "the host read the bridge again")
        host.onSurfacesChanged = { finished.fulfill() }
        hosts.reconcile()
        await fulfillment(of: [finished], timeout: 10)
    }

    func testAWallpaperThatLeavesTheNativeBackendStopsPlayingImmediately() async {
        // The bridge stops returning it — because the user switched wallpaper,
        // turned the backend off, or the routing changed. Leaving the player
        // running would mean two backends decoding for one display.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper()])
        XCTAssertEqual(host.activeDisplayIDs, [7])

        await host.apply([])

        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(
            recorder.stopped, 1,
            "the player must stop in the same pass, not when something else happens to run")
        host.shutdown()
    }

    func testSwitchingWallpaperOnOneDisplayReplacesTheSurface() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper(id: "300")])
        let firstGeneration = host.surfaceGenerationForTest

        await host.apply([wallpaper(id: "301", admissionKey: 2)])

        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertNotEqual(
            host.surfaceGenerationForTest, firstGeneration,
            "a new wallpaper is a new surface, so its counters are not merged with the old one's")
        host.shutdown()
    }

    func testAPosterFromAReplacedSurfaceIsNotPublished() async {
        // The request outlives the wallpaper it was made against. Publishing
        // its frame would put the previous clip's picture under the new one.
        let recorder = Recorder()
        let center = NotificationCenter()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder, frameCenter: center)
        host.start()
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        surfacesMade[7]?.poster = Self.makeImage()
        surfacesMade[7]?.posterDelay = .milliseconds(60)

        var published: [CALayer] = []
        let observer = center.addObserver(
            forName: DesktopPosterNotification.ready, object: nil,
            queue: .main
        ) { note in
            if let layer = note.object as? CALayer { published.append(layer) }
        }
        defer { center.removeObserver(observer) }

        center.post(
            name: DesktopPosterNotification.request, object: surfacesMade[7]?.posterLayer)
        // Replace the wallpaper while the request is still in flight.
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(
            published.isEmpty,
            "a frame produced by the surface that has been replaced must not be delivered")
        host.shutdown()
    }

    func testAPosterFromTheCurrentSurfaceReachesTheDesktopCoordinator() async throws {
        let recorder = Recorder()
        let center = NotificationCenter()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder, frameCenter: center)
        host.start()
        await host.apply([wallpaper()])
        surfacesMade[7]?.poster = Self.makeImage()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-poster-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = DesktopPictureTarget(display: "7", space: "test-space")
        let workspace = PosterWorkspace(target: target, original: root.appendingPathComponent("original.png"))
        let layer = try XCTUnwrap(surfacesMade[7]?.posterLayer)
        let updated = expectation(description: "native pixels published through the real desktop coordinator")
        let sync = try DesktopWallpaperSync(folder: root.appendingPathComponent("posters"), workspace: workspace,
            surfaces: { [DesktopPosterSurface(layer: layer, display: "7")] }, frameCenter: center,
            scope: { _ in .desktop(id: "test-space", context: "native-video-space-visit") })
        workspace.didWrite = { updated.fulfill() }
        sync.start()
        sync.refresh()
        await fulfillment(of: [updated], timeout: 2)

        let picture = try XCTUnwrap(workspace.picture)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(picture.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        let frame = try XCTUnwrap(DesktopPosterFrame.rgba(image))
        // ImageIO's ICC round trip can move an 8-bit channel by a few levels.
        for (actual, expected) in zip(frame.pixels.prefix(3), [255, 0, 0]) {
            XCTAssertEqual(Double(actual), Double(expected), accuracy: 4)
        }
        workspace.didWrite = nil
        try sync.stopAndRestore()
        host.shutdown()
    }

    func testScreenGeometryUpdatesWithoutRecreatingThePlayingSurface() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper()])
        let surface = try XCTUnwrap(surfacesMade[7])
        let movedAndResized = NSRect(x: -400, y: 80, width: 400, height: 300)
        screenFrames[0].frame = movedAndResized
        await host.apply([wallpaper()])
        XCTAssertTrue(surfacesMade[7] === surface)
        XCTAssertEqual(surface.frame, movedAndResized)
        XCTAssertTrue(surface.isPlaying)
        XCTAssertEqual(recorder.stopped, 0)
        host.shutdown()
    }

    func testTheUsersScalingReachesTheSurfaceWithoutReopeningIt() async throws {
        let recorder = Recorder()
        let fit = wallpaper(scalingMode: .match, scalingFactor: 1.5)
        let host = makeHost(wallpapers: [fit], recorder: recorder)
        defer { host.shutdown() }
        await host.apply([fit])
        let surface = try XCTUnwrap(surfacesMade[7])
        XCTAssertEqual(surface.scalingCalls.map(\.mode), [.match])
        XCTAssertEqual(surface.scalingCalls.map(\.factor), [1.5])
        let generation = host.surfaceGenerationForTest

        // The user switches to Original size and back to 1x. Same clip, same
        // admission key: the running surface is told, and nothing is re-read
        // or reopened.
        let original = wallpaper(scalingMode: .none, scalingFactor: 1.0)
        await host.apply([original])

        XCTAssertTrue(surfacesMade[7] === surface)
        XCTAssertEqual(surface.scalingCalls.last?.mode, BridgeScalingMode.none)
        XCTAssertEqual(surface.scalingCalls.last?.factor, 1.0)
        XCTAssertEqual(recorder.admissionProbes.count, 1)
        XCTAssertEqual(host.surfaceGenerationForTest, generation)
        XCTAssertEqual(recorder.stopped, 0)
        XCTAssertTrue(surface.isPlaying)
    }

    func testTheUsersPositionReachesTheSurfaceWithoutReopeningIt() async throws {
        let recorder = Recorder()
        let moved = wallpaper(framing: BridgeFraming(panX: 0.9, panY: 0.1))
        let host = makeHost(wallpapers: [moved], recorder: recorder)
        defer { host.shutdown() }
        await host.apply([moved])
        let surface = try XCTUnwrap(surfacesMade[7])
        XCTAssertEqual(surface.scalingCalls.last?.pan, NativeVideoLayout.Pan(x: 0.9, y: 0.1),
            "the surface opens where the user put the picture, not in the middle")
        let generation = host.surfaceGenerationForTest

        // Center, saved: same clip, same key. The running surface is told and
        // nothing is reread or reopened.
        await host.apply([wallpaper()])

        XCTAssertTrue(surfacesMade[7] === surface)
        XCTAssertEqual(surface.scalingCalls.last?.pan, NativeVideoLayout.Pan.centered)
        XCTAssertEqual(recorder.admissionProbes.count, 1)
        XCTAssertEqual(host.surfaceGenerationForTest, generation)
        XCTAssertEqual(recorder.stopped, 0)
    }

    func testEachDisplayKeepsItsOwnPosition() async throws {
        let recorder = Recorder()
        let first = wallpaper(displayID: 7, framing: BridgeFraming(panX: 0, panY: 1))
        let second = wallpaper(displayID: 9)
        let host = makeHost(wallpapers: [first, second], recorder: recorder)
        defer { host.shutdown() }
        await host.apply([first, second])

        XCTAssertEqual(try XCTUnwrap(surfacesMade[7]).scalingCalls.last?.pan, NativeVideoLayout.Pan(x: 0, y: 1))
        XCTAssertEqual(try XCTUnwrap(surfacesMade[9]).scalingCalls.last?.pan, NativeVideoLayout.Pan.centered)
    }

    func testEachDisplayKeepsItsOwnScaling() async throws {
        let recorder = Recorder()
        let first = wallpaper(displayID: 7, scalingMode: .match, scalingFactor: 1)
        let second = wallpaper(displayID: 9, scalingMode: .stretch, scalingFactor: 2)
        let host = makeHost(wallpapers: [first, second], recorder: recorder)
        defer { host.shutdown() }
        await host.apply([first, second])

        XCTAssertEqual(try XCTUnwrap(surfacesMade[7]).scalingCalls.last?.mode, .match)
        XCTAssertEqual(try XCTUnwrap(surfacesMade[9]).scalingCalls.last?.mode, .stretch)
        XCTAssertEqual(try XCTUnwrap(surfacesMade[9]).scalingCalls.last?.factor, 2)
    }

    /// Eight columns of two pixels, red, green, blue, white, four rows high: a
    /// clip frame whose crop and zoom can be read off a few pixels.
    private func stripedSource() throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
            bytesPerRow: 32, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: index * 2, y: 0, width: 2, height: 4))
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// One pixel of a poster as RGB, counted from the top-left corner.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let frame = try XCTUnwrap(DesktopPosterFrame.rgba(image))
        let offset = (y * frame.width + x) * 4
        return frame.pixels[offset..<offset + 3].map(Int.init)
    }

    private func isColor(_ actual: [Int], _ expected: [Int]) -> Bool {
        // ImageIO and resampling can move an 8-bit channel by a few levels.
        zip(actual, expected).allSatisfy { abs($0 - $1) <= 6 }
    }

    func testPosterUsesTheSameFillCropOrStretchAsTheVideoSurface() throws {
        let source = try stripedSource()
        let fill = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 4, height: 4), backingScale: 1, mode: .fill, factor: 1))
        let stretch = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 4, height: 4), backingScale: 1, mode: .stretch, factor: 1))
        XCTAssertEqual(try pixel(fill, 0, 0), [0, 255, 0])
        XCTAssertTrue(isColor(try pixel(stretch, 0, 0), [255, 0, 0]))
        XCTAssertEqual(fill.width, 4)
        XCTAssertEqual(fill.height, 4)
    }

    func testPosterOfFitLeavesBlackBarsLikeTheVideoSurface() throws {
        let source = try stripedSource()
        // 8x4 into 4x4 at the smaller ratio: a 4x2 picture with a bar above and below.
        let fit = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 4, height: 4), backingScale: 1, mode: .match, factor: 1))
        XCTAssertEqual(try pixel(fit, 0, 0), [0, 0, 0], "the bar above the picture")
        XCTAssertEqual(try pixel(fit, 3, 3), [0, 0, 0], "the bar below it")
        XCTAssertTrue(isColor(try pixel(fit, 0, 1), [255, 0, 0]), "the whole width is the picture")
        XCTAssertTrue(isColor(try pixel(fit, 3, 2), [255, 255, 255]))
    }

    func testPosterOfOriginalSizeIsNotScaledToTheDisplay() throws {
        let source = try stripedSource()
        // 8x4 points on a 16x16 point display: one video pixel is one point, so
        // the picture is a small 8x4 island in the middle, and Fill would not be.
        let original = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 16, height: 16), backingScale: 1, mode: .none, factor: 1))
        XCTAssertEqual(try pixel(original, 0, 0), [0, 0, 0])
        XCTAssertEqual(try pixel(original, 3, 8), [0, 0, 0], "left of the picture")
        XCTAssertTrue(isColor(try pixel(original, 4, 7), [255, 0, 0]), "the picture's first column")
        XCTAssertTrue(isColor(try pixel(original, 11, 7), [255, 255, 255]), "its last column")
        XCTAssertEqual(try pixel(original, 12, 7), [0, 0, 0], "right of the picture")
        XCTAssertEqual(try pixel(original, 8, 3), [0, 0, 0], "above the picture")

        // On a 2x display the same 8x4 points cover 16x8 device pixels.
        let retina = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 16, height: 16), backingScale: 2, mode: .none, factor: 1))
        XCTAssertTrue(isColor(try pixel(retina, 0, 8), [255, 0, 0]), "the picture spans the width")
        XCTAssertTrue(isColor(try pixel(retina, 15, 8), [255, 255, 255]))
        XCTAssertEqual(try pixel(retina, 8, 3), [0, 0, 0])
    }

    func testPosterFollowsTheScaleFactor() throws {
        let source = try stripedSource()
        let plain = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 4, height: 4), backingScale: 1, mode: .stretch, factor: 1))
        XCTAssertTrue(isColor(try pixel(plain, 0, 0), [255, 0, 0]))
        // Doubled, the display shows only the middle half of the stretched picture.
        let zoomed = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 4, height: 4), backingScale: 1, mode: .stretch, factor: 2))
        XCTAssertTrue(isColor(try pixel(zoomed, 0, 0), [0, 255, 0]))
        XCTAssertTrue(isColor(try pixel(zoomed, 3, 0), [0, 0, 255]))
        // Halved, the picture shrinks to an island with black around it.
        let shrunk = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 4, height: 4), backingScale: 1, mode: .stretch, factor: 0.5))
        XCTAssertEqual(try pixel(shrunk, 0, 0), [0, 0, 0])
        XCTAssertEqual(try pixel(shrunk, 3, 3), [0, 0, 0])
    }

    func testPosterPutsThePictureWhereThePositionSays() throws {
        let source = try stripedSource()
        // 8x4 points on a 16x16 point display leaves 8 points of room across and 12 down.
        // Top-left puts the picture's corner on the display's.
        let topLeft = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 16, height: 16), backingScale: 1, mode: .none, factor: 1,
            pan: .init(x: 0, y: 0)))
        XCTAssertTrue(isColor(try pixel(topLeft, 0, 0), [255, 0, 0]), "the picture's first column")
        XCTAssertTrue(isColor(try pixel(topLeft, 7, 3), [255, 255, 255]), "its last column")
        XCTAssertEqual(try pixel(topLeft, 8, 0), [0, 0, 0], "right of the picture")
        XCTAssertEqual(try pixel(topLeft, 0, 4), [0, 0, 0], "below the picture")

        let bottomRight = try XCTUnwrap(NativeVideoWallpaperWindow.fittedPoster(
            source, pixelSize: CGSize(width: 16, height: 16), backingScale: 1, mode: .none, factor: 1,
            pan: .init(x: 1, y: 1)))
        XCTAssertTrue(isColor(try pixel(bottomRight, 8, 12), [255, 0, 0]), "the picture's first column")
        XCTAssertTrue(isColor(try pixel(bottomRight, 15, 15), [255, 255, 255]), "its last column")
        XCTAssertEqual(try pixel(bottomRight, 0, 0), [0, 0, 0])
    }

    func testPosterRefusesADisplayItCannotDrawInto() throws {
        let source = try stripedSource()
        for size in [CGSize.zero, CGSize(width: 20_000, height: 100), CGSize(width: CGFloat.nan, height: 4)] {
            XCTAssertNil(NativeVideoWallpaperWindow.fittedPoster(
                source, pixelSize: size, backingScale: 1, mode: .fill, factor: 1), "\(size)")
        }
    }

    // MARK: Switch hold

    /// A switch hold on a notification center the test owns. The wallpaper on screen answers its
    /// request for a still at once and its timers are fired by hand. Reduce Motion is on, so a
    /// released picture is removed on the spot instead of being faded out by a timer.
    @MainActor
    private final class HoldHarness {
        let center = NotificationCenter()
        let timers = ManualSleeper()
        /// Time stands still, so the length of a timer is exactly the limit it was set for.
        private let instant = ContinuousClock.now
        var reduceMotion = true
        /// The layer each display's visible wallpaper has, as the hold looks for it.
        var onScreen: [UInt32: CALayer] = [:]
        private(set) var hold: WallpaperSwitchHold!
        private var responder: NSObjectProtocol?

        init() {
            hold = WallpaperSwitchHold(
                center: center,
                layers: { [unowned self] display in self.onScreen[display].map { [$0] } ?? [] },
                shouldHold: { _ in true },
                reduceMotion: { [unowned self] in self.reduceMotion },
                sleep: timers.closure,
                now: { [unowned self] in self.instant })
            responder = center.addObserver(
                forName: DesktopPosterNotification.request, object: nil, queue: nil
            ) { [unowned self] note in
                MainActor.assumeIsolated {
                    guard let layer = note.object as? CALayer else { return }
                    let red = Data((0..<16).map { [255, 0, 0, 255][$0 % 4] })
                    DesktopPosterFrame(pixels: red, width: 2, height: 2, bgra: false).publish(
                        for: layer, to: self.center, context: note.userInfo?["context"] as? String)
                }
            }
            hold.start()
        }

        func finish() {
            hold.stop()
            if let responder { center.removeObserver(responder) }
        }

        func state(_ display: UInt32 = 7) -> WallpaperSwitchHold.Phase? {
            hold.stateForTest(display: display)
        }

        func veil(on layer: CALayer?) -> CALayer? {
            layer?.sublayers?.first { $0.name == SwitchHoldVeil.layerName }
        }

        /// What the renderer's window code posts for a layer it gives a window.
        func announce(
            _ layer: CALayer, display: UInt32, reason: WallpaperSwitchHoldNotification.Reason
        ) {
            center.post(
                name: WallpaperSwitchHoldNotification.layerInstalled, object: layer,
                userInfo: [
                    WallpaperSwitchHoldNotification.displayIDKey: NSNumber(value: display),
                    WallpaperSwitchHoldNotification.reasonKey: reason.rawValue,
                ])
        }
    }

    /// Shows `descriptor` on its display, then lets the hold take a still of it, as a switch
    /// away from it does.
    private func showAndHold(
        _ descriptor: BridgeNativeVideoWallpaper, on host: NativeVideoWallpaperHost,
        _ harness: HoldHarness
    ) async throws -> FakeSurface {
        await host.apply([descriptor])
        let surface = try XCTUnwrap(surfacesMade[descriptor.displayId])
        harness.onScreen[descriptor.displayId] = surface.posterLayer
        await harness.hold.begin(displays: [descriptor.displayId])
        // The replacement closes this window, and a closed window is not listed any more.
        harness.onScreen[descriptor.displayId] = nil
        return surface
    }

    func testTheReplacementWindowOpensWithTheHeldPictureOverIt() async throws {
        // The window is ordered in with the picture it replaces already over it, and the
        // picture goes when the clip shows its first frame and not before.
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        let first = try await showAndHold(wallpaper(id: "300", admissionKey: 1), on: host, harness)
        XCTAssertEqual(harness.state(), .armed)
        recorder.events.removeAll()

        await host.apply([wallpaper(id: "301", admissionKey: 2)])

        let second = try XCTUnwrap(surfacesMade[7])
        XCTAssertFalse(second === first)
        XCTAssertEqual(
            recorder.events, ["probe", "stop", "make", "present+veil"],
            "the picture is on the window when it reaches the desktop")
        XCTAssertNotNil(harness.veil(on: second.posterLayer))
        XCTAssertNil(harness.veil(on: first.posterLayer))
        XCTAssertEqual(harness.state(), .onHost)

        // Offering the same wallpaper again, or a change of setting, shows no picture.
        await host.apply([wallpaper(id: "301", volume: 0.5, admissionKey: 2)])
        XCTAssertEqual(harness.state(), .onHost)
        XCTAssertNotNil(harness.veil(on: second.posterLayer))

        second.isReadyForDisplay = true
        second.onReadyForDisplay?()

        XCTAssertNil(harness.state(), "the clip has its picture")
        XCTAssertNil(harness.veil(on: second.posterLayer))
    }

    func testTheHeldPictureFadesWhenMotionIsAllowed() async throws {
        let recorder = Recorder()
        let harness = HoldHarness()
        harness.reduceMotion = false
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        _ = try await showAndHold(wallpaper(id: "300", admissionKey: 1), on: host, harness)
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        let second = try XCTUnwrap(surfacesMade[7])

        second.isReadyForDisplay = true
        second.onReadyForDisplay?()

        XCTAssertEqual(harness.state(), .dismissing)
        XCTAssertNotNil(
            harness.veil(on: second.posterLayer)?.animation(forKey: SwitchHoldVeil.fadeAnimationKey),
            "the veil fades over the clip and does not vanish")
        await harness.timers.waitUntilPending()
        harness.timers.fireNext()
        await settle { harness.state() == nil }
        XCTAssertNil(harness.veil(on: second.posterLayer))
    }

    func testAClipThatAlreadyHasItsPictureReleasesTheHeldPictureOnceShown() async throws {
        // A layer that reports a picture the moment the callback is installed does so before the
        // window has taken the veil; the host lets it go after the window is up.
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        _ = try await showAndHold(wallpaper(id: "300", admissionKey: 1), on: host, harness)
        surfaceReadyAtBirth = true
        recorder.events.removeAll()

        await host.apply([wallpaper(id: "301", admissionKey: 2)])

        XCTAssertEqual(recorder.events, ["probe", "stop", "make", "present+veil"])
        XCTAssertNil(harness.state(), "nothing is left covering a clip that is already showing")
        XCTAssertNil(harness.veil(on: surfacesMade[7]?.posterLayer))
    }

    func testAReplacementThatIsReplacedBeforeItsFirstFrameHandsTheHeldPictureOn() async throws {
        // A quick second switch: the picture is carried by the newest window, and a late report
        // from the window that was replaced cannot take it away.
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        _ = try await showAndHold(wallpaper(id: "300", admissionKey: 1), on: host, harness)
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        let second = try XCTUnwrap(surfacesMade[7])
        XCTAssertNotNil(harness.veil(on: second.posterLayer))

        await host.apply([wallpaper(id: "302", admissionKey: 3)])

        let third = try XCTUnwrap(surfacesMade[7])
        XCTAssertTrue(second.isStopped)
        XCTAssertNil(harness.veil(on: second.posterLayer))
        XCTAssertNotNil(harness.veil(on: third.posterLayer))
        XCTAssertEqual(harness.state(), .onHost)

        second.isReadyForDisplay = true
        second.onReadyForDisplay?()
        XCTAssertEqual(harness.state(), .onHost, "the replaced window has no say")
        XCTAssertNotNil(harness.veil(on: third.posterLayer))

        third.isReadyForDisplay = true
        third.onReadyForDisplay?()
        XCTAssertNil(harness.state())
        XCTAssertNil(harness.veil(on: third.posterLayer))
    }

    func testAHeldPictureIsOnlyGivenToItsOwnDisplay() async throws {
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        let on7 = wallpaper(displayID: 7, id: "300", admissionKey: 1)
        let on9 = wallpaper(displayID: 9, id: "301", admissionKey: 2)
        await host.apply([on7, on9])
        let ninth = try XCTUnwrap(surfacesMade[9])
        harness.onScreen[9] = ninth.posterLayer
        await harness.hold.begin(displays: [9])
        harness.onScreen[9] = nil
        XCTAssertEqual(harness.state(9), .armed)

        await host.apply([wallpaper(displayID: 7, id: "302", admissionKey: 3), on9])

        XCTAssertNil(harness.veil(on: surfacesMade[7]?.posterLayer), "display 9's picture is not display 7's")
        XCTAssertEqual(harness.state(9), .armed)
        XCTAssertNil(harness.state(7))
    }

    func testAClipThatFailsToPlayReleasesTheHeldPicture() async throws {
        // The window the picture sat on is closed and nothing takes the wallpaper over: the
        // picture must not wait for a successor that is not coming.
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        _ = try await showAndHold(wallpaper(id: "300", admissionKey: 1), on: host, harness)
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        let second = try XCTUnwrap(surfacesMade[7])
        XCTAssertEqual(harness.state(), .onHost)

        second.failPreparation("synthetic decoder failure")
        await settle { !recorder.rejected.isEmpty }

        XCTAssertNil(harness.state())
        XCTAssertNil(harness.veil(on: second.posterLayer))
    }

    func testAPictureOnAClipWindowThatClosesWithNoWallpaperToTakeItsPlaceIsReleased() async throws {
        // The wallpaper was ejected while the replacement was loading: the window the picture
        // sat on is gone, and a later switch must not find it and show it again.
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        _ = try await showAndHold(wallpaper(id: "300", admissionKey: 1), on: host, harness)
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        let second = try XCTUnwrap(surfacesMade[7])
        XCTAssertEqual(harness.state(), .onHost)
        XCTAssertNotNil(harness.veil(on: second.posterLayer))

        await host.apply([])

        XCTAssertTrue(second.isStopped)
        XCTAssertNil(harness.state(), "no window is left for the picture to cover")
        XCTAssertNil(harness.veil(on: second.posterLayer))
    }

    func testAPictureOnAClipWindowIsReleasedWhenItsDisplayGoesAway() async throws {
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        let both = screenFrames
        _ = try await showAndHold(wallpaper(id: "300", admissionKey: 1), on: host, harness)
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        let second = try XCTUnwrap(surfacesMade[7])
        XCTAssertEqual(harness.state(), .onHost)

        screenFrames = both.filter { $0.id != 7 }
        await host.apply([wallpaper(id: "301", admissionKey: 2)])

        XCTAssertTrue(second.isStopped, "there is nothing to draw on")
        XCTAssertNil(harness.state())
        XCTAssertNil(harness.veil(on: second.posterLayer))
    }

    func testAClosedClipWindowLeavesAPictureThatWaitsForAnotherBackendsWindow() async throws {
        // Switching from a clip to a web page: this host closes the clip's window on the same
        // snapshot that makes the web host build the page's, perhaps first. The picture was
        // kept for the page's window, so closing the clip's must not end it.
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        let first = try await showAndHold(wallpaper(id: "300", admissionKey: 1), on: host, harness)
        XCTAssertEqual(harness.state(), .armed)

        await host.apply([])

        XCTAssertTrue(first.isStopped)
        XCTAssertEqual(harness.state(), .armed)
        let pageWindow = CALayer()
        XCTAssertTrue(harness.hold.adopt(into: pageWindow, displayID: 7))
        XCTAssertNotNil(harness.veil(on: pageWindow))
    }

    func testAClosedClipWindowLeavesAPictureThatSitsOnASceneLayer() async throws {
        // A clip replaced by a scene: the renderer's layer already carries the picture when
        // this host closes the clip's window, and the scene has not drawn yet.
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(wallpapers: [], recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        let first = try await showAndHold(wallpaper(id: "300", admissionKey: 1), on: host, harness)
        let scene = CALayer()
        harness.announce(scene, display: 7, reason: .replace)
        XCTAssertEqual(harness.state(), .onScene)

        await host.apply([])

        XCTAssertTrue(first.isStopped)
        XCTAssertEqual(harness.state(), .onScene)
        XCTAssertNotNil(harness.veil(on: scene))
    }

    func testARefusedReplacementEndsTheHoldAfterTheGrace() async throws {
        // A refusal comes before any window exists, and nothing takes the clip over: the display
        // is reported as failed and the picture is not kept for a window that is not coming. It
        // goes after the short grace a host window would have had.
        let recorder = Recorder()
        let harness = HoldHarness()
        defer { harness.finish() }
        let host = makeHost(
            wallpapers: [],
            refusalByPath: [Self.refusedPath: .notPlayable("synthetic: no video track")],
            recorder: recorder, switchHold: harness.hold)
        defer { host.shutdown() }
        let first = try await showAndHold(
            wallpaper(id: "300", admissionKey: 1), on: host, harness)
        XCTAssertEqual(harness.state(), .armed)

        await host.apply([wallpaper(id: "301", admissionKey: 2, mediaPath: Self.refusedPath)])

        XCTAssertEqual(recorder.rejected.map(\.id), ["301"], "the display is reported as failed")
        XCTAssertTrue(first.isStopped)
        XCTAssertEqual(recorder.made.count, 1, "no window for a clip nothing can play")
        XCTAssertEqual(harness.state(), .armed, "a window of another host may still come")
        let grace = WallpaperSwitchHold.Configuration().hostGrace
        await settle { harness.timers.requested.contains(grace) }
        XCTAssertTrue(harness.timers.requested.contains(grace), "the hold now runs out after the grace")
        harness.timers.fireNext()
        await settle { harness.state() == nil }
    }

    func testTheOldClipKeepsPlayingWhileTheReplacementsFileIsRead() async throws {
        // Reading a file can take seconds. The clip on screen plays through them, and is
        // stopped only once the replacement is decided, in the turn that builds its successor.
        let recorder = Recorder()
        let gate = stuckFile(recorder, path: Self.pathB)
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        await host.apply([wallpaper(id: "300", admissionKey: 1, mediaPath: Self.pathA)])
        let first = try XCTUnwrap(surfacesMade[7])
        recorder.events.removeAll()

        let pass = Task {
            await host.apply([wallpaper(id: "301", admissionKey: 2, mediaPath: Self.pathB)])
        }
        await gate.waitUntilWaiting()

        XCTAssertEqual(recorder.events, ["probe"], "nothing is stopped or built yet")
        XCTAssertEqual(host.isPlaying(displayID: 7), true)
        XCTAssertFalse(first.isStopped)

        gate.open()
        await pass.value

        XCTAssertEqual(
            recorder.events, ["probe", "stop", "make", "present"],
            "the file is read once, before the old clip stops, and not again")
        XCTAssertTrue(first.isStopped)
        XCTAssertEqual(recorder.admissionProbes.count, 2, "one read per wallpaper")
        XCTAssertEqual(host.activeDisplayIDs, [7])
    }

    func testAReplacementOvertakenWhileItsFileIsReadNeverStopsTheOldClip() async throws {
        // The user switched back while the file of the wallpaper they left was read: the pass
        // that was waiting has nothing to do, and the clip they came back to never stopped.
        let recorder = Recorder()
        let gate = stuckFile(recorder, path: Self.pathB)
        let host = makeHost(wallpapers: [], recorder: recorder, manualLimits: true)
        defer { host.shutdown() }
        let original = wallpaper(id: "300", admissionKey: 1, mediaPath: Self.pathA)
        await host.apply([original])
        let first = try XCTUnwrap(surfacesMade[7])

        let pass = Task {
            await host.apply([wallpaper(id: "301", admissionKey: 2, mediaPath: Self.pathB)])
        }
        await gate.waitUntilWaiting()
        await host.apply([original])
        gate.open()
        await pass.value

        XCTAssertFalse(first.isStopped)
        XCTAssertEqual(recorder.made, [Self.pathA], "the abandoned replacement built no window")
        XCTAssertTrue(surfacesMade[7] === first)
        XCTAssertEqual(host.isPlaying(displayID: 7), true)
    }

    func testWithoutASwitchHoldAReplacementOpensPlain() async throws {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        defer { host.shutdown() }
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        recorder.events.removeAll()

        await host.apply([wallpaper(id: "301", admissionKey: 2)])

        let second = try XCTUnwrap(surfacesMade[7])
        XCTAssertEqual(recorder.events, ["probe", "stop", "make", "present"])
        XCTAssertNil(second.posterLayer?.sublayers)
    }

    private final class PosterWorkspace: DesktopPictureWorkspace {
        let target: DesktopPictureTarget
        var picture: DesktopPicture?
        var didWrite: (() -> Void)?
        init(target: DesktopPictureTarget, original: URL) {
            self.target = target
            picture = DesktopPicture(url: original, scaling: 0, allowClipping: false, fill: [0, 0, 0, 1])
        }
        func targets() -> [DesktopPictureTarget] { [target] }
        func currentPicture(target: DesktopPictureTarget) -> DesktopPicture? { picture }
        func setPicture(_ picture: DesktopPicture, target: DesktopPictureTarget) {
            self.picture = picture
            didWrite?()
        }
        func referencedPictureURLs(targets: [DesktopPictureTarget]) -> Set<URL> { [] }
    }
}
