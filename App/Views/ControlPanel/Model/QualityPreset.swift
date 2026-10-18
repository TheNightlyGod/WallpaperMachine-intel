import Foundation

/// The Quality row's presets: a frame-rate limit and a render scale chosen together.
///
/// The Settings row, the quick Quality module and the welcome guide's Performance page all offer
/// these three, and `PanelController.applyQualityPreset(_:)` applies them, so the values live here once.
enum QualityPreset: String, CaseIterable, Sendable {
  case low, medium, high

  /// The internal render scale the preset sets.
  var renderScale: Float {
    switch self {
    case .low: 0.5
    case .medium: 0.75
    case .high: 1
    }
  }

  /// The frame-rate limit the preset sets; nil is no limit, which is the default High returns to.
  var frameRateCap: UInt32? {
    switch self {
    case .low: 30
    case .medium: 60
    case .high: nil
    }
  }

  /// The preset the *saved* values match, or nil when they match none and the row reads Custom.
  /// Only what is saved counts (a value on its way to the engine does not), and a render scale
  /// within a thousandth of a preset's is that preset's.
  static func active(frameRateCap: UInt32?, preferredRenderScale: Float) -> QualityPreset? {
    allCases.first {
      $0.frameRateCap == frameRateCap
        && abs(Double($0.renderScale) - Double(preferredRenderScale)) < 0.001
    }
  }

  @MainActor var title: String {
    switch self {
    case .low: L("Low")
    case .medium: L("Medium")
    case .high: L("High")
    }
  }

  /// What the row says when no preset matches. Never offered as a choice.
  @MainActor static var customTitle: String { L("Custom") }
}

/// The Frame rate limit slider: every rate from 10 up to the highest display refresh is a cap,
/// and one position past it means no limit, which leaves each display at its own frame rate.
struct FrameRateCapSlider: Equatable, Sendable {
  /// The slowest cap the slider offers. The engine accepts lower ones; only a stale control sends one.
  static let minimum = 10
  /// Assumed when no display reports a usable refresh rate.
  static let fallbackRefreshRate = 60

  /// The highest refresh rate among the displays, a cap that can still lower something.
  let refreshRate: Int

  /// `refreshRate` is the highest display refresh the settings report; a missing or implausible
  /// figure (under 10) reads as 60.
  init(refreshRate: Int?) {
    guard let refreshRate, refreshRate >= Self.minimum else {
      self.refreshRate = Self.fallbackRefreshRate
      return
    }
    self.refreshRate = refreshRate
  }

  init(displays: [BridgeDisplaySettingsRow]) {
    self.init(refreshRate: displays.map(\.maxFps).max().map(Int.init))
  }

  /// The top position, which stands for no limit.
  var maximum: Int { refreshRate + 1 }

  var range: ClosedRange<Int> { Self.minimum...maximum }

  /// Where the slider sits for the saved cap. A cap above the refresh shows as the refresh and one
  /// under 10 as 10, so the control never reads a value it cannot offer.
  func position(forCap cap: UInt32?) -> Int {
    guard let cap else { return maximum }
    return min(refreshRate, max(Self.minimum, Int(cap)))
  }

  /// The cap a position means: the top is no limit, anything else is that rate.
  func cap(atPosition position: Int) -> UInt32? {
    position >= maximum ? nil : UInt32(max(0, position))
  }

  /// What the readout beside the slider says for a position.
  @MainActor func readout(atPosition position: Int) -> String {
    guard let cap = cap(atPosition: position) else { return L("No limit") }
    return L("\(Int(cap)) fps")
  }
}

/// One entry of the Internal render scale menu.
struct RenderScaleChoice: Equatable, Identifiable, Sendable {
  var scale: Float
  var title: String
  var id: Float { scale }
}

enum RenderScaleChoices {
  /// The scales the menu offers, best first.
  static let standard: [Float] = [1, 0.75, 0.5]

  /// The menu for the saved scale. A scale in between, which only a hand-edited configuration can
  /// hold, is carried as an entry of its own at the top, so the menu shows what is saved instead of
  /// snapping to a neighbouring step the user never chose.
  @MainActor static func options(saved: Float) -> [RenderScaleChoice] {
    let steps = standard.map { RenderScaleChoice(scale: $0, title: title(for: $0)) }
    guard saved.isFinite, !standard.contains(saved) else { return steps }
    // The percent sign belongs to the figure here, so the sentence takes the formatted text.
    return [
      RenderScaleChoice(scale: saved, title: L("\(percent(saved)) (from configuration)"))
    ] + steps
  }

  /// A scale as the panel prints it: a whole percent, or "Unavailable" when there is none.
  @MainActor static func percent(_ scale: Float) -> String {
    guard scale.isFinite else { return L("Unavailable") }
    return "\(Int((scale * 100).rounded()))%"
  }

  @MainActor private static func title(for scale: Float) -> String {
    scale == 1 ? L("100% (native)") : percent(scale)
  }
}
