import Foundation

/// What Performance › Energy use shows: the monitor's reading, its grade, the battery share and the
/// comparison with the figure before the last quality change.
///
/// Built from the monitor (`EnergyUsageMonitor.readout`), which keeps measuring only while Settings
/// is on screen. The formatting is the page's: a reading in watts with one decimal from 1,000 mW,
/// milliwatts below, in the Mac's region and not the app's language.
struct EnergyReadout: Equatable {
  enum Status: Equatable, Sendable {
    case measuring, ready, unavailable
  }

  /// A condition that stops a figure from being graded or compared, with what it says.
  enum Caveat: Equatable, Sendable {
    /// A plain video: macOS charges its decoding and drawing to nobody
    /// this app owns.
    case nativeVideo
    /// Other apps kept the GPU busy, which makes macOS charge this app's GPU work more.
    case gpuContended

    @MainActor var title: String {
      switch self {
      case .nativeVideo: L("Video not counted")
      case .gpuContended: L("GPU shared with other apps")
      }
    }

    @MainActor var note: String {
      switch self {
      case .nativeVideo:
        L(
          "macOS decodes and draws videos and charges none of that to this app, so these figures leave most of it out. The grade and any comparison are off while one plays."
        )
      case .gpuContended:
        L(
          "Other apps are keeping the GPU busy, so the GPU figure reads higher than this app’s own share. The grade and any comparison wait until the GPU is free."
        )
      }
    }
  }

  /// The settled figure from before the last change, and the one after it once it has settled.
  struct Comparison: Equatable, Sendable {
    var beforeMilliwatts: Double
    var afterMilliwatts: Double?
  }

  static let measuring = EnergyReadout(status: .measuring)

  var status: Status
  var cpuMilliwatts = 0.0
  var gpuMilliwatts = 0.0
  var nativeVideo = false
  var gpuContended = false
  /// Low, medium or high, only for a ready figure that nothing qualifies.
  var level: EnergyLevel?
  /// A share of a full battery charge per hour, only for a graded figure on a Mac with a battery.
  var batteryPercentPerHour: Double?
  var comparison: Comparison?

  var totalMilliwatts: Double { cpuMilliwatts + gpuMilliwatts }

  /// The conditions that qualify the figure, the first of which names it. Native video comes first.
  var caveats: [Caveat] {
    var result = [Caveat]()
    if nativeVideo { result.append(.nativeVideo) }
    if gpuContended { result.append(.gpuContended) }
    return result
  }

  // MARK: Building from the monitor

  /// `batteryCapacityWattHours` is the battery's full charge, nil on a Mac without one; the grade and
  /// battery share exist only for a figure that is comparable.
  init(
    reading: EnergyUsageReading, comparison: EnergyUsageComparison?, batteryCapacityWattHours: Double?
  ) {
    switch reading.status {
    case .measuring: status = .measuring
    case .ready: status = .ready
    case .unavailable: status = .unavailable
    }
    cpuMilliwatts = reading.cpuMilliwatts
    gpuMilliwatts = reading.gpuMilliwatts
    nativeVideo = reading.nativeVideo
    gpuContended = reading.gpuContended
    if reading.isComparable {
      level = EnergyLevel(milliwatts: reading.totalMilliwatts)
      if let batteryCapacityWattHours, batteryCapacityWattHours > 0 {
        batteryPercentPerHour = reading.totalMilliwatts / 1000 / batteryCapacityWattHours * 100
      }
    }
    self.comparison = comparison.map {
      Comparison(
        beforeMilliwatts: $0.before.totalMilliwatts, afterMilliwatts: $0.after?.totalMilliwatts)
    }
  }

  init(status: Status) { self.status = status }

  // MARK: Words

  /// "Low energy use" for the grade, nil when the figure has none.
  @MainActor var levelTitle: String? { level.map(Self.title(for:)) }

  /// "About 4% of a full battery charge per hour.", nil without a share.
  @MainActor var batteryShareNote: String? {
    batteryPercentPerHour.flatMap(Self.batteryShareNote(percentPerHour:))
  }

  /// The words for a grade. The inspector's per-wallpaper energy line uses them too.
  @MainActor static func title(for level: EnergyLevel) -> String {
    switch level {
    case .low: L("Low energy use")
    case .medium: L("Medium energy use")
    case .high: L("High energy use")
    }
  }

  /// "About 4% of a full battery charge per hour.", "Less than 1%…" under one, nil for a figure that
  /// is not a number.
  @MainActor static func batteryShareNote(percentPerHour percent: Double) -> String? {
    guard percent.isFinite else { return nil }
    if percent < 1 { return L("Less than 1% of a full battery charge per hour.") }
    return L("About \(Int(percent.rounded()))% of a full battery charge per hour.")
  }

  /// What the change did to the energy use, nil while there is nothing to compare.
  ///
  /// With no figure for after yet it says it is measuring. A change under half a percent reads "about
  /// the same". The minus sign is U+2212.
  @MainActor func comparisonNote(locale: Locale = .current) -> String? {
    guard let comparison, comparison.beforeMilliwatts.isFinite else { return nil }
    let before = Self.milliwatts(comparison.beforeMilliwatts, locale: locale)
    guard let afterMilliwatts = comparison.afterMilliwatts, afterMilliwatts.isFinite else {
      return L("Measuring the effect of your change. Before it: \(before).")
    }
    let after = Self.milliwatts(afterMilliwatts, locale: locale)
    let change =
      comparison.beforeMilliwatts > 0
      ? Int(
        ((afterMilliwatts - comparison.beforeMilliwatts) / comparison.beforeMilliwatts * 100)
          .rounded()) : nil
    guard let change, change != 0 else {
      return L("Before your change: \(before). Now: \(after), about the same.")
    }
    let text = change > 0 ? "+\(change)%" : "\u{2212}\(abs(change))%"
    return L("Before your change: \(before). Now: \(after) (\(text)).")
  }

  /// "1.2 W" from 1,000 mW, "840 mW" below it, "Unavailable" for a figure that is not a number.
  @MainActor static func milliwatts(_ value: Double, locale: Locale = .current) -> String {
    guard value.isFinite else { return L("Unavailable") }
    if value >= 1000 {
      let watts = (value / 1000).formatted(
        .number.rounded(rule: .toNearestOrAwayFromZero).precision(.fractionLength(1)).locale(locale))
      return L("\(watts) W")
    }
    let milli = value.formatted(
      .number.rounded(rule: .toNearestOrAwayFromZero).precision(.fractionLength(0)).locale(locale))
    return L("\(milli) mW")
  }
}

extension EnergyUsageMonitor {
  /// The reading as the Energy use readout words it.
  var readout: EnergyReadout {
    EnergyReadout(
      reading: reading, comparison: comparison, batteryCapacityWattHours: batteryCapacity)
  }
}
