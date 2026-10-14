import XCTest

@testable import WallpaperMachine

/// Per-wallpaper ratings are credited from background samples. These cover when an
/// interval may be credited to a wallpaper, how measurements combine, and persistence.
@MainActor
final class WallpaperEnergyRatingsTests: XCTestCase {
  private let second: UInt64 = 1_000_000_000
  private var folder: URL!
  private var file: URL { folder.appendingPathComponent("EnergyRatings.json") }

  override func setUp() {
    super.setUp()
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "energy-ratings-\(UUID().uuidString)")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)
    super.tearDown()
  }

  private func context(
    _ id: String = "100", displays: Int = 1, cap: UInt32? = nil, scale: Double = 1
  ) -> WallpaperEnergyContext {
    WallpaperEnergyContext(
      wallpaperID: id,
      conditions: WallpaperEnergyConditions(
        displays: displays, frameRateCap: cap, renderScale: scale))
  }

  private func sample(at seconds: UInt64, joules: UInt64, otherBusy: UInt64 = 0)
    -> EnergyUsageSample
  {
    EnergyUsageSample(
      uptimeNanoseconds: seconds * second,
      own: [
        1: CoalitionEnergyCounters(
          cpuEnergyNanojoules: joules * second, gpuEnergyNanojoules: 0, gpuTimeNanoseconds: 0)
      ],
      otherGPUTime: [9: otherBusy])
  }

  func testContextNeedsExactlyOnePresentingWallpaper() {
    let shared = WallpaperEnergyContext.resolve(
      assignments: [("1", "a"), ("2", "a")], suspendedDisplays: [], frameRateCap: 60,
      renderScale: 0.75)
    XCTAssertEqual(shared, context("a", displays: 2, cap: 60, scale: 0.75))

    XCTAssertNil(
      WallpaperEnergyContext.resolve(
        assignments: [("1", "a"), ("2", "b")], suspendedDisplays: [], frameRateCap: nil,
        renderScale: 1),
      "energy is charged to the whole app, so two wallpapers cannot be told apart")
    XCTAssertEqual(
      WallpaperEnergyContext.resolve(
        assignments: [("1", "a"), ("2", "b")], suspendedDisplays: [2], frameRateCap: nil,
        renderScale: 1),
      context("a"), "a covered display is suspended and draws nothing")
    XCTAssertNil(
      WallpaperEnergyContext.resolve(
        assignments: [("1", "")], suspendedDisplays: [], frameRateCap: nil, renderScale: 1))
  }

  func testNativeVideoOnAPresentingDisplayIsNotRated() {
    XCTAssertNil(
      WallpaperEnergyContext.resolve(
        assignments: [("1", "a"), ("2", "a")], suspendedDisplays: [], nativeVideoDisplays: [2],
        frameRateCap: nil, renderScale: 1),
      "macOS charges a native video's decoding and drawing to no coalition of this app")
    XCTAssertEqual(
      WallpaperEnergyContext.resolve(
        assignments: [("1", "a"), ("2", "a")], suspendedDisplays: [2], nativeVideoDisplays: [2],
        frameRateCap: nil, renderScale: 1),
      context("a"), "a covered display's native player is paused")
  }

  func testVersionOneVideoRatingsAreHiddenAndReplacedRatherThanAveraged() throws {
    // Saved before native video was left out: a video may read as almost nothing.
    let saved = """
      {"video": {"milliwatts": 0.18, "seconds": 15759, "updated": 0,
                 "conditions": {"displays": 1, "renderScale": 1}},
       "scene": {"milliwatts": 757, "seconds": 1441, "updated": 0,
                 "conditions": {"displays": 1, "renderScale": 1}}}
      """
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(saved.utf8).write(to: file)
    let ratings = WallpaperEnergyRatings(file: file)
    XCTAssertNil(ratings.snapshot(for: "video", kind: .video))
    XCTAssertNotNil(ratings.snapshot(for: "scene", kind: .projectScene))

    ratings.record(context("video"), milliwatts: 900, seconds: 120)
    XCTAssertEqual(
      ratings.entries["video"]?.milliwatts ?? 0, 900, accuracy: 0.001,
      "the old figure is not averaged in")
    XCTAssertNotNil(ratings.snapshot(for: "video", kind: .video))
    ratings.flush()
    XCTAssertEqual(
      WallpaperEnergyRatings(file: file).entries["video"]?.version,
      WallpaperEnergyRating.currentVersion)
  }

  func testRatingAppearsAfterTwoMinutesAsATimeWeightedMean() throws {
    let ratings = WallpaperEnergyRatings(file: file)
    ratings.record(context(), milliwatts: 300, seconds: 30)
    ratings.record(context(), milliwatts: 300, seconds: 30)
    XCTAssertNil(ratings.rating(for: "100"), "one minute is not enough to rate")

    ratings.record(context(), milliwatts: 1_500, seconds: 60)
    let rating = try XCTUnwrap(ratings.rating(for: "100"))
    XCTAssertEqual(rating.milliwatts, 900, accuracy: 0.001)
    XCTAssertEqual(rating.level, .medium)
  }

  func testShownRatingSharesItsPowerOfTheBattery() {
    var batteryReads = 0
    let ratings = WallpaperEnergyRatings(file: file) {
      batteryReads += 1
      return 50
    }
    ratings.record(context("a"), milliwatts: 1_000, seconds: 150)
    ratings.record(context("b"), milliwatts: 250, seconds: 150)
    XCTAssertNil(ratings.snapshot(for: "unrated", kind: .projectScene))
    XCTAssertEqual(batteryReads, 0, "the battery is not read while nothing is rated")

    XCTAssertEqual(
      ratings.snapshot(for: "a", kind: .projectScene)?["batteryPercentPerHour"] as? Double ?? 0,
      2, accuracy: 0.001, "1 W from a 50 Wh battery is 2 % an hour")
    XCTAssertEqual(
      ratings.snapshot(for: "b", kind: .projectScene)?["batteryPercentPerHour"] as? Double ?? 0,
      0.5, accuracy: 0.001)
    XCTAssertEqual(batteryReads, 1, "every wallpaper's snapshot shares one battery read")

    let desktop = WallpaperEnergyRatings(file: folder.appendingPathComponent("desktop.json"))
    desktop.record(context("a"), milliwatts: 1_000, seconds: 150)
    let snapshot = desktop.snapshot(for: "a", kind: .projectScene)
    XCTAssertNotNil(snapshot)
    XCTAssertNil(snapshot?["batteryPercentPerHour"], "a Mac without a battery shows no share")
  }

  func testStableSelectorsUseLiveDisplayMappingAndUnknownMappingDoesNotAttributeEnergy() {
    let identity = "identity:{\"uuid\":\"example\"}"
    let assignments = [(display: "primary", wallpaper: "a"), (display: identity, wallpaper: "b")]
    var mapping: [String: UInt32] = ["primary": 7, identity: 8]
    func resolve(_ suspended: Set<UInt32>) -> WallpaperEnergyContext? {
      WallpaperEnergyContext.resolve(assignments: assignments, suspendedDisplays: suspended,
        frameRateCap: nil, renderScale: 1, resolveDisplay: { mapping[$0] })
    }
    XCTAssertEqual(resolve([8]), context("a"))
    mapping[identity] = 19
    XCTAssertNil(resolve([8]), "The reconnected display has a new physical id")
    XCTAssertEqual(resolve([19]), context("a"))
    mapping.removeValue(forKey: identity)
    XCTAssertNil(resolve([19]), "Unresolved content is not assumed to be visible or absent")
    XCTAssertEqual(ResolvedDisplayTitles.liveDisplayID("primary", title: "Display (7 - Primary)"), 7)
    XCTAssertEqual(ResolvedDisplayTitles.liveDisplayID(identity, title: "Display (19 - Secondary)"), 19)
  }

  func testMeasurementUnderOtherSettingsReplacesTheRating() {
    let ratings = WallpaperEnergyRatings(file: file)
    ratings.record(context(), milliwatts: 1_000, seconds: 120)
    ratings.record(context(cap: 30), milliwatts: 200, seconds: 60)

    XCTAssertNil(ratings.rating(for: "100"), "the 30 fps rating has only a minute behind it")
    XCTAssertEqual(ratings.entries["100"]?.conditions.frameRateCap, 30)
    XCTAssertEqual(ratings.entries["100"]?.milliwatts ?? 0, 200, accuracy: 0.001)
  }

  func testLongHistoryDoesNotFreezeTheRating() {
    let ratings = WallpaperEnergyRatings(file: file)
    ratings.record(context(), milliwatts: 100, seconds: 3_600)
    ratings.record(context(), milliwatts: 1_900, seconds: 1_800)
    // An hour of history weighs as half an hour, so the new half hour counts equally.
    XCTAssertEqual(ratings.rating(for: "100")?.milliwatts ?? 0, 1_000, accuracy: 0.001)
  }

  func testRatingsSurviveARelaunchAndAnUnreadableFileStartsEmpty() throws {
    let ratings = WallpaperEnergyRatings(file: file)
    ratings.record(context(), milliwatts: 400, seconds: 120)
    ratings.record(context(), milliwatts: 400, seconds: 30)
    ratings.flush()
    XCTAssertEqual(WallpaperEnergyRatings(file: file).rating(for: "100")?.seconds, 150)

    try Data("not json".utf8).write(to: file)
    let recovered = WallpaperEnergyRatings(file: file)
    XCTAssertTrue(recovered.entries.isEmpty)
    recovered.record(context(), milliwatts: 400, seconds: 120)
    XCTAssertNotNil(WallpaperEnergyRatings(file: file).rating(for: "100"))
  }

  func testRecorderCreditsOnlyIntervalsWhoseEndsAgreeAndWhoseGPUWasFree() {
    let ratings = WallpaperEnergyRatings(file: file)
    let recorder = WallpaperEnergyRecorder(source: nil, ratings: ratings) { nil }
    let a = context("a")
    let b = context("b")

    recorder.record(sample(at: 0, joules: 0), context: a)
    recorder.record(sample(at: 60, joules: 30), context: a)
    XCTAssertEqual(ratings.entries["a"]?.milliwatts ?? 0, 500, accuracy: 0.001)

    recorder.record(sample(at: 120, joules: 90), context: b)
    XCTAssertNil(ratings.entries["b"], "the interval straddled a wallpaper change")

    recorder.invalidate(at: 150 * second)
    recorder.record(sample(at: 180, joules: 150), context: b)
    XCTAssertNil(ratings.entries["b"], "a pause inside the interval invalidated it")

    recorder.record(sample(at: 240, joules: 180, otherBusy: 30 * second), context: b)
    XCTAssertNil(ratings.entries["b"], "another app kept the GPU busy half the interval")

    recorder.record(nil, context: b)
    recorder.record(sample(at: 300, joules: 210, otherBusy: 30 * second), context: b)
    XCTAssertNil(ratings.entries["b"], "unreadable counters break the chain")

    recorder.record(sample(at: 360, joules: 222, otherBusy: 30 * second), context: b)
    XCTAssertEqual(ratings.entries["b"]?.milliwatts ?? 0, 200, accuracy: 0.001)
    XCTAssertEqual(ratings.entries["a"]?.seconds ?? 0, 60, accuracy: 0.001)
  }

  func testRecorderLetsAWallpaperFinishLoadingBeforeAnIntervalStarts() {
    let ratings = WallpaperEnergyRatings(file: file)
    let recorder = WallpaperEnergyRecorder(source: nil, ratings: ratings) { nil }
    let a = context("a")

    recorder.invalidate(at: 0)
    recorder.record(sample(at: 2, joules: 0), context: a)
    recorder.record(sample(at: 32, joules: 30), context: a)
    XCTAssertNil(ratings.entries["a"], "an interval starting 2 s after the switch holds the load")

    recorder.record(sample(at: 62, joules: 45), context: a)
    XCTAssertEqual(ratings.entries["a"]?.milliwatts ?? 0, 500, accuracy: 0.001)
  }
}
