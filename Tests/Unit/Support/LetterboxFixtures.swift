import CoreGraphics
import CoreMedia
import Foundation

@testable import WallpaperMachine

/// Synthetic frames for the black-bar tests: a bright, smooth picture with black bars painted
/// at exact pixel counts, so an expected fraction is arithmetic and not a measurement.
enum LetterboxFixtures {
  /// Luma of the picture at a pixel: a smooth ramp between 100 and 240, never near black, with
  /// `seed` shifting it a little so successive frames are not identical.
  static func picture(x: Int, y: Int, width: Int, height: Int, seed: Int = 0) -> UInt8 {
    UInt8(100 + (x * 100 / max(width, 1)) + (y * 40 / max(height, 1)) + seed % 4)
  }

  /// A frame of 8-bit luma, row 0 at the top, with bars of the given pixel counts.
  struct Canvas {
    let width: Int
    let height: Int
    var luma: [UInt8]

    init(width: Int = 320, height: Int = 180, top: Int = 0, bottom: Int = 0, left: Int = 0,
         right: Int = 0, barLuma: UInt8 = 0, seed: Int = 0) {
      self.width = width
      self.height = height
      luma = (0..<(width * height)).map { index in
        let x = index % width, y = index / width
        let isBar = y < top || y >= height - bottom || x < left || x >= width - right
        return isBar ? barLuma : LetterboxFixtures.picture(x: x, y: y, width: width, height: height, seed: seed)
      }
    }

    mutating func fill(x: Int, y: Int, width w: Int, height h: Int, luma value: UInt8) {
      for row in y..<min(y + h, height) {
        for column in x..<min(x + w, width) { luma[row * width + column] = value }
      }
    }

    var frame: LetterboxDetector.Frame { .init(width: width, height: height, luma: luma) }

    var image: CGImage {
      let provider = CGDataProvider(data: Data(luma) as CFData)!
      return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
  }

  /// Canvases as the frames a source would return, each at its own time.
  static func frames(_ canvases: [Canvas]) -> VideoLetterboxProbe.Frames {
    canvases.enumerated().map { (image: $1.image, time: CMTime(value: CMTimeValue($0 + 1), timescale: 10)) }
  }

  /// Five frames with the same bars and a slightly different picture in each.
  static func frames(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0,
                     width: Int = 320, height: Int = 180, count: Int = 5) -> VideoLetterboxProbe.Frames {
    frames((0..<count).map {
      Canvas(width: width, height: height, top: top, bottom: bottom, left: left, right: right, seed: $0)
    })
  }
}
