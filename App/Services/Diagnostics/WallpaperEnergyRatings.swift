import Foundation

/// The settings a wallpaper's energy was measured under. A rating is only comparable
/// with measurements taken under the same ones.
struct WallpaperEnergyConditions: Codable, Equatable, Sendable {
  /// Displays showing the wallpaper.
  var displays: Int
  /// Global frame-rate ceiling in force, the battery one included; nil is no limit.
  var frameRateCap: UInt32?
  /// Render scale in force, rounded to hundredths.
  var renderScale: Double
}

/// One wallpaper, alone on every display that is presenting, under known conditions.
struct WallpaperEnergyContext: Equatable, Sendable {
  var wallpaperID: String
  var conditions: WallpaperEnergyConditions

  /// Energy is charged to the whole app, so it can be attributed only while exactly one
  /// wallpaper is presenting. Displays suspended on their own (covered by windows) do
  /// not count; a display with no wallpaper does not either.
  ///
  /// A display playing a video through macOS's native player rules the interval out:
  /// the media engine decodes it and WindowServer draws it, and macOS charges neither
  /// to this app, so it would be rated as almost free.
  static func resolve(
    assignments: [(display: String, wallpaper: String)], suspendedDisplays: Set<UInt32>,
    nativeVideoDisplays: Set<UInt32> = [], frameRateCap: UInt32?, renderScale: Float,
    resolveDisplay: (String) -> UInt32? = { UInt32($0) }
  ) -> WallpaperEnergyContext? {
    var presenting: [(display: UInt32, wallpaper: String)] = []
    for assignment in assignments where !assignment.wallpaper.isEmpty {
      // Unknown topology means unknown attribution: dropping the row would charge
      // another wallpaper's work to the one display we happened to resolve.
      guard let display = resolveDisplay(assignment.display) else { return nil }
      if !suspendedDisplays.contains(display) {
        if nativeVideoDisplays.contains(display) { return nil }
        presenting.append((display, assignment.wallpaper))
      }
    }
    let ids = Set(presenting.map(\.wallpaper))
    guard ids.count == 1, let id = ids.first else { return nil }
    return WallpaperEnergyContext(
      wallpaperID: id,
      conditions: WallpaperEnergyConditions(
        displays: presenting.count, frameRateCap: frameRateCap,
        renderScale: (Double(renderScale) * 100).rounded() / 100))
  }
}

/// Mean power the app drew while one wallpaper played under `conditions`.
struct WallpaperEnergyRating: Codable, Equatable, Sendable {
  /// Ratings from another version are replaced, not averaged into. Version 1 (saved
  /// without one) also credited video played by macOS's native player, which reads as
  /// almost nothing, so a video wallpaper's version 1 rating is not shown.
  static let currentVersion = 2

  var milliwatts: Double
  /// Measured time behind the mean.
  var seconds: Double
  var conditions: WallpaperEnergyConditions
  var updated: Date
  var version: Int? = Self.currentVersion

  var level: EnergyLevel { EnergyLevel(milliwatts: milliwatts) }
}

/// Energy ratings per wallpaper id, kept in one small JSON file.
///
/// A measurement under different conditions replaces the rating instead of being
/// averaged in, so a rating always describes the settings it names. Writes are
/// batched: the file is saved when a rating first becomes shown or changes level,
/// at most every `saveInterval` otherwise, and on `flush()`.
@MainActor
final class WallpaperEnergyRatings {
  /// Measured time before a rating is shown. Two minutes is four or more intervals,
  /// enough to ride out a scene's loading work and the kernel's batched GPU energy.
  static let minimumSeconds = 120.0
  /// Past this much measured time a new interval keeps the same weight, so a rating
  /// follows a wallpaper whose cost changed (an update, a renderer change).
  static let weightCapSeconds = 1_800.0
  static let saveInterval: TimeInterval = 600

  private(set) var entries: [String: WallpaperEnergyRating]
  private(set) var revision: UInt64 = 0
  private let file: URL
  private var lastSave: Date?
  private var dirty = false
  private let batteryWattHours: @MainActor () -> Double?
  /// Read when the first rating is shown, then kept: the panel asks for every wallpaper
  /// in each snapshot, and a battery's full charge moves over months, not minutes.
  private lazy var batteryCapacity: Double? = batteryWattHours()

  init(file: URL, batteryWattHours: @escaping @MainActor () -> Double? = { nil }) {
    self.file = file
    self.batteryWattHours = batteryWattHours
    do {
      entries =
        FileManager.default.fileExists(atPath: file.path)
        ? try JSONDecoder().decode([String: WallpaperEnergyRating].self, from: Data(contentsOf: file))
        : [:]
    } catch {
      // A rating is a measurement that is taken again, not user data worth failing over.
      AppLog.error("Energy ratings could not be read and start empty: \(error.localizedDescription)")
      entries = [:]
    }
  }

  /// Nil until the wallpaper has been measured for `minimumSeconds`.
  func rating(for id: String) -> WallpaperEnergyRating? {
    guard let entry = entries[id], entry.seconds >= Self.minimumSeconds else { return nil }
    return entry
  }

  func record(
    _ context: WallpaperEnergyContext, milliwatts: Double, seconds: Double, now: Date = Date()
  ) {
    guard seconds > 0, milliwatts.isFinite, milliwatts >= 0 else { return }
    let id = context.wallpaperID
    let shownLevel = rating(for: id)?.level
    var entry = WallpaperEnergyRating(
      milliwatts: milliwatts, seconds: seconds, conditions: context.conditions, updated: now)
    if let existing = entries[id], existing.conditions == context.conditions,
      existing.version == entry.version
    {
      let weight = min(existing.seconds, Self.weightCapSeconds)
      entry.milliwatts = (existing.milliwatts * weight + milliwatts * seconds) / (weight + seconds)
      entry.seconds = existing.seconds + seconds
    }
    entries[id] = entry
    revision &+= 1
    dirty = true
    let due = lastSave.map { now.timeIntervalSince($0) >= Self.saveInterval } ?? true
    if due || rating(for: id)?.level != shownLevel { save(now: now) }
  }

  func flush() {
    if dirty { save(now: Date()) }
  }

  /// What the panel shows for one wallpaper, or nil when it has no rating yet. On a Mac
  /// with a battery it adds the share of a full charge the rated power uses per hour.
  func snapshot(for id: String, kind: BridgeWallpaperKind) -> [String: Any]? {
    guard let rating = rating(for: id),
      kind != .video || rating.version == WallpaperEnergyRating.currentVersion
    else { return nil }
    var result: [String: Any] = [
      "level": rating.level.rawValue,
      "milliwatts": rating.milliwatts,
      "displays": rating.conditions.displays,
      "frameRateCap": rating.conditions.frameRateCap.map { Int($0) } as Any? ?? NSNull(),
      "renderScale": rating.conditions.renderScale,
    ]
    if let batteryCapacity, batteryCapacity > 0 {
      result["batteryPercentPerHour"] = rating.milliwatts / 1000 / batteryCapacity * 100
    }
    return result
  }

  private func save(now: Date) {
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(entries).write(to: file, options: .atomic)
      dirty = false
      lastSave = now
    } catch {
      AppLog.error("Energy ratings could not be saved: \(error.localizedDescription)")
    }
  }
}

/// Measures the app's energy in the background and credits it to the wallpaper playing.
///
/// Every `interval` it asks `context` what is on screen. Nil (paused, suspended, more
/// than one wallpaper, a native video, the panel open, a download running) takes no
/// sample and breaks the chain. Otherwise it samples the coalition counters off the main thread, and an
/// interval whose two ends saw the same context and whose GPU was not contended is
/// recorded. Anything that changes presentation in between should call `invalidate()`,
/// since a pause and resume inside one interval leaves both ends looking the same.
@MainActor
final class WallpaperEnergyRecorder {
  /// One sample costs about 3 ms of kernel calls; every 30 s that is 0.01 % of a core.
  nonisolated static let defaultInterval: Duration = .seconds(30)
  /// How long after a presentation change no interval starts. On an M5 Pro a scene's
  /// first load drew 6–7 W for 2–4 s while its shaders compiled (10–22 J); a load with
  /// every cache warm cost about 1.5 J.
  nonisolated static let loadingNanoseconds: UInt64 = 8_000_000_000

  private let source: EnergyUsageSource?
  private let ratings: WallpaperEnergyRatings
  private let interval: Duration
  private let context: @MainActor () -> WallpaperEnergyContext?
  private var previous: (sample: EnergyUsageSample, context: WallpaperEnergyContext)?
  /// Uptime of the last presentation change, on the samples' clock.
  private var changedAt: UInt64?
  private var task: Task<Void, Never>?

  var isRunning: Bool { task != nil }

  init(
    source: EnergyUsageSource?, ratings: WallpaperEnergyRatings,
    interval: Duration = defaultInterval,
    context: @escaping @MainActor () -> WallpaperEnergyContext?
  ) {
    self.source = source
    self.ratings = ratings
    self.interval = interval
    self.context = context
  }

  func start() {
    guard task == nil, let source else { return }
    let interval = interval
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, let self else { return }
        guard let context = self.context() else {
          self.previous = nil
          continue
        }
        let sample = await Task.detached(priority: .utility) { source.sample() }.value
        guard !Task.isCancelled else { return }
        self.record(sample, context: context)
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
    previous = nil
    ratings.flush()
  }

  /// Presentation changed; the interval in progress must not be credited to anyone, and
  /// the next one starts only once a wallpaper that may be loading has had time to.
  func invalidate(at uptime: UInt64 = DispatchTime.now().uptimeNanoseconds) {
    previous = nil
    changedAt = uptime
  }

  /// Credits the interval since the previous sample when both ends agree. Nil means the
  /// counters could not be read.
  func record(_ sample: EnergyUsageSample?, context: WallpaperEnergyContext) {
    guard let sample else {
      previous = nil
      return
    }
    // Compiling shaders and decoding textures is what loading costs, not playing.
    if let changedAt, sample.uptimeNanoseconds < changedAt + Self.loadingNanoseconds {
      previous = nil
      return
    }
    defer { previous = (sample, context) }
    guard let previous, previous.context == context else { return }
    let reading = EnergyUsageReading.between(previous.sample, sample)
    guard reading.isComparable else { return }
    ratings.record(context, milliwatts: reading.totalMilliwatts, seconds: reading.seconds)
  }
}
