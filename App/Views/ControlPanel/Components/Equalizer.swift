import SwiftUI

/// Three bars that rise and fall while a wallpaper plays and rest while it does not.
///
/// It draws its frames itself instead of repeating an animation, so it can stop completely: the
/// bars move only while `isPlaying`, the panel is on screen and Reduce Motion is off.
struct Equalizer: View {
  var isPlaying: Bool
  var barWidth: CGFloat = 2
  var height: CGFloat = 10

  @Environment(\.panelIsVisible) private var panelIsVisible
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Seconds per cycle of each bar, and where in its cycle it starts, so the bars never move
  /// together.
  private static let cycles: [(period: Double, phase: Double)] = [
    (1.1, 0), (0.9, 2.1), (1.25, 4.0),
  ]
  static let restingScale = 0.45

  private var animates: Bool { isPlaying && panelIsVisible && !reduceMotion }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animates)) { context in
      HStack(alignment: .bottom, spacing: barWidth * 0.75) {
        ForEach(Self.cycles.indices, id: \.self) { index in
          Capsule()
            .frame(width: barWidth, height: height * scale(of: index, at: context.date))
        }
      }
      .frame(height: height, alignment: .bottom)
    }
    .accessibilityHidden(true)
  }

  private func scale(of index: Int, at date: Date) -> Double {
    guard animates else { return Self.restingScale }
    return Self.scale(period: Self.cycles[index].period, phase: Self.cycles[index].phase, at: date)
  }

  /// Between 0.35 and 1 of the full height.
  static func scale(period: Double, phase: Double, at date: Date) -> Double {
    let angle = date.timeIntervalSinceReferenceDate * 2 * .pi / period + phase
    return 0.35 + 0.65 * (0.5 + 0.5 * sin(angle))
  }
}
