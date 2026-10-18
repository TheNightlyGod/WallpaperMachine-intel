import AppKit
import SwiftUI

/// What a slider tells its owner. A pointer drag and a key press are different things to the
/// inspector, which previews a drag and saves a key press at once, so they come as separate events:
///
/// - `onDrag`: the pointer moved the thumb; the value is a candidate, not yet a choice.
/// - `onRelease`: the pointer came up after the thumb moved, with the value it settled on. It is
///   always sent for a drag that moved, even when the value is where the drag began.
/// - `onStep`: a key press or an accessibility action (VoiceOver) changed the value; save it now.
struct PanelSliderEvents {
  var onDrag: (Double) -> Void = { _ in }
  var onRelease: (Double) -> Void = { _ in }
  var onStep: (Double) -> Void = { _ in }
}

/// The system slider with its pointer, keyboard and accessibility paths told apart.
///
/// SwiftUI's `Slider` does not say whether a change came from the pointer or from a key, and the
/// page's rule (only a pointer drag previews; a key press or VoiceOver action saves at once) needs
/// it. `NSSlider` runs its pointer tracking inside `mouseDown`, which is what this subclass wraps,
/// so every action sent while it runs is a drag and every one outside it is a step. Arrow keys,
/// Page Up/Down, Home and End and the accessibility increment and decrement move by the slider's own
/// step (a hundredth of its range when it has none).
final class PanelNSSlider: NSSlider {
  var events = PanelSliderEvents()
  /// The author's step; nil is any value.
  var step: Double?

  /// Whether the pointer is tracking the thumb now.
  private(set) var isTrackingPointer = false
  private var measuredHeight: (size: NSControl.ControlSize, height: CGFloat)?

  /// The slider's own height, measured once for its control size. `intrinsicContentSize` has the
  /// cell measure itself on every call, and SwiftUI asks at every layout pass of the inspector, so
  /// asking it each time was a large share of the panel's main-thread time.
  var naturalHeight: CGFloat {
    if let measuredHeight, measuredHeight.size == controlSize { return measuredHeight.height }
    let height = intrinsicContentSize.height
    measuredHeight = (controlSize, height)
    return height
  }
  private var valueAtBegin = 0.0
  private var lastDragged: Double?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    target = self
    action = #selector(valueDidChange(_:))
    isContinuous = true
    numberOfTickMarks = 0
    allowsTickMarkValuesOnly = false
  }

  /// The value held to the range and moved onto the step.
  func snapped(_ value: Double) -> Double {
    var result = value
    if let step, step > 0 {
      result = minValue + ((value - minValue) / step).rounded() * step
      // Remove the floating-point dust the multiplication leaves (0.30000000000000004).
      result = (result * 1e9).rounded() / 1e9
    }
    return min(maxValue, max(minValue, result))
  }

  /// How far one key press moves the value.
  var increment: Double {
    if let step, step > 0 { return step }
    return (maxValue - minValue) / 100
  }

  // MARK: Pointer

  override func mouseDown(with event: NSEvent) {
    beginPointer()
    super.mouseDown(with: event)
    endPointer()
  }

  /// Pointer tracking starts. Public so a test can run the sequence `mouseDown` wraps.
  func beginPointer() {
    isTrackingPointer = true
    valueAtBegin = doubleValue
    lastDragged = nil
  }

  /// Pointer tracking ends: a drag that moved is released with its last value.
  func endPointer() {
    isTrackingPointer = false
    if let value = lastDragged {
      lastDragged = nil
      events.onRelease(value)
    }
  }

  @objc func valueDidChange(_ sender: Any?) {
    let value = snapped(doubleValue)
    if value != doubleValue { doubleValue = value }
    if isTrackingPointer {
      // A click on the thumb that does not move it is not a drag.
      if lastDragged == nil, value == valueAtBegin { return }
      // A step the pump has been told of already is not told again.
      if lastDragged == value { return }
      lastDragged = value
      events.onDrag(value)
    } else {
      events.onStep(value)
    }
  }

  // MARK: Keyboard and accessibility

  /// Moves by `steps` increments and tells the owner, if the value changed.
  @discardableResult
  func nudge(by steps: Double) -> Bool {
    guard isEnabled else { return false }
    let value = snapped(doubleValue + steps * increment)
    guard value != doubleValue else { return false }
    doubleValue = value
    events.onStep(value)
    return true
  }

  func jump(to value: Double) {
    guard isEnabled else { return }
    let value = snapped(value)
    guard value != doubleValue else { return }
    doubleValue = value
    events.onStep(value)
  }

  override func keyDown(with event: NSEvent) {
    guard isEnabled else { return super.keyDown(with: event) }
    switch event.keyCode {
    case 123, 125: nudge(by: -1)  // left, down
    case 124, 126: nudge(by: 1)  // right, up
    case 116: nudge(by: 10)  // page up
    case 121: nudge(by: -10)  // page down
    case 115: jump(to: minValue)  // home
    case 119: jump(to: maxValue)  // end
    default: super.keyDown(with: event)
    }
  }

  override func accessibilityPerformIncrement() -> Bool { nudge(by: 1) }
  override func accessibilityPerformDecrement() -> Bool { nudge(by: -1) }
}

/// A slider that reports a drag, its release and a key or VoiceOver step separately.
struct PanelSlider: NSViewRepresentable {
  var value: Double
  var range: ClosedRange<Double>
  var step: Double?
  var accessibilityLabel: String
  /// What VoiceOver reads for the value ("40%").
  var accessibilityValue: String
  var events: PanelSliderEvents

  @Environment(\.panelTheme) private var theme

  func makeNSView(context: Context) -> PanelNSSlider {
    let slider = PanelNSSlider()
    slider.controlSize = .small
    return slider
  }

  func updateNSView(_ slider: PanelNSSlider, context: Context) {
    slider.events = events
    slider.step = step
    slider.minValue = range.lowerBound
    slider.maxValue = range.upperBound
    // The value the pointer is dragging is the slider's own until it is released.
    if !slider.isTrackingPointer, slider.doubleValue != value { slider.doubleValue = value }
    slider.isEnabled = context.environment.isEnabled
    slider.trackFillColor = NSColor(theme.accent.accent.color)
    slider.setAccessibilityLabel(accessibilityLabel)
    slider.setAccessibilityValueDescription(accessibilityValue)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: PanelNSSlider, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 120, height: nsView.naturalHeight)
  }
}
