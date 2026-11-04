import SwiftUI

/// A small round mark over a tile's preview picture (approved, favorite, update available…):
/// one look for the Library and the Workshop, a glyph on a disc that reads over any picture.
struct TileMarkChip: View {
  let systemImage: String
  let glyph: Color
  let fill: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 9.5, weight: .bold))
      .foregroundStyle(glyph)
      .frame(width: 20, height: 20)
      .background(fill, in: Circle())
  }
}
