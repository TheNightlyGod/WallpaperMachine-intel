import Foundation

/// The keys the inspector's controls start their actions under, so a control can disable itself on
/// `controller.isBusy(key)` and a repeat is dropped or chained the way the page's `send()` did.
///
/// A key names one control's work. The page keyed an action by `action:id:displayID:detail`; so
/// does `PanelActionCoordinator.key`. A control that sends many values (a slider, a field) starts
/// its action with `policy: .latestWins`, which waits for the pending value and then sends its own,
/// so the newest value always lands last: `property`, `engineOption`, `wallpaperSetting`,
/// `displayConfig` and `displayPosition`. Every other action keeps the default and a second click while one is pending
/// is ignored.
enum InspectorAction {
  /// Apply changes and Revert lock every property control while they run.
  static func apply(_ id: String) -> String { PanelActionCoordinator.key("apply", id: id) }
  static func revert(_ id: String) -> String { PanelActionCoordinator.key("revert", id: id) }

  /// A property's committed value (`.latestWins`).
  static func property(_ id: String, _ propertyID: String) -> String {
    PanelActionCoordinator.key("property", id: id, detail: propertyID)
  }
  static func restoreProperty(_ id: String, _ propertyID: String) -> String {
    PanelActionCoordinator.key("restoreProperty", id: id, detail: propertyID)
  }
  static func restoreAll(_ id: String) -> String {
    PanelActionCoordinator.key("restoreAllProperties", id: id)
  }
  /// A Wallpaper Engine option's committed value (`.latestWins`).
  static func engineOption(_ id: String, _ option: BridgeEngineOptionId) -> String {
    PanelActionCoordinator.key("engineOption", id: id, detail: "\(option)")
  }
  static func restoreEngineOption(_ id: String, _ option: BridgeEngineOptionId) -> String {
    PanelActionCoordinator.key("restoreEngineOption", id: id, detail: "\(option)")
  }
  static func restoreAllEngineOptions(_ id: String) -> String {
    PanelActionCoordinator.key("restoreAllEngineOptions", id: id)
  }
  /// Choosing or clearing a file, folder or texture.
  static func propertyPath(_ id: String, _ propertyID: String) -> String {
    PanelActionCoordinator.key("propertyPath", id: id, detail: propertyID)
  }

  /// One of the wallpaper's own settings: `volume`, `muted`, `audioResponseEnabled` or
  /// `mediaIntegrationEnabled` (`.latestWins`).
  static func wallpaperSetting(_ id: String, _ setting: String) -> String {
    PanelActionCoordinator.key("wallpaperSetting", id: id, detail: setting)
  }
  /// One display's setting for the wallpaper: `enabled`, `scalingMode`, `scalingFactor` or `fps`
  /// (`.latestWins`).
  static func displayConfig(_ id: String, display: String, _ setting: String) -> String {
    PanelActionCoordinator.key("displayConfig", id: id, displayID: display, detail: setting)
  }

  /// A position save or Center (`.latestWins`). Both axes share a key, so x and y of one display
  /// serialize.
  static func displayPosition(_ id: String, display: String) -> String {
    PanelActionCoordinator.key("displayPosition", id: id, displayID: display)
  }

  static func imagePlacement(_ id: String, display: String) -> String {
    PanelActionCoordinator.key("imagePlacement", id: id, displayID: display)
  }

  static func compatibilityCheck(_ id: String, display: String) -> String {
    PanelActionCoordinator.key("compatibilityCheck", id: id, displayID: display)
  }
  static func letterboxCheck(_ id: String, display: String) -> String {
    PanelActionCoordinator.key("videoLetterboxCheck", id: id, displayID: display)
  }
  static func letterboxStage(_ id: String, display: String) -> String {
    PanelActionCoordinator.key("videoLetterboxStage", id: id, displayID: display)
  }

  /// A preset action. Saving and importing are keyed by the wallpaper, the others by the preset.
  /// The presets bar disables itself while any of them is pending.
  static func preset(_ action: String, id: String) -> String {
    PanelActionCoordinator.key("wallpaperPreset\(action)", id: id)
  }
}
