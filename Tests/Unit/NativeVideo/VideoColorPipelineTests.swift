import AVFoundation
import CoreImage
import XCTest

@testable import WallpaperMachine

/// Wallpaper Engine's per-wallpaper options on a video (plan step 10.3): the colour kernel
/// against the `ccsimple` formulas, no composition at the identity, and the native player's
/// rate, flip placement and scheme-colour border.
@MainActor
final class VideoColorPipelineTests: XCTestCase {
  // MARK: Swift reference of ccsimple.frag COL with common.h's rgb2hsv / hsv2rgb

  private static func reference(_ rgb: SIMD3<Float>, _ p: SIMD4<Float>) -> SIMD3<Float> {
    let c = SIMD3<Float>(repeating: 0.5) + (rgb - SIMD3(repeating: 0.5)) * p.y
    let pp: SIMD4<Float> = c.y < c.z ? SIMD4(c.z, c.y, -1, 2.0 / 3) : SIMD4(c.y, c.z, 0, -1.0 / 3)
    let q: SIMD4<Float> = c.x < pp.x ? SIMD4(pp.x, pp.y, pp.w, c.x) : SIMD4(c.x, pp.y, pp.z, pp.x)
    let chroma = q.x - min(q.w, q.y)
    var hsv = SIMD3<Float>(abs((q.w - q.y) / (6 * chroma + 1e-10) + q.z), chroma / (q.x + 1e-10), q.x)
    hsv.z *= p.x
    hsv.y *= p.z
    hsv.x += p.w
    let k = SIMD4<Float>(1, 2.0 / 3, 1.0 / 3, 3)
    func channel(_ offset: Float) -> Float {
      let f = hsv.x + offset
      let t = abs((f - f.rounded(.down)) * 6 - k.w)
      return hsv.z * (1 + (min(max(t - 1, 0), 1) - 1) * hsv.y)
    }
    return SIMD3(channel(k.x), channel(k.y), channel(k.z))
  }

  func testTheColourKernelMatchesTheCcsimpleFormulasOnOnePixel() throws {
    let kernel = try XCTUnwrap(VideoColorPipeline.colorKernel, "the kernel loads from the bundle's metallib")
    var options = WallpaperEngineOptions.identity
    options.colorEnabled = true
    options.brightness = 60
    options.contrast = 30
    options.saturation = 80
    options.hueShift = 65
    let p = VideoColorPipeline.colorParams(options)
    XCTAssertEqual(p, SIMD4(1.44, Float(0.6).squareRoot(), Float(1.6).squareRoot(), 0.15), accuracy: 1e-5)
    for rgb in [SIMD3<Float>(0.5, 0.25, 0.25), SIMD3(0.1, 0.7, 0.3), SIMD3(0.9, 0.85, 0.2)] {
      let input = CIImage(color: CIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z)))
        .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
      let output = try XCTUnwrap(
        kernel.apply(
          extent: input.extent,
          arguments: [input, CIVector(x: CGFloat(p.x), y: CGFloat(p.y), z: CGFloat(p.z), w: CGFloat(p.w))]))
      var pixel = [Float](repeating: 0, count: 4)
      CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        .render(output, toBitmap: &pixel, rowBytes: 16, bounds: input.extent, format: .RGBAf, colorSpace: nil)
      let expected = Self.reference(rgb, p)
      XCTAssertEqual(pixel[0], expected.x, accuracy: 1e-4, "\(rgb)")
      XCTAssertEqual(pixel[1], expected.y, accuracy: 1e-4, "\(rgb)")
      XCTAssertEqual(pixel[2], expected.z, accuracy: 1e-4, "\(rgb)")
    }
  }

  func testTheIdentityAttachesNoComposition() async throws {
    let pipeline = VideoColorPipeline()
    let none = try await pipeline.videoComposition(for: AVMutableComposition())
    XCTAssertNil(none)
    var options = WallpaperEngineOptions.identity
    options.imageFilter = "amber"
    // A filter whose file could not be decoded changes nothing either.
    XCTAssertFalse(VideoColorPipeline.needsComposition(.init(options: options, lut: nil)))
    options.colorEnabled = true
    XCTAssertFalse(VideoColorPipeline.needsComposition(.init(options: options, lut: nil)), "every slider at 50")
    options.brightness = 60
    XCTAssertTrue(VideoColorPipeline.needsComposition(.init(options: options, lut: nil)))
  }

  func testTheColourKernelAdjustsStraightColourAndKeepsPremultipliedAlpha() throws {
    let kernel = try XCTUnwrap(VideoColorPipeline.colorKernel)
    var options = WallpaperEngineOptions.identity
    options.colorEnabled = true
    options.brightness = 60
    options.contrast = 30
    let params = VideoColorPipeline.colorParams(options)
    let rgb = SIMD3<Float>(0.7, 0.2, 0.4)
    for alpha in [Float(0), 0.5, 1] {
      let image = CIImage(color: CIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: CGFloat(alpha)))
        .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
      let output = try XCTUnwrap(kernel.apply(extent: image.extent, arguments: [image,
        CIVector(x: CGFloat(params.x), y: CGFloat(params.y), z: CGFloat(params.z), w: CGFloat(params.w))]))
      var pixel = [Float](repeating: 0, count: 4)
      CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        .render(output, toBitmap: &pixel, rowBytes: 16, bounds: image.extent, format: .RGBAf, colorSpace: nil)
      let expected = Self.reference(rgb, params) * alpha
      for i in 0..<3 { XCTAssertEqual(pixel[i], expected[i], accuracy: 1e-4, "alpha \(alpha)") }
      XCTAssertEqual(pixel[3], alpha, accuracy: 1e-6)
    }
  }

  func testAHalfStrengthInvertingLutMixesInEncodedColourSpace() throws {
    var cube: [Float] = []
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
      cube += [Float(1-r), Float(1-g), Float(1-b), 1]
    } } }
    let lut = VideoLut(size: 2, cube: cube.withUnsafeBufferPointer { Data(buffer: $0) })
    let pipeline = VideoColorPipeline()
    var options = WallpaperEngineOptions.identity
    options.imageFilter = "inverted"
    options.filterStrength = 50
    pipeline.update(.init(options: options, lut: lut))
    let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    let color = try XCTUnwrap(CIColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1, colorSpace: linear))
    let image = CIImage(color: color)
      .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    var pixel = [UInt8](repeating: 0, count: 4)
    CIContext(options: [.workingColorSpace: linear])
      .render(try pipeline.apply(to: image), toBitmap: &pixel, rowBytes: 4, bounds: image.extent, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    // Half of c and 1-c is encoded 0.5. The GPU tone curves may differ below one 8-bit step.
    for channel in pixel.prefix(3) { XCTAssertEqual(Double(channel), 128, accuracy: 1) }
    XCTAssertEqual(pixel[3], 255)
  }

  func testAMissingColourKernelIsAnErrorInsteadOfAnUnadjustedPicture() async throws {
    let pipeline = VideoColorPipeline(kernelProvider: { nil })
    let input = CIImage(color: .white)
    XCTAssertNoThrow(try pipeline.apply(to: input), "the identity needs no kernel")
    var options = WallpaperEngineOptions.identity
    options.colorEnabled = true
    options.brightness = 0
    pipeline.update(.init(options: options))
    XCTAssertThrowsError(try pipeline.apply(to: input))
    do {
      _ = try await pipeline.videoComposition(for: AVMutableComposition())
      XCTFail("a requested adjustment must not silently disappear")
    } catch VideoColorPipeline.Failure.missingColorKernel {}
  }

  // MARK: Native player

  private func makePlayer() -> NativeVideoPlayer {
    let counters = RuntimeCounters()
    let player = NativeVideoPlayer(
      surface: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 1, generation: 1),
      counters: counters, paused: true)
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    view.wantsLayer = true
    player.attach(to: view)
    addTeardownBlock { @MainActor in player.stop() }
    return player
  }

  func testThePlaybackRateIsTheDefaultRate() {
    let player = makePlayer()
    var options = WallpaperEngineOptions.identity
    options.playbackRate = 150
    player.setEngineOptions(options, lut: nil, borderColor: nil)
    XCTAssertEqual(player.playerDefaultRateForTest, 1.5)
  }

  func testFlipMirrorsTheLayerAboutItsCentreAndKeepsItsPlace() {
    let player = makePlayer()
    let bounds = player.layerBoundsForTest
    let position = player.layerPositionForTest
    var options = WallpaperEngineOptions.identity
    options.flipHorizontal = true
    player.setEngineOptions(options, lut: nil, borderColor: nil)
    XCTAssertEqual(player.layerTransformForTest, CGAffineTransform(scaleX: -1, y: 1))
    XCTAssertEqual(player.layerBoundsForTest, bounds)
    XCTAssertEqual(player.layerPositionForTest, position)
    XCTAssertEqual(position, CGPoint(x: 100, y: 50))
    options.flipHorizontal = false
    player.setEngineOptions(options, lut: nil, borderColor: nil)
    XCTAssertEqual(player.layerTransformForTest, .identity)
  }

  func testTheSchemeColourBordersAFitVideoAndFillStaysBlack() {
    let player = makePlayer()
    let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    player.setScaling(.match, factor: 1)
    player.setEngineOptions(.identity, lut: nil, borderColor: red)
    XCTAssertEqual(player.layerBackgroundForTest, red)
    player.setScaling(.fill, factor: 1)
    XCTAssertEqual(player.layerBackgroundForTest?.components?.first.map { Double($0) }, 0, "Fill covers the display: black")
    player.setScaling(.none, factor: 1)
    XCTAssertEqual(player.layerBackgroundForTest, red)
    player.setEngineOptions(.identity, lut: nil, borderColor: nil)
    XCTAssertEqual(player.layerBackgroundForTest?.components?.first.map { Double($0) }, 0)
  }

  func testALockScreenFrameKeepsTheSchemeColourInItsBars() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-border-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try await SyntheticVideoFixture.write(
      .constantRate(name: "border", numerator: 30, denominator: 1, frames: 4), into: directory)
    let player = LockScreenVideoPlayer(
      url: url, mode: .match, factor: 1, viewport: CGSize(width: 40, height: 40), backingScale: 1,
      borderColor: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    defer { player.stop() }
    let frame = await player.frame()
    let image = try XCTUnwrap(frame)
    let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
    let at = image.bytesPerRow * 2 + 2 * 4
    XCTAssertEqual(Array(pixels[at..<(at + 3)]), [255, 0, 0], "the captured frame has the same red border as the live layer")
  }
}

private func XCTAssertEqual(
  _ a: SIMD4<Float>, _ b: SIMD4<Float>, accuracy: Float, file: StaticString = #filePath, line: UInt = #line
) {
  for i in 0..<4 { XCTAssertEqual(a[i], b[i], accuracy: accuracy, file: file, line: line) }
}
