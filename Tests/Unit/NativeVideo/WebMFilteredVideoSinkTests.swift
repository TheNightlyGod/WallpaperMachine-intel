import AVFoundation
import VideoToolbox
import WallpaperMedia
import XCTest
import os

@testable import WallpaperMachine

private final class FilteredVideoOutput: WebMSampleSink {
  var buffers: [CMSampleBuffer] = []
  var hasRoom: Bool { true }
  func accept(_ buffer: CMSampleBuffer) { buffers.append(buffer) }
}

/// The filtered feed is observed before a display renderer receives it: no window or audio.
@MainActor
final class WebMFilteredVideoSinkTests: XCTestCase {
  private func pipeline() -> VideoColorPipeline {
    let pipeline = VideoColorPipeline()
    var options = WallpaperEngineOptions.identity
    options.colorEnabled = true
    options.brightness = 0
    pipeline.update(.init(options: options))
    return pipeline
  }

  private func file() throws -> WebMFile {
    switch WebMOpening.open(data: WebMFixture.vp9) {
    case .success(let file): return file
    case .failure(let error): throw error
    }
  }

  private func whiteSample(
    gray: UInt8 = 255, width: Int = 4, height: Int = 4,
    time: CMTime = CMTime(value: 7, timescale: 3)
  ) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
    let image = try XCTUnwrap(pixel)
    CVPixelBufferLockBaseAddress(image, [])
    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
    memset(bytes, Int32(gray), CVPixelBufferGetDataSize(image))
    for y in 0..<height { for x in 0..<width { bytes[y * CVPixelBufferGetBytesPerRow(image) + x * 4 + 3] = 255 } }
    CVPixelBufferUnlockBaseAddress(image, [])
    CVBufferSetAttachment(image, kCVImageBufferCGColorSpaceKey,
      try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), .shouldPropagate)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }

  func testDecodedFramesAreFilteredAndKeepTheirTiming() throws {
    let output = FilteredVideoOutput()
    let sink = WebMFilteredVideoSink(output: output, pipeline: pipeline())
    let source = try whiteSample()
    sink.accept(source)
    XCTAssertEqual(output.buffers.count, 1)
    let result = try XCTUnwrap(output.buffers.first)
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(result))
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels, count: 3)), [0, 0, 0])
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(result), CMSampleBufferGetPresentationTimeStamp(source))
    XCTAssertEqual(CMSampleBufferGetDuration(result), CMSampleBufferGetDuration(source))
  }

  func testFilteredPixelBuffersAreEncodedForTheDisplay() throws {
    let pipeline = VideoColorPipeline()
    var options = WallpaperEngineOptions.identity
    options.colorEnabled = true
    options.brightness = 40
    pipeline.update(.init(options: options))
    let output = FilteredVideoOutput()
    let sink = WebMFilteredVideoSink(output: output, pipeline: pipeline)
    sink.accept(try whiteSample(gray: 128))
    let sample = try XCTUnwrap(output.buffers.first)
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
    // ccsimple scales encoded grey by (40/50)^2: 128 * 0.64 = 81.92.
    for channel in 0..<3 { XCTAssertEqual(Double(pixels[channel]), 82, accuracy: 1) }
  }

  func testConsecutiveFilteredFramesKeepTheirPixelsTimingAndMatchingFormatAcrossResizes() throws {
    let pipeline = VideoColorPipeline()
    var options = WallpaperEngineOptions.identity
    options.colorEnabled = true
    options.brightness = 40
    pipeline.update(.init(options: options))
    let output = FilteredVideoOutput()
    let sink = WebMFilteredVideoSink(output: output, pipeline: pipeline)
    let frames: [(width: Int, height: Int, gray: UInt8)] = [(4, 4, 64), (4, 4, 128), (6, 3, 192), (4, 4, 255)]
    for (index, frame) in frames.enumerated() {
      let source = try whiteSample(
        gray: frame.gray, width: frame.width, height: frame.height, time: CMTime(value: Int64(index), timescale: 30))
      sink.accept(source)
      XCTAssertEqual(output.buffers.count, index + 1)
      let sample = try XCTUnwrap(output.buffers.last)
      let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
      let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
      XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: image))
      XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, Int32(frame.width))
      XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).height, Int32(frame.height))
      XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetPresentationTimeStamp(source))
      XCTAssertEqual(CMSampleBufferGetDuration(sample), CMSampleBufferGetDuration(source))
      CVPixelBufferLockBaseAddress(image, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
      let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
      for channel in 0..<3 { XCTAssertEqual(Double(pixels[channel]), Double(frame.gray) * 0.64, accuracy: 1) }
      XCTAssertEqual(pixels[3], 255)
    }
    let firstFormat = try XCTUnwrap(CMSampleBufferGetFormatDescription(output.buffers[0]))
    let nextFormat = try XCTUnwrap(CMSampleBufferGetFormatDescription(output.buffers[1]))
    XCTAssertTrue(firstFormat === nextFormat, "successive same-format frames share one description")
  }

  func testFramesMarkedDoNotDisplayAreDecodedWithoutBeingDisplayedOrPassedThrough() throws {
    let reader = try file().makeVideoReader()
    let output = FilteredVideoOutput()
    let sink = WebMFilteredVideoSink(output: output, pipeline: pipeline())
    let errors = OSAllocatedUnfairLock(initialState: [String]())
    sink.onFailure = { error in errors.withLock { $0.append(error.localizedDescription) } }
    var shown: [CMTime] = []
    var hidden = 0
    var hiddenTime = CMTime.invalid
    while let sample = reader.copyNextSampleBuffer() {
      // The reference frame is still needed by later packets; only its presentation is hidden.
      if !hiddenTime.isValid {
        let list = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: NSMutableDictionary.self)
        dictionary[kCMSampleAttachmentKey_DoNotDisplay] = true
        hiddenTime = CMSampleBufferGetPresentationTimeStamp(sample)
      }
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
      if attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true { hidden += 1 }
      else { shown.append(CMSampleBufferGetPresentationTimeStamp(sample)) }
      sink.accept(sample)
    }
    XCTAssertGreaterThan(hidden, 0, "the fixture must exercise invisible reference frames")
    XCTAssertTrue(errors.withLock { $0.isEmpty }, errors.withLock { $0.joined(separator: "; ") })
    XCTAssertFalse(output.buffers.isEmpty)
    XCTAssertLessThanOrEqual(output.buffers.count, shown.count)
    for sample in output.buffers {
      XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample), "a filtered feed never hands compressed packets to the display")
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      XCTAssertNotEqual(time, hiddenTime)
      XCTAssertTrue(shown.contains { abs(CMTimeSubtract(time, $0).seconds) < 0.000001 })
    }
  }

  func testDecoderFailureIsReportedInsteadOfSendingAnUnfilteredPacket() throws {
    let reader = try file().makeVideoReader()
    let sample = try XCTUnwrap(reader.copyNextSampleBuffer())
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
    let count = CMBlockBufferGetDataLength(block)
    let zero = [UInt8](repeating: 0, count: count)
    XCTAssertEqual(zero.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
    }, noErr)
    let output = FilteredVideoOutput()
    let sink = WebMFilteredVideoSink(output: output, pipeline: pipeline())
    let errors = OSAllocatedUnfairLock(initialState: [String]())
    sink.onFailure = { error in errors.withLock { $0.append(error.localizedDescription) } }
    sink.accept(sample)
    XCTAssertTrue(output.buffers.isEmpty)
    XCTAssertEqual(errors.withLock { $0.count }, 1)
    XCTAssertFalse(sink.hasRoom)
    sink.reset()
    sink.accept(try whiteSample())
    XCTAssertEqual(output.buffers.count, 1, "a reposition can use a fresh filtering session")
    XCTAssertEqual(errors.withLock { $0.count }, 1)
  }
}
