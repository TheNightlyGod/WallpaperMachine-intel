import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Samples a few frames of a video file and reports whether black bars are baked into its picture.
///
/// Read-only and bounded: about five frame decodes, a time limit, and a file stamp compared before
/// and after so a file replaced mid-check is reported instead of judged. Nothing is written.
actor VideoLetterboxProbe {
  typealias Frames = [(image: CGImage, time: CMTime)]
  /// Produces the sampled frames of a file; tests inject one instead of decoding.
  typealias FrameSource = @Sendable (URL) async throws -> Frames

  struct Report: Equatable, Sendable {
    let stamp: VideoFileStamp
    /// Width over height of the decoded, upright frame.
    let aspect: Double
    /// Distinct frames the verdict was drawn from.
    let sampled: Int
    let verdict: LetterboxDetector.Verdict
  }

  enum Failure: Error, Equatable, Sendable {
    /// AVFoundation could not open or decode the file; the detail is its description.
    case unreadable(String)
    case noVideoTrack
    case timedOut
    /// The file's size, date or identity changed while it was being sampled.
    case fileChanged
  }

  private let frames: FrameSource
  private let thresholds: LetterboxDetector.Thresholds
  private let timeout: Duration

  init(frames: @escaping FrameSource = VideoLetterboxProbe.generatedFrames,
       thresholds: LetterboxDetector.Thresholds = .standard, timeout: Duration = .seconds(20)) {
    self.frames = frames
    self.thresholds = thresholds
    self.timeout = timeout
  }

  func check(_ url: URL) async throws -> Report {
    let before: VideoFileStamp
    do { before = try VideoFileStamp(url: url) } catch { throw Failure.unreadable(error.localizedDescription) }
    let source = frames, limit = timeout
    let sampled: Frames
    do {
      sampled = try await withThrowingTaskGroup(of: Frames?.self) { group in
        group.addTask { try await source(url) }
        group.addTask {
          try await Task.sleep(for: limit)
          return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let result = first else { throw Failure.timedOut }
        return result
      }
    } catch let failure as Failure {
      throw failure
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Failure.unreadable(error.localizedDescription)
    }
    try Task.checkCancellation()
    guard (try? VideoFileStamp(url: url)) == before else { throw Failure.fileChanged }

    var seen: [CMTime] = []
    var luma: [LetterboxDetector.Frame] = []
    var aspect = 0.0
    for (image, time) in sampled {
      // Zero-tolerance generation snaps short or single-frame clips onto the same frame; a
      // repeat would count one picture several times toward the agreement rule.
      if time.isValid, seen.contains(time) {
        AppLog.debug("Black bar check: dropped a repeated frame of \(url.lastPathComponent)")
        continue
      }
      seen.append(time)
      guard let frame = LetterboxDetector.Frame(image: image) else {
        AppLog.debug("Black bar check: skipped a frame of \(url.lastPathComponent) that could not be read as luma")
        continue
      }
      if aspect == 0 { aspect = Double(image.width) / Double(image.height) }
      luma.append(frame)
    }
    return Report(stamp: before, aspect: aspect, sampled: luma.count,
                  verdict: LetterboxDetector.verdict(frames: luma, thresholds: thresholds))
  }

  /// The file's present stamp, or nil when it cannot be read. Run here, not on the main actor, so
  /// the store can confirm a result still describes the file without touching the disk itself.
  func currentStamp(of url: URL) -> VideoFileStamp? {
    try? VideoFileStamp(url: url)
  }

  /// The fractions of the clip at which frames are taken, away from the ends where fades live.
  static let samplePositions: [Double] = [0.1, 0.3, 0.5, 0.7, 0.9]
  /// Frames are decoded no larger than this on either side: bars show at any size.
  static let maximumFrameDimension = 640

  /// Decodes the frames with `AVAssetImageGenerator`: upright, bounded in size, at exact times.
  /// A frame that fails to decode is skipped; only when none decode is the file unreadable.
  static let generatedFrames: FrameSource = { url in
    let asset = AVURLAsset(url: url)
    do {
      guard try await asset.load(.isPlayable) else { throw Failure.unreadable("not playable") }
      guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw Failure.noVideoTrack }
    } catch let failure as Failure {
      throw failure
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw Failure.unreadable(error.localizedDescription)
    }
    let duration = (try? await asset.load(.duration)) ?? .invalid
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maximumFrameDimension, height: maximumFrameDimension)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var decoded: Frames = []
    var firstError: Error?
    for time in sampleTimes(duration: duration) {
      try Task.checkCancellation()
      do {
        let result = try await generator.image(at: time)
        decoded.append((image: result.image, time: result.actualTime))
      } catch {
        if Task.isCancelled { throw CancellationError() }
        AppLog.debug("Black bar check: no frame at \(time.seconds)s of \(url.lastPathComponent): \(error.localizedDescription)")
        firstError = firstError ?? error
      }
    }
    guard !decoded.isEmpty else {
      throw Failure.unreadable(firstError?.localizedDescription ?? "no frame could be decoded")
    }
    return decoded
  }

  /// A clip with no usable duration is sampled once, at its start.
  static func sampleTimes(duration: CMTime) -> [CMTime] {
    guard duration.isNumeric, duration.seconds > 0 else { return [.zero] }
    return samplePositions.map { CMTimeMultiplyByFloat64(duration, multiplier: $0) }
  }
}

extension LetterboxDetector.Frame {
  /// The image drawn into 8-bit gray, scaled down so neither side exceeds `maximumDimension`.
  /// Transparency reads as black, matching how a bar looks on a dark desktop.
  init?(image: CGImage, maximumDimension: Int = VideoLetterboxProbe.maximumFrameDimension) {
    guard image.width > 0, image.height > 0 else { return nil }
    let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
      let base = context.data
    else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(bounds)
    context.interpolationQuality = .medium
    context.draw(image, in: bounds)
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    var luma = [UInt8](repeating: 0, count: width * height)
    for row in 0..<height {
      let source = pixels + row * context.bytesPerRow
      for column in 0..<width { luma[row * width + column] = source[column] }
    }
    self.init(width: width, height: height, luma: luma)
  }
}
