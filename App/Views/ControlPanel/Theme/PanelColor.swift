import SwiftUI

/// An sRGB colour with an exact `#rrggbb` form, so tokens can be compared and written back
/// without the rounding a `Color` round trip adds.
struct PanelColor: Equatable, Hashable, Sendable {
  let rgb: UInt32
  /// Opacity from 0 to 1; the surface tokens that are overlays (dividers, hover) are not opaque.
  let alpha: Double

  init(rgb: UInt32, alpha: Double = 1) {
    self.rgb = rgb & 0xff_ffff
    self.alpha = alpha
  }

  /// Six hex digits after `#`, either case; nil for anything else.
  init?(hex: String) {
    guard AppThemePreferences.validAccent(hex), let value = UInt32(hex.dropFirst(), radix: 16)
    else { return nil }
    self.init(rgb: value)
  }

  /// Lowercase `#rrggbb`; the opacity is not part of it.
  var hex: String {
    let digits = String(rgb, radix: 16)
    return "#" + String(repeating: "0", count: 6 - digits.count) + digits
  }

  var color: Color {
    Color(
      .sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
      blue: Double(rgb & 255) / 255, opacity: alpha)
  }

  /// WCAG contrast ratio against another opaque colour, from 1 to 21.
  func contrast(with other: PanelColor) -> Double {
    ContrastMath.contrast(rgb, other.rgb)
  }
}
