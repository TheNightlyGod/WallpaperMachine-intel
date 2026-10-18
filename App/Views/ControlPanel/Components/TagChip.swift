import SwiftUI

/// A tag as a small capsule. It only draws the tag: a filter wraps it in a `Button`.
///
/// Tags come from wallpaper manifests, so the text is never read as a localization key.
struct TagChip: View {
  enum Selection {
    case plain
    /// A tag every shown wallpaper must carry.
    case required
    /// A tag no shown wallpaper may carry.
    case excluded
  }

  let text: String
  var selection: Selection = .plain

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Text(verbatim: text)
      .font(.system(size: 11, weight: .medium))
      .strikethrough(selection == .excluded)
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(background, in: Capsule())
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
    case .plain: theme.surface.badge.color
    case .required: theme.accent.primary.color
    case .excluded: theme.surface.danger.color.opacity(0.14)
    }
  }
}

/// Lays its children out left to right and wraps them onto new lines at the width it is given.
struct TagFlow: Layout {
  var spacing: CGFloat = 6
  /// Sets each child on its row's centre line instead of its top, for a row of controls of
  /// different heights (the accent swatches, the colour well and the hex beside them).
  var centersRows = false

  /// Where each size lands in rows no wider than `width`, and the size the rows take together. A
  /// child wider than `width` sits alone on its row. A nil width means a single row.
  static func arrange(
    _ sizes: [CGSize], width: CGFloat?, spacing: CGFloat, centersRows: Bool = false
  ) -> (origins: [CGPoint], size: CGSize) {
    var origins: [CGPoint] = []
    /// The row each child is on, and each row's height.
    var rowOf: [Int] = []
    var rowHeights: [CGFloat] = [0]
    var x: CGFloat = 0
    var y: CGFloat = 0
    var widest: CGFloat = 0
    for size in sizes {
      if let width, x > 0, x + size.width > width {
        y += rowHeights[rowHeights.count - 1] + spacing
        x = 0
        rowHeights.append(0)
      }
      origins.append(CGPoint(x: x, y: y))
      rowOf.append(rowHeights.count - 1)
      x += size.width + spacing
      widest = max(widest, x - spacing)
      rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
    }
    if centersRows {
      for index in origins.indices {
        origins[index].y += (rowHeights[rowOf[index]] - sizes[index].height) / 2
      }
    }
    let height = sizes.isEmpty ? 0 : y + rowHeights[rowHeights.count - 1]
    return (origins, CGSize(width: widest, height: height))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    return Self.arrange(sizes, width: proposal.width, spacing: spacing).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let arranged = Self.arrange(
      sizes, width: bounds.width, spacing: spacing, centersRows: centersRows)
    for (subview, origin) in zip(subviews, arranged.origins) {
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
    }
  }
}
