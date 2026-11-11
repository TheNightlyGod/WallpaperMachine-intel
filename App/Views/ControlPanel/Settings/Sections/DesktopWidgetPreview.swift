import AppKit
import SwiftUI

/// Settings › Desktop Widgets' Arrange row: a small picture of a display, with the frame its
/// wallpaper draws (its first at once, then one past any intro or fade-in once it has played a
/// moment) and the widgets shown on it drawn as the desktop draws them, scaled down. Without a frame
/// the picture shows the wallpaper's still, and a note under it says why when one is to come. Dragging a widget moves it; the position is saved when it is let
/// go. The words are those of when the page was drawn: the preview runs no clock of its own and the
/// frame does not move. The position sliders below it are the keyboard's and VoiceOver's way to the
/// same thing, so the picture itself is hidden from VoiceOver.
struct DesktopWidgetPreview: View {
  let screen: DesktopWidgetController.Screen

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.widgetsSettings
    let display = screen.frame.size
    let aspect = display.height > 0 ? display.width / display.height : 16 / 10
    VStack(spacing: 6) {
      GeometryReader { proxy in
        let size = proxy.size
        let scale = display.width > 0 ? size.width / display.width : 1
        ZStack(alignment: .topLeading) {
          backdrop(
            frame: model.wallpaperFrame(on: screen.displayID), still: model.wallpaperStill(on: screen.displayID),
            size: size)
          ForEach(model.widgets(on: screen)) { widget in
            item(model.shown(widget), saved: widget, in: size, scale: scale)
          }
        }
        .coordinateSpace(.named(Self.space))
      }
      .aspectRatio(aspect, contentMode: .fit)
      .frame(maxWidth: 480, maxHeight: 270)
      if model.waitsForWallpaperToSettle(on: screen.displayID) {
        Text("Showing the wallpaper’s preview image until it has played for a moment.")
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .task(id: model.frameRequest(on: screen.displayID)) {
      guard let request = model.frameRequest(on: screen.displayID) else { return }
      await model.loadWallpaperFrame(request)
    }
    .frame(maxWidth: .infinity)
    .accessibilityHidden(true)
  }

  private static let space = "desktop-widget-preview"

  /// The frame the display's wallpaper drew, which has the display's shape and the wallpaper's
  /// placement; else its still, or a quiet well while it has none or it loads: no glyph, which the
  /// widgets would sit on.
  private func backdrop(frame: CGImage?, still: PanelImageSource?, size: CGSize) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return ZStack {
      theme.surface.mediaWell.color
      if let frame {
        Image(decorative: frame, scale: 1)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fill)
      } else {
        PanelImage(source: still, pointSize: max(size.width, size.height), contentMode: .fill)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipShape(shape)
    .overlay { shape.strokeBorder(theme.surface.divider.color, lineWidth: 0.5) }
  }

  private func item(_ widget: DesktopWidget, saved: DesktopWidget, in size: CGSize, scale: CGFloat) -> some View {
    let model = controller.widgetsSettings
    let content = model.content(for: widget, scale: scale)
    // AppKit's frame counts up from the bottom; the picture counts down from the top.
    let frame = DesktopWidgetRendering.frame(
      textSize: content.size, padding: content.padding, widget: widget,
      display: NSRect(origin: .zero, size: size))
    let isSelected = model.selectedID == widget.id
    return WidgetDrawing(drawing: content.drawing, padding: content.padding)
      .frame(width: frame.width, height: frame.height)
      .overlay {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .strokeBorder(
            isSelected ? theme.accent.accent.color : Color.clear, lineWidth: 1, antialiased: true)
      }
      .contentShape(Rectangle())
      .position(x: frame.midX, y: size.height - frame.midY)
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
          .onChanged { drag in
            if model.selectedID != widget.id { model.select(widget.id) }
            let x = saved.x + drag.translation.width / max(size.width, 1)
            let y = saved.y + drag.translation.height / max(size.height, 1)
            model.drag = .init(id: widget.id, x: min(max(x, 0), 1), y: min(max(y, 0), 1))
          }
          .onEnded { _ in model.endDrag() }
      )
      .onTapGesture { model.select(widget.id) }
  }
}

/// A widget drawn by the same view the desktop's widget window uses.
private struct WidgetDrawing: NSViewRepresentable {
  let drawing: DesktopWidgetRendering.Drawing
  let padding: CGFloat

  func makeNSView(context: Context) -> DesktopWidgetView { DesktopWidgetView() }

  func updateNSView(_ view: DesktopWidgetView, context: Context) {
    view.update(drawing: drawing, padding: padding)
  }
}
