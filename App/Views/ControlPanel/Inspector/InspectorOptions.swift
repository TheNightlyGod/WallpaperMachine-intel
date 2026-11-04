import Foundation

/// The selected wallpaper's options as the inspector draws them: its audio and media switches, one
/// card per display, and the authored property rows.
///
/// Built by `PanelController.inspectorOptions(for:)` from the bridge's options snapshot and the
/// panel's own overlay (text typed but not committed, a value chosen but not yet saved, the
/// measured files and folders, the delivery report of the running host), so a control always shows
/// what the user last did. `make` is the pure factory the tests drive.
struct InspectorOptions: Equatable {
  let wallpaperID: String
  let kind: BridgeWallpaperKind
  /// False for a wallpaper this Mac cannot render: everything stays visible, but Apply, Restore all
  /// and the position rows are unavailable.
  let isSupported: Bool
  /// The bridge holds edits Apply changes would save and Revert would undo.
  let isDirty: Bool
  /// Text typed into a property, or a value just chosen, that the bridge has not taken yet.
  let hasUnsentChanges: Bool
  /// A command is running or waiting, or this wallpaper is being applied or reverted: every control
  /// that changes the wallpaper's properties waits, except the Position sliders and Center, which
  /// queue (a disabled slider would drop the keyboard focus the next arrow key needs).
  let isLocked: Bool
  /// The wallpaper's own volume, from 0 to 1.
  let volume: Double
  let isMuted: Bool
  /// The user's settings; the delivery report never overwrites them.
  let audioResponseEnabled: Bool
  let mediaIntegrationEnabled: Bool
  /// A value that a visibility rule hides is modified: the inspector is not given its row, yet the
  /// value still reaches the wallpaper, so Restore all defaults has to know of it.
  let hiddenModified: Bool
  let delivery: DeliveryReport
  let displays: [DisplayRow]
  /// The enabled properties in the author's order. A property a visibility rule hides is not
  /// listed. Group and description rows can still have no words: the inspector's label renderer
  /// decides that and leaves them out.
  let properties: [PropertyRow]
  /// Wallpaper Engine's per-wallpaper options (colour adjustments, image filter, flip, mouse
  /// parallax, playback rate), the enabled ones in Wallpaper Engine's order; nil for a wallpaper
  /// that has none (a web page).
  var engineOptions: [EngineOptionRow]? = nil
  /// A modified option whose row is not listed because its switch is off (a colour slider with
  /// the colour adjustments off, the filter strength with no filter): its value is saved, so
  /// Restore all defaults has to know of it.
  var engineHiddenModified = false

  /// Whether Apply changes and Revert have anything to act on.
  var hasChanges: Bool { isDirty || hasUnsentChanges }
  var canRevert: Bool { !isLocked && hasChanges }
  var canApply: Bool { !isLocked && hasChanges && isSupported }

  /// Restore all defaults stages every default except chosen files and folders, which keep their
  /// own Clear. A modified value behind a hiding rule counts, though its row is not listed.
  var canRestoreAll: Bool {
    guard !isLocked, isSupported else { return false }
    return hasUnsentChanges || hiddenModified
      || properties.contains { $0.isDirty && !$0.control.isChosenPath }
  }

  /// The Wallpaper Engine options' own Restore all defaults: a modified option, listed or not, or a
  /// value on its way.
  var canRestoreAllEngineOptions: Bool {
    guard !isLocked, isSupported, let engineOptions else { return false }
    return hasUnsentChanges || engineHiddenModified || engineOptions.contains { $0.row.isModified }
  }

  /// Scene and video wallpapers can be moved on a display; a still image page is a web wallpaper and
  /// keeps its own Position on screen, and a web page always fills its window.
  var offersPosition: Bool {
    isSupported && (kind == .projectScene || kind == .video)
  }

  /// Whether Media integration is offered: only for the wallpaper kinds that can read track details.
  var offersMediaIntegration: Bool { kind == .webpage || kind == .projectScene }
}

// MARK: - Displays

extension InspectorOptions {
  /// One display's playback of this wallpaper. Enabled, Scaling mode and Frame rate are saved at
  /// once; the Scale factor is a draft that waits for Apply changes.
  struct DisplayRow: Equatable, Identifiable {
    let id: String
    let title: String
    let isEnabled: Bool
    let scalingMode: BridgeScalingMode
    let scalingFactor: Double
    let frameRate: Int
    /// The highest frame rate the display offers; 0 when it did not say.
    let maximumFrameRate: Int
    let position: Position
    /// macOS's own video player draws this wallpaper on the display, at the clip's own frame rate,
    /// so the display's frame rate and any ceiling on it do not apply to it.
    let isDrawnByNativePlayer: Bool
    /// The frame-rate ceiling in force, and what sets it, when it is below the saved frame rate.
    let frameRateLimit: FrameRateCeiling?
  }

  /// Where the wallpaper sits on a display: fractions from 0 (left, top) to 1 (right, bottom) of
  /// the room the display leaves around it.
  struct Position: Equatable {
    let x: Double
    let y: Double

    static let centered = Position(x: 0.5, y: 0.5)
    var isCentered: Bool { x == 0.5 && y == 0.5 }

    /// A value from the bridge held to 0...1; one that is not a number reads as centred.
    init(x: Double, y: Double) {
      func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.5 }
      self.x = clamped(x)
      self.y = clamped(y)
    }
  }
}
