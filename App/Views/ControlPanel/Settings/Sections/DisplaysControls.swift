import SwiftUI

// The controls the Displays page's rows hold (`DisplaysRow`): number fields, the Volume slider, the
// naming form, result lines and menus of the user's own titles.

/// A number field that commits when it is submitted or left, never per keystroke. A text that is not
/// a number the control accepts sends nothing: it stays in the field, which says what it accepts
/// (`invalidMessage`) until it is corrected, and Return keeps the keyboard there. Escape puts the
/// stored value back.
struct DisplaysNumberField: View {
  let value: Double
  var integer = false
  /// The most fraction digits the field writes.
  var digits = 2
  var width: CGFloat = 64
  var unit: String?
  let accepts: (Double) -> Bool
  /// What the field accepts, said under it after a text it refused: "Enter a whole number from 1
  /// to 60."
  let invalidMessage: String
  /// Runs the change and returns when it has finished, so the field can show the stored value again.
  let commit: @MainActor (Double) async -> Void

  @Environment(\.locale) private var locale
  @Environment(\.panelTheme) private var theme
  /// What is typed; nil shows the stored value.
  @State private var text: String?
  /// The number just sent, shown until its change has run.
  @State private var sent: Double?
  /// The typed text was refused: it stays, with `invalidMessage` under it.
  @State private var isInvalid = false
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .trailing, spacing: 3) {
      HStack(spacing: 6) {
        TextField(
          noLabel,
          text: Binding(
            get: { text ?? shown },
            set: { typed in
              // The field can write back the text it holds (as it takes focus or lays out). Only a
              // change ends the alert: writing state for an unchanged text would lay the field out
              // again, and the field would write again.
              guard typed != (text ?? shown) else { return }
              text = typed
              isInvalid = false
            })
        )
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12.5).monospacedDigit())
        .multilineTextAlignment(.trailing)
        .frame(width: width)
        .focused($isFocused)
        .onSubmit { if !finish() { isFocused = true } }
        .onChange(of: isFocused) { _, focused in if !focused { finish() } }
        .onExitCommand {
          text = nil
          isInvalid = false
        }
        if let unit { DisplaysUnitLabel(text: unit) }
      }
      if isInvalid {
        Text(verbatim: invalidMessage)
          .font(.system(size: 11))
          .foregroundStyle(theme.surface.danger.color)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 220, alignment: .trailing)
      }
    }
    .announcesChanges(of: isInvalid ? invalidMessage : nil)
  }

  private var shown: String {
    DisplaysNumberInput.text(sent ?? value, digits: digits, locale: locale)
  }

  /// Sends what is typed when the field accepts it (`DisplaysNumberCommit`). Returns false when it
  /// refused the text, which then stays in the field.
  @discardableResult
  private func finish() -> Bool {
    switch DisplaysNumberCommit.outcome(
      typed: text, stored: value, integer: integer, locale: locale, accepts: accepts)
    {
    case .refuse:
      isInvalid = true
      return false
    case .none:
      text = nil
      isInvalid = false
    case .send(let number):
      text = nil
      isInvalid = false
      sent = number
      Task {
        await commit(number)
        sent = nil
      }
    }
    return true
  }
}

/// The unit after a number field ("×", "fps", "min"), in a slot of one width so the fields of a
/// card end at the same edge whatever their unit.
struct DisplaysUnitLabel: View {
  let text: String

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Text(verbatim: text)
      .font(.system(size: 12))
      .foregroundStyle(theme.surface.muted.color)
      .frame(width: 26, alignment: .leading)
      // The row names the field; the unit is part of what it already says.
      .accessibilityHidden(true)
  }
}

/// The Volume slider: the readout follows the drag, and the change is sent when it is let go.
struct DisplaysVolumeSlider: View {
  let value: Double
  let commit: @MainActor (Double) async -> Void

  @Environment(\.panelTheme) private var theme
  @State private var live: Double?

  private var readout: String { "\(Int(((live ?? value) * 100).rounded()))%" }

  var body: some View {
    HStack(spacing: 8) {
      Slider(
        value: Binding(get: { live ?? value }, set: { live = $0 }), in: 0...1,
        onEditingChanged: { editing in
          guard !editing, let final = live else { return }
          Task {
            await commit(final)
            live = nil
          }
        }
      )
      .frame(width: 130)
      // The slider says its value itself, so the readout beside it is not read twice.
      .accessibilityValue(Text(verbatim: readout))
      Text(verbatim: readout)
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(theme.surface.muted.color)
        .frame(width: 38, alignment: .trailing)
        .accessibilityHidden(true)
    }
  }
}

/// The inline form that names something: a field, Cancel and Save. Escape cancels, Return saves.
struct DisplaysNameFormRow: View {
  @Binding var form: DisplaysNameForm
  let label: String
  let canSubmit: Bool
  let cancel: () -> Void
  let submit: () -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      TextField(label, text: Binding(get: { form.text }, set: { form.text = DisplaysNameForm.limited($0) }))
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onSubmit { if canSubmit { submit() } }
        .onExitCommand(perform: cancel)
        .accessibilityLabel(Text(verbatim: label))
      Button("Cancel", action: cancel)
      Button("Save", action: submit)
        .buttonStyle(.panelPrimary(size: .small))
        .disabled(!canSubmit)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(minHeight: 36)
    .onAppear { isFocused = true }
  }
}

/// A result or a failure as a line of a card: the result of the last layout action, the box of a
/// failure that takes focus, a service's error. `.announcesChanges(of:)` on the group that holds it
/// tells VoiceOver when it changes.
struct DisplaysMessageRow: View {
  let text: String
  var isError = false

  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        .font(.system(size: 11))
        .foregroundStyle(isError ? theme.surface.danger.color : theme.surface.approved.color)
        .accessibilityHidden(true)
      Text(verbatim: text)
        .font(.system(size: 12))
        .foregroundStyle(isError ? theme.surface.danger.color : theme.surface.muted.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.updatesFrequently)
  }
}

/// A menu of choices whose titles are the user's own text: wallpaper names, display names, saved
/// playlists. The control is as wide as `width` and shows the title of the choice made, cut at the
/// end; the entries never decide its width, which a pop-up button's entries do (its widest title
/// would make the page, and with it the window, wider than the narrowest window allows).
struct DisplaysTitleMenu<Value: Hashable, Options: View>: View {
  @Binding var selection: Value
  /// The title of the choice made, or what asks for one.
  let title: String
  var width: CGFloat = 200
  /// Where the button sits in its width: at the trailing edge beside a row's text, the leading edge
  /// under it.
  var alignment = Alignment.trailing
  /// The button is as wide as its title, up to `width`, instead of always `width`: for a menu under
  /// a row's text, which has the row's width to grow into, so a long title is cut only where the
  /// row cannot hold it.
  var fitsTitle = false
  @ViewBuilder var options: Options

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Menu {
      Picker(noLabel, selection: $selection) { options }
        .pickerStyle(.inline)
        .labelsHidden()
    } label: {
      Text(verbatim: title)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: fitsTitle ? nil : .infinity, alignment: .leading)
    }
    .menuStyle(.button)
    .buttonStyle(.bordered)
    .modifier(TitleMenuWidth(width: width, alignment: alignment, fitsTitle: fitsTitle))
    .accessibilityValue(Text(verbatim: title))
  }
}

/// The width of a `DisplaysTitleMenu`: a fixed width while the page has room, no wider than the
/// narrowest page leaves; or, for one that fits its title, its title's width up to `width`.
private struct TitleMenuWidth: ViewModifier {
  let width: CGFloat
  let alignment: Alignment
  let fitsTitle: Bool

  func body(content: Content) -> some View {
    if fitsTitle {
      content.frame(maxWidth: width, alignment: alignment)
    } else {
      content.frame(minWidth: min(120, width), idealWidth: width, maxWidth: width, alignment: alignment)
    }
  }
}

extension View {
  /// Tells VoiceOver `text` each time it changes to a new message while the view is on screen, as
  /// the web page's live regions and alerts did. A message already showing when the view appears
  /// is not repeated, so opening a page does not read out old results.
  func announcesChanges(of text: String?) -> some View {
    onChange(of: text) { _, message in
      guard let message, !message.isEmpty else { return }
      AccessibilityNotification.Announcement(message).post()
    }
  }

  /// Tells VoiceOver `message` when `key` changes, for a message whose words change more often than
  /// what it means (a download's percent).
  func announcesChanges<Key: Equatable>(of key: Key, saying message: String?) -> some View {
    onChange(of: key) { _, _ in
      guard let message, !message.isEmpty else { return }
      AccessibilityNotification.Announcement(message).post()
    }
  }

  /// A pop-up menu control of fixed entries, sized to its longest one. A menu of the user's own
  /// titles is a `DisplaysTitleMenu` instead.
  func displaysMenu() -> some View {
    labelsHidden().pickerStyle(.menu).fixedSize()
  }
}
