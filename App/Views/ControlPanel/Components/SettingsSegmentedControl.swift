import SwiftUI

/// A row of choices in one rounded track, the selected one raised: the Quality preset and the short
/// choices of Quick Settings.
///
/// It is built from buttons rather than a native segmented picker so that one segment can be shown
/// as the current state yet never be pressable (Quality's Custom), and so its colours follow the
/// panel's palettes. `selection` may be nil or a value with no segment, which selects nothing.
///
/// Every segment uses the same type size, whatever room it has: a label that does not fit is cut
/// short rather than drawn smaller than its neighbours.
struct SettingsSegmentedControl<Value: Hashable>: View {
  struct Segment: Identifiable {
    let value: Value
    let title: String
    /// A segment that can be the selection but never be chosen by the user.
    var isEnabled = true
    var id: Value { value }
  }

  let segments: [Segment]
  let selection: Value?
  /// Dims and stops the whole control, as a Mac that is busy does.
  var isEnabled = true
  /// Shares the width it is offered equally between the segments, as a module card's full-width
  /// choice does. Off, the control is as wide as its labels and each segment as wide as its own, for
  /// a control at the trailing edge of a row.
  var fillsWidth = true
  let onSelect: (Value) -> Void

  @Environment(\.panelTheme) private var theme
  @FocusState private var focused: Value?

  var body: some View {
    // The arrow keys move between the segments that can be chosen.
    let chooseable = segments.filter { $0.isEnabled }.map(\.value)
    HStack(spacing: 2) {
      ForEach(segments) { segment in
        SegmentButton(
          title: segment.title, isSelected: segment.value == selection,
          isChoosable: segment.isEnabled, isEnabled: isEnabled, fillsWidth: fillsWidth
        ) { onSelect(segment.value) }
        .settingsRadioKeys(segment.value, in: chooseable, focus: $focused) { onSelect($0) }
      }
    }
    .fixedSize(horizontal: !fillsWidth, vertical: false)
    .padding(2)
    .background(theme.surface.hover.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .opacity(isEnabled ? 1 : 0.5)
    .accessibilityElement(children: .contain)
  }
}

private struct SegmentButton: View {
  let title: String
  let isSelected: Bool
  /// False for a segment that is only ever a state (Quality's Custom): it shows as the selection
  /// when it is one, and is never a button.
  let isChoosable: Bool
  /// The whole control takes input; false while the Mac is busy.
  let isEnabled: Bool
  let fillsWidth: Bool
  let action: () -> Void

  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    if isChoosable {
      Button(action: action) { label }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    } else {
      // Not a disabled button: a disabled button draws its label dimmed, which made the selected
      // Custom read as unavailable rather than as the state in force. It is a label in the same
      // place, in the text colour on the raised fill while selected and muted otherwise, that
      // nothing can press or focus.
      label
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isStaticText] : .isStaticText)
    }
  }

  private var label: some View {
    // Sized by the title's semibold form, which the selected segment uses, so choosing a segment
    // never moves its neighbours.
    Text(verbatim: title)
      .font(.system(size: 12.5, weight: .semibold))
      .lineLimit(1)
      .hidden()
      .overlay {
        Text(verbatim: title)
          .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(
            isSelected || isChoosable ? theme.surface.text.color : theme.surface.muted.color
          )
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 24)
      .background {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(fill)
          .shadow(color: .black.opacity(isSelected ? 0.14 : 0), radius: 1, y: 0.5)
      }
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var fill: Color {
    if isSelected { return theme.surface.segmentSelected.color }
    return isHovering && isChoosable && isEnabled ? theme.surface.selected.color : .clear
  }
}
