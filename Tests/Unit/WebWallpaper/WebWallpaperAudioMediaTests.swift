import XCTest

@testable import WallpaperMachine

/// The two host-side machines behind the author APIs: the single audio poller
/// shared by every display, and the media relay that decides what a page is
/// told about the system's playback. Neither needs a web view.
@MainActor
final class WebWallpaperAudioMediaTests: XCTestCase {
  // MARK: - audio pump

  func testPollingRunsOnlyWhileSomethingIsSubscribed() async throws {
    var reads = 0
    let pump = WebWallpaperAudioPump(
      read: {
        reads += 1
        return BridgeAudioSpectrum(
          generation: UInt64(reads), stereo: false, bins: [Float](repeating: 0, count: 128))
      },
      interval: .milliseconds(1))
    var delivered = 0
    pump.onSpectrum = { _ in delivered += 1 }
    let first = NSObject()
    let second = NSObject()

    XCTAssertFalse(pump.isPolling, "an idle desktop must not run a timer at all")
    pump.setSubscribed(true, for: ObjectIdentifier(first))
    XCTAssertTrue(pump.isPolling)
    try await poll { delivered >= 2 }

    pump.setSubscribed(true, for: ObjectIdentifier(second))
    pump.setSubscribed(true, for: ObjectIdentifier(second))
    XCTAssertEqual(pump.subscriberCount, 2, "subscribing twice is one subscriber")
    pump.setSubscribed(false, for: ObjectIdentifier(first))
    XCTAssertTrue(pump.isPolling, "a second page is still listening")

    pump.setSubscribed(false, for: ObjectIdentifier(second))
    XCTAssertFalse(pump.isPolling)
    let settled = reads
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(reads, settled, "nothing is read once the last page has gone")
  }

  func testASpectrumTheAnalyserDidNotRecomputeIsNotDeliveredAgain() async throws {
    var generation: UInt64 = 7
    var reads = 0
    let pump = WebWallpaperAudioPump(
      read: {
        reads += 1
        return BridgeAudioSpectrum(
          generation: generation, stereo: false, bins: [Float](repeating: 0.5, count: 128))
      },
      interval: .milliseconds(1))
    var delivered: [UInt64] = []
    pump.onSpectrum = { delivered.append($0.generation) }
    let page = NSObject()
    pump.setSubscribed(true, for: ObjectIdentifier(page))

    try await poll { reads >= 5 }
    XCTAssertEqual(delivered, [7], "repeated reads of one generation wake the page once")

    generation = 8
    try await poll { delivered.count == 2 }
    XCTAssertEqual(delivered, [7, 8])
    pump.setSubscribed(false, for: ObjectIdentifier(page))
  }

  func testAFailingAnalyserStopsDeliveryWithoutStoppingThePump() async throws {
    struct Unavailable: Error {}
    var reads = 0
    let pump = WebWallpaperAudioPump(
      read: {
        reads += 1
        throw Unavailable()
      },
      interval: .milliseconds(1))
    var delivered = 0
    pump.onSpectrum = { _ in delivered += 1 }
    let page = NSObject()
    pump.setSubscribed(true, for: ObjectIdentifier(page))

    try await poll { reads >= 3 }
    XCTAssertEqual(delivered, 0, "a failed read is not a frame")
    XCTAssertTrue(pump.isPolling, "one failure must not permanently silence a recovering analyser")
    pump.setSubscribed(false, for: ObjectIdentifier(page))
  }

  // MARK: - silence cadence

  func testSilenceCadenceRepeatsAClearedFrameThroughTheSettleWindowThenAtOneHertz() {
    var cadence = WebWallpaperSilenceCadence()
    let start = ContinuousClock.now
    let silent = Self.spectrum(generation: 8, level: 0)
    cadence.recordNew(at: start)

    // The pump polls at about 30 Hz; step in 33 ms like it does.
    let step = Duration.milliseconds(33)
    var repeats: [Duration] = []
    for index in 1...121 {
      let elapsed = step * index
      if cadence.shouldRepeat(silent, at: start.advanced(by: elapsed)) { repeats.append(elapsed) }
    }

    let inWindow = repeats.filter { $0 < .milliseconds(1500) }
    XCTAssertEqual(inWindow.count, 45, "every poll until the settle window closes repeats, so a decay can finish")
    let afterwards = repeats.filter { $0 >= .milliseconds(1500) }
    XCTAssertEqual(afterwards.count, 2, "between 1.5 s and 4 s the keep-alive fires twice")
    let gaps = zip(repeats.filter { $0 >= .milliseconds(1485) }, afterwards).map { $1 - $0 }
    XCTAssertTrue(
      gaps.allSatisfy { $0 >= .seconds(1) && $0 < .milliseconds(1034) },
      "the keep-alive is spaced one second from the previous repeat, not from the sound")
  }

  func testSilenceCadenceNeedsAGenerationToRepeatAndForgetsItOnReset() {
    var cadence = WebWallpaperSilenceCadence()
    let now = ContinuousClock.now
    let silent = Self.spectrum(generation: 8, level: 0)

    XCTAssertFalse(
      cadence.shouldRepeat(silent, at: now), "nothing has been delivered yet, so there is nothing to repeat")
    cadence.recordNew(at: now)
    XCTAssertTrue(cadence.shouldRepeat(silent, at: now.advanced(by: .milliseconds(33))))
    cadence.reset()
    XCTAssertFalse(
      cadence.shouldRepeat(silent, at: now.advanced(by: .milliseconds(66))),
      "after a reset the next delivery has to come from a new generation")
    XCTAssertFalse(
      cadence.shouldRepeat(
        BridgeAudioSpectrum(generation: 9, stereo: false, bins: []), at: now.advanced(by: .seconds(5))))
  }

  func testPumpRepeatsAZeroFrameWhileTheAnalyserStaysQuiet() {
    let clock = FakeClock()
    var current = Self.spectrum(generation: 7, level: 0.5)
    let pump = WebWallpaperAudioPump(read: { current }, now: { clock.now })
    var delivered: [UInt64] = []
    pump.onSpectrum = { delivered.append($0.generation) }

    pump.pollOnce()
    XCTAssertEqual(delivered, [7])

    // The analyser clears once and then goes silent without a new generation.
    current = Self.spectrum(generation: 8, level: 0)
    clock.advance(.milliseconds(33))
    pump.pollOnce()
    XCTAssertEqual(delivered, [7, 8])

    for _ in 0..<40 {
      clock.advance(.milliseconds(33))
      pump.pollOnce()
    }
    XCTAssertEqual(
      delivered, [7, 8] + [UInt64](repeating: 8, count: 40),
      "inside the settle window the cleared frame follows every poll")

    clock.advance(.milliseconds(280))  // 1.6 s after the cleared frame
    pump.pollOnce()
    XCTAssertEqual(delivered.count, 42, "a poll that comes right after the last repeat has nothing to say")

    clock.advance(.milliseconds(900))  // 2.5 s
    pump.pollOnce()
    XCTAssertEqual(delivered.count, 43, "the keep-alive is one frame a second")
    clock.advance(.milliseconds(100))
    pump.pollOnce()
    XCTAssertEqual(delivered.count, 43)

    // Sound returns: the new generation is delivered, and a frame with signal is
    // never repeated.
    current = Self.spectrum(generation: 9, level: 0.4)
    clock.advance(.milliseconds(100))
    pump.pollOnce()
    XCTAssertEqual(delivered.last, 9)
    XCTAssertEqual(delivered.count, 44)
    for _ in 0..<5 {
      clock.advance(.milliseconds(33))
      pump.pollOnce()
    }
    XCTAssertEqual(delivered.count, 44, "a spectrum with signal is delivered once")

    // And the next silence starts a fresh settle window.
    current = Self.spectrum(generation: 10, level: 0)
    clock.advance(.milliseconds(33))
    pump.pollOnce()
    clock.advance(.milliseconds(33))
    pump.pollOnce()
    XCTAssertEqual(Array(delivered.suffix(2)), [10, 10])
  }

  func testAFrameWithSignalIsNeverRepeated() {
    let clock = FakeClock()
    var bins = [Float](repeating: 0, count: 128)
    bins[127] = 0.0001  // one barely audible band is still a real analysis
    var current = BridgeAudioSpectrum(generation: 3, stereo: true, bins: bins)
    let pump = WebWallpaperAudioPump(read: { current }, now: { clock.now })
    var delivered: [UInt64] = []
    pump.onSpectrum = { delivered.append($0.generation) }

    for _ in 0..<400 {  // about 13 s of polling
      pump.pollOnce()
      clock.advance(.milliseconds(33))
    }
    XCTAssertEqual(delivered, [3], "replaying a stale spectrum would show sound that has stopped")

    current = Self.spectrum(generation: 4, level: 0.25)
    for _ in 0..<100 {
      pump.pollOnce()
      clock.advance(.milliseconds(33))
    }
    XCTAssertEqual(delivered, [3, 4])
  }

  func testStoppingResetsTheCadenceSoANewSubscriberGetsItsFirstFrame() async throws {
    let clock = FakeClock()
    let pump = WebWallpaperAudioPump(
      read: { Self.spectrum(generation: 8, level: 0) },
      interval: .milliseconds(1), now: { clock.now },
      wait: { _ in try await Task.sleep(for: .seconds(3600)) })
    var delivered: [UInt64] = []
    pump.onSpectrum = { delivered.append($0.generation) }
    let first = NSObject()
    let second = NSObject()

    pump.setSubscribed(true, for: ObjectIdentifier(first))
    try await poll { delivered.count == 1 }
    clock.advance(.seconds(2))
    pump.pollOnce()
    XCTAssertEqual(delivered.count, 2, "settled silence still reaches the page once a second")

    // Past the settle window and right after a repeat, a plain repeat would be
    // refused; a page that has just subscribed must not wait for the next one.
    pump.setSubscribed(false, for: ObjectIdentifier(first))
    XCTAssertFalse(pump.isPolling)
    clock.advance(.milliseconds(100))
    pump.setSubscribed(true, for: ObjectIdentifier(second))
    try await poll { delivered.count == 3 }
    pump.setSubscribed(false, for: ObjectIdentifier(second))
  }

  // MARK: - media relay

  func testProviderConsumersReturnToZeroWhenEveryPageLeaves() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    let first = NSObject()
    let second = NSObject()

    relay.setConsuming(true, for: ObjectIdentifier(first))
    relay.setConsuming(true, for: ObjectIdentifier(first))
    XCTAssertEqual(provider.consumers, 1, "one page is one consumer however often it says so")

    relay.setConsuming(true, for: ObjectIdentifier(second))
    XCTAssertEqual(provider.consumers, 2)
    relay.setConsuming(false, for: ObjectIdentifier(first))
    XCTAssertEqual(provider.consumers, 1, "another visible page must keep the provider running")

    relay.setConsuming(false, for: ObjectIdentifier(second))
    XCTAssertEqual(provider.consumers, 0)
    XCTAssertEqual(relay.consumerCount, 0)
  }

  func testRemovingEveryConsumerAtOnceReleasesThemAll() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    let pages = [NSObject(), NSObject(), NSObject()]
    for page in pages { relay.setConsuming(true, for: ObjectIdentifier(page)) }
    XCTAssertEqual(provider.consumers, 3)

    relay.removeAllConsumers()
    XCTAssertEqual(provider.consumers, 0)
    relay.removeAllConsumers()
    XCTAssertEqual(provider.consumers, 0, "a second sweep must not drive the count negative")
  }

  func testAnUnavailableProviderIsReportedAsTheUserSettingWithNothingInvented() {
    let provider = FakeSystemMediaProvider()
    provider.availability = .unavailable(reason: "MediaRemote returns nothing without the entitlement")
    let relay = WebWallpaperMediaRelay(provider: provider)
    relay.setConsuming(true, for: ObjectIdentifier(self))

    XCTAssertEqual(
      relay.currentEvents(userEnabled: true),
      [.status(true), .properties(SystemMediaProperties()), .playback(.stopped)],
      "the status listener reports the user's setting; nothing else may be made up")
  }

  func testUnchangedProviderValuesEmitNothingAndFieldsAreIndependent() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    var events: [WebWallpaperMediaRelay.Event] = []
    relay.onChange = { events.append($0) }
    relay.setConsuming(true, for: ObjectIdentifier(self))
    events.removeAll()

    let track = SystemMediaProperties(title: "Track", artist: "Artist")
    provider.onPropertiesChanged?(track)
    provider.onPropertiesChanged?(track)
    XCTAssertEqual(events, [.properties(track)])

    events.removeAll()
    provider.onPlaybackChanged?(.playing)
    provider.onPlaybackChanged?(.playing)
    XCTAssertEqual(events, [.playback(.playing)], "a repeated state is not a change")

    events.removeAll()
    provider.onPropertiesChanged?(SystemMediaProperties(title: "Next", artist: "Artist"))
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first, .properties(SystemMediaProperties(title: "Next", artist: "Artist")))
  }

  /// A listener key and a consumer key name different things, and the shared
  /// relay must not assume otherwise.
  ///
  /// `WebWallpaperHost` registers exactly one listener for all of its pages
  /// and then counts consumers per page, so its listener key is never itself a
  /// consumer. A relay that only delivered to listeners it also counted as
  /// consumers would therefore silence every visible web wallpaper. The real
  /// host is built here on a shared relay so the production registration runs.
  func testEveryListenerIsFedEvenThoughListenerKeysAreNeverConsumerKeys() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    let host = WebWallpaperHost(fetch: { [] }, screens: { [] }, mediaRelay: relay)
    XCTAssertNotNil(host, "the host registers its listener on the shared relay")

    // A second listener, registered the same way the host and the scene sink
    // do: under its own identity, never as a consumer.
    final class Listener {}
    let listener = Listener()
    var delivered: [WebWallpaperMediaRelay.Event] = []
    relay.addListener(ObjectIdentifier(listener)) { delivered.append($0) }

    // Pages vote separately, under their own keys.
    final class Page {}
    let page = Page()
    relay.setConsuming(true, for: ObjectIdentifier(page))
    delivered.removeAll()

    provider.onPlaybackChanged?(.playing)
    XCTAssertEqual(
      delivered, [.playback(.playing)],
      "a listener was dropped because its key was not also a consumer key")
  }

  func testATimelineTheProviderWithdrewEmitsNothingRatherThanZero() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    var events: [WebWallpaperMediaRelay.Event] = []
    relay.onChange = { events.append($0) }
    relay.setConsuming(true, for: ObjectIdentifier(self))
    events.removeAll()

    let timeline = SystemMediaTimeline(position: 12, duration: 240)
    provider.onTimelineChanged?(timeline)
    XCTAssertEqual(events, [.timeline(timeline)])

    events.removeAll()
    provider.onTimelineChanged?(nil)
    XCTAssertTrue(events.isEmpty, "there is no 'no timeline' event; a wallpaper must cope with silence")
    XCTAssertFalse(
      relay.currentEvents(userEnabled: true).contains {
        if case .timeline = $0 { return true } else { return false }
      },
      "a withdrawn timeline must not be replayed to the next page")
  }

  func testTheLastConsumerLeavingForgetsTheTrack() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    let page = NSObject()
    relay.setConsuming(true, for: ObjectIdentifier(page))
    provider.onPropertiesChanged?(SystemMediaProperties(title: "Track"))
    provider.onPlaybackChanged?(.playing)
    provider.onThumbnailChanged?(Self.thumbnail)

    relay.setConsuming(false, for: ObjectIdentifier(page))
    XCTAssertEqual(
      relay.currentEvents(userEnabled: true),
      [.status(true), .properties(SystemMediaProperties()), .playback(.stopped)],
      "nothing is being watched, so nothing is known; handing the next page the old track invents it")
  }

  func testReplayingAnAlreadyKnownStateDoesNotRebroadcastIt() {
    let provider = FakeSystemMediaProvider()
    provider.properties = SystemMediaProperties(title: "Track")
    provider.playback = .playing
    let relay = WebWallpaperMediaRelay(provider: provider)
    var events: [WebWallpaperMediaRelay.Event] = []
    relay.onChange = { events.append($0) }

    let first = NSObject()
    relay.setConsuming(true, for: ObjectIdentifier(first))
    XCTAssertEqual(
      events, [.properties(SystemMediaProperties(title: "Track")), .playback(.playing)],
      "the first consumer learns the current state")

    // A second page joining replays the provider, which must not re-deliver
    // state the pages already listening have seen.
    events.removeAll()
    let second = NSObject()
    relay.setConsuming(true, for: ObjectIdentifier(second))
    XCTAssertTrue(events.isEmpty)
    XCTAssertEqual(
      relay.currentEvents(userEnabled: false).first, .status(false),
      "the joining page is given the state directly, with its own wallpaper's setting")
  }

  // MARK: - helpers

  private static func spectrum(generation: UInt64, level: Float) -> BridgeAudioSpectrum {
    BridgeAudioSpectrum(generation: generation, stereo: false, bins: [Float](repeating: level, count: 128))
  }

  private static let thumbnail = SystemMediaThumbnail(
    pngBase64DataURL: "data:image/png;base64,iVBORw0KGgo=",
    primaryColor: "rgb(10, 20, 30)", secondaryColor: "rgb(40, 50, 60)",
    tertiaryColor: "rgb(70, 80, 90)", textColor: "rgb(255, 255, 255)",
    highContrastColor: "rgb(255, 255, 255)")

  private func poll(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("condition not met before timeout")
  }
}

/// A `SystemMediaProvider` that reports exactly what the test set, so the relay
/// is exercised without MediaRemote, a running player or an entitlement.
@MainActor
final class FakeSystemMediaProvider: SystemMediaProvider {
  var availability: SystemMediaAvailability = .available
  var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
  var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
  var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
  var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?

  private(set) var consumers = 0
  private(set) var replays = 0
  var properties = SystemMediaProperties()
  var playback = SystemMediaPlaybackState.stopped
  var thumbnail: SystemMediaThumbnail?
  var timeline: SystemMediaTimeline?

  func addConsumer() { consumers += 1 }
  func removeConsumer() { consumers -= 1 }

  func replayCurrentState() {
    replays += 1
    onPropertiesChanged?(properties)
    if let thumbnail { onThumbnailChanged?(thumbnail) }
    onPlaybackChanged?(playback)
    if let timeline { onTimelineChanged?(timeline) }
  }
}

/// A clock the test moves by hand, so a cadence that lasts seconds is checked
/// in microseconds and never depends on how busy the machine is.
@MainActor
final class FakeClock {
  private(set) var now = ContinuousClock.now

  func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}
