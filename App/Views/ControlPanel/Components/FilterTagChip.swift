import SwiftUI

/// A tag of a Filters sidebar as a chip that starts out filtering nothing.
///
/// A click selects it, filled with the accent and a check, so only wallpapers carrying the tag are
/// shown; a second click lets it go. Option-click, or Hide this tag in its context menu, hides
/// every wallpaper carrying it instead, struck through in red, and a click lets that go too.
struct FilterTagChip<Label: View>: View {
  let selection: TagChip.Selection
  let onChange: (TagChip.Selection) -> Void
  @ViewBuilder var label: Label

  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    Button {
      onChange(Self.selection(after: selection, hiding: NSEvent.modifierFlags.contains(.option)))
    } label: {
      HStack(spacing: 3) {
        if selection == .required {
          Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
        }
        label
      }
      .font(.system(size: 11, weight: .medium))
      .strikethrough(selection == .excluded)
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(background, in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu {
      Button("Show only this tag") { onChange(.required) }
        .disabled(selection == .required)
      Button("Hide this tag") { onChange(.excluded) }
        .disabled(selection == .excluded)
      Button("Don't filter by this tag") { onChange(.plain) }
        .disabled(selection == .plain)
    }
    .help(L("Click to show only wallpapers with this tag. Option-click to hide them."))
    .accessibilityAddTraits(selection == .required ? .isSelected : [])
    .accessibilityValue(selection == .excluded ? Text("Hidden") : Text(verbatim: ""))
    .accessibilityAction(named: Text("Hide this tag")) { onChange(.excluded) }
  }

  /// What a click makes of a chip: a plain one is selected and anything else lets go. With
  /// Option held a click hides the tag, or lets a hidden one go.
  static func selection(after selection: TagChip.Selection, hiding: Bool) -> TagChip.Selection {
    if hiding { return selection == .excluded ? .plain : .excluded }
    return selection == .plain ? .required : .plain
  }

  private var foreground: Color {
    switch selection {
    case .plain: theme.surface.tagInk.color
    case .required: theme.accent.onPrimary.color
    case .excluded: theme.surface.danger.color
    }
  }

  private var background: Color {
    switch selection {
    case .plain: isHovering ? theme.surface.selected.color : theme.surface.badge.color
    case .required: theme.accent.primary.color.opacity(isHovering ? 0.85 : 1)
    case .excluded: theme.surface.danger.color.opacity(isHovering ? 0.2 : 0.14)
    }
  }
}
