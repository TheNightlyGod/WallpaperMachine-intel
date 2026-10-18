import SwiftUI

// The pieces the guide's pages are made of. Nothing here knows a page: they take their words as
// `Text` (which follows the panel's language through the environment) and their actions as
// closures, and read the panel theme for every colour.

extension EnvironmentValues {
  /// The card is short (a small window): pages use their tighter spacing and a smaller hero.
  @Entry var welcomeIsCompact = false
  /// The choice group around a tile has keyboard focus, so its chosen tile draws a focus ring.
  @Entry var welcomeGroupHasFocus = false
}

// MARK: - Surfaces

extension View {
  /// The grey well the guide's tiles, forms and rows sit in on the white card.
  func welcomeSurface(radius: CGFloat = 12) -> some View {
    modifier(WelcomeSurface(radius: radius))
  }
}

private struct WelcomeSurface: ViewModifier {
  let radius: CGFloat
  @Environment(\.panelTheme) private var theme

  func body(content: Content) -> some View {
    content
      .background(
        theme.surface.well.color, in: RoundedRectangle(cornerRadius: radius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
      }
  }
}

// MARK: - Headings

/// A page's title and the sentence under it. VoiceOver is moved to the title whenever a page
/// appears, the way a sighted person starts reading at the top.
struct WelcomePageHeader: View {
  let title: Text
  var lead: Text?
  var alignment: HorizontalAlignment = .leading

  @Environment(FirstRunModel.self) private var model
  @Environment(\.panelTheme) private var theme
  @Environment(\.welcomeIsCompact) private var compact
  @AccessibilityFocusState private var titleHasFocus: Bool

  var body: some View {
    WelcomeColumn(spacing: 8, centered: alignment == .center) {
      title
        .font(.system(size: compact ? 21 : 24, weight: .bold))
        .tracking(-0.4)
        .foregroundStyle(theme.surface.text.color)
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleHasFocus)
        .textSelection(.enabled)
      if let lead {
        lead
          .font(.system(size: 14))
          .lineSpacing(3)
          .foregroundStyle(theme.surface.muted.color)
          .multilineTextAlignment(alignment == .center ? .center : .leading)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    .onAppear { titleHasFocus = true }
    .onChange(of: model.titleFocusRequest) { titleHasFocus = true }
  }
}

/// The small heading over a group of choices: a glyph and a name.
struct WelcomeGroupLabel: View {
  let systemImage: String
  let title: Text
  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.accent.accent.color)
        .accessibilityHidden(true)
      title
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.surface.text.color)
        .accessibilityAddTraits(.isHeader)
    }
  }
}

/// A line of small print under a group.
struct WelcomeNote: View {
  let text: Text
  @Environment(\.panelTheme) private var theme

  var body: some View {
    text
      .font(.system(size: 12))
      .lineSpacing(2)
      .foregroundStyle(theme.surface.muted.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }
}

// MARK: - Notices

/// A message the page owes the person: a failure or a caution. Announced when it appears.
struct WelcomeNotice: View {
  enum Style { case error, warning, info }

  let style: Style
  let message: String

  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(verbatim: message)
        .font(.system(size: 12))
        .lineSpacing(2)
        .foregroundStyle(theme.surface.text.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .accessibilityElement(children: .combine)
    .onAppear { if style == .error { Self.announce(message) } }
    .onChange(of: message) { if style == .error { Self.announce(message) } }
  }

  private var symbol: String {
    switch style {
    case .error: "exclamationmark.triangle.fill"
    case .warning: "exclamationmark.circle.fill"
    case .info: "info.circle.fill"
    }
  }

  private var tint: Color {
    switch style {
    case .error: theme.surface.danger.color
    case .warning: theme.surface.warning.color
    case .info: theme.accent.accent.color
    }
  }

  private static func announce(_ message: String) {
    AccessibilityNotification.Announcement(message).post()
  }
}

/// How the guide speaks to VoiceOver about something that changed where the person is not looking.
enum WelcomeAnnouncer {
  /// Queued after whatever VoiceOver is reading, never interrupting it: a status, not an alarm.
  @MainActor
  static func polite(_ message: String) {
    var announcement = AttributedString(message)
    announcement.accessibilitySpeechAnnouncementPriority = .default
    AccessibilityNotification.Announcement(announcement).post()
  }
}

// MARK: - Status cards

/// An icon, a title, a sentence and whatever else belongs to a state of the Steam page. While
/// something is working the icon is a spinner (which only moves while the window is on screen),
/// which VoiceOver reads as a progress indicator named for what is working.
struct WelcomeStatusCard<Content: View>: View {
  var systemImage: String
  var title: Text
  var detail: Text?
  var isSuccess = false
  /// A ring in place of the icon: `nil` spins, a fraction fills.
  var working: WelcomeWorking?
  @ViewBuilder var content: Content

  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      leading
        .frame(width: 32, height: 32)
      WelcomeColumn(spacing: 8) {
        title
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(theme.surface.text.color)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
        if let detail {
          detail
            .font(.system(size: 12.5))
            .lineSpacing(2)
            .foregroundStyle(theme.surface.muted.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        content
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(isSuccess ? theme.accent.primary.color.opacity(0.10) : theme.surface.well.color)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(
          isSuccess ? theme.accent.primaryLine.color.opacity(0.4) : theme.surface.divider.color,
          lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var leading: some View {
    if let working {
      ProgressRing(value: working.fraction, lineWidth: 2.5)
        .padding(6)
        // The ring is drawn by hand and is decoration on its own; VoiceOver gets the system's
        // progress indicator in its place, with the label and how far along it is.
        .accessibilityRepresentation {
          if let fraction = working.fraction {
            ProgressView(value: fraction) { Text(verbatim: working.label) }
          } else {
            ProgressView { Text(verbatim: working.label) }
          }
        }
    } else {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(isSuccess ? theme.accent.onPrimary.color : theme.accent.accent.color)
        .frame(width: 32, height: 32)
        .background(
          isSuccess ? theme.accent.primary.color : theme.accent.accent.color.opacity(0.12),
          in: Circle())
        .accessibilityHidden(true)
    }
  }
}

/// Whether a status card is working, and how far along.
struct WelcomeWorking: Equatable {
  /// `nil` when how much is done is not known.
  var fraction: Double?
  /// The name VoiceOver gives the card's progress indicator.
  var label: String

  static func indeterminate(_ label: String) -> WelcomeWorking {
    WelcomeWorking(fraction: nil, label: label)
  }
}

// MARK: - Links

/// A link that opens an address through the panel's allowlist.
struct WelcomeLinkButton: View {
  let title: Text
  let url: URL

  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    Button {
      ExternalLink.open(url)
    } label: {
      HStack(spacing: 4) {
        title
        Image(systemName: "arrow.up.right")
          .font(.system(size: 9.5, weight: .bold))
          .accessibilityHidden(true)
      }
      .font(.system(size: 12.5, weight: .medium))
      .foregroundStyle(theme.accent.accent.color)
      .underline(isHovering)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

// MARK: - Buttons

/// The pill that moves the guide forward: **Continue**, **Start using the app**, **Sign in**. The
/// compact size is the button inside a card: Allow, Install, Buy, Submit.
///
/// The guide's buttons take their height from padding and never from a `minHeight` frame, which
/// would make them flexible in height and the stack around them squeeze the text beside them.
struct WelcomePrimaryButtonStyle: ButtonStyle {
  enum Size {
    case regular, compact
  }

  var size = Size.regular

  func makeBody(configuration: Configuration) -> some View {
    WelcomePrimaryBody(configuration: configuration, size: size)
  }
}

private struct WelcomePrimaryBody: View {
  let configuration: ButtonStyleConfiguration
  let size: WelcomePrimaryButtonStyle.Size
  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    let accent = theme.accent
    configuration.label
      .font(.system(size: size == .regular ? 13.5 : 12.5, weight: .semibold))
      .foregroundStyle(accent.onPrimary.color)
      .lineLimit(1)
      .padding(.horizontal, size == .regular ? 18 : 12)
      .padding(.vertical, size == .regular ? 9 : 5)
      .background(fill.color, in: Capsule())
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
  }

  private var fill: PanelColor {
    let accent = theme.accent
    if configuration.isPressed { return accent.primaryActive }
    return isHovering && isEnabled ? accent.primaryHover : accent.primary
  }
}

/// A text button for what is optional: **Back**, **Skip**.
struct WelcomeQuietButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    WelcomeQuietBody(configuration: configuration)
  }
}

private struct WelcomeQuietBody: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(theme.surface.text.color.opacity(0.85))
      .lineLimit(1)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(background, in: Capsule())
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
  }

  private var background: Color {
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering && isEnabled ? theme.surface.hover.color : .clear
  }
}

/// A quiet filled capsule for a secondary action inside a card: Cancel, Check again, Review.
/// `isActive` tints it with the accent, for the one that asks for the person's attention.
struct WelcomeCapsuleButtonStyle: ButtonStyle {
  var isActive = false

  func makeBody(configuration: Configuration) -> some View {
    WelcomeCapsuleBody(configuration: configuration, isActive: isActive)
  }
}

private struct WelcomeCapsuleBody: View {
  let configuration: ButtonStyleConfiguration
  let isActive: Bool
  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .font(.system(size: 12.5, weight: .medium))
      .foregroundStyle(isActive ? theme.accent.accent.color : theme.surface.text.color)
      .lineLimit(1)
      .padding(.horizontal, 11)
      .padding(.vertical, 5)
      .background(background, in: Capsule())
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
  }

  private var background: Color {
    if isActive { return theme.accent.accent.color.opacity(configuration.isPressed ? 0.24 : 0.16) }
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering && isEnabled ? theme.surface.selected.color : theme.surface.hover.color
  }
}

extension ButtonStyle where Self == WelcomePrimaryButtonStyle {
  static var welcomePrimary: WelcomePrimaryButtonStyle { WelcomePrimaryButtonStyle() }
  static func welcomePrimary(size: WelcomePrimaryButtonStyle.Size) -> WelcomePrimaryButtonStyle {
    WelcomePrimaryButtonStyle(size: size)
  }
}

extension ButtonStyle where Self == WelcomeQuietButtonStyle {
  static var welcomeQuiet: WelcomeQuietButtonStyle { WelcomeQuietButtonStyle() }
}

extension ButtonStyle where Self == WelcomeCapsuleButtonStyle {
  static var welcomeCapsule: WelcomeCapsuleButtonStyle { WelcomeCapsuleButtonStyle() }
  static func welcomeCapsule(isActive: Bool) -> WelcomeCapsuleButtonStyle {
    WelcomeCapsuleButtonStyle(isActive: isActive)
  }
}

// MARK: - Choice tiles

/// A set of tiles of which one is chosen, as the native radio group behaves: one tab stop for the
/// whole group, the arrow keys, Home and End move the choice (and wrap), and VoiceOver reads the
/// group by its name with the chosen tile marked.
struct WelcomeChoiceGroup<Content: View>: View {
  /// The group's name, for VoiceOver.
  let label: String
  /// How many tiles there are and which is chosen (nil: none matches).
  let count: Int
  let selectedIndex: Int?
  var isEnabled = true
  /// Chooses the tile at an index: what a key press does. A click is the tile's own action.
  let select: (Int) -> Void
  @ViewBuilder var content: Content

  @FocusState private var hasFocus: Bool

  var body: some View {
    content
      .environment(\.welcomeGroupHasFocus, hasFocus)
      .focusable()
      .focused($hasFocus)
      .focusEffectDisabled()
      .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in
        guard isEnabled, count > 0 else { return .ignored }
        guard let target = Self.destination(
          from: selectedIndex, key: press.key, count: count)
        else { return .ignored }
        select(target)
        return .handled
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(label)
  }

  /// Where an arrow key, Home or End leads from `index`; the arrows wrap, as a radio group's do.
  static func destination(from index: Int?, key: KeyEquivalent, count: Int) -> Int? {
    guard count > 0 else { return nil }
    switch key {
    case .home: return 0
    case .end: return count - 1
    case .rightArrow, .downArrow: return ((index ?? -1) + 1) % count
    case .leftArrow, .upArrow: return ((index ?? count) - 1 + count) % count
    default: return nil
    }
  }
}

/// One choice: a card that shows the accent ring and a check when it is the one chosen.
struct WelcomeTile<Content: View>: View {
  let isSelected: Bool
  var isEnabled = true
  let action: () -> Void
  @ViewBuilder var content: Content

  @Environment(\.welcomeGroupHasFocus) private var groupHasFocus

  var body: some View {
    Button(action: action) { content }
      .buttonStyle(WelcomeTileStyle(isSelected: isSelected, showsFocus: groupHasFocus))
      .disabled(!isEnabled)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct WelcomeTileStyle: ButtonStyle {
  let isSelected: Bool
  let showsFocus: Bool

  func makeBody(configuration: Configuration) -> some View {
    WelcomeTileBody(configuration: configuration, isSelected: isSelected, showsFocus: showsFocus)
  }
}

private struct WelcomeTileBody: View {
  let configuration: ButtonStyleConfiguration
  let isSelected: Bool
  let showsFocus: Bool

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  private let radius: CGFloat = 12

  var body: some View {
    configuration.label
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(
            isSelected ? theme.accent.primaryLine.color : theme.surface.divider.color,
            lineWidth: isSelected ? 2 : 0.5)
      }
      .overlay(alignment: .topTrailing) { check }
      .background {
        if isSelected && showsFocus {
          RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
            .stroke(theme.accent.focus.color.opacity(0.55), lineWidth: 3)
            .padding(-3)
        }
      }
      .opacity(isEnabled ? 1 : 0.55)
      .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
  }

  private var fill: Color {
    if isSelected { return theme.accent.primary.color.opacity(configuration.isPressed ? 0.18 : 0.10) }
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering && isEnabled ? theme.surface.raisedHover.color : theme.surface.well.color
  }

  private var check: some View {
    Image(systemName: "checkmark")
      .font(.system(size: 9, weight: .heavy))
      .foregroundStyle(theme.accent.onPrimary.color)
      .frame(width: 18, height: 18)
      .background(theme.accent.primary.color, in: Circle())
      .padding(7)
      .opacity(isSelected ? 1 : 0)
      .scaleEffect(isSelected || reduceMotion ? 1 : 0.6)
      .accessibilityHidden(true)
  }
}

// MARK: - Equal-height rows

/// Tiles side by side in equal columns and at the height of the tallest, which the tiles fill. A
/// plain stack cannot do this without flexible-height frames, and a flexible height inside a page
/// makes the stack around it squeeze the wrapping text next to it down to one line.
struct WelcomeTileRow: Layout {
  var spacing: CGFloat = 10

  private func column(for width: CGFloat, count: Int) -> CGFloat {
    max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
  }

  private func height(in column: CGFloat, _ subviews: Subviews) -> CGFloat {
    subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let width =
      proposal.width
      ?? (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0) * CGFloat(subviews.count)
      + spacing * CGFloat(subviews.count - 1)
    return CGSize(width: width, height: height(in: column(for: width, count: subviews.count), subviews))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard !subviews.isEmpty else { return }
    let column = column(for: bounds.width, count: subviews.count)
    let rowHeight = height(in: column, subviews)
    for (index, subview) in subviews.enumerated() {
      subview.place(
        at: CGPoint(x: bounds.minX + CGFloat(index) * (column + spacing), y: bounds.minY),
        proposal: ProposedViewSize(width: column, height: rowHeight))
    }
  }
}

// MARK: - Columns

/// Children one under another, each at the height it needs for the width it is given, whatever
/// height the column itself is offered.
///
/// A `VStack` placed at exactly the height it asked for still shares that height out between its
/// children, by how flexible each is, and a child made of wrapping text can then be handed a little
/// less than it needs: a line is all or nothing, so a note of two lines comes out as one with an
/// ellipsis. The guide's pages are taller than their card as often as not and scroll, so a column
/// that simply stacks ideal heights, and proposes none to its children, is the right shape for a page.
struct WelcomeColumn: Layout {
  var spacing: CGFloat = 0
  /// Whether a child narrower than the column is centred instead of leading.
  var centered = false

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
    let width = proposal.width ?? sizes.map(\.width).max() ?? 0
    let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(subviews.count - 1)
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      let x = centered ? bounds.minX + (bounds.width - size.width) / 2 : bounds.minX
      subview.place(
        at: CGPoint(x: x, y: y), anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: nil))
      y += size.height + spacing
    }
  }
}
