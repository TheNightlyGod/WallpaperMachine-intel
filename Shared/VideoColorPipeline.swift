import AVFoundation
import CoreImage

/// Wallpaper Engine's colour adjustments and image filter for a video, as the scene renderer's
/// `ccsimple` pass draws them (`wallpaper64.exe` `sub_140181F30`): the picture is sRGB-encoded,
/// adjusted by the `wallpaperEngineColor` kernel, then mixed with its LUT colour by the filter
/// strength, and decoded again. The parameters live in a lock-protected box, so a slider change
/// reaches the next frame without rebuilding the item; only switching between "nothing to do"
/// and "something to do" needs a new composition, which `needsComposition` tells.
final class VideoColorPipeline: @unchecked Sendable {
  enum Failure: Error { case missingColorKernel, colorKernelCouldNotApply }
  struct Parameters: Equatable, Sendable {
    var options: WallpaperEngineOptions = .identity
    var lut: VideoLut?
  }

  private let lock = NSLock()
  private var parameters = Parameters()
  private let kernelProvider: @Sendable () -> CIColorKernel?

  init(kernelProvider: @escaping @Sendable () -> CIColorKernel? = { VideoColorPipeline.colorKernel }) {
    self.kernelProvider = kernelProvider
  }

  var current: Parameters {
    lock.lock()
    defer { lock.unlock() }
    return parameters
  }

  func update(_ value: Parameters) {
    lock.lock()
    parameters = value
    lock.unlock()
  }

  /// Whether `value` changes the picture at all; at the identity no composition is attached.
  static func needsComposition(_ value: Parameters) -> Bool {
    !value.options.isColorIdentity || (!value.options.isFilterIdentity && value.lut != nil)
  }

  /// `g_Params` of `ccsimple`: (brightness², √contrast, √saturation, hue shift).
  static func colorParams(_ options: WallpaperEngineOptions) -> SIMD4<Float> {
    let brightness = Float(options.brightness / 50)
    return SIMD4(
      brightness * brightness, Float(options.contrast / 50).squareRoot(),
      Float(options.saturation / 50).squareRoot(), Float(options.hueShift / 100 - 0.5))
  }

  /// A composition that runs the pipeline on every frame, or nil at the identity.
  func videoComposition(for asset: AVAsset) async throws -> AVVideoComposition? {
    guard Self.needsComposition(current) else { return nil }
    if !current.options.isColorIdentity, kernelProvider() == nil { throw Failure.missingColorKernel }
    let composition = try await AVVideoComposition.videoComposition(with: asset) { [self] request in
      do { request.finish(with: try apply(to: request.sourceImage), context: nil) }
      catch { request.finish(with: error) }
    }
    return Self.needsComposition(current) ? composition : nil
  }

  /// Item preparation can suspend while sliders change on the main actor. Attach only a
  /// composition that agrees with the latest identity state, before the item starts playing.
  @MainActor
  func configure(_ item: AVPlayerItem) async throws {
    while true {
      let composition = try await videoComposition(for: item.asset)
      try Task.checkCancellation()
      guard (composition != nil) == Self.needsComposition(current) else { continue }
      item.videoComposition = composition
      return
    }
  }

  /// The pipeline on one linear-light picture.
  func apply(to image: CIImage) throws -> CIImage {
    let value = current
    guard Self.needsComposition(value) else { return image }
    var picture = image.applyingFilter("CILinearToSRGBToneCurve")
    if !value.options.isColorIdentity {
      guard let kernel = kernelProvider() else { throw Failure.missingColorKernel }
      let params = Self.colorParams(value.options)
      guard let adjusted = kernel.apply(
          extent: picture.extent,
          arguments: [picture, CIVector(x: CGFloat(params.x), y: CGFloat(params.y), z: CGFloat(params.z), w: CGFloat(params.w))]
        ) else { throw Failure.colorKernelCouldNotApply }
      picture = adjusted
    }
    if !value.options.isFilterIdentity, let lut = value.lut {
      let filtered = picture.applyingFilter(
        "CIColorCubeWithColorSpace",
        parameters: [
          "inputCubeDimension": lut.size, "inputCubeData": lut.cube,
          // `picture` is already explicitly sRGB-encoded. Keep the cube operation
          // numeric here, so Core Image does not apply a second transfer curve.
          "inputColorSpace": CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
        ])
      picture = picture.applyingFilter(
        "CIDissolveTransition",
        parameters: [kCIInputTargetImageKey: filtered, kCIInputTimeKey: min(1, value.options.filterStrength / 100)])
    }
    return picture.applyingFilter("CISRGBToneCurveToLinear").cropped(to: image.extent)
  }

  static let colorKernel: CIColorKernel? = {
    let bundle = Bundle(for: VideoColorPipeline.self)
    guard let url = bundle.url(forResource: "default", withExtension: "metallib"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? CIColorKernel(functionName: "wallpaperEngineColor", fromMetalLibraryData: data)
  }()
}
