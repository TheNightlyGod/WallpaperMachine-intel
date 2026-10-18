import AppKit
import SwiftUI

/// The inspector column along the page's trailing edge: the selected wallpaper's details, 300
/// points wide at first, between 260 and 420 by dragging its leading edge. The toolbar's
/// **Wallpaper details** shows and hides it (`ShellModel.isInspectorShown`).
///
/// It is part of the page, not the system's inspector column, so the title bar keeps one shade
/// across the window (`PageScrollHost`). It asks for exactly its own width; the page beside it has
/// none of its own.
struct InspectorColumn<Content: View>: View {
  static var widths: ClosedRange<CGFloat> { 260...420 }
  static var idealWidth: CGFloat { 300 }

  @ViewBuilder var content: Content

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let shell = controller.shell
    HStack(spacing: 0) {
      Rectangle()
        .fill(theme.surface.line.color)
        .frame(width: 0.5)
        .overlay {
          ResizeHandle(
            width: Binding(get: { shell.inspectorWidth }, set: { shell.inspectorWidth = $0 }))
        }
        .zIndex(1)
      content
        .frame(width: shell.inspectorWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface.surface.color)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: L("Wallpaper details")))
  }
}

/// The column's leading edge as a handle: the resize pointer on hover, and a drag that widens the
/// column to the left and narrows it to the right, within `InspectorColumn.widths`.
private struct ResizeHandle: View {
  @Binding var width: CGFloat
  @State private var start: CGFloat?

  var body: some View {
    Color.clear
      .frame(width: 8)
      .contentShape(Rectangle())
      .onHover { inside in
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            let from = start ?? width
            if start == nil { start = width }
            let widths = InspectorColumn<EmptyView>.widths
            width = min(max(from - drag.translation.width, widths.lowerBound), widths.upperBound)
          }
          .onEnded { _ in start = nil }
      )
      .accessibilityHidden(true)
  }
}
