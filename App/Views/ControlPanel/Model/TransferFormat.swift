import Foundation

/// How the panel words a transfer: sizes, speeds, time left and the line that combines them.
///
/// Sizes count in base 1024 (as a file does on disk) and speeds in base 1000 (as a network
/// does), which is why `ByteCountFormatter` cannot stand in for either. Every figure keeps one
/// fraction digit at most, rounds half away from zero, and reads in `locale`. A value that is
/// missing or has no meaning comes back as the empty string, so a caller can join the pieces
/// that exist.
@MainActor
enum TransferFormat {
  /// What a download or a pixiv save reports; the line words whichever of it is known.
  struct Progress: Equatable {
    var progress: Double?
    var bytesReceived: Double?
    var bytesExpected: Double?
    var bytesPerSecond: Double?
    var secondsRemaining: Double?

    init(
      progress: Double? = nil, bytesReceived: Double? = nil, bytesExpected: Double? = nil,
      bytesPerSecond: Double? = nil, secondsRemaining: Double? = nil
    ) {
      self.progress = progress
      self.bytesReceived = bytesReceived
      self.bytesExpected = bytesExpected
      self.bytesPerSecond = bytesPerSecond
      self.secondsRemaining = secondsRemaining
    }
  }

  /// "1.5 MB": base 1024, units B, KB, MB, GB. Empty for a size that is not positive.
  static func bytes(_ value: Double?, locale: Locale = .current) -> String {
    guard let value, value.isFinite, value > 0 else { return "" }
    let exponent = min(max(Int((log(value) / log(1024)).rounded(.down)), 0), 3)
    let unit = ["B", "KB", "MB", "GB"][exponent]
    return "\(number(value / pow(1024, Double(exponent)), locale: locale)) \(unit)"
  }

  /// "600 KB/s": base 1000, units B/s, KB/s, MB/s, GB/s. Zero is a speed ("0 B/s"); a negative
  /// or non-finite one is not.
  static func speed(_ value: Double?, locale: Locale = .current) -> String {
    guard let value, value.isFinite, value >= 0 else { return "" }
    let exponent =
      value > 0 ? min(max(Int((log10(value) / 3).rounded(.down)), 0), 3) : 0
    let unit = ["B/s", "KB/s", "MB/s", "GB/s"][exponent]
    return "\(number(value / pow(1000, Double(exponent)), locale: locale)) \(unit)"
  }

  /// Seconds under a minute and a half, minutes under an hour and a half, then hours with one
  /// decimal, each in the abbreviated unit of `locale`. Empty for a span that is not positive.
  static func duration(_ seconds: Double?, locale: Locale = .current) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
    let value: Double
    let unit: UnitDuration
    if seconds < 90 {
      (value, unit) = (seconds.rounded(), .seconds)
    } else if seconds < 5400 {
      (value, unit) = ((seconds / 60).rounded(), .minutes)
    } else {
      (value, unit) = ((seconds / 360).rounded() / 10, .hours)
    }
    return Measurement(value: value, unit: unit).formatted(
      .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: numberStyle)
        .locale(locale))
  }

  /// "Network speed: 600 KB/s", or empty when there is no speed.
  static func rate(_ bytesPerSecond: Double?, locale: Locale = .current) -> String {
    let pace = speed(bytesPerSecond, locale: locale)
    return pace.isEmpty ? "" : L("Network speed: \(pace)")
  }

  /// "2 min left", or empty when there is no estimate.
  static func timeLeft(_ seconds: Double?, locale: Locale = .current) -> String {
    let time = duration(seconds, locale: locale)
    return time.isEmpty ? "" : L("\(time) left")
  }

  /// "42%": the progress clamped to 0...1 and rounded half up. Empty when it is unknown.
  static func percent(_ progress: Double?) -> String {
    guard let progress, progress.isFinite else { return "" }
    return "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
  }

  /// The one line a row shows: percent, "received of expected", speed and time left, joined
  /// with " · ", leaving out whatever is not known. `includePercent` is false where the percent
  /// is drawn as a ring beside the line instead.
  static func transfer(
    _ item: Progress, includePercent: Bool = true, locale: Locale = .current
  ) -> String {
    let received = bytes(item.bytesReceived, locale: locale)
    let expected = bytes(item.bytesExpected, locale: locale)
    let amount =
      !received.isEmpty && !expected.isEmpty
      ? L("\(received) of \(expected)") : received
    return [
      includePercent ? percent(item.progress) : "", amount,
      rate(item.bytesPerSecond, locale: locale), timeLeft(item.secondsRemaining, locale: locale),
    ].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// One fraction digit at most, half away from zero: what the web panel's `toLocaleString`
  /// produced, and what a user reading "1.3 KB" for 1,280 bytes expects.
  private static var numberStyle: FloatingPointFormatStyle<Double> {
    .number.rounded(rule: .toNearestOrAwayFromZero).precision(.fractionLength(0...1))
  }

  private static func number(_ value: Double, locale: Locale) -> String {
    value.formatted(numberStyle.locale(locale))
  }
}
