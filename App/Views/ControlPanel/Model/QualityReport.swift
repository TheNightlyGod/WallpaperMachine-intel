import Foundation

/// Why quality is lower than the user's own settings right now, as the Performance and Playback
/// sections name it.
///
/// Declared in the order the causes are named when several hold: the reasons the engine reports
/// (heat, Low Power Mode, a low battery) come first, and the battery mode, which the engine reports
/// as the power source and not as a reason, comes last. The raw values are the names the
/// diagnostics report prints.
enum QualityCause: String, CaseIterable, Sendable {
  case heat, lowPowerMode, lowBattery, battery

  /// The causes in force, most specific first. The engine's own order is not used: this one is, so
  /// heat is named before Low Power Mode and a throttle before the battery.
  static func inForce(
    throttle: [BridgeQualityThrottleCause], batteryMode: BridgeBatteryMode, onBatteryPower: Bool
  ) -> [QualityCause] {
    var causes = [QualityCause]()
    for cause in [QualityCause.heat, .lowPowerMode, .lowBattery]
    where throttle.contains(where: { QualityCause($0) == cause }) {
      causes.append(cause)
    }
    if batteryMode == .reducedQuality, onBatteryPower { causes.append(.battery) }
    return causes
  }

  init(_ condition: SystemCondition) {
    switch condition {
    case .heat: self = .heat
    case .lowPowerMode: self = .lowPowerMode
    case .lowBattery: self = .lowBattery
    }
  }

  init(_ throttle: BridgeQualityThrottleCause) {
    switch throttle {
    case .heat: self = .heat
    case .lowPowerMode: self = .lowPowerMode
    case .lowBattery: self = .lowBattery
    }
  }

  /// "On battery. Reduced quality is in use." and its siblings.
  @MainActor var statusText: String {
    switch self {
    case .heat: L("The Mac is hot. Reduced quality is in use.")
    case .lowPowerMode: L("Low Power Mode is on. Reduced quality is in use.")
    case .lowBattery: L("The battery is low. Reduced quality is in use.")
    case .battery: L("On battery. Reduced quality is in use.")
    }
  }

  /// The sentence for the render scale in force beside the saved one, naming this cause.
  @MainActor func effectiveText(effective: String, saved: String) -> String {
    switch self {
    case .heat: L("\(effective) while the Mac is hot. Your setting is \(saved).")
    case .lowPowerMode: L("\(effective) in Low Power Mode. Your setting is \(saved).")
    case .lowBattery: L("\(effective) while the battery is low. Your setting is \(saved).")
    case .battery: L("\(effective) on battery. Your setting is \(saved).")
    }
  }
}

/// The frame-rate ceiling the engine holds wallpapers to now, and the setting that sets it: the saved
/// Frame rate limit, or the Reduced quality choice of the cause named first. Settings › Displays,
/// the inspector and Performance › Effective now name it and open the page it is changed on, so a
/// limit is never put down to a setting that did not set it (a Frame rate limit reading No limit
/// cannot explain 30 fps that the low-battery rule asked for).
struct FrameRateCeiling: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    /// Performance › Frame rate limit.
    case frameRateLimit
    /// The reduced-quality profile, asked for by this cause's Reduced quality choice.
    case reducedQuality(QualityCause)
  }

  let fps: Int
  let source: Source

  /// `effectiveCap` is the engine's ceiling, which already folds the saved cap and the profile's
  /// rate together; nil is no ceiling. One below the saved cap, or with none saved, can only be the
  /// profile's, so it is the first cause's. Otherwise the saved cap holds it, even while a cause is
  /// in force, because the profile then lowers nothing.
  init?(savedCap: UInt32?, effectiveCap: UInt32?, causes: [QualityCause]) {
    guard let effectiveCap else { return nil }
    fps = Int(effectiveCap)
    if let cause = causes.first, savedCap.map({ effectiveCap < $0 }) ?? true {
      source = .reducedQuality(cause)
    } else {
      source = .frameRateLimit
    }
  }

  /// The ceiling in force in `settings`, put down to the causes the engine reports.
  init?(_ settings: BridgeSettingsSnapshot) {
    self.init(
      savedCap: settings.frameRateCap, effectiveCap: settings.effectiveFrameRateCap,
      causes: QualityCause.inForce(
        throttle: settings.qualityThrottle, batteryMode: settings.batteryMode,
        onBatteryPower: settings.onBatteryPower))
  }

  /// This ceiling where it holds a display below `saved`, the display's own frame rate; nil where
  /// it does not. The display's own refresh is not a setting, so it is not a limit here.
  func limiting(saved: Int) -> FrameRateCeiling? { fps < saved ? self : nil }

  /// The page the setting that sets it is changed on.
  var section: SettingsSection { source == .frameRateLimit ? .performance : .playback }

  /// "Limited to 30 fps while the battery is low" and its siblings.
  @MainActor var note: String {
    switch source {
    case .frameRateLimit: L("Limited to \(fps) fps by Performance settings")
    case .reducedQuality(.heat): L("Limited to \(fps) fps while the Mac is hot")
    case .reducedQuality(.lowPowerMode): L("Limited to \(fps) fps in Low Power Mode")
    case .reducedQuality(.lowBattery): L("Limited to \(fps) fps while the battery is low")
    case .reducedQuality(.battery): L("Limited to \(fps) fps on battery")
    }
  }
}

/// What the Performance and Playback sections say about quality being lowered: whether the shared
/// reduced-quality profile is worth showing, which cause is named, and the render scale and
/// frame-rate ceiling in force.
struct QualityReport: Equatable {
  /// The causes in force, most specific first. Empty while nothing lowers quality.
  var causes: [QualityCause]
  /// Whether any Reduced quality choice is made, so the render scale and frame rate it uses are
  /// worth editing. A low-battery choice counts only on a Mac with a battery, where its menu is
  /// offered at all.
  var reducedQualityChosen: Bool
  var renderScale: Float
  var preferredRenderScale: Float
  /// Whether any running wallpaper can honour a render scale.
  var renderScaleSupported: Bool
  /// The frame-rate ceiling in force and what sets it; nil while there is none.
  var frameRate: FrameRateCeiling?
  /// Whether the Mac runs on battery, which is when the On battery choice applies at all.
  var onBatteryPower: Bool

  /// The first cause, the one the sentences name.
  var cause: QualityCause? { causes.first }

  /// What Quick Settings' Quality card says while something lowers quality below the preset it
  /// shows: the cause. Nil while the usual settings are in use.
  @MainActor var inForceText: String? { cause?.statusText }

  /// What Quick Settings' On battery card says while the Mac runs on battery and quality is lower
  /// than the user's settings, so Keep running that a low-battery, Low Power Mode or heat rule
  /// overrides never reads as the choice in force. Nil plugged in, where the choice does nothing.
  @MainActor var onBatteryText: String? { onBatteryPower ? inForceText : nil }

  /// Effective now's frame-rate line: the ceiling a Reduced quality choice sets, which the Frame
  /// rate limit slider cannot show (it shows the saved limit, perhaps No limit). Nil while the
  /// saved limit is what holds frames, or nothing does.
  @MainActor var effectiveFrameRateText: String? {
    guard let frameRate, frameRate.source != .frameRateLimit else { return nil }
    return frameRate.note
  }

  /// Everything Effective now says, the frame-rate line first; nil while it has nothing to add.
  @MainActor var effectiveNowText: String? {
    let lines = [effectiveFrameRateText, effectiveText].compactMap { $0 }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  /// "Effective now" is worth a row only while a scale the engine uses differs from the saved one
  /// (the published values are compared, not the menu's steps, so it disappears the moment quality
  /// is restored).
  var showsEffectiveScale: Bool { renderScaleSupported && renderScale != preferredRenderScale }

  /// The reading under the reduced-quality profile, or the generic one when nothing holds.
  @MainActor var statusText: String {
    cause?.statusText ?? L("Your usual quality settings are in use.")
  }

  /// The Effective now line, nil while it has nothing to add.
  @MainActor var effectiveText: String? {
    guard showsEffectiveScale else { return nil }
    let effective = RenderScaleChoices.percent(renderScale)
    let saved = RenderScaleChoices.percent(preferredRenderScale)
    guard let cause else {
      return L("\(effective). Your setting of \(saved) is not in effect right now.")
    }
    return cause.effectiveText(effective: effective, saved: saved)
  }

  /// `batteryPercent` is nil on a Mac without an internal battery.
  static func make(
    settings: BridgeSettingsSnapshot, lowPowerModeAction: SystemConditionAction,
    thermalAction: SystemConditionAction, lowBatteryAction: SystemConditionAction,
    batteryPercent: Int?
  ) -> QualityReport {
    QualityReport(
      causes: QualityCause.inForce(
        throttle: settings.qualityThrottle, batteryMode: settings.batteryMode,
        onBatteryPower: settings.onBatteryPower),
      reducedQualityChosen: settings.batteryMode == .reducedQuality
        || lowPowerModeAction.reducesQuality || thermalAction.reducesQuality
        || (batteryPercent != nil && lowBatteryAction.reducesQuality),
      renderScale: settings.renderScale, preferredRenderScale: settings.preferredRenderScale,
      renderScaleSupported: settings.renderScaleSupported, frameRate: FrameRateCeiling(settings),
      onBatteryPower: settings.onBatteryPower)
  }
}

/// What Quick Settings and Playback & Power say about a low-battery, Low Power Mode or heat rule that
/// is engaged, as `SystemConditionMonitor` reports it.
extension EngagedSystemCondition {
  /// "The battery is low. Wallpapers are paused." and its siblings. A reduced-quality effect reads
  /// as its quality cause does.
  @MainActor var statusText: String {
    switch (condition, effect) {
    case (_, .reducedQuality): QualityCause(condition).statusText
    case (.heat, .pause): L("The Mac is hot. Wallpapers are paused.")
    case (.heat, .stop): L("The Mac is hot. Wallpapers are stopped.")
    case (.lowPowerMode, .pause): L("Low Power Mode is on. Wallpapers are paused.")
    case (.lowPowerMode, .stop): L("Low Power Mode is on. Wallpapers are stopped.")
    case (.lowBattery, .pause): L("The battery is low. Wallpapers are paused.")
    case (.lowBattery, .stop): L("The battery is low. Wallpapers are stopped.")
    }
  }
}

extension EngagedSystemCondition.Effect {
  /// The line a condition's own row adds while its rule is engaged.
  @MainActor var inEffectText: String {
    switch self {
    case .reducedQuality: L("In effect now. Reduced quality is in use.")
    case .pause: L("In effect now. Wallpapers are paused.")
    case .stop: L("In effect now. Wallpapers are stopped.")
    }
  }
}

/// What macOS reports about the Mac's heat, in the words the Playback section uses for it.
enum ThermalLevel: String, CaseIterable, Sendable {
  case nominal, fair, serious, critical

  init(_ state: ProcessInfo.ThermalState) {
    switch state {
    case .nominal: self = .nominal
    case .fair: self = .fair
    case .serious: self = .serious
    case .critical: self = .critical
    @unknown default: self = .nominal
    }
  }

  @MainActor var word: String {
    switch self {
    case .nominal: L("normal")
    case .fair: L("warm")
    case .serious: L("hot")
    case .critical: L("very hot")
    }
  }

  /// The note under "When the Mac is hot": what the choice does and how hot the Mac is now. The
  /// Reduced quality variant says that it pauses wallpapers at very hot, which the others do not.
  @MainActor func note(for action: SystemConditionAction) -> String {
    let state = word
    return action.reducesQuality
      ? L(
        "Reduced quality applies while the Mac is hot, and wallpapers pause if it becomes very hot. Right now it is \(state)."
      )
      : L(
        "Applies while macOS reports the Mac as hot or very hot, which is when it starts slowing itself down. Right now it is \(state)."
      )
  }
}

/// The Focus filter in effect, which Playback reports beside the "Open Focus Settings…" button.
enum FocusFilterEffect: String, Sendable {
  case keepRunning, mute, pause, stop, wallpaper, playlist

  /// What a filter does, as the note names it. Nil for one this build does not know, which the note
  /// prints raw.
  @MainActor var title: String {
    switch self {
    case .keepRunning: L("Keep running")
    case .mute: L("Mute")
    case .pause: L("Pause")
    case .stop: L("Stop (free memory)")
    case .wallpaper: L("Use wallpaper")
    case .playlist: L("Use saved playlist")
    }
  }

  /// "A Focus filter is in effect now: Mute." while one does something; nil when none does, and the
  /// row says where to add one instead.
  @MainActor static func note(forRawValue raw: String) -> String? {
    guard raw != FocusFilterEffect.keepRunning.rawValue else { return nil }
    let action = FocusFilterEffect(rawValue: raw)?.title ?? raw
    return L("A Focus filter is in effect now: \(action).")
  }
}
