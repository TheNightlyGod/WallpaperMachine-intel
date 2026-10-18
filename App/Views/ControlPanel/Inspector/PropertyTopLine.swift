import AppKit
import SwiftUI

/// The top line of a switch, choice or colour row: the label, its marks (Modified, Restore
/// default) and the control.
///
/// They share one line while the label fits beside the marks and the control without wrapping.
/// Otherwise the control moves under the label, at the trailing edge, and the label takes the whole
/// width beside its marks: in the narrowest inspector a long author label then wraps between words
/// instead of being broken mid-word in a sliver of a column, and the control keeps its own width.
///
/// The choice counts the Modified mark even while it is hidden (`reserve`), so changing a value
/// never moves the control from one line to the other under the pointer.
struct PropertyTopLineLayout: Layout {
  enum Part { case label, marks, control }

  /// Which part a subview is; a subview that does not say is the label.
  struct PartKey: LayoutValueKey {
    static let defaultValue = Part.label
  }

  /// The width of the Modified mark while it is not shown, counted when choosing the arrangement.
  var reserve: CGFloat = 0
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 6

  /// Whether the label fits on one line beside the marks and the control in `width`.
  ///
  /// - Parameters:
  ///   - label: The label's width on one line.
  ///   - marks: The width of the marks shown, plus `reserve`.
  ///   - control: The control's own width; 0 for none, which always fits.
  static func fitsBeside(label: CGFloat, marks: CGFloat, control: CGFloat, spacing: CGFloat, width: CGFloat)
    -> Bool
  {
    guard control > 0 else { return true }
    let gaps = spacing * (marks > 0 ? 2 : 1)
    return label + gaps + marks + control <= width
  }

  /// Where each part goes for a width.
  fileprivate struct Arrangement {
    var size: CGSize
    var label: CGRect
    var marks: CGRect
    var control: CGRect
  }

  /// The parts' measurements, kept until a part changes (SwiftUI then makes a new cache).
  ///
  /// SwiftUI asks a row for its size several times in one layout pass, and lays the open inspector
  /// out again whenever anything in the window changes. Measuring the parts afresh each time (the
  /// control is often an AppKit slider) made the inspector most of the panel's main-thread time and
  /// dropped frames while the grid beside it scrolled.
  struct Cache {
    fileprivate var ideal: (label: CGSize, marks: CGSize, control: CGSize)?
    fileprivate var arrangements: [CGFloat: Arrangement] = [:]
  }

  func makeCache(subviews: Subviews) -> Cache { Cache() }

  private func parts(_ subviews: Subviews) -> (label: LayoutSubview?, marks: LayoutSubview?, control: LayoutSubview?) {
    (
      subviews.first { $0[PartKey.self] == .label }, subviews.first { $0[PartKey.self] == .marks },
      subviews.first { $0[PartKey.self] == .control }
    )
  }

  private func arrangement(width proposed: CGFloat?, _ subviews: Subviews, cache: inout Cache)
    -> Arrangement
  {
    let (label, marks, control) = parts(subviews)
    let measured =
      cache.ideal
      ?? (
        label?.sizeThatFits(.unspecified) ?? .zero, marks?.sizeThatFits(.unspecified) ?? .zero,
        control?.sizeThatFits(.unspecified) ?? .zero
      )
    cache.ideal = measured
    let (labelIdeal, marksSize, controlSize) = measured
    let marksGap = marksSize.width > 0 ? spacing : 0
    let controlGap = controlSize.width > 0 ? spacing : 0
    // No width, or an unbounded one, asks for the ideal size: everything on one line.
    let ideal = labelIdeal.width + marksGap + marksSize.width + controlGap + controlSize.width
    let width = proposed.map { $0.isFinite ? $0 : ideal } ?? ideal
    if let known = cache.arrangements[width] { return known }
    let made = arrangement(
      width: width, label: label, control: control, labelIdeal: labelIdeal, marksSize: marksSize,
      controlSize: controlSize)
    cache.arrangements[width] = made
    return made
  }

  private func arrangement(
    width: CGFloat, label: LayoutSubview?, control: LayoutSubview?, labelIdeal: CGSize,
    marksSize: CGSize, controlSize: CGSize
  ) -> Arrangement {
    let marksGap = marksSize.width > 0 ? spacing : 0
    let controlGap = controlSize.width > 0 ? spacing : 0
    let beside = Self.fitsBeside(
      label: labelIdeal.width, marks: marksSize.width + reserve, control: controlSize.width,
      spacing: spacing, width: width)

    if beside {
      let labelWidth = max(0, width - marksGap - marksSize.width - controlGap - controlSize.width)
      let labelHeight = label?.sizeThatFits(.init(width: labelWidth, height: nil)).height ?? 0
      let height = max(labelHeight, marksSize.height, controlSize.height)
      let controlX = width - controlSize.width
      let marksX = controlX - controlGap - marksSize.width
      return Arrangement(
        size: CGSize(width: width, height: height),
        label: CGRect(x: 0, y: (height - labelHeight) / 2, width: labelWidth, height: labelHeight),
        marks: CGRect(
          x: marksX, y: (height - marksSize.height) / 2, width: marksSize.width,
          height: marksSize.height),
        control: CGRect(
          x: controlX, y: (height - controlSize.height) / 2, width: controlSize.width,
          height: controlSize.height))
    }

    let labelWidth = max(0, width - marksGap - marksSize.width)
    let labelHeight = label?.sizeThatFits(.init(width: labelWidth, height: nil)).height ?? 0
    let firstLine = max(labelHeight, marksSize.height)
    let controlWidth = min(controlSize.width, width)
    let controlHeight =
      control?.sizeThatFits(.init(width: controlWidth, height: nil)).height ?? controlSize.height
    return Arrangement(
      size: CGSize(width: width, height: firstLine + lineSpacing + controlHeight),
      label: CGRect(x: 0, y: (firstLine - labelHeight) / 2, width: labelWidth, height: labelHeight),
      marks: CGRect(
        x: width - marksSize.width, y: (firstLine - marksSize.height) / 2,
        width: marksSize.width, height: marksSize.height),
      control: CGRect(
        x: width - controlWidth, y: firstLine + lineSpacing, width: controlWidth,
        height: controlHeight))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    arrangement(width: proposal.width, subviews, cache: &cache).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    let arrangement = arrangement(width: bounds.width, subviews, cache: &cache)
    let (label, marks, control) = parts(subviews)
    func place(_ subview: LayoutSubview?, _ frame: CGRect) {
      subview?.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
        proposal: ProposedViewSize(frame.size))
    }
    place(label, arrangement.label)
    place(marks, arrangement.marks)
    place(control, arrangement.control)
  }
}

/// The Modified pill beside a property's label.
struct ModifiedMark: View {
  private static let fontSize: CGFloat = 10.5
  private static let inset: CGFloat = 6

  @Environment(\.panelTheme) private var theme

  /// The pill's width in the panel's language, which a row keeps in mind while the pill is hidden.
  @MainActor
  static func width() -> CGFloat {
    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let text = L("Modified") as NSString
    return (text.size(withAttributes: [.font: font]).width + inset * 2).rounded(.up)
  }

  var body: some View {
    Text("Modified")
      .font(.system(size: Self.fontSize, weight: .semibold))
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .foregroundStyle(theme.accent.accent.color)
      .padding(.horizontal, Self.inset)
      .frame(minHeight: 16)
      .background(theme.accent.accent.color.opacity(0.14), in: Capsule())
  }
}
