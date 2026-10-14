import Foundation

/// Decides from a handful of decoded frames whether black bars are baked into a video's
/// picture and how wide they are. Pure arithmetic over 8-bit luma, with no AVFoundation.
///
/// One frame proves little: a dark scene looks like a bar and a subtitle shortens one. So
/// each frame is measured on its own, frames that are too dark to judge are skipped, and the
/// bars are the median across the rest, accepted only when most frames agree with it.
enum LetterboxDetector {
  /// A decoded frame as row-major 8-bit luma, `width * height` bytes.
  struct Frame: Equatable, Sendable {
    let width: Int
    let height: Int
    let luma: [UInt8]
  }

  /// Bar sizes as fractions (0...1) of the frame dimension they cut: `top` and `bottom` of the
  /// height, `left` and `right` of the width.
  struct Bars: Equatable, Sendable {
    var top: Double
    var bottom: Double
    var left: Double
    var right: Double

    static let zero = Bars(top: 0, bottom: 0, left: 0, right: 0)
    var widest: Double { max(top, bottom, left, right) }

    /// The four sides as percentages of the picture, for the log.
    var summary: String {
      func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
      return "top \(percent(top)) bottom \(percent(bottom)) left \(percent(left)) right \(percent(right))"
    }
  }

  struct Thresholds: Equatable, Sendable {
    /// Luma at or below this counts as black; video black (16) plus codec noise stays under it.
    var darkLuma: UInt8 = 20
    /// Share of a row or column that must be black for it to belong to a bar. Below 100% so a
    /// logo or a few subtitle glyphs inside a bar do not end it.
    var barShare = 0.985
    /// A frame whose picture area averages below this (0...1) is a fade or a dark scene.
    var minPictureMean = 0.06
    var minUsableFrames = 3
    /// An edge narrower than this fraction of its dimension is not a bar.
    var minEdge = 0.015
    /// Share of usable frames that must measure an edge within `agreementTolerance` of its median.
    var agreement = 0.6
    var agreementTolerance = 0.015
    /// Opposite bars match when they differ by at most this share of the larger (never less
    /// than `agreementTolerance`).
    var symmetryRatio = 0.25
    /// Bars on one axis adding up to more than this are not trusted.
    var axisLimit = 0.45

    static let standard = Thresholds()
  }

  enum Reason: Equatable, Sendable { case tooDark, tooFewFrames, disagree, implausible }

  enum Verdict: Equatable, Sendable {
    /// No bar wider than the minimum on any side.
    case none
    /// Bars on one or both axes, each pair matching, so a centred zoom can hide them.
    case bars(Bars)
    /// Bars exist but one side is missing or lopsided; a centred zoom would also cut picture.
    case uneven(Bars)
    case indeterminate(Reason)
  }

  /// The bars of one frame, or nil when the frame cannot be judged: malformed, entirely black,
  /// or a picture area dark enough to be a fade.
  static func edges(of frame: Frame, thresholds: Thresholds = .standard) -> Bars? {
    let width = frame.width, height = frame.height
    guard width > 0, height > 0, frame.luma.count == width * height else { return nil }
    let dark = thresholds.darkLuma
    return frame.luma.withUnsafeBufferPointer { pixels -> Bars? in
      var rowDark = [Int](repeating: 0, count: height)
      for row in 0..<height {
        let base = row * width
        var count = 0
        for column in 0..<width where pixels[base + column] <= dark { count += 1 }
        rowDark[row] = count
      }
      let rowLimit = Double(width) * thresholds.barShare
      var top = 0
      while top < height, Double(rowDark[top]) >= rowLimit { top += 1 }
      guard top < height else { return nil }
      var bottom = 0
      while bottom < height - top, Double(rowDark[height - 1 - bottom]) >= rowLimit { bottom += 1 }
      let rows = top..<(height - bottom)

      // Columns are judged over the picture rows only, so a window-boxed video is measured
      // correctly and a logo sitting in a bar cannot widen or end a column.
      var columnDark = [Int](repeating: 0, count: width)
      for row in rows {
        let base = row * width
        for column in 0..<width where pixels[base + column] <= dark { columnDark[column] += 1 }
      }
      let columnLimit = Double(rows.count) * thresholds.barShare
      var left = 0
      while left < width, Double(columnDark[left]) >= columnLimit { left += 1 }
      guard left < width else { return nil }
      var right = 0
      while right < width - left, Double(columnDark[width - 1 - right]) >= columnLimit { right += 1 }

      var total = 0
      for row in rows {
        let base = row * width
        for column in left..<(width - right) { total += Int(pixels[base + column]) }
      }
      let area = rows.count * (width - left - right)
      guard area > 0, Double(total) / Double(area * 255) >= thresholds.minPictureMean else { return nil }
      return Bars(top: Double(top) / Double(height), bottom: Double(bottom) / Double(height),
                  left: Double(left) / Double(width), right: Double(right) / Double(width))
    }
  }

  static func verdict(frames: [Frame], thresholds: Thresholds = .standard) -> Verdict {
    let measured = frames.map { edges(of: $0, thresholds: thresholds) }
    let usable = measured.compactMap { $0 }
    guard usable.count >= thresholds.minUsableFrames else {
      return .indeterminate(measured.count - usable.count > usable.count ? .tooDark : .tooFewFrames)
    }
    var medians = Bars.zero
    for edge in sides {
      let values = usable.map { $0[keyPath: edge] }.sorted()
      // The lower median: when frames split evenly, the smaller bar is the one a zoom can
      // apply without cutting into the picture.
      let median = values[(values.count - 1) / 2]
      let agreeing = values.filter { abs($0 - median) <= thresholds.agreementTolerance + 1e-9 }.count
      guard Double(agreeing) >= thresholds.agreement * Double(values.count) - 1e-9 else {
        return .indeterminate(.disagree)
      }
      medians[keyPath: edge] = median >= thresholds.minEdge ? median : 0
    }
    guard medians.top + medians.bottom <= thresholds.axisLimit,
          medians.left + medians.right <= thresholds.axisLimit else {
      return .indeterminate(.implausible)
    }
    guard medians.widest > 0 else { return .none }
    func matched(_ a: Double, _ b: Double) -> Bool {
      if a == 0 && b == 0 { return true }
      guard a > 0, b > 0 else { return false }
      return abs(a - b) <= max(thresholds.agreementTolerance, thresholds.symmetryRatio * max(a, b))
    }
    return matched(medians.top, medians.bottom) && matched(medians.left, medians.right)
      ? .bars(medians) : .uneven(medians)
  }

  private static let sides: [WritableKeyPath<Bars, Double>] = [\.top, \.bottom, \.left, \.right]
}
