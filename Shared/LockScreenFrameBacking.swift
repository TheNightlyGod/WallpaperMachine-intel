import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import QuartzCore

/// Keeps actual frame pixels in the remote layer tree when no Metal drawable is available.
enum LockScreenFrameBacking {
  static func install(_ surface: IOSurface, on root: CALayer) throws {
      let width = surface.width
      let height = surface.height
      guard surface.pixelFormat == kCVPixelFormatType_32BGRA, surface.bytesPerElement == 4,
            width > 0, height > 0,
            surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else {
          throw CocoaError(.fileReadCorruptFile)
      }
      // The pixels stay in the surface: the image owns a retained reference and the read lock, and
      // gives both back when the last copy of the image goes away.
      let bytesPerRow = surface.bytesPerRow
      let owner = Unmanaged.passRetained(surface)
      let provider = CGDataProvider(
          dataInfo: owner.toOpaque(), data: surface.baseAddress, size: bytesPerRow * height,
          releaseData: { info, _, _ in
              guard let info else { return }
              let held = Unmanaged<IOSurface>.fromOpaque(info).takeRetainedValue()
              held.unlock(options: .readOnly, seed: nil)
          })
      let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
      guard let provider, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmap, provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
          if provider == nil {
              surface.unlock(options: .readOnly, seed: nil)
              owner.release()
          }
          throw CocoaError(.fileReadCorruptFile)
      }
      // One committed frame, with no implicit fade. Flushing makes "ready" mean the frame is in the
      // tree; waiting for scanout here would deadlock, since the host has not received this
      // context yet.
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      root.contents = image
      root.contentsGravity = .resize
      CATransaction.commit()
      CATransaction.flush()
  }
}
