import SwiftUI

/// The app's mark: a rounded square, open at its lower left, where a gear sits. The web panel drew
/// it as an SVG of 24 units; the two shapes here keep its coordinates and scale to the size asked
/// for, so it stays sharp at any size and takes the colour of what is around it.
///
/// In the Halloween season a carved pumpkin takes the gear's place, in the tint, its stem in the
/// frame's colour; the Dock icon draws the same pumpkin (`scripts/brand.py`).
struct AppMark: View {
  var size: CGFloat = 20
  var season: Season?

  var body: some View {
    let unit = size / 24
    ZStack {
      AppMarkFrame()
        .stroke(style: StrokeStyle(lineWidth: 2.9 * unit, lineCap: .round, lineJoin: .round))
      switch season {
      case .halloween:
        AppMarkPumpkinStem()
        AppMarkPumpkin().fill(.tint, style: FillStyle(eoFill: true))
      case nil:
        AppMarkGear().fill(style: FillStyle(eoFill: true))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// The jack-o'-lantern in the gear's place: three lobes side by side, with the eyes and the mouth
/// cut through, filled even-odd. In the mark's 24 units, like `brand.py`'s `PUMPKIN`.
private struct AppMarkPumpkin: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 24
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
    func lobe(_ cx: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
      let cy: CGFloat = 18.5
      return Path(
        ellipseIn: CGRect(
          x: rect.minX + (cx - rx) * scale, y: rect.minY + (cy - ry) * scale,
          width: rx * 2 * scale, height: ry * 2 * scale))
    }
    let body = lobe(5.9, 2.6, 3.7).union(lobe(3.85, 2.45, 3.3)).union(lobe(7.95, 2.45, 3.3))
    var face = Path()
    face.addLines([pt(3.6, 18.2), pt(4.72, 16.41), pt(5.42, 18.2)])
    face.closeSubpath()
    face.addLines([pt(8.2, 18.2), pt(7.08, 16.41), pt(6.38, 18.2)])
    face.closeSubpath()
    face.move(to: pt(3.33, 19.24))
    face.addLines([
      pt(4.29, 19.67), pt(4.86, 19.28), pt(5.9, 19.81), pt(6.94, 19.28), pt(7.51, 19.67),
      pt(8.47, 19.24),
    ])
    face.addQuadCurve(to: pt(3.33, 19.24), control: pt(5.9, 22.42))
    face.closeSubpath()
    var pumpkin = body
    pumpkin.addPath(face)
    return pumpkin
  }
}

/// The pumpkin's short, curled stem, above the middle lobe.
private struct AppMarkPumpkinStem: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 24
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
    var p = Path()
    p.move(to: pt(5.33, 15.15))
    p.addLine(to: pt(5.6, 13.85))
    p.addQuadCurve(to: pt(6.99, 13.41), control: pt(6.07, 13.15))
    p.addQuadCurve(to: pt(6.29, 14.11), control: pt(6.47, 13.67))
    p.addLine(to: pt(6.38, 15.15))
    p.closeSubpath()
    return p
  }
}

/// The square: from the bottom edge, round the right, top and left sides, stopping above the gear.
private struct AppMarkFrame: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 24
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
    var p = Path()
    p.move(to: pt(12.273, 20))
    p.addArc(tangent1End: pt(21, 20), tangent2End: pt(21, 16.4), radius: 3.6 * scale)
    p.addArc(tangent1End: pt(21, 3), tangent2End: pt(17.4, 3), radius: 3.6 * scale)
    p.addArc(tangent1End: pt(4, 3), tangent2End: pt(4, 6.6), radius: 3.6 * scale)
    p.addLine(to: pt(4, 11.727))
    return p
  }
}

/// The gear, with its hole, filled even-odd.
private struct AppMarkGear: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 24
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
    var p = Path()
    p.move(to: pt(9.706, 18.1))
    p.addQuadCurve(to: pt(9.952, 18.481), control: pt(9.706, 18.37))
    p.addLine(to: pt(10.735, 18.836))
    p.addQuadCurve(to: pt(10.959, 19.403), control: pt(11.121, 19.011))
    p.addLine(to: pt(10.398, 20.756))
    p.addQuadCurve(to: pt(9.839, 20.998), control: pt(10.236, 21.148))
    p.addLine(to: pt(9.034, 20.696))
    p.addQuadCurve(to: pt(8.592, 20.792), control: pt(8.782, 20.601))
    p.addLine(to: pt(8.592, 20.792))
    p.addQuadCurve(to: pt(8.496, 21.234), control: pt(8.401, 20.982))
    p.addLine(to: pt(8.798, 22.039))
    p.addQuadCurve(to: pt(8.556, 22.598), control: pt(8.948, 22.436))
    p.addLine(to: pt(7.203, 23.159))
    p.addQuadCurve(to: pt(6.636, 22.935), control: pt(6.811, 23.321))
    p.addLine(to: pt(6.281, 22.152))
    p.addQuadCurve(to: pt(5.9, 21.906), control: pt(6.17, 21.906))
    p.addLine(to: pt(5.9, 21.906))
    p.addQuadCurve(to: pt(5.519, 22.152), control: pt(5.63, 21.906))
    p.addLine(to: pt(5.164, 22.935))
    p.addQuadCurve(to: pt(4.597, 23.159), control: pt(4.989, 23.321))
    p.addLine(to: pt(3.244, 22.598))
    p.addQuadCurve(to: pt(3.002, 22.039), control: pt(2.852, 22.436))
    p.addLine(to: pt(3.304, 21.234))
    p.addQuadCurve(to: pt(3.208, 20.792), control: pt(3.399, 20.982))
    p.addLine(to: pt(3.208, 20.792))
    p.addQuadCurve(to: pt(2.766, 20.696), control: pt(3.018, 20.601))
    p.addLine(to: pt(1.961, 20.998))
    p.addQuadCurve(to: pt(1.402, 20.756), control: pt(1.564, 21.148))
    p.addLine(to: pt(0.841, 19.403))
    p.addQuadCurve(to: pt(1.065, 18.836), control: pt(0.679, 19.011))
    p.addLine(to: pt(1.848, 18.481))
    p.addQuadCurve(to: pt(2.094, 18.1), control: pt(2.094, 18.37))
    p.addLine(to: pt(2.094, 18.1))
    p.addQuadCurve(to: pt(1.848, 17.719), control: pt(2.094, 17.83))
    p.addLine(to: pt(1.065, 17.364))
    p.addQuadCurve(to: pt(0.841, 16.797), control: pt(0.679, 17.189))
    p.addLine(to: pt(1.402, 15.444))
    p.addQuadCurve(to: pt(1.961, 15.202), control: pt(1.564, 15.052))
    p.addLine(to: pt(2.766, 15.504))
    p.addQuadCurve(to: pt(3.208, 15.408), control: pt(3.018, 15.599))
    p.addLine(to: pt(3.208, 15.408))
    p.addQuadCurve(to: pt(3.304, 14.966), control: pt(3.399, 15.218))
    p.addLine(to: pt(3.002, 14.161))
    p.addQuadCurve(to: pt(3.244, 13.602), control: pt(2.852, 13.764))
    p.addLine(to: pt(4.597, 13.041))
    p.addQuadCurve(to: pt(5.164, 13.265), control: pt(4.989, 12.879))
    p.addLine(to: pt(5.519, 14.048))
    p.addQuadCurve(to: pt(5.9, 14.294), control: pt(5.63, 14.294))
    p.addLine(to: pt(5.9, 14.294))
    p.addQuadCurve(to: pt(6.281, 14.048), control: pt(6.17, 14.294))
    p.addLine(to: pt(6.636, 13.265))
    p.addQuadCurve(to: pt(7.203, 13.041), control: pt(6.811, 12.879))
    p.addLine(to: pt(8.556, 13.602))
    p.addQuadCurve(to: pt(8.798, 14.161), control: pt(8.948, 13.764))
    p.addLine(to: pt(8.496, 14.966))
    p.addQuadCurve(to: pt(8.592, 15.408), control: pt(8.401, 15.218))
    p.addLine(to: pt(8.592, 15.408))
    p.addQuadCurve(to: pt(9.034, 15.504), control: pt(8.782, 15.599))
    p.addLine(to: pt(9.839, 15.202))
    p.addQuadCurve(to: pt(10.398, 15.444), control: pt(10.236, 15.052))
    p.addLine(to: pt(10.959, 16.797))
    p.addQuadCurve(to: pt(10.735, 17.364), control: pt(11.121, 17.189))
    p.addLine(to: pt(9.952, 17.719))
    p.addQuadCurve(to: pt(9.706, 18.1), control: pt(9.706, 17.83))
    p.closeSubpath()
    let hole = 1.59 * scale
    let centre = pt(5.9, 18.1)
    p.addEllipse(
      in: CGRect(x: centre.x - hole, y: centre.y - hole, width: hole * 2, height: hole * 2))
    return p
  }
}
