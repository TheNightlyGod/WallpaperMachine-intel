import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// The animation player: it understands every format a preview may arrive in, holds one frame at a
/// time, and plays only while it is asked to.
@MainActor
final class AnimatedPreviewTests: XCTestCase {
  /// Four 63 px frames of an animated WebP, 100 ms each, made with `img2webp`.
  private static let animatedWebP = Data(
    base64Encoded:
      "UklGRgABAABXRUJQVlA4WAoAAAACAAAAPwAAPwAAQU5JTQYAAAD/////AABBTk1GLAAAAAAAAAAAAD8AAD8AAGQAAAJWUDhMFAAAAC8/wA8ABxAR/Q8ACeH/ey2i/6kfQU5NRjAAAAAAAAAAAAA/AAA/AABkAAAAVlA4TBcAAAAvP8APAAfQqla1qv8BICH8f69F9D/1AwBBTk1GMAAAAAAAAAAAAD8AAD8AAGQAAABWUDhMFwAAAC8/wA8AB1DVqla1/wEgIfx/r0X0P/UDAEFOTUYwAAAAAAAAAAAAPwAAPwAAZAAAAFZQOEwXAAAALz/ADwAH0P/+97//ASAh/H+vRfQ/9QMA")!

  /// `frames` 64 px frames in `type`, each shown for `delay` seconds.
  private func animation(_ type: UTType, frames: Int, delay: Double) throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, type.identifier as CFString, frames, nil))
    let properties: [CFString: Any]
    switch type {
    case .gif: properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
    default: properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
    }
    for frame in 0..<frames {
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(gray: CGFloat(frame) / CGFloat(max(frames - 1, 1)), alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  func testGifApngAndWebPAreAllPlayableWithTheirOwnFrameDelays() throws {
    let gif = try XCTUnwrap(AnimatedFrames(data: try animation(.gif, frames: 3, delay: 0.25)))
    XCTAssertEqual(gif.count, 3)
    XCTAssertEqual(gif.delays, [0.25, 0.25, 0.25])
    let apng = try XCTUnwrap(AnimatedFrames(data: try animation(.png, frames: 4, delay: 0.5)))
    XCTAssertEqual(apng.count, 4)
    XCTAssertEqual(apng.delays, [0.5, 0.5, 0.5, 0.5])
    let webp = try XCTUnwrap(AnimatedFrames(data: Self.animatedWebP))
    XCTAssertEqual(webp.count, 4)
    XCTAssertEqual(webp.delays, [0.1, 0.1, 0.1, 0.1])
    for frames in [gif, apng, webp] {
      let image = try XCTUnwrap(frames.image(at: frames.count - 1, maxPixelSize: 32))
      XCTAssertLessThanOrEqual(max(image.width, image.height), 32, "a frame is decoded at the size it is drawn")
      XCTAssertNil(frames.image(at: frames.count, maxPixelSize: 32))
      XCTAssertNil(frames.image(at: -1, maxPixelSize: 32))
    }
  }

  func testDelaysAuthorsWriteForAsFastAsPossibleBecomeAHundredMilliseconds() throws {
    for delay in [0.0, 0.01] {
      let frames = try XCTUnwrap(AnimatedFrames(data: try animation(.gif, frames: 2, delay: delay)))
      XCTAssertEqual(frames.delays, [0.1, 0.1], "\(delay) s")
    }
    let quick = try XCTUnwrap(AnimatedFrames(data: try animation(.gif, frames: 2, delay: 0.02)))
    XCTAssertEqual(quick.delays, [0.02, 0.02], "20 ms is the quickest a browser plays")
  }

  func testASingleFrameOrNonImageHasNothingToPlay() throws {
    XCTAssertNil(AnimatedFrames(data: try PanelImagePipelineTests.png(width: 8, height: 8)))
    XCTAssertNil(AnimatedFrames(data: Data("<svg/>".utf8)))
    XCTAssertNil(AnimatedFrames(data: Data()))
  }

  func testTheViewHoldsNoTimerUntilItIsAskedToPlayAndNeverWithoutAWindow() throws {
    let view = AnimatedPreviewView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    view.set(data: try animation(.gif, frames: 3, delay: 0.1))
    XCTAssertFalse(view.isAnimating)
    view.setPlaying(true)
    XCTAssertFalse(view.isAnimating, "a view that is not in a visible window plays nothing")
    view.setPlaying(false)
    XCTAssertEqual(view.currentFrameIndex, 0)
    view.set(data: nil)
    XCTAssertFalse(view.isAnimating)
  }
}
