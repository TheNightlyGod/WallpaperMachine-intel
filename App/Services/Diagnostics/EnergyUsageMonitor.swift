import Foundation

/// Cumulative counters of one resource coalition, as the kernel keeps them.
struct CoalitionEnergyCounters: Equatable, Sendable {
  var cpuEnergyNanojoules: UInt64
  var gpuEnergyNanojoules: UInt64
  var gpuTimeNanoseconds: UInt64
}

/// Everything one readout needs, read at a single instant.
struct EnergyUsageSample: Equatable, Sendable {
  /// Monotonic clock, nanoseconds.
  var uptimeNanoseconds: UInt64
  /// This app's coalition and the lock-screen extension's, by coalition id.
  var own: [UInt64: CoalitionEnergyCounters]
  /// GPU time of every other resource coalition on the Mac, by coalition id.
  var otherGPUTime: [UInt64: UInt64]
}

protocol EnergyUsageSource: Sendable {
  /// Nil when the counters cannot be read.
  func sample() -> EnergyUsageSample?
}

/// How much power a figure is, in the three words the panel uses.
///
/// A MacBook Air doing light work draws roughly 3–5 W in total, display included, so
/// 0.5 W adds on the order of a tenth to its battery drain and 2 W on the order of half.
enum EnergyLevel: String, Codable, Sendable {
  case low, medium, high

  static let mediumFromMilliwatts = 500.0
  static let highFromMilliwatts = 2_000.0

  init(milliwatts: Double) {
    self =
      milliwatts >= Self.highFromMilliwatts
      ? .high : milliwatts >= Self.mediumFromMilliwatts ? .medium : .low
  }
}

/// Mean CPU and GPU power charged to this app between two samples.
///
/// macOS charges GPU energy to a coalition in proportion to the GPU time its work
/// occupied. When other apps keep the GPU busy, the clock rises and this app's work
/// shares the GPU for longer, so the figure charged to it rises although the app does
/// no more work. Measured on an M5 Pro: 0.59 W alone, 4.6 W next to a 25 % GPU load
/// and 15 W next to a saturating one. `gpuContended` flags those windows.
struct EnergyUsageReading: Equatable {
  enum Status: String {
    case measuring, ready, unavailable
  }

  /// Share of the window other coalitions kept the GPU busy, summed, above which the
  /// GPU figure is flagged. The same Mac measured about 0.15 with only the desktop,
  /// a browser and this app running and 0.4 or more beside any sizeable GPU load.
  static let contentionThreshold = 0.25

  var status: Status
  var cpuMilliwatts = 0.0
  var gpuMilliwatts = 0.0
  var gpuContended = false
  /// A video was playing through macOS's native player during the window. The media
  /// engine decodes it and WindowServer draws it, and macOS charges neither to any of
  /// this app's coalitions, so the figure leaves most of that video's cost out.
  var nativeVideo = false
  /// Length of the window the means cover.
  var seconds = 0.0

  var totalMilliwatts: Double { cpuMilliwatts + gpuMilliwatts }
  /// A ready figure that neither GPU contention nor native video qualifies, so it can
  /// be graded and compared.
  var isComparable: Bool { status == .ready && !gpuContended && !nativeVideo }

  static let measuring = EnergyUsageReading(status: .measuring)
  static let unavailable = EnergyUsageReading(status: .unavailable)

  /// A coalition present in only one sample started or ended inside the window, so it
  /// has no delta and is left out rather than counted from zero.
  static func between(_ older: EnergyUsageSample, _ newer: EnergyUsageSample)
    -> EnergyUsageReading
  {
    guard newer.uptimeNanoseconds > older.uptimeNanoseconds else { return .measuring }
    let seconds = Double(newer.uptimeNanoseconds - older.uptimeNanoseconds) / 1e9
    var cpu: UInt64 = 0
    var gpu: UInt64 = 0
    for (id, after) in newer.own {
      guard let before = older.own[id] else { continue }
      cpu += delta(before.cpuEnergyNanojoules, after.cpuEnergyNanojoules)
      gpu += delta(before.gpuEnergyNanojoules, after.gpuEnergyNanojoules)
    }
    var otherGPUTime: UInt64 = 0
    for (id, after) in newer.otherGPUTime {
      guard let before = older.otherGPUTime[id] else { continue }
      otherGPUTime += delta(before, after)
    }
    // Nanojoules per second divided by 1e6 is milliwatts.
    return EnergyUsageReading(
      status: .ready,
      cpuMilliwatts: Double(cpu) / 1e6 / seconds,
      gpuMilliwatts: Double(gpu) / 1e6 / seconds,
      gpuContended: Double(otherGPUTime) / 1e9 / seconds >= contentionThreshold,
      seconds: seconds)
  }

  private static func delta(_ before: UInt64, _ after: UInt64) -> UInt64 {
    after >= before ? after - before : 0
  }

  var snapshot: [String: Any] {
    [
      "status": status.rawValue,
      "cpuMilliwatts": cpuMilliwatts,
      "gpuMilliwatts": gpuMilliwatts,
      "gpuContended": gpuContended,
      "nativeVideo": nativeVideo,
      "seconds": seconds,
    ]
  }
}

/// Readings either side of a setting change, each over a full window of its own.
struct EnergyUsageComparison: Equatable {
  var before: EnergyUsageReading
  /// Nil until a full, uncontended window has passed since the change.
  var after: EnergyUsageReading?
}

/// Samples this app's energy use while the Settings readout is on screen.
///
/// Nothing runs while inactive: no timer, no thread, no retained samples. Each sample is
/// taken off the main thread because it reads every resource coalition on the Mac
/// (a few hundred kernel calls). The reading averages the last `windowSamples`
/// intervals, since the kernel posts GPU energy in batches about half a second apart.
///
/// `settingChanged()` starts a fresh window and keeps the last settled reading as the
/// "before" half of a comparison, so the page can show what a change did.
@MainActor
final class EnergyUsageMonitor {
  nonisolated static let defaultInterval: Duration = .seconds(2)
  /// Samples kept; the reading spans `windowSamples - 1` intervals.
  static let windowSamples = 4

  /// Called on the main actor whenever `reading` or `comparison` changes.
  var onChange: (@MainActor () -> Void)?
  /// Whether a video is playing through macOS's native player now. Asked once per
  /// sample; a reading whose window holds such a sample is flagged `nativeVideo`.
  var nativeVideoPlaying: @MainActor () -> Bool = { false }
  private(set) var reading = EnergyUsageReading.measuring
  private(set) var comparison: EnergyUsageComparison?
  var isActive: Bool { task != nil }

  private struct Recorded {
    var sample: EnergyUsageSample
    var nativeVideo: Bool
  }

  private let source: EnergyUsageSource?
  private let interval: Duration
  private let batteryWattHours: @MainActor () -> Double?
  /// Read once per activation; a battery's full charge moves over months, not minutes. Watt-hours,
  /// nil on a Mac without a battery. Readable so the panel's typed readout can word the battery share.
  private(set) var batteryCapacity: Double?
  private var samples: [Recorded] = []
  private var task: Task<Void, Never>?

  init(
    source: EnergyUsageSource?, interval: Duration = defaultInterval,
    batteryWattHours: @escaping @MainActor () -> Double? = { nil }
  ) {
    self.source = source
    self.interval = interval
    self.batteryWattHours = batteryWattHours
  }

  convenience init() {
    self.init(
      source: CoalitionEnergySource(), batteryWattHours: { BatteryCapacity.fullChargeWattHours() })
  }

  /// What the page draws: the reading, its grade and battery share when the figure is
  /// comparable, and the comparison in progress.
  var snapshot: [String: Any] {
    var result = reading.snapshot
    if reading.isComparable {
      result["level"] = EnergyLevel(milliwatts: reading.totalMilliwatts).rawValue
      if let batteryCapacity, batteryCapacity > 0 {
        result["batteryPercentPerHour"] = reading.totalMilliwatts / 1000 / batteryCapacity * 100
      }
    }
    if let comparison {
      var entry: [String: Any] = ["beforeMilliwatts": comparison.before.totalMilliwatts]
      if let after = comparison.after { entry["afterMilliwatts"] = after.totalMilliwatts }
      result["comparison"] = entry
    }
    return result
  }

  func setActive(_ active: Bool) {
    if !active {
      task?.cancel()
      task = nil
      samples.removeAll()
      comparison = nil
      return
    }
    guard task == nil else { return }
    samples.removeAll()
    comparison = nil
    guard let source else {
      publish(.unavailable)
      return
    }
    batteryCapacity = batteryWattHours()
    publish(.measuring)
    let interval = interval
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        let sample = await Task.detached(priority: .utility) { source.sample() }.value
        guard !Task.isCancelled, let self else { return }
        self.record(sample)
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// A setting that changes rendering work was applied. The window restarts so the next
  /// settled reading covers only the new setting. A second change before the first one
  /// settled keeps the original "before", so the comparison spans both.
  func settingChanged() {
    guard isActive else { return }
    if comparison?.after != nil || comparison == nil {
      comparison =
        samples.count == Self.windowSamples && reading.isComparable
        ? EnergyUsageComparison(before: reading) : nil
    }
    samples.removeAll()
    reading = .measuring
    onChange?()
  }

  /// Adds one sample and recomputes the reading; nil means the counters became unreadable.
  func record(_ sample: EnergyUsageSample?) {
    guard let sample else {
      samples.removeAll()
      comparison = nil
      publish(.unavailable)
      return
    }
    samples.append(Recorded(sample: sample, nativeVideo: nativeVideoPlaying()))
    if samples.count > Self.windowSamples { samples.removeFirst(samples.count - Self.windowSamples) }
    guard let first = samples.first, samples.count > 1 else {
      publish(.measuring)
      return
    }
    var value = EnergyUsageReading.between(first.sample, sample)
    value.nativeVideo = samples.contains(where: \.nativeVideo)
    if value.nativeVideo, comparison != nil {
      // The native video's own work is not counted, so the change can never be measured;
      // switching to the native player would otherwise read as a near-total saving.
      comparison = nil
      reading = value
      onChange?()
      return
    }
    if var pending = comparison, pending.after == nil, samples.count == Self.windowSamples,
      value.isComparable
    {
      pending.after = value
      comparison = pending
      reading = value
      onChange?()
      return
    }
    publish(value)
  }

  private func publish(_ value: EnergyUsageReading) {
    guard value != reading else { return }
    reading = value
    onChange?()
  }
}
