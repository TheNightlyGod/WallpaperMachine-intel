import SwiftUI

/// Draws a parsed author label: headings and paragraphs as styled text, rules, and the images the
/// app registered. Links are runs of the text; opening one goes through `ExternalLink` (the root of
/// the inspector sets the `openURL` handler), and a link to anywhere the parser did not allow is not
/// a link at all.
struct PropertyLabelView: View {
  let document: PropertyLabelDocument
  /// The size body text is drawn at; headings and `<big>` scale from it.
  var baseSize: CGFloat = 13
  /// Draw plain runs in this weight (a group's heading is semibold).
  var baseWeight = Font.Weight.regular
  var color: Color?

  @Environment(\.panelTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .paragraph(let paragraph):
          ParagraphView(
            paragraph: paragraph, baseSize: baseSize, baseWeight: baseWeight,
            color: color ?? theme.surface.text.color, accent: theme.accent.accent.color)
        case .image(let image):
          PropertyLabelImageView(image: image)
        case .rule:
          Rectangle().fill(theme.surface.line.color).frame(height: 0.5).padding(.vertical, 2)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private struct ParagraphView: View {
    let paragraph: PropertyLabelDocument.Paragraph
    let baseSize: CGFloat
    let baseWeight: Font.Weight
    let color: Color
    let accent: Color

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        if let marker = paragraph.marker {
          Text(verbatim: marker).font(.system(size: baseSize)).foregroundStyle(color)
        }
        Text(
          PropertyLabelView.attributed(
            paragraph, baseSize: baseSize, baseWeight: baseWeight, accent: accent)
        )
        .foregroundStyle(color)
        .multilineTextAlignment(paragraph.isCentered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: paragraph.isCentered ? .center : .leading)
        .textSelection(.enabled)
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(paragraph.heading == nil ? [] : .isHeader)
    }
  }

  // MARK: Text

  /// Relative sizes of the heading levels, kept modest for a column that is only a few hundred
  /// points wide.
  private static let headingScale: [Int: Double] = [1: 1.35, 2: 1.25, 3: 1.15, 4: 1.08, 5: 1, 6: 0.95]

  /// The paragraph as attributed text. Colour is the author's when it is a valid spelling.
  static func attributed(
    _ paragraph: PropertyLabelDocument.Paragraph, baseSize: CGFloat, baseWeight: Font.Weight,
    accent: Color
  ) -> AttributedString {
    var result = AttributedString()
    let headingScale = paragraph.heading.flatMap { Self.headingScale[$0] } ?? 1
    for run in paragraph.runs {
      var piece = AttributedString(run.text)
      let size = baseSize * min(1.8, max(0.7, run.scale * headingScale))
      var font = Font.system(
        size: size, weight: run.isBold || paragraph.heading != nil ? .bold : baseWeight)
      if run.isItalic { font = font.italic() }
      piece.font = font
      if run.isUnderlined { piece.underlineStyle = .single }
      if run.isStruck { piece.strikethroughStyle = .single }
      switch run.baseline {
      case .normal: break
      case .subscripted: piece.baselineOffset = -size * 0.2
      case .superscripted: piece.baselineOffset = size * 0.35
      }
      if let spelling = run.color, let resolved = LabelColor.resolve(spelling) {
        piece.foregroundColor = resolved
      } else if run.isAccented {
        piece.foregroundColor = accent
      }
      if let link = run.link { piece.link = link }
      result += piece
    }
    return result
  }
}

/// The colours an author may name: a hex value or one of the common CSS names. Anything else is
/// ignored and the text keeps the panel's colour.
enum LabelColor {
  private static let named: [String: UInt32] = [
    "black": 0x000000, "white": 0xffffff, "red": 0xff0000, "green": 0x008000, "blue": 0x0000ff,
    "yellow": 0xffff00, "orange": 0xffa500, "purple": 0x800080, "pink": 0xffc0cb, "gray": 0x808080,
    "grey": 0x808080, "cyan": 0x00ffff, "aqua": 0x00ffff, "magenta": 0xff00ff, "fuchsia": 0xff00ff,
    "lime": 0x00ff00, "maroon": 0x800000, "navy": 0x000080, "olive": 0x808000, "teal": 0x008080,
    "silver": 0xc0c0c0, "gold": 0xffd700, "brown": 0xa52a2a, "violet": 0xee82ee,
    "indigo": 0x4b0082, "crimson": 0xdc143c, "coral": 0xff7f50, "salmon": 0xfa8072,
    "tomato": 0xff6347, "skyblue": 0x87ceeb, "lightblue": 0xadd8e6, "lightgreen": 0x90ee90,
    "darkred": 0x8b0000, "darkblue": 0x00008b, "darkgreen": 0x006400, "orchid": 0xda70d6,
    "turquoise": 0x40e0d0, "khaki": 0xf0e68c, "tan": 0xd2b48c, "chocolate": 0xd2691e,
    "hotpink": 0xff69b4, "deeppink": 0xff1493, "royalblue": 0x4169e1, "steelblue": 0x4682b4,
    "dodgerblue": 0x1e90ff, "limegreen": 0x32cd32, "seagreen": 0x2e8b57, "firebrick": 0xb22222,
    "gainsboro": 0xdcdcdc, "lightgray": 0xd3d3d3, "lightgrey": 0xd3d3d3, "darkgray": 0xa9a9a9,
    "darkgrey": 0xa9a9a9, "dimgray": 0x696969, "dimgrey": 0x696969,
  ]

  /// The sRGB components of an author's spelling, or nil when it is not one the panel reads.
  static func components(_ spelling: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
    let value = spelling.trimmingCharacters(in: .whitespaces).lowercased()
    if value.hasPrefix("#") {
      let digits = value.dropFirst()
      guard digits.allSatisfy(\.isHexDigit) else { return nil }
      let expanded: String
      switch digits.count {
      case 3, 4: expanded = digits.map { "\($0)\($0)" }.joined()
      case 6, 8: expanded = String(digits)
      default: return nil
      }
      guard let number = UInt64(expanded, radix: 16) else { return nil }
      let hasAlpha = expanded.count == 8
      let red = Double((number >> (hasAlpha ? 24 : 16)) & 255) / 255
      let green = Double((number >> (hasAlpha ? 16 : 8)) & 255) / 255
      let blue = Double((number >> (hasAlpha ? 8 : 0)) & 255) / 255
      let alpha = hasAlpha ? Double(number & 255) / 255 : 1
      return (red, green, blue, alpha)
    }
    guard let rgb = named[value] else { return nil }
    return (
      Double((rgb >> 16) & 255) / 255, Double((rgb >> 8) & 255) / 255, Double(rgb & 255) / 255, 1
    )
  }

  static func resolve(_ spelling: String) -> Color? {
    components(spelling).map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) }
  }
}

/// An image of a label, drawn at the size the author asked for within the width it is given.
struct PropertyLabelImageView: View {
  let image: PropertyLabelDocument.Image

  @Environment(\.panelImages) private var images
  @Environment(\.displayScale) private var displayScale
  @Environment(\.panelTheme) private var theme
  @State private var loaded: DecodedPanelImage?

  var body: some View {
    let content = ImageBoxLayout(
      aspect: aspect, width: image.width, height: image.height, naturalWidth: naturalWidth
    ) {
      ZStack {
        if let loaded {
          Image(decorative: loaded.cgImage, scale: 1).resizable()
        } else {
          theme.surface.mediaWell.color
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: image.isCentered ? .center : .leading)
    .task(id: image.url) { await load() }
    if let link = image.link {
      Button {
        ExternalLink.open(link)
      } label: {
        content
      }
      .buttonStyle(.plain)
      .accessibilityLabel(image.alt.isEmpty ? (link.host ?? "") : image.alt)
    } else {
      content.accessibilityLabel(image.alt).accessibilityAddTraits(.isImage)
    }
  }

  private var aspect: Double {
    guard let loaded, loaded.pixelSize.height > 0 else { return 1 }
    return loaded.pixelSize.width / loaded.pixelSize.height
  }

  private var naturalWidth: CGFloat? {
    loaded.map { $0.pixelSize.width / max(1, displayScale) }
  }

  private func load() async {
    guard let images else { return }
    let request = PanelImageSource.propertyImage(image.url)
    if let cached = images.cachedImage(for: request, maxPixelSize: 1200) {
      loaded = cached
      return
    }
    loaded = try? await images.image(for: request, maxPixelSize: 1200)
  }
}

/// Sizes its one child like an `<img>`: the requested width (a share of the line or points), else
/// its own width, at most the width offered; height from the requested height or the picture's
/// proportions.
private struct ImageBoxLayout: Layout {
  var aspect: Double
  var width: PropertyLabelDocument.Width?
  var height: Int?
  var naturalWidth: CGFloat?

  func size(in available: CGFloat) -> CGSize {
    var w: CGFloat
    switch width {
    case .percent(let percent)?: w = available * CGFloat(percent / 100)
    case .pixels(let pixels)?: w = min(CGFloat(pixels), available)
    case nil: w = min(naturalWidth ?? available, available)
    }
    var h = w / CGFloat(max(0.01, aspect))
    if let height {
      h = CGFloat(height)
      if width == nil { w = min(available, h * CGFloat(aspect)) }
    }
    return CGSize(width: max(1, w), height: max(1, h))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    size(in: proposal.width ?? naturalWidth ?? 120)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let box = size(in: bounds.width)
    subviews.first?.place(
      at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(box))
  }
}
