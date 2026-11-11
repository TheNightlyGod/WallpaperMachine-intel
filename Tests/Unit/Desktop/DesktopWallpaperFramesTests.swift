import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// The panel's picture of what a display's wallpaper draws: a frame the surface draws once the
/// wallpaper has played past any intro, scaled down and never blank; else the last such frame of the
/// same look, else the desktop picture sync's settled poster; else why there is none.
@MainActor
final class DesktopWallpaperFramesTests: XCTestCase {
  /// The contexts of the requests the surface was sent; touched only on the main queue.
  private final class Requests: @unchecked Sendable {
    var contexts: [String] = []
  }

  private let center = NotificationCenter()
  private let layer = CALayer()
  private let sent = Requests()
  private var requests: [String] { sent.contexts }
  private var observer: NSObjectProtocol?
  private let calm = DesktopPosterLook(display: "7", wallpaperID: "lake", inputs: ["rain": "0"])
  private let stormy = DesktopPosterLook(display: "7", wallpaperID: "lake", inputs: ["rain": "1"])

  override func tearDown() {
    if let observer { center.removeObserver(observer) }
    observer = nil
    super.tearDown()
  }

  /// The surface answers each request with a `width` by `height` frame from `pixel`, which gives
  /// the four bytes (BGRA) of the pixel at a column and row.
  private func answer(width: Int, height: Int, pixel: @escaping @Sendable (Int, Int) -> [UInt8] = DesktopWallpaperFramesTests.scenery) {
    let center = center, sent = sent
    var pixels = Data(capacity: width * height * 4)
    for row in 0..<height { for column in 0..<width { pixels.append(contentsOf: pixel(column, row)) } }
    let frame = DesktopPosterFrame(pixels: pixels, width: width, height: height, bgra: true)
    observer = center.addObserver(forName: DesktopPosterNotification.request, object: layer, queue: .main) { note in
      MainActor.assumeIsolated {
        guard let layer = note.object as? CALayer else { return }
        let context = DesktopPosterNotification.context(in: note.userInfo) ?? ""
        sent.contexts.append(context)
        frame.publish(for: layer, to: center, context: context)
      }
    }
  }

  /// A picture with something in it: a diagonal ramp.
  nonisolated private static let scenery: @Sendable (Int, Int) -> [UInt8] = { column, row in
    [UInt8((column * 7 + row * 3) % 256), UInt8((row * 5) % 256), 80, 255]
  }

  private func countRequests() {
    let sent = sent
    observer = center.addObserver(forName: DesktopPosterNotification.request, object: nil, queue: .main) { note in
      MainActor.assumeIsolated { sent.contexts.append(DesktopPosterNotification.context(in: note.userInfo) ?? "") }
    }
  }

  /// The service over display 7, whose surface is `surface()` when the test asks.
  private func frames(
    surface: @escaping @MainActor () -> DesktopWallpaperFrames.Surface?, awaits: Bool = false,
    poster: Data? = nil, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) -> DesktopWallpaperFrames {
    DesktopWallpaperFrames(
      center: center, surface: { $0 == 7 ? surface() : nil }, awaitsFrame: { _ in awaits },
      settledPoster: { $0 == 7 ? poster : nil }, configuration: .init(timeout: .seconds(2)), sleep: sleep)
  }

  private func surface(settled: Bool, remaining: Duration? = nil, look: DesktopPosterLook?) -> DesktopWallpaperFrames.Surface {
    .init(layer: layer, isSettled: settled, remaining: remaining, look: look)
  }

  private func image(_ answer: DesktopWallpaperFrames.Answer) -> CGImage? {
    if case .frame(let image) = answer { return image }
    return nil
  }

  private func jpeg(width: Int, height: Int, value: UInt8? = nil) throws -> Data {
    var pixels = Data(capacity: width * height * 4)
    for row in 0..<height {
      for column in 0..<width {
        pixels.append(contentsOf: value.map { [$0, $0, $0, 255] } ?? Self.scenery(column, row))
      }
    }
    let picture = try XCTUnwrap(
      DesktopPosterFrame(pixels: pixels, width: width, height: height, bgra: false).cgImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, picture, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  func testASettledWallpaperIsAskedOnceAndItsFrameComesBackScaledDownInItsShape() async throws {
    answer(width: 400, height: 200)
    let settled = surface(settled: true, look: calm)
    let answered = await frames(surface: { settled }).frame(display: 7, maxPixelSize: 100)
    let picture = try XCTUnwrap(image(answered))
    XCTAssertEqual(picture.width, 100)
    XCTAssertEqual(picture.height, 50)
    XCTAssertEqual(requests.count, 1)
    XCTAssertTrue(
      requests[0].hasPrefix("panel-preview:"),
      "its own context, so the desktop picture sync never takes the frame as a poster")

    let unscaled = await frames(surface: { settled }).frame(display: 7, maxPixelSize: 1000)
    XCTAssertEqual(image(unscaled)?.width, 400, "a smaller frame is not enlarged")
  }

  func testAFrameTheSyncAwaitsIsTakenWithoutAskingInItsPlace() async throws {
    countRequests()
    let settled = surface(settled: true, look: nil)
    let frames = frames(surface: { settled }, awaits: true)
    let center = center, layer = layer
    Task { @MainActor in
      var pixels = Data()
      for index in 0..<4 { pixels.append(contentsOf: Self.scenery(index * 40, index * 30)) }
      DesktopPosterFrame(pixels: pixels, width: 2, height: 2, bgra: true).publish(for: layer, to: center, context: "")
    }
    let answered = await frames.frame(display: 7, maxPixelSize: 100)
    XCTAssertEqual(image(answered)?.width, 2)
    XCTAssertEqual(requests, [], "the sync's own request is answered")
  }

  /// A wallpaper still in its intro gives the frame it draws now at once, as a first picture, and
  /// the answer says when asking again can have a settled one. A blank first frame is not given.
  func testAWallpaperInItsIntroGivesItsFirstFrameAndSaysWhenItWillHaveSettled() async throws {
    answer(width: 40, height: 20)
    let playing = surface(settled: false, remaining: .seconds(9), look: calm)
    let answered = await frames(surface: { playing }).frame(display: 7, maxPixelSize: 100)
    guard case .unsettled(let first, let retryAfter) = answered else { return XCTFail("\(answered)") }
    XCTAssertEqual(first?.width, 40)
    XCTAssertEqual(retryAfter, .seconds(9))
    XCTAssertEqual(requests.count, 1)

    let held = surface(settled: false, remaining: nil, look: calm)
    let paused = await frames(surface: { held }).frame(display: 7, maxPixelSize: 100)
    guard case .unsettled(let frozen, nil) = paused else { return XCTFail("a wallpaper that does not play: \(paused)") }
    XCTAssertNotNil(frozen, "the frame it holds")
  }

  func testABlankFirstFrameIsNotGiven() async throws {
    answer(width: 40, height: 20) { _, _ in [0, 0, 0, 255] }
    let playing = surface(settled: false, remaining: .seconds(9), look: calm)
    let answered = await frames(surface: { playing }).frame(display: 7, maxPixelSize: 100)
    guard case .unsettled(nil, .seconds(9)) = answered else { return XCTFail("\(answered)") }
  }

  /// The frame a settled wallpaper gave stays while the wallpaper replays its intro with the same
  /// look, and goes with a new look, whose frame the old one does not show.
  func testTheLastSettledFrameStandsInWhileTheSameLookReplaysItsIntro() async throws {
    answer(width: 40, height: 20)
    var current = surface(settled: true, look: calm)
    let frames = frames(surface: { current })
    let settledAnswer = await frames.frame(display: 7, maxPixelSize: 100)
    let first = try XCTUnwrap(image(settledAnswer))

    current = surface(settled: false, remaining: .seconds(5), look: calm)
    let replay = await frames.frame(display: 7, maxPixelSize: 100)
    XCTAssertTrue(image(replay) === first)
    XCTAssertEqual(requests.count, 1, "not asked while it replays")

    current = surface(settled: false, remaining: .seconds(5), look: stormy)
    guard case .unsettled = await frames.frame(display: 7, maxPixelSize: 100) else {
      return XCTFail("a frame of another look is not shown as settled")
    }
    current = surface(settled: false, remaining: .seconds(5), look: nil)
    guard case .unsettled = await frames.frame(display: 7, maxPixelSize: 100) else {
      return XCTFail("nor one whose look cannot be told")
    }
  }

  /// A black or flat frame (an intro that has not faded in yet) is never shown: the settled
  /// poster stands in, and without one there is no frame.
  func testABlankFrameGivesWayToTheSettledPosterAndWithoutOneToNothing() async throws {
    answer(width: 64, height: 32) { _, _ in [0, 0, 0, 255] }
    let settled = surface(settled: true, look: calm)
    let poster = try jpeg(width: 64, height: 32)
    let fromPoster = await frames(surface: { settled }, poster: poster).frame(display: 7, maxPixelSize: 16)
    XCTAssertEqual(image(fromPoster)?.width, 16, "the poster, scaled down")

    guard case .unavailable = await frames(surface: { settled }).frame(display: 7, maxPixelSize: 16) else {
      return XCTFail("no frame")
    }
    let blankPoster = try jpeg(width: 64, height: 32, value: 2)
    guard case .unavailable = await frames(surface: { settled }, poster: blankPoster).frame(display: 7, maxPixelSize: 16)
    else { return XCTFail("a black poster is not shown either") }
  }

  func testNoAnswerOrNoWindowHasNoFrame() async throws {
    countRequests()
    let now: @Sendable (Duration) async throws -> Void = { _ in }
    let settled = surface(settled: true, look: calm)
    guard case .unavailable = await frames(surface: { settled }, sleep: now).frame(display: 7, maxPixelSize: 100)
    else { return XCTFail("no answer") }
    guard case .unavailable = await frames(surface: { settled }, sleep: now).frame(display: 8, maxPixelSize: 100)
    else { return XCTFail("no wallpaper window") }
    XCTAssertEqual(requests.count, 1, "only the display with a window is asked")
  }

  func testBlankMeansBlackOrOneFlatColourAllOver() throws {
    func picture(_ pixel: @escaping (Int, Int) -> [UInt8]) throws -> CGImage {
      var pixels = Data()
      for row in 0..<90 { for column in 0..<160 { pixels.append(contentsOf: pixel(column, row)) } }
      return try XCTUnwrap(DesktopPosterFrame(pixels: pixels, width: 160, height: 90, bgra: false).cgImage())
    }
    XCTAssertTrue(DesktopWallpaperFrames.isBlank(try picture { _, _ in [0, 0, 0, 255] }), "black")
    XCTAssertTrue(DesktopWallpaperFrames.isBlank(try picture { _, _ in [3, 2, 4, 255] }), "nearly black")
    XCTAssertTrue(DesktopWallpaperFrames.isBlank(try picture { _, _ in [250, 250, 250, 255] }), "a white fade")
    XCTAssertFalse(DesktopWallpaperFrames.isBlank(try picture { column, row in Self.scenery(column, row) }))
    XCTAssertFalse(
      DesktopWallpaperFrames.isBlank(try picture { column, _ in [UInt8(column / 4), UInt8(column / 8), 30, 255] }),
      "a dark night sky still has something in it")
  }
}
