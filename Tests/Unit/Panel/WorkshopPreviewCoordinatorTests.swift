import XCTest

@testable import WallpaperMachine

/// Answers each Steam picture with bytes the test chose, and can hold one back until released.
private final class PictureFetcher: WorkshopThumbnailFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var gates: [String: AsyncGate] = [:]
  private var recorded: [URL] = []
  private let payload: @Sendable (String) throws -> Data

  init(payload: @escaping @Sendable (String) throws -> Data) { self.payload = payload }

  var requests: [URL] { lock.withLock { recorded } }

  func hold(_ id: String) -> AsyncGate {
    lock.withLock {
      let gate = AsyncGate()
      gates[id] = gate
      return gate
    }
  }

  func fetch(_ url: URL) async throws -> Data {
    let id = url.pathComponents.dropLast().last ?? ""
    let gate = lock.withLock { () -> AsyncGate? in
      recorded.append(url)
      return gates[id]
    }
    if let gate { await gate.wait() }
    return try payload(id)
  }
}

/// Which Discover tiles load a still and an animation, and when: every still of the page first, then
/// the animations of the tiles on screen, released again as they leave or the window hides.
@MainActor
final class WorkshopPreviewCoordinatorTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "preview-coordinator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

  private func pipeline(_ fetcher: PictureFetcher) -> PanelImagePipeline {
    let library = home.appendingPathComponent("Library")
    return PanelImagePipeline(
      thumbnailCache: WorkshopThumbnailCache(
        directory: home.appendingPathComponent("steam"), fetcher: fetcher),
      pixivThumbnailCache: WorkshopThumbnailCache(
        directory: home.appendingPathComponent("pixiv"),
        fetcher: PreviewFetcher { _ in throw URLError(.notConnectedToInternet) }),
      libraryThumbnailCache: WorkshopThumbnailCache(
        directory: home.appendingPathComponent("covers"),
        fetcher: LibraryPreviewFetcher(root: library), keepsAnimation: false),
      libraryRoot: { library })
  }

  private func tile(_ id: String, animates: Bool = true, still: Bool = true)
    -> WorkshopPreviewCoordinator.Tile
  {
    WorkshopPreviewCoordinator.Tile(
      id: id,
      still: still
        ? .steamThumbnail(URL(string: "https://images.steamusercontent.com/ugc/\(id)/preview/")!)
        : nil,
      animates: animates)
  }

  private func animated(_ frames: Int = 3) -> @Sendable (String) throws -> Data {
    { _ in try DiscoverPictures.gif(frames: frames, brightness: 0.3) }
  }

  private func waitFor(
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { return XCTFail("Timed out", file: file, line: line) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func testNoAnimationStartsUntilEveryStillOfThePageHasSettled() async throws {
    let fetcher = PictureFetcher(payload: animated())
    let slow = fetcher.hold("c")
    let coordinator = WorkshopPreviewCoordinator(images: pipeline(fetcher))
    let tiles = [tile("a"), tile("b"), tile("c")]
    coordinator.pageChanged(tiles, stillPixels: 128)
    for id in ["a", "b", "c"] { coordinator.setOnScreen(id, true) }

    try await waitFor { fetcher.requests.count == 3 }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(coordinator.animationRequests, 0, "one still is still on its way: no animation yet")
    XCTAssertTrue(coordinator.animations.isEmpty)

    slow.open()
    try await waitFor { coordinator.animations.count == 3 }
    XCTAssertEqual(coordinator.animationRequests, 3)
    XCTAssertTrue(["a", "b", "c"].allSatisfy(coordinator.isPlaying))
    XCTAssertEqual(
      Set(fetcher.requests.map(\.absoluteString)).count, 3,
      "each preview was downloaded once: the animation reads what the still kept")
    XCTAssertEqual(fetcher.requests.count, 3)
  }

  func testATileOffScreenLoadsNoAnimationAndOneThatComesBackReusesTheDiskCache() async throws {
    let fetcher = PictureFetcher(payload: animated())
    let coordinator = WorkshopPreviewCoordinator(images: pipeline(fetcher))
    coordinator.pageChanged([tile("a"), tile("b")], stillPixels: 128)
    coordinator.setOnScreen("a", true)
    try await waitFor { coordinator.animations["a"] != nil }
    XCTAssertNil(coordinator.animation(for: "b"), "b was never on screen")

    coordinator.setOnScreen("a", false)
    XCTAssertNil(coordinator.animation(for: "a"), "scrolled away: the animation is released")
    XCTAssertFalse(coordinator.isPlaying("a"))

    coordinator.setOnScreen("a", true)
    try await waitFor { coordinator.animations["a"] != nil }
    XCTAssertEqual(fetcher.requests.count, 2, "one download each for a and b, none for the return")
    XCTAssertEqual(coordinator.animationRequests, 2, "a asked twice, from the cache the second time")
  }

  func testASingleFramePreviewKeepsItsStillAndScrollingNeverRetriesIt() async throws {
    let fetcher = PictureFetcher(payload: animated(1))
    let coordinator = WorkshopPreviewCoordinator(images: pipeline(fetcher))
    coordinator.pageChanged([tile("a")], stillPixels: 128)
    coordinator.setOnScreen("a", true)
    try await waitFor { coordinator.scheduler.states["a"] == .failed }
    XCTAssertNil(coordinator.animation(for: "a"))
    XCTAssertEqual(coordinator.animationRequests, 1)

    coordinator.setOnScreen("a", false)
    coordinator.setOnScreen("a", true)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(coordinator.animationRequests, 1, "a failed preview is not asked for again")
    XCTAssertEqual(coordinator.scheduler.states["a"], .failed)
  }

  func testAHiddenWindowReleasesEveryAnimationAndShowingBringsTheOnScreenOnesBack() async throws {
    let fetcher = PictureFetcher(payload: animated())
    let coordinator = WorkshopPreviewCoordinator(images: pipeline(fetcher))
    coordinator.pageChanged([tile("a"), tile("b")], stillPixels: 128)
    coordinator.setOnScreen("a", true)
    coordinator.setOnScreen("b", true)
    try await waitFor { coordinator.animations.count == 2 }

    coordinator.setHidden(true)
    XCTAssertTrue(coordinator.animations.isEmpty, "nothing plays where nobody can see it")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(coordinator.animations.isEmpty, "and nothing loads while it is hidden")

    coordinator.setHidden(false)
    try await waitFor { coordinator.animations.count == 2 }
  }

  func testLeavingThePageForgetsEverythingIncludingWhatFailed() async throws {
    let fetcher = PictureFetcher(payload: animated(1))
    let coordinator = WorkshopPreviewCoordinator(images: pipeline(fetcher))
    coordinator.pageChanged([tile("a")], stillPixels: 128)
    coordinator.setOnScreen("a", true)
    try await waitFor { coordinator.scheduler.states["a"] == .failed }
    coordinator.releaseAll()
    XCTAssertTrue(coordinator.scheduler.states.isEmpty)
    XCTAssertTrue(coordinator.animations.isEmpty)
    // Back on the page, the same tile is asked afresh.
    coordinator.pageChanged([tile("a")], stillPixels: 128)
    coordinator.setOnScreen("a", true)
    try await waitFor { coordinator.animationRequests == 2 }
  }

  func testAnInstalledTileShowsTheLibrarysStillAndNeverAnimates() async throws {
    let fetcher = PictureFetcher(payload: animated())
    let coordinator = WorkshopPreviewCoordinator(images: pipeline(fetcher))
    coordinator.pageChanged([tile("a", animates: false), tile("b")], stillPixels: 128)
    coordinator.setOnScreen("a", true)
    coordinator.setOnScreen("b", true)
    try await waitFor { coordinator.animations["b"] != nil }
    XCTAssertNil(coordinator.animation(for: "a"))
    XCTAssertNil(coordinator.scheduler.states["a"], "an installed copy is not even queued")
    XCTAssertEqual(coordinator.animationRequests, 1)

    // The copy of b arrives in the library while it plays: it gives its place back.
    coordinator.pageChanged([tile("a", animates: false), tile("b", animates: false)], stillPixels: 128)
    XCTAssertNil(coordinator.animation(for: "b"))
    XCTAssertNil(coordinator.scheduler.states["b"])
  }

  func testATileWithNoStillHasNothingToWaitForAndNothingToReplace() async throws {
    let fetcher = PictureFetcher(payload: animated())
    let coordinator = WorkshopPreviewCoordinator(images: pipeline(fetcher))
    coordinator.pageChanged([tile("a", still: false), tile("b")], stillPixels: 128)
    coordinator.setOnScreen("a", true)
    coordinator.setOnScreen("b", true)
    try await waitFor { coordinator.animations["b"] != nil }
    XCTAssertNil(coordinator.animation(for: "a"), "with no still there is no tile to animate")
    XCTAssertEqual(fetcher.requests.count, 1)
  }

  func testTilesThatLeaveThePageAreForgottenAndANewPageStartsAfresh() async throws {
    let fetcher = PictureFetcher(payload: animated())
    let coordinator = WorkshopPreviewCoordinator(images: pipeline(fetcher))
    coordinator.pageChanged([tile("a")], stillPixels: 128)
    coordinator.setOnScreen("a", true)
    try await waitFor { coordinator.animations["a"] != nil }
    coordinator.pageChanged([tile("b")], stillPixels: 128)
    XCTAssertNil(coordinator.scheduler.states["a"], "a left the page")
    XCTAssertNil(coordinator.animation(for: "a"), "a tile that left the page keeps no animation bytes")
    coordinator.setOnScreen("b", true)
    try await waitFor { coordinator.animations["b"] != nil }
  }
}
