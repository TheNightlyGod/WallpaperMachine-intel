import SwiftUI

// The two controls that take a number: a field the person types in and a slider. They commit at
// different moments from a switch, and the rules are plain values so they are tested alone.

// MARK: - Number field

/// What a typed number means to the field that took it.
enum SettingsNumberEntry {
  /// The whole number the text names when it lies inside `range`; nil for anything else, which the
  /// field answers by putting the saved value back instead of sending a number nobody chose.
  static func value(of text: String, in range: ClosedRange<Int>) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), let value = Int(trimmed),
      range.contains(value)
    else { return nil }
    return value
  }

  /// What leaving the field does: send a new valid number, or put `saved` back for text that is not
  /// one. Text that names the saved value changes nothing.
  enum Outcome: Equatable {
    case send(Int)
    case revert
    case keep
  }

  static func outcome(of text: String, in range: ClosedRange<Int>, saved: Int) -> Outcome {
    guard let value = value(of: text, in: range) else { return .revert }
    return value == saved ? .keep : .send(value)
  }
}

/// A small field for a whole number, committed when the person presses Return or leaves it, and
/// restored to the saved value when the text is not a number in range.
///
/// While it has the keyboard it shows what is typed, never what the stores report: a new snapshot
/// must not rewrite a number in the middle of being typed. VoiceOver names it after its row, even
/// beside its unit.
struct SettingsNumberField: View {
  let key: String
  let saved: Int
  let range: ClosedRange<Int>
  var width: CGFloat = 56
  let perform: @MainActor (Int) async throws -> Void

  @Environment(PanelController.self) private var controller
  @Environment(\.settingsRow) private var row
  @State private var text = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    let settings = controller.settings
    let shown = settings.value(key, saved: saved)
    TextField(
      text: Binding(
        get: { Self.displayed(isFocused: isFocused, typed: text, saved: shown) },
        set: { text = $0 })
    ) {
      EmptyView()
    }
    .textFieldStyle(.roundedBorder)
    .controlSize(.small)
    .multilineTextAlignment(.trailing)
    .font(.system(size: 12.5).monospacedDigit())
    .frame(width: width)
    .focused($isFocused)
    // The label view stays empty: a macOS field shows its label as the placeholder.
    .settingsRowAccessibility(row)
    .onSubmit { leave(settings, shown: shown) }
    .onChange(of: isFocused) { _, focused in
      if focused {
        text = String(shown)
      } else {
        leave(settings, shown: shown)
      }
    }
    .disabled(settings.isLocked(key))
  }

  /// What the field shows: the text being typed while it has the keyboard, never the stores' value,
  /// which may change underneath it; the stores' value otherwise.
  static func displayed(isFocused: Bool, typed: String, saved: Int) -> String {
    isFocused ? typed : String(saved)
  }

  private func leave(_ settings: SettingsModel, shown: Int) {
    switch SettingsNumberEntry.outcome(of: text, in: range, saved: shown) {
    case .send(let value):
      settings.commit(key, to: value, policy: .latestWins, perform: perform)
    case .revert:
      text = String(shown)
    case .keep:
      break
    }
  }
}

// MARK: - Slider

/// The rules of a slider that commits when it is let go.
///
/// A drag shows its value as it moves and sends only the value it stops on. A change that comes with
/// no drag, a press of an arrow key or a VoiceOver adjustment, is already a decision, so it is sent
/// at once. Letting go on the value the drag began at sends nothing.
struct SettingsSliderSession: Equatable {
  private(set) var value: Int
  private(set) var isDragging = false
  private var start: Int

  init(value: Int) {
    self.value = value
    start = value
  }

  mutating func begin(at value: Int) {
    self.value = value
    start = value
    isDragging = true
  }

  /// The slider moved to `new` from `shown`, the value it was drawing. True when that is a decision
  /// to send now rather than a step of a drag.
  mutating func update(_ new: Int, from shown: Int) -> Bool {
    guard new != shown else { return false }
    value = new
    return !isDragging
  }

  /// The drag ended. The value to send, nil when it ended where it began.
  mutating func end() -> Int? {
    defer { isDragging = false }
    return isDragging && value != start ? value : nil
  }
}

/// A slider over whole numbers that sends its value when it is let go, with the value beside it.
///
/// It is the panel's AppKit slider (`PanelSlider`), not SwiftUI's: a SwiftUI `Slider` with a step
/// draws a tick mark for every step on macOS, a dotted line of a hundred-odd ticks under the
/// frame-rate track, and without one an arrow key moves it by a twentieth of its range, past most
/// rates. `PanelSlider` draws no ticks, moves one whole number per arrow key or VoiceOver
/// adjustment (ten per Page Up or Down), and tells a drag from a key press, which is the
/// distinction `SettingsSliderSession` needs.
struct SettingsSliderControl: View {
  let key: String
  let saved: Int
  let range: ClosedRange<Int>
  var width: CGFloat = 160
  /// The text beside the slider for a position: "No limit", "30 fps".
  let readout: (Int) -> String
  let perform: @MainActor (Int) async throws -> Void

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.settingsRow) private var row
  @State private var session = SettingsSliderSession(value: 0)

  var body: some View {
    let settings = controller.settings
    let current = settings.value(key, saved: saved)
    let shown = session.isDragging ? session.value : current
    HStack(spacing: 10) {
      PanelSlider(
        value: Double(shown), range: Double(range.lowerBound)...Double(range.upperBound), step: 1,
        // The slider says its value to VoiceOver itself, so the words beside it are not read twice.
        accessibilityLabel: row?.title ?? "", accessibilityValue: readout(shown),
        events: PanelSliderEvents(
          onDrag: { drag(to: $0, from: current) },
          onRelease: { value in
            drag(to: value, from: current)
            if session.end() != nil { send(settings) }
          },
          onStep: { value in
            if session.update(Int(value.rounded()), from: shown) { send(settings) }
          })
      )
      .frame(width: width)
      .settingsAccessibilityHint(row?.hint)
      Text(verbatim: readout(shown))
        .font(.system(size: 12.5).monospacedDigit())
        .foregroundStyle(theme.surface.muted.color)
        .frame(minWidth: 62, alignment: .trailing)
        .accessibilityHidden(true)
    }
    .disabled(settings.isLocked(key))
  }

  /// A step of a pointer drag, which only moves what is shown; the first one starts the drag at the
  /// value the slider showed.
  private func drag(to value: Double, from current: Int) {
    if !session.isDragging { session.begin(at: current) }
    _ = session.update(Int(value.rounded()), from: session.value)
  }

  private func send(_ settings: SettingsModel) {
    settings.commit(key, to: session.value, policy: .latestWins, perform: perform)
  }
}
