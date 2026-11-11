import SwiftUI

/// The label of a control whose row already says what it is. A variable, not a literal, so the
/// empty string is not taken for a phrase to translate.
let noLabel = ""

// The rows and controls the Displays page draws its per-display cards with. They look exactly like
// `SettingsRow` and `SettingsDisclosure` (same type, padding and hairlines), and differ where a
// display needs it: the same row exists once per display, so its state and identity carry the
// display; a card whose display name matches a search keeps every row; and a value such as the
// wallpaper's title is shown whole instead of being cut behind an ⓘ button.

/// A row of a display's card: the title, an optional note and an optional value under it, and the
/// control at the trailing edge. Not drawn while a search leaves its item out, unless `forced`.
struct DisplaysRow<Control: View>: View {
  let item: SettingsItem
  /// A title that is not the item's own: "Desktop 2", "Unavailable desktop".
  var title: String?
  /// A live note that replaces the declared one, cut after its first sentence like any note. An
  /// empty note hides the declared one, for a row whose declared note is only there to be searched.
  var note: String?
  /// Values shown whole under the title, one line each: a wallpaper's title, a path, a count.
  /// Untrusted text, never cut behind an ⓘ button.
  var details: [String] = []
  /// The title is a file path: written small and monospaced, cut in the middle when it is long.
  var isPath = false
  /// The title stands in for a value that is missing ("Unavailable"): written in the quiet colour,
  /// so it does not read as data.
  var isPlaceholder = false
  /// A line in the danger colour under the title: why a shortcut was refused.
  var alert: String?
  /// Lines in the warning colour under the title: what to check before a restore.
  var warnings: [String] = []
  /// The row stays whatever the search says: its display's name matched.
  var forced = false
  /// The display or the row it belongs to, so the same item on two displays stays two rows.
  var identity: String?
  /// What VoiceOver calls the control when that is more than the title: "Volume for Studio Display".
  var controlLabel: String?
  /// Whether the row names its control after itself. True for one control that has no name of its
  /// own (a switch, a menu, a field, a slider). False for buttons and for controls made of several
  /// elements: a label set on a group reaches every element in it, which would rename each button
  /// after the row, so the elements keep their own names and the group carries `controlLabel`, if
  /// any, as its own.
  var labelsControl = true
  /// Puts the control under the text instead of beside it, for a control too wide for the row.
  var stacked = false
  @ViewBuilder var control: Control

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var showsMore = false

  var body: some View {
    let settings = controller.settings
    if forced || settings.search.shows(item) {
      let title = self.title ?? settings.text(item.title)
      let parts = noteParts(settings)
      let more = parts.more.map { [$0] + extraInfo(settings) } ?? extraInfo(settings)
      DisplaysRowLayout(forcesStack: stacked) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            if isPath {
              Text(verbatim: title)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            } else if isPlaceholder {
              Text(verbatim: title).font(.system(size: 13)).foregroundStyle(theme.surface.muted.color)
            } else {
              Text(verbatim: title).font(.system(size: 13))
            }
            if !more.isEmpty { moreButton(title: title, details: more) }
          }
          if let lead = parts.lead {
            Text(verbatim: lead)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
          }
          ForEach(details.indices, id: \.self) { index in
            Text(verbatim: details[index])
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          if let alert {
            Text(verbatim: alert)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.danger.color)
          }
          ForEach(warnings.indices, id: \.self) { index in
            Text(verbatim: warnings[index])
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.warning.color)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One subview whatever the control is made of, and none that vanishes: the layout reads two.
        ZStack {
          if labelsControl {
            control.accessibilityLabel(Text(verbatim: controlLabel ?? title))
          } else if let controlLabel {
            control.accessibilityElement(children: .contain).accessibilityLabel(Text(verbatim: controlLabel))
          } else {
            control.accessibilityElement(children: .contain)
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(minHeight: 36)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(identity.map { "\(item.id).\($0)" } ?? item.id)
    }
  }

  private func noteParts(_ settings: SettingsModel) -> (lead: String?, more: String?) {
    guard let text = note ?? item.note.map(settings.text) else { return (nil, nil) }
    let parts = SettingsNote.parts(text)
    return (parts.lead.isEmpty ? nil : parts.lead, parts.more)
  }

  private func extraInfo(_ settings: SettingsModel) -> [String] { item.info.map(settings.text) }

  private func moreButton(title: String, details: [String]) -> some View {
    Button {
      showsMore.toggle()
    } label: {
      Image(systemName: "info.circle").font(.system(size: 12))
    }
    .buttonStyle(.plain)
    .foregroundStyle(theme.surface.muted.color)
    .help(L("More about \(title)"))
    .accessibilityLabel(Text(verbatim: L("More about \(title)")))
    .popover(isPresented: $showsMore, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(details.indices, id: \.self) { index in
          Text(verbatim: details[index])
        }
      }
      .font(.system(size: 12))
      .frame(width: 300, alignment: .leading)
      .padding(14)
    }
  }
}

/// A line of explanation inside a card that is not a setting: the hint of a disclosure, a status.
struct DisplaysNote: View {
  let text: String
  var tone = Tone.muted

  enum Tone { case muted, warning, danger }

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Text(verbatim: text)
      .font(.system(size: 11.5))
      .foregroundStyle(color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
  }

  private var color: Color {
    switch tone {
    case .muted: theme.surface.muted.color
    case .warning: theme.surface.warning.color
    case .danger: theme.surface.danger.color
    }
  }
}

/// A disclosure of one display's card. Its open state is the display's own, so two displays'
/// Playlist disclosures open apart, and its summary says what is inside (the playlist's mode).
struct DisplaysDisclosure<Content: View>: View {
  let item: SettingsItem
  let display: String
  /// The title as the card words it: the item's own, or a live one such as "Playlist: Rotate".
  var title: String?
  /// A short muted line beside the title, such as "Playlist paused".
  var summary: String?
  /// What a search keeps of the display's card, which decides whether this disclosure shows and
  /// opens on this display; without one the search's own answer for the item does.
  var card: DisplaysCardSearch?
  @ViewBuilder var content: Content

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let settings = controller.settings
    if card?.showsDisclosure(item) ?? settings.search.shows(item) {
      let model = controller.displaysSettings
      let isOpen = model.isOpen(item, display: display, searchOpens: card.map { $0.opens(item) })
      VStack(spacing: 0) {
        SettingsDisclosureHeader(
          title: title ?? settings.text(item.title), note: summary, isOpen: isOpen,
          identifier: "\(item.id).\(display)"
        ) {
          model.setOpen(!isOpen, item, display: display)
        }
        if isOpen {
          Rectangle().fill(theme.surface.divider.color).frame(height: 0.5)
          DividedRows { content }
            .background { Rectangle().fill(theme.surface.hover.color.opacity(0.5)) }
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
    }
  }
}

/// A row's text and its control: side by side while the text keeps a word's width beside the
/// control, and the control under the text when it does not. It reports the narrower of the two as
/// its minimum, so a page that holds such rows does not ask the window for more than the narrowest
/// window gives: the shell counts the hidden inspector's minimum width against every page, which
/// leaves a Settings page 320 points at 760.
///
/// Two subviews: the text, then the control.
struct DisplaysRowLayout: Layout {
  var spacing: CGFloat = 12
  var stackedSpacing: CGFloat = 8
  /// Puts the control under the text whatever the width, for one that is wide or flexible.
  var forcesStack = false
  /// Gives the control the width that is left instead of its own, for one that fills its place (a
  /// wrapping set of buttons, a field).
  var fillsControl = false

  /// The widths a row is laid out with.
  private struct Widths {
    /// What the text keeps beside the control before the control goes under it: its own width, or
    /// `textFloor`. A text breaks between any two letters when it is squeezed, so the least it can
    /// take is no measure of what is readable.
    let textBeside: CGFloat
    /// The least the text takes at all, which matters when the control is under it.
    let textMinimum: CGFloat
    let controlMinimum: CGFloat
    let controlIdeal: CGFloat
  }

  /// The most a row asks its text to keep beside its control: about a short word or two.
  private static let textFloor: CGFloat = 112

  private func widths(_ subviews: Subviews) -> Widths {
    Widths(
      textBeside: min(subviews[0].sizeThatFits(.unspecified).width, Self.textFloor),
      textMinimum: subviews[0].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width,
      controlMinimum: subviews[1].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width,
      controlIdeal: subviews[1].sizeThatFits(.unspecified).width)
  }

  private func isSideBySide(_ widths: Widths, in width: CGFloat?) -> Bool {
    if forcesStack { return false }
    guard let width else { return true }
    return widths.textBeside + spacing + widths.controlMinimum <= width
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 2 else { return .zero }
    let widths = widths(subviews)
    if isSideBySide(widths, in: proposal.width) {
      let needed = widths.textBeside + spacing + widths.controlMinimum
      let available = proposal.width.map { max($0, needed) }
      // What the control is given: its own width, or all that the text leaves it when it fills.
      let given = available.map { width -> CGFloat in
        let left = width - spacing - widths.textBeside
        return max(widths.controlMinimum, fillsControl ? left : min(widths.controlIdeal, left))
      }
      let text = subviews[0].sizeThatFits(
        ProposedViewSize(width: available.flatMap { width in given.map { max(0, width - spacing - $0) } }, height: nil))
      let control = subviews[1].sizeThatFits(ProposedViewSize(width: given, height: nil))
      return CGSize(
        width: available ?? text.width + spacing + control.width, height: max(text.height, control.height))
    }
    let needed = max(widths.textMinimum, widths.controlMinimum)
    let width = proposal.width.map { max($0, needed) }
    let text = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    let control = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
    return CGSize(
      width: width ?? max(text.width, control.width), height: text.height + stackedSpacing + control.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard subviews.count == 2 else { return }
    let widths = widths(subviews)
    if isSideBySide(widths, in: bounds.width) {
      let controlWidth = max(
        widths.controlMinimum,
        min(fillsControl ? bounds.width : widths.controlIdeal, bounds.width - spacing - widths.textBeside))
      let control = subviews[1].sizeThatFits(ProposedViewSize(width: controlWidth, height: nil))
      let textWidth = max(0, bounds.width - spacing - controlWidth)
      let text = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
      let height = max(text.height, control.height)
      subviews[0].place(
        at: CGPoint(x: bounds.minX, y: bounds.minY + (height - text.height) / 2), anchor: .topLeading,
        proposal: ProposedViewSize(width: textWidth, height: text.height))
      subviews[1].place(
        at: CGPoint(x: bounds.maxX, y: bounds.minY + (height - control.height) / 2), anchor: .topTrailing,
        proposal: ProposedViewSize(width: controlWidth, height: control.height))
    } else {
      let text = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      subviews[0].place(
        at: bounds.origin, anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: text.height))
      let control = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      subviews[1].place(
        at: CGPoint(x: bounds.minX, y: bounds.minY + text.height + stackedSpacing), anchor: .topLeading,
        proposal: ProposedViewSize(width: min(bounds.width, max(control.width, 0)), height: control.height))
    }
  }
}
