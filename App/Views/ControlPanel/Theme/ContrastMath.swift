import Foundation

/// The colour arithmetic behind `AccentPalette`, ported from `WebUI/theme.js`: WCAG contrast
/// and hue-preserving lightness fitting on packed `0xrrggbb` values. The operations and their
/// order are the original's so the results match it to the digit.
enum ContrastMath {
  /// sRGB channel value to linear light.
  private static let linear: [Double] = (0..<256).map { value in
    let channel = Double(value) / 255
    return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
  }

  struct HSL {
    var hue: Double
    var saturation: Double
    var lightness: Double
  }

  static func luminance(_ rgb: UInt32) -> Double {
    0.2126 * linear[Int((rgb >> 16) & 255)] + 0.7152 * linear[Int((rgb >> 8) & 255)]
      + 0.0722 * linear[Int(rgb & 255)]
  }

  static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la = luminance(a) + 0.05
    let lb = luminance(b) + 0.05
    return la > lb ? la / lb : lb / la
  }

  static func hsl(_ rgb: UInt32) -> HSL {
    let r = Double((rgb >> 16) & 255) / 255
    let g = Double((rgb >> 8) & 255) / 255
    let b = Double(rgb & 255) / 255
    let high = r > g ? (r > b ? r : b) : (g > b ? g : b)
    let low = r < g ? (r < b ? r : b) : (g < b ? g : b)
    let span = high - low
    let lightness = (high + low) / 2
    var hue = 0.0
    var saturation = 0.0
    if span > 0 {
      saturation = lightness > 0.5 ? span / (2 - high - low) : span / (high + low)
      if high == r {
        hue = (g - b) / span + (g < b ? 6 : 0)
      } else if high == g {
        hue = (b - r) / span + 2
      } else {
        hue = (r - g) / span + 4
      }
      hue /= 6
    }
    return HSL(hue: hue, saturation: saturation, lightness: lightness)
  }

  private static func hueChannel(_ p: Double, _ q: Double, _ turn: Double) -> Double {
    var t = turn
    if t < 0 { t += 1 }
    if t > 1 { t -= 1 }
    if t < 1.0 / 6 { return p + (q - p) * 6 * t }
    if t < 0.5 { return q }
    if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
    return p
  }

  /// Back to a packed colour, rounding every channel as `Math.round` does.
  static func pack(_ hue: Double, _ saturation: Double, _ lightness: Double) -> UInt32 {
    let r: Double
    let g: Double
    let b: Double
    if saturation == 0 {
      (r, g, b) = (lightness, lightness, lightness)
    } else {
      let q =
        lightness < 0.5
        ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
      let p = 2 * lightness - q
      r = hueChannel(p, q, hue + 1.0 / 3)
      g = hueChannel(p, q, hue)
      b = hueChannel(p, q, hue - 1.0 / 3)
    }
    func channel(_ value: Double) -> UInt32 { UInt32(max(0, (value * 255).rounded())) }
    return (channel(r) << 16) | (channel(g) << 8) | channel(b)
  }

  static func shiftLightness(_ rgb: UInt32, by delta: Double) -> UInt32 {
    let color = hsl(rgb)
    return pack(color.hue, color.saturation, min(1, max(0, color.lightness + delta)))
  }

  /// Moves `rgb` along its own lightness axis, hue and saturation kept, until it clears `ratio`
  /// against `ref` while staying as close to the input as possible. The direction is whichever
  /// endpoint reaches further, so black accents brighten and white ones darken without special cases.
  static func fit(_ rgb: UInt32, against ref: UInt32, ratio: Double) -> UInt32 {
    if contrast(rgb, ref) >= ratio { return rgb }
    let color = hsl(rgb)
    let up =
      contrast(pack(color.hue, color.saturation, 1), ref)
      >= contrast(pack(color.hue, color.saturation, 0), ref)
    var low = up ? color.lightness : 0
    var high = up ? 1 : color.lightness
    var best = pack(color.hue, color.saturation, up ? high : low)
    if contrast(best, ref) < ratio { return best }
    for _ in 0..<14 {
      let mid = (low + high) / 2
      let candidate = pack(color.hue, color.saturation, mid)
      if contrast(candidate, ref) >= ratio {
        best = candidate
        if up { high = mid } else { low = mid }
      } else if up {
        low = mid
      } else {
        high = mid
      }
    }
    return best
  }
}
