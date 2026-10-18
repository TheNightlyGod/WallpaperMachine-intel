import Foundation

/// Values the guide holds until **Continue** commits them, one per key, in the order they were first
/// chosen: a `Map` of the web guide. Choosing a key again replaces its value without moving it, so
/// the commit sends them in the order the person decided them.
struct DraftList<Key: Hashable, Value: Equatable>: Equatable {
  struct Entry: Equatable {
    let key: Key
    var value: Value
  }

  private(set) var entries: [Entry] = []

  var isEmpty: Bool { entries.isEmpty }

  func value(for key: Key) -> Value? { entries.first { $0.key == key }?.value }

  mutating func set(_ value: Value, for key: Key) {
    if let index = entries.firstIndex(where: { $0.key == key }) {
      entries[index].value = value
    } else {
      entries.append(Entry(key: key, value: value))
    }
  }

  mutating func removeAll() { entries.removeAll() }
}

// MARK: - Performance

/// What the Performance page has changed and not yet saved: the frame-rate limit and the render
/// scale, which a preset sets together and the slider sets alone.
struct WelcomePerformanceDraft: Equatable {
  enum Key: Hashable { case frameRateCap, renderScale }

  enum Entry: Equatable {
    /// `nil` is no limit.
    case frameRateCap(UInt32?)
    case renderScale(Float)

    var key: Key {
      switch self {
      case .frameRateCap: .frameRateCap
      case .renderScale: .renderScale
      }
    }
  }

  /// A render scale within a thousandth of another is the same scale.
  static let scaleTolerance: Float = 0.001

  private var cap = DraftList<Key, Entry>()

  var isEmpty: Bool { cap.isEmpty }

  /// A preset sets both the limit and the scale, the limit first, as the page always sent them.
  mutating func choose(_ preset: QualityPreset) {
    cap.set(.frameRateCap(preset.frameRateCap), for: .frameRateCap)
    cap.set(.renderScale(preset.renderScale), for: .renderScale)
  }

  /// The slider changes only the limit: the render scale stays what it was.
  mutating func setFrameRateCap(_ value: UInt32?) {
    cap.set(.frameRateCap(value), for: .frameRateCap)
  }

  mutating func clear() { cap.removeAll() }

  /// The limit the page shows: the draft, else what is saved.
  func frameRateCap(saved: UInt32?) -> UInt32? {
    if case .frameRateCap(let value)? = cap.value(for: .frameRateCap) { return value }
    return saved
  }

  func renderScale(saved: Float) -> Float {
    if case .renderScale(let value)? = cap.value(for: .renderScale) { return value }
    return saved
  }

  /// The preset the page shows as chosen, nil when the values match none (the Custom note).
  func activePreset(savedCap: UInt32?, savedScale: Float) -> QualityPreset? {
    QualityPreset.active(
      frameRateCap: frameRateCap(saved: savedCap),
      preferredRenderScale: renderScale(saved: savedScale))
  }

  /// The drafts that differ from what is saved, in the order they were first chosen. A draft equal
  /// to the saved value is not a change.
  func changes(savedCap: UInt32?, savedScale: Float) -> [Entry] {
    cap.entries.map(\.value).filter { entry in
      switch entry {
      case .frameRateCap(let value): value != savedCap
      case .renderScale(let value): abs(value - savedScale) > Self.scaleTolerance
      }
    }
  }
}

// MARK: - Preferences

/// What the Preferences page holds: the settings **Continue** commits.
struct WelcomePreferenceValues: Equatable {
  var launchAtLogin: Bool
  var keepsWindowsOnWallpaperClick: Bool
  var batteryMode: BridgeBatteryMode
  /// **Send performance data**, off until chosen (docs/features/telemetry.md).
  var sendsPerformanceData = false
}

/// What the Preferences page has changed and not yet saved. The lock screen is not here: it applies
/// at once.
struct WelcomePreferenceDraft: Equatable {
  enum Key: Hashable { case launchAtLogin, keepsWindows, batteryMode, performanceData }

  enum Entry: Equatable {
    case launchAtLogin(Bool)
    case keepsWindows(Bool)
    case batteryMode(BridgeBatteryMode)
    case performanceData(Bool)

    var key: Key {
      switch self {
      case .launchAtLogin: .launchAtLogin
      case .keepsWindows: .keepsWindows
      case .batteryMode: .batteryMode
      case .performanceData: .performanceData
      }
    }
  }

  private var list = DraftList<Key, Entry>()

  var isEmpty: Bool { list.isEmpty }

  mutating func set(_ entry: Entry) { list.set(entry, for: entry.key) }
  mutating func clear() { list.removeAll() }

  /// The values the page shows: each draft over what is saved.
  func values(saved: WelcomePreferenceValues) -> WelcomePreferenceValues {
    var shown = saved
    for entry in list.entries.map(\.value) {
      switch entry {
      case .launchAtLogin(let value): shown.launchAtLogin = value
      case .keepsWindows(let value): shown.keepsWindowsOnWallpaperClick = value
      case .batteryMode(let value): shown.batteryMode = value
      case .performanceData(let value): shown.sendsPerformanceData = value
      }
    }
    return shown
  }

  /// The drafts that differ from what is saved, in the order they were first chosen.
  func changes(saved: WelcomePreferenceValues) -> [Entry] {
    list.entries.map(\.value).filter { entry in
      switch entry {
      case .launchAtLogin(let value): value != saved.launchAtLogin
      case .keepsWindows(let value): value != saved.keepsWindowsOnWallpaperClick
      case .batteryMode(let value): value != saved.batteryMode
      case .performanceData(let value): value != saved.sendsPerformanceData
      }
    }
  }
}
