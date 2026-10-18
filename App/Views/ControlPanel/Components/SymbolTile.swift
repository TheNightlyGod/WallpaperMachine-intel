import SwiftUI

/// A white filled SF Symbol on a coloured rounded square: the tile of a Settings section, as in
/// System Settings.
struct SymbolTile: View {
  /// The three sizes in use: the section list's row, a compact row and the page header.
  enum Size: CGFloat {
    case small = 20
    case medium = 28
    case large = 44
  }

  let systemImage: String
  let color: Color
  var size: Size = .medium

  var body: some View {
    let side = size.rawValue
    RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
      .fill(color.gradient)
      .frame(width: side, height: side)
      .overlay {
        Image(systemName: systemImage)
          .symbolVariant(.fill)
          .font(.system(size: side * 0.54, weight: .medium))
          .foregroundStyle(.white)
      }
      .accessibilityHidden(true)
  }
}
