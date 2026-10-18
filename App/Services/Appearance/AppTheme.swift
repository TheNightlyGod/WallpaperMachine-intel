import AppKit
import Combine

struct AppThemePreferences: Equatable {
  enum Mode: String {
    case system, light, dark

    var appearance: NSAppearance? {
      switch self {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
    }
  }

  enum Tone: String {
    case neutral, warm, cool
  }

  enum Icon: String, CaseIterable {
    case minimal, day, night

    /// The asset catalog image set holding the 1024 px artwork.
    var imageName: String { "AppIcon" + rawValue.capitalized }

    func image(in bundle: Bundle = .main) throws -> NSImage {
      guard let source = bundle.image(forResource: NSImage.Name(imageName)) else {
        throw CocoaError(.fileNoSuchFile)
      }
      // The catalog hands out one shared instance; the Dock gets its own sized copy.
      guard source.isValid, let image = source.copy() as? NSImage else {
        throw CocoaError(.fileReadCorruptFile)
      }
      image.size = NSSize(width: 512, height: 512)
      return image
    }
  }

  var mode: Mode = .system
  var accent = "#80bbff"
  var tone: Tone = .neutral
  var icon: Icon = .day

  var snapshot: [String: Any] {
    ["mode": mode.rawValue, "accent": accent, "tone": tone.rawValue, "icon": icon.rawValue]
  }

  static func validAccent(_ value: String) -> Bool {
    value.utf8.count == 7 && value.first == "#"
      && value.utf8.dropFirst().allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }
  }
}

/// Native storage survives the panel's ephemeral WebKit data store and process recovery.
@MainActor
final class AppThemeStore: ObservableObject {
  static let shared = AppThemeStore()
  static let defaultsKey = "WallpaperMachine.appTheme"
  @Published private(set) var preferences: AppThemePreferences
  private let defaults: UserDefaults

  init(defaults: UserDefaults = ClientPreferences.defaults) {
    self.defaults = defaults
    let saved = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
    var preferences = AppThemePreferences()
    if let mode = saved["mode"] as? String, let value = AppThemePreferences.Mode(rawValue: mode) {
      preferences.mode = value
    }
    if let accent = saved["accent"] as? String, AppThemePreferences.validAccent(accent) {
      preferences.accent = accent.lowercased()
    }
    if let tone = saved["tone"] as? String, let value = AppThemePreferences.Tone(rawValue: tone) {
      preferences.tone = value
    }
    if let icon = saved["icon"] as? String, let value = AppThemePreferences.Icon(rawValue: icon) {
      preferences.icon = value
    }
    self.preferences = preferences
  }

  func set(_ key: String, value: String) throws {
    var next = preferences
    switch key {
    case "mode":
      guard let mode = AppThemePreferences.Mode(rawValue: value) else {
        throw InvalidControlValue()
      }
      next.mode = mode
    case "accent":
      guard AppThemePreferences.validAccent(value) else { throw InvalidControlValue() }
      next.accent = value.lowercased()
    case "tone":
      guard let tone = AppThemePreferences.Tone(rawValue: value) else {
        throw InvalidControlValue()
      }
      next.tone = tone
    case "icon":
      guard let icon = AppThemePreferences.Icon(rawValue: value) else {
        throw InvalidControlValue()
      }
      next.icon = icon
    default: throw InvalidControlValue()
    }
    guard next != preferences else { return }
    defaults.set(next.snapshot, forKey: Self.defaultsKey)
    preferences = next
  }

  func reset() {
    defaults.removeObject(forKey: Self.defaultsKey)
    preferences = AppThemePreferences()
  }
}
