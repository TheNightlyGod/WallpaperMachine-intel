import Foundation

/// The six pages of the first-run guide, in order.
enum WelcomeStep: Int, CaseIterable, Identifiable, Sendable {
  case language, steam, performance, preferences, tips, start

  var id: Int { rawValue }

  var next: WelcomeStep? { WelcomeStep(rawValue: rawValue + 1) }
  var previous: WelcomeStep? { WelcomeStep(rawValue: rawValue - 1) }
  var isFirst: Bool { self == .language }
  var isLast: Bool { self == .start }

  /// The step's name in the panel's language: the tooltip, the accessibility label and the line
  /// under the progress dots.
  @MainActor
  var name: String {
    switch self {
    case .language: L("Language & appearance")
    case .steam: L("Steam")
    case .performance: L("Performance")
    case .preferences: L("Preferences")
    case .tips: L("Tips")
    case .start: L("Start")
    }
  }
}

/// The sizes the guide lays itself out in. The card never asks for more room than the window
/// gives it, so the 760 x 560 floor works with a pinned footer and a scrolling body.
enum WelcomeLayout {
  /// Space kept free around the card.
  static let margin: CGFloat = 24
  static let maximumWidth: CGFloat = 640
  static let maximumHeight: CGFloat = 700
  /// The widest a page's content grows; the card pads it.
  static let contentWidth: CGFloat = 576
  /// Below this card height the pages use their tighter spacing and a smaller hero.
  static let compactHeight: CGFloat = 580

  static func cardSize(in available: CGSize) -> CGSize {
    CGSize(
      width: min(maximumWidth, max(0, available.width - 2 * margin)),
      height: min(maximumHeight, max(0, available.height - 2 * margin)))
  }

  static func isCompact(cardHeight: CGFloat) -> Bool { cardHeight < compactHeight }
}
