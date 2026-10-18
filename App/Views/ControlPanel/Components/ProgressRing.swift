import SwiftUI

/// A thin ring that shows how far something is, or that it is working when that is not known.
///
/// Only the indeterminate ring moves, and only while it is `isActive`, the panel is on screen and
/// Reduce Motion is off; otherwise it is a still arc. It is decoration: the control that holds it
/// states the progress in its own accessibility label.
struct ProgressRing: View {
  /// 0 to 1, or nil while the amount is not known.
  let value: Double?
  var lineWidth: CGFloat = 2
  var isActive = true

  @Environment(\.panelIsVisible) private var panelIsVisible
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var spins: Bool { value == nil && isActive && panelIsVisible && !reduceMotion }

  var body: some View {
    ZStack {
      Circle().stroke(.primary.opacity(0.14), lineWidth: lineWidth)
      if let value {
        Circle()
          .trim(from: 0, to: min(max(value, 0), 1))
          .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
      } else {
        // The timeline stops asking for frames while paused, so a ring that is not spinning costs
        // nothing.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spins)) { context in
          Circle()
            .trim(from: 0, to: 0.26)
            .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spins ? Self.angle(at: context.date) : -90))
        }
      }
    }
    .padding(lineWidth / 2)
    .accessibilityHidden(true)
  }

  /// One turn a second.
  static func angle(at date: Date) -> Double {
    (date.timeIntervalSinceReferenceDate * 360).truncatingRemainder(dividingBy: 360) - 90
  }
}
