import AVFoundation
import CoreImage
import VideoToolbox
import os

/// The WebM feed while Wallpaper Engine's colour options change the picture: each compressed
/// sample is decoded here (`VTDecompressionSession`, with the system's supplemental VP9 decoder),
/// run through `VideoColorPipeline` into a pooled pixel buffer, and handed to the display layer
/// uncompressed with the decoder's presentation timing. At the identity the player feeds the compressed
/// samples straight to the layer and this costs nothing. Runs on the player's feed queue only.
final class WebMFilteredVideoSink: WebMSampleSink, @unchecked Sendable {
  private let output: any WebMSampleSink
  private let pipeline: VideoColorPipeline
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var session: VTDecompressionSession?
  private var sessionFormat: CMFormatDescription?
  private var pool: CVPixelBufferPool?
  private var poolSize = CGSize.zero
  private var outputFormat: CMVideoFormatDescription?
  private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private(set) var hasFailed = false

  private struct DecodeResult {
    var status: OSStatus = noErr
    var image: CVImageBuffer?
    var time = CMTime.invalid
    var duration = CMTime.invalid
  }
  private let decodedFrame = OSAllocatedUnfairLock(initialState: DecodeResult())

  var onFailure: (@Sendable (Error) -> Void)?

  init(output: any WebMSampleSink, pipeline: VideoColorPipeline) {
    self.output = output
    self.pipeline = pipeline
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
  }

  deinit {
    if let session { VTDecompressionSessionInvalidate(session) }
  }

  var hasRoom: Bool { !hasFailed && output.hasRoom }

  /// Called on the feed queue after it has stopped using the old decode session.
  func reset() {
    if let session { VTDecompressionSessionInvalidate(session) }
    session = nil
    sessionFormat = nil
    hasFailed = false
  }

  func accept(_ buffer: CMSampleBuffer) {
    guard !hasFailed else { return }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
    let hidden = attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true
    do {
      if let image = CMSampleBufferGetImageBuffer(buffer) {
        if hidden { return }
        var timing = CMSampleTimingInfo()
        try check(CMSampleBufferGetSampleTimingInfo(buffer, at: 0, timingInfoOut: &timing))
        output.accept(try filtered(image, timing: timing))
      } else {
        guard let format = CMSampleBufferGetFormatDescription(buffer) else {
          throw NSError(domain: NSOSStatusErrorDomain, code: Int(kVTVideoDecoderBadDataErr))
        }
        // Hidden packets still update codec references, but they never reach the display.
        guard let frame = try decode(buffer, format: format, hidden: hidden), !hidden,
          let image = frame.image else { return }
        let timing = CMSampleTimingInfo(
          duration: frame.duration.isNumeric ? frame.duration : CMSampleBufferGetDuration(buffer),
          presentationTimeStamp: frame.time.isNumeric ? frame.time : CMSampleBufferGetPresentationTimeStamp(buffer),
          decodeTimeStamp: .invalid)
        output.accept(try filtered(image, timing: timing))
      }
    } catch {
      hasFailed = true
      onFailure?(error)
    }
  }

  private func check(_ status: OSStatus) throws {
    if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }

  private func decode(_ buffer: CMSampleBuffer, format: CMFormatDescription, hidden: Bool) throws -> DecodeResult? {
    if session == nil || sessionFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
      if let session { VTDecompressionSessionInvalidate(session) }
      session = nil
      var created: VTDecompressionSession?
      let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
      try check(VTDecompressionSessionCreate(
        allocator: nil, formatDescription: format, decoderSpecification: nil,
        imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &created))
      session = created
      sessionFormat = format
    }
    guard let session else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kVTInvalidSessionErr)) }
    let result = decodedFrame
    result.withLock { $0 = DecodeResult() }
    // With asynchronous and temporal processing both disabled, VideoToolbox calls the
    // output handler before returning. The reader supplies one coded frame per buffer.
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: buffer, flags: hidden ? [._DoNotOutputFrame] : [], infoFlagsOut: nil
    ) { status, _, image, time, duration in
      result.withLock { $0 = DecodeResult(status: status, image: image, time: time, duration: duration) }
    }
    try check(status)
    let frame = result.withLock { value in
      let frame = value
      value.image = nil
      return frame
    }
    try check(frame.status)
    return frame.image == nil ? nil : frame
  }

  private func filtered(_ image: CVImageBuffer, timing source: CMSampleTimingInfo) throws -> CMSampleBuffer {
    let size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
    if pool == nil || poolSize != size {
      var created: CVPixelBufferPool?
      try check(CVPixelBufferPoolCreate(
        nil, nil,
        [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
          kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary, &created))
      pool = created
      poolSize = size
    }
    var output: CVPixelBuffer?
    guard let pool else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCVReturnAllocationFailed)) }
    try check(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output))
    guard let output else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCVReturnAllocationFailed)) }
    CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, outputColorSpace, .shouldPropagate)
    CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    context.render(try pipeline.apply(to: CIImage(cvImageBuffer: image)), to: output,
      bounds: CGRect(origin: .zero, size: size), colorSpace: outputColorSpace)
    // The pool normally produces the same format on every frame. Keep one description,
    // but check the actual buffer's layout and colour attachments before reusing it.
    if outputFormat.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: output) }) != true {
      var format: CMVideoFormatDescription?
      try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: output, formatDescriptionOut: &format))
      outputFormat = format
    }
    guard let format = outputFormat else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCVReturnInvalidPixelFormat)) }
    var timing = source
    var sample: CMSampleBuffer?
    try check(CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil, imageBuffer: output, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample))
    guard let sample else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCVReturnAllocationFailed)) }
    return sample
  }
}
