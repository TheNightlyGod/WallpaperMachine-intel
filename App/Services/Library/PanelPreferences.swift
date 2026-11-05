import Foundation

/// The panel's own persisted choices.
///
/// The key strings are what earlier builds wrote, and what `AppDelegate`, the backup allow-list
/// and the What's New rule read, so none of them may change. Every reader takes the defaults it
/// should look in; production passes `ClientPreferences.defaults`, tests a `TemporaryDefaults`.
enum PanelPreferences {
  /// Whether the first-run welcome has been read, skipped or simply used past. Also read by
  /// `ControlPanelLaunch` (a login launch stays in the menu bar once set up) and by What's New.
  static let welcomeSeenKey = "WallpaperMachine.welcomeSeen"
  /// The favorite wallpaper ids: the JSON of the sorted `[String]`, not a property-list array.
  static let favoritesKey = "WallpaperMachine.favoriteWallpaperIDs"
  /// Whether the user swept across tiles to select them, or dismissed the tip that teaches it.
  static let dragSelectLearnedKey = "WallpaperMachine.dragSelectLearned"
  /// Whether applying a wallpaper hides the app so the result is visible.
  static let hideAfterActivatingKey = "WallpaperMachine.hideAfterActivating"
  /// Whether Library tiles play their animated preview only while the pointer rests on one (or
  /// keyboard focus is on it), instead of every tile on screen playing.
  static let libraryPreviewsOnHoverKey = "WallpaperMachine.libraryPreviewsOnHover"
  /// How far the tile grids are zoomed: a step of `TileZoom.steps`, 0 the standard size.
  static let tileZoomKey = "WallpaperMachine.tileZoom"
  /// Earlier builds stored a dragged inspector width here; the width now follows the window
  /// alone, so the key is removed rather than read.
  static let legacyInspectorWidthKey = "WallpaperMachine.inspectorWidth"

  static func welcomeSeen(in defaults: UserDefaults = ClientPreferences.defaults) -> Bool {
    defaults.bool(forKey: welcomeSeenKey)
  }

  static func markWelcomeSeen(in defaults: UserDefaults) {
    defaults.set(true, forKey: welcomeSeenKey)
  }

  static func dragSelectLearned(in defaults: UserDefaults = ClientPreferences.defaults) -> Bool {
    defaults.bool(forKey: dragSelectLearnedKey)
  }

  static func markDragSelectLearned(in defaults: UserDefaults) {
    defaults.set(true, forKey: dragSelectLearnedKey)
  }

  /// Off unless turned on, so the panel stays open until the user closes it.
  static func hidesAfterActivating(in defaults: UserDefaults = ClientPreferences.defaults) -> Bool {
    defaults.object(forKey: hideAfterActivatingKey) as? Bool ?? false
  }

  /// Off unless turned on, so every Library tile on screen plays its animated preview, as the
  /// Workshop's grid does.
  static func playsLibraryPreviewsOnHover(
    in defaults: UserDefaults = ClientPreferences.defaults
  ) -> Bool {
    defaults.object(forKey: libraryPreviewsOnHoverKey) as? Bool ?? false
  }

  /// The tile zoom step, held to the steps there are; anything unreadable is the standard size.
  static func tileZoom(in defaults: UserDefaults = ClientPreferences.defaults) -> Int {
    TileZoom.clamped(defaults.object(forKey: tileZoomKey) as? Int ?? 0)
  }

  static func setTileZoom(_ zoom: Int, in defaults: UserDefaults) {
    let zoom = TileZoom.clamped(zoom)
    if zoom == 0 { defaults.removeObject(forKey: tileZoomKey) } else { defaults.set(zoom, forKey: tileZoomKey) }
  }

  /// The favorites; anything unreadable is an empty set rather than a failure.
  static func favorites(in defaults: UserDefaults = ClientPreferences.defaults) -> Set<String> {
    Set(
      (try? JSONDecoder().decode([String].self, from: defaults.data(forKey: favoritesKey) ?? Data()))
        ?? [])
  }

  /// Posted after the favorites are saved, so the control panel and the menu bar panel, which
  /// can each change them, show what the other saved.
  static let favoritesDidChangeNotification = Notification.Name("WallpaperMachine.favoritesDidChange")

  static func saveFavorites(_ ids: Set<String>, in defaults: UserDefaults) throws {
    defaults.set(try JSONEncoder().encode(ids.sorted()), forKey: favoritesKey)
    NotificationCenter.default.post(name: favoritesDidChangeNotification, object: nil)
  }

  /// Adds `id` to the favorites, or takes it out when it is one; returns whether it is one now.
  @discardableResult
  static func toggleFavorite(_ id: String, in defaults: UserDefaults) throws -> Bool {
    var ids = favorites(in: defaults)
    let added = ids.insert(id).inserted
    if !added { ids.remove(id) }
    try saveFavorites(ids, in: defaults)
    return added
  }

  /// The one-time cleanup of keys earlier builds left behind; harmless to run on every start.
  static func removeLegacyKeys(from defaults: UserDefaults) {
    defaults.removeObject(forKey: legacyInspectorWidthKey)
  }
}
