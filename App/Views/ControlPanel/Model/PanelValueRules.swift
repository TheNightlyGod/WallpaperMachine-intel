import Foundation

/// The ranges the inspector's controls offer, and the refusal for a value outside them.
///
/// The web panel's requests were untyped, so every number was checked on arrival and a value outside
/// its range was refused rather than moved to the nearest edge: a control only ever offers values
/// inside the range, so an outlier is a stale or forged control and not something to nudge into
/// a choice nobody made. Typed parameters make the type checks disappear and leave these.
enum PanelValueRules {
  /// A text property's longest value, in characters.
  static let maximumTextLength = 65_536

  /// A position or placement axis: a finite fraction from 0 to 1.
  static func fraction(_ value: Double) throws -> Double {
    guard value.isFinite, (0...1).contains(value) else { throw InvalidControlValue() }
    return value
  }

  /// A wallpaper's volume: a finite fraction from 0 to 1.
  static func volume(_ value: Double) throws -> Float {
    Float(try fraction(value))
  }

  /// A scale factor: finite and greater than zero.
  static func scalingFactor(_ value: Double) throws -> Double {
    guard value.isFinite,
      (Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude).contains(value)
    else { throw InvalidControlValue() }
    return value
  }

  /// A display's frame rate for one wallpaper: a whole number from 1 to the display's maximum, which
  /// is never read as less than 1.
  static func frameRate(_ value: Int, maximum: UInt32) throws -> UInt32 {
    guard (1...Int(max(1, maximum))).contains(value) else { throw InvalidControlValue() }
    return UInt32(value)
  }
}
