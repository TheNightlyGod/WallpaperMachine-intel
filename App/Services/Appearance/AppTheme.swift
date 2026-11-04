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

  /// When the window wears the Halloween look (`Season.halloween`).
  enum Halloween: String {
    /// During Halloween week only (`Season.halloween.covers(_:in:)`).
    case automatic
    case always, off
  }

  enum Icon: String, CaseIterable {
    case minimal, day, night

    /// The asset catalog image set holding the 1024 px artwork.
    var imageName: String { "AppIcon" + rawValue.capitalized }

    func image(in bundle: Bundle = .main) throws -> NSImage {
      try AppThemePreferences.dockImage(named: imageName, in: bundle)
    }
  }

  var mode: Mode = .system
  var accent = "#80bbff"
  var tone: Tone = .neutral
  var icon: Icon = .day
  var halloween: Halloween = .automatic

  var snapshot: [String: Any] {
    [
      "mode": mode.rawValue, "accent": accent, "tone": tone.rawValue, "icon": icon.rawValue,
      "halloween": halloween.rawValue,
    ]
  }

  /// The seasonal look the window wears on `date` under these choices, nil for the person's own.
  func season(on date: Date, calendar: Calendar) -> Season? {
    switch halloween {
    case .automatic: Season.halloween.covers(date, in: calendar) ? .halloween : nil
    case .always: .halloween
    case .off: nil
    }
  }

  /// The 1024-pixel artwork of an asset catalog image set as a 512-point Dock icon.
  static func dockImage(named name: String, in bundle: Bundle = .main) throws -> NSImage {
    guard let source = bundle.image(forResource: NSImage.Name(name)) else {
      throw CocoaError(.fileNoSuchFile)
    }
    // The catalog hands out one shared instance; the Dock gets its own sized copy.
    guard source.isValid, let image = source.copy() as? NSImage else {
      throw CocoaError(.fileReadCorruptFile)
    }
    image.size = NSSize(width: 512, height: 512)
    return image
  }

  static func validAccent(_ value: String) -> Bool {
    value.utf8.count == 7 && value.first == "#"
      && value.utf8.dropFirst().allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }
  }
}

/// A look the window wears for a holiday instead of the person's own: its palettes and accent
/// (`PanelTheme`), the mark beside the traffic lights and the Dock icon. The person's choices are
/// kept and come back when it ends.
enum Season: String, Sendable {
  case halloween

  /// The accent while the season is on, fitted for contrast like any other (`AccentPalette`).
  var accent: String { "#ff7a1a" }

  /// The asset catalog image set of its Dock icon.
  var dockImageName: String { "AppIcon" + rawValue.capitalized }

  /// Whether `date` is in the season's week by the local calendar: October 24 to November 1.
  func covers(_ date: Date, in calendar: Calendar) -> Bool {
    let day = calendar.dateComponents([.month, .day], from: date)
    switch (day.month, day.day) {
    case (10?, let dayOfMonth?): return dayOfMonth >= 24
    case (11?, 1?): return true
    default: return false
    }
  }
}

/// Native storage survives the panel's ephemeral WebKit data store and process recovery.
@MainActor
final class AppThemeStore: ObservableObject {
  static let shared = AppThemeStore()
  nonisolated static let defaultsKey = "WallpaperMachine.appTheme"
  @Published private(set) var preferences: AppThemePreferences
  /// The seasonal look in effect, nil for the person's own: `preferences.halloween` read against
  /// today. It follows the preference, and the date when the day changes.
  @Published private(set) var season: Season?
  private let defaults: UserDefaults
  private let calendar: Calendar
  private let now: () -> Date
  private var dayChange: AnyCancellable?

  /// - Parameters:
  ///   - calendar, now: The days a season covers are read with these; tests pass a fixed date.
  init(
    defaults: UserDefaults = ClientPreferences.defaults, calendar: Calendar = .autoupdatingCurrent,
    now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.calendar = calendar
    self.now = now
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
    if let halloween = saved["halloween"] as? String,
      let value = AppThemePreferences.Halloween(rawValue: halloween)
    {
      preferences.halloween = value
    }
    self.preferences = preferences
    season = preferences.season(on: now(), calendar: calendar)
    // Posted when the calendar day changes, and on waking when it changed during sleep.
    dayChange = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshSeason() } }
  }

  /// The asset catalog image set the Dock shows: the season's while one is on, else the choice.
  var dockIconName: String { season?.dockImageName ?? preferences.icon.imageName }

  /// Reads the season again for today; the store does it itself when the day changes.
  func refreshSeason() {
    let current = preferences.season(on: now(), calendar: calendar)
    if current != season { season = current }
  }

  func setMode(_ mode: AppThemePreferences.Mode) { update { $0.mode = mode } }

  /// `hex` is `#rrggbb`; any other form is refused, as a control never offers one.
  func setAccent(_ hex: String) throws {
    guard AppThemePreferences.validAccent(hex) else { throw InvalidControlValue() }
    update { $0.accent = hex.lowercased() }
  }

  func setTone(_ tone: AppThemePreferences.Tone) { update { $0.tone = tone } }

  func setIcon(_ icon: AppThemePreferences.Icon) { update { $0.icon = icon } }

  func setHalloween(_ halloween: AppThemePreferences.Halloween) { update { $0.halloween = halloween } }

  /// Saves `change` and publishes it, unless it changes nothing.
  private func update(_ change: (inout AppThemePreferences) -> Void) {
    var next = preferences
    change(&next)
    guard next != preferences else { return }
    defaults.set(next.snapshot, forKey: Self.defaultsKey)
    preferences = next
    refreshSeason()
  }

  func reset() {
    defaults.removeObject(forKey: Self.defaultsKey)
    preferences = AppThemePreferences()
    refreshSeason()
  }
}
