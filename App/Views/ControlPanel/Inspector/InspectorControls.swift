import SwiftUI

// Shared building blocks of the inspector's rows: a switch row, a slider that keeps the value under
// the pointer, and the box that holds a drag driver for the life of a view.

extension PanelController {
  /// Whether an inspector control waits. Property controls, the Displays inputs, Restore all, Apply
  /// and Revert wait while a command runs or the wallpaper is applied or reverted, except the
  /// control whose own edit is the command, which stays enabled so it keeps keyboard focus.
  func isInspectorControlDisabled(_ options: InspectorOptions, key: String) -> Bool {
    options.isLocked && !isBusy(key)
  }
}

/// Holds an object a view creates on first use (a drag driver, which needs the controller from the
/// environment) for as long as the view lives.
final class DriverBox<Driver> {
  var driver: Driver?
}

/// A card row with a title and a switch.
struct InspectorToggleRow: View {
  let title: LocalizedStringKey
  let isOn: Bool
  var isDisabled = false
  let onChange: (Bool) -> Void

  var body: some View {
    InspectorRow(title) {
      Toggle(title, isOn: Binding(get: { isOn }, set: { onChange($0) }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }
    .disabled(isDisabled)
  }
}

/// A slider that shows the value under the pointer while it is dragged, hands the owner the drag,
/// the release and each key or VoiceOver step, and goes back to the model's value once the owner's
/// save has finished (or failed). `header` draws the line above the slider with the value's text.
struct DraggableSlider<Header: View>: View {
  let value: Double
  let range: ClosedRange<Double>
  var step: Double?
  let format: (Double) -> String
  let accessibilityLabel: String
  var onDrag: (Double) -> Void = { _ in }
  var onRelease: (Double) -> Task<Void, Never>? = { _ in nil }
  var onStep: (Double) -> Task<Void, Never>? = { _ in nil }
  @ViewBuilder var header: (String) -> Header

  @State private var live: Double?
  @State private var token = 0

  var body: some View {
    let shown = live ?? value
    VStack(alignment: .leading, spacing: 4) {
      header(format(shown))
      PanelSlider(
        value: shown, range: range, step: step, accessibilityLabel: accessibilityLabel,
        accessibilityValue: format(shown),
        events: PanelSliderEvents(
          onDrag: { new in
            token += 1
            live = new
            onDrag(new)
          },
          onRelease: { new in
            token += 1
            live = new
            finish(onRelease(new))
          },
          onStep: { new in
            token += 1
            live = new
            finish(onStep(new))
          }))
    }
  }

  /// The slider returns to the model's value once the save has ended, unless another change began.
  private func finish(_ task: Task<Void, Never>?) {
    let mine = token
    Task { @MainActor in
      await task?.value
      if token == mine { live = nil }
    }
  }
}

/// A row for a slider: title and value on one line, the slider under them.
struct InspectorSliderRow: View {
  let title: LocalizedStringKey
  let value: Double
  let range: ClosedRange<Double>
  var step: Double?
  let accessibilityLabel: String
  let format: (Double) -> String
  var onDrag: (Double) -> Void = { _ in }
  var onRelease: (Double) -> Task<Void, Never>? = { _ in nil }
  var onStep: (Double) -> Task<Void, Never>? = { _ in nil }

  @Environment(\.panelTheme) private var theme

  var body: some View {
    DraggableSlider(
      value: value, range: range, step: step, format: format,
      accessibilityLabel: accessibilityLabel, onDrag: onDrag, onRelease: onRelease, onStep: onStep
    ) { output in
      HStack(spacing: 8) {
        Text(title)
          .font(.system(size: 13))
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(verbatim: output)
          .font(.system(size: 12).monospacedDigit())
          .foregroundStyle(theme.surface.muted.color)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}
