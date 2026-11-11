import SwiftUI

/// A drawn miniature of a window, as the picture cards of Appearance show a mode or a tone: a
/// sidebar bar, a line in the accent and two quieter lines; a season's also has its moon and its
/// horizon along the bottom.
///
/// `split` draws a second look on the lower-right half, cut on the diagonal, which is how System
/// shows light and dark at once. The colours are fixed by the caller (`SurfacePalette.miniature`),
/// never taken from the current theme, so a card shows the look it stands for whatever look the
/// panel has.
struct SettingsMiniWindow: View {
  /// The size of the drawing, in points.
  static let size = CGSize(width: 86, height: 56)

  let miniature: SurfacePalette.Miniature
  var split: SurfacePalette.Miniature?
  let accent: Color
  /// The accent of the `split` half when it shows a look with its own (a season's).
  var splitAccent: Color?

  @Environment(\.panelTheme) private var theme

  var body: some View {
    ZStack {
      layer(miniature, accent: accent)
      if let split {
        layer(split, accent: splitAccent ?? accent).mask(LowerRightHalf())
      }
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(theme.surface.line.color, lineWidth: 0.5)
    }
    .accessibilityHidden(true)
  }

  private func layer(_ look: SurfacePalette.Miniature, accent: Color) -> some View {
    ZStack(alignment: .topLeading) {
      look.background.color
      look.bar.color.frame(width: 22)
      line(look.line, width: 38).offset(x: 30, y: 12)
      line(look.line, width: 28).offset(x: 30, y: 24)
      line(look.line, width: 34).offset(x: 30, y: 36)
      line(accent, width: 38).offset(x: 30, y: 12)
      if let moon = look.moon {
        Circle().fill(moon.color).frame(width: 9, height: 9).offset(x: 72, y: 6)
        MiniHills()
          .fill(SeasonHorizon.ink.color)
          .frame(width: Self.size.width, height: 10)
          .offset(y: Self.size.height - 10)
      }
    }
    .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
  }

  private func line(_ color: PanelColor, width: CGFloat) -> some View {
    line(color.color, width: width)
  }

  private func line(_ color: Color, width: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 2, style: .continuous)
      .fill(color)
      .frame(width: width, height: 5)
  }
}

/// The season's rolling hills at the size of a miniature.
private struct MiniHills: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
    path.addQuadCurve(
      to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.45),
      control: CGPoint(x: rect.width * 0.22, y: rect.minY - rect.height * 0.1))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.3),
      control: CGPoint(x: rect.width * 0.78, y: rect.minY + rect.height * 0.9))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// The half of a rectangle below the diagonal from its top-right to its bottom-left corner.
private struct LowerRightHalf: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}
