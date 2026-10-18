import AppKit
import SwiftUI

/// What a click on an Installed tile does. A plain click chooses the wallpaper for the inspector
/// and applies nothing; the second click of a double click applies it, without choosing a second
/// time first; Command, Control or Shift, or selection mode, tick the tile for a batch instead
/// (Shift extends from the anchor).
enum LibraryTileClick {
  enum Action: Equatable {
    /// Show it in the inspector.
    case select
    /// Apply it to the target display.
    case activate
    /// Tick or untick it for a batch action.
    case toggle
    /// Tick every tile from the anchor to this one.
    case extendRange
  }

  /// - Parameters:
  ///   - clickCount: 1 or 2 for a mouse; 0 for Return or Space on a focused tile, which is a click
  ///     with no modifiers.
  ///   - isSelecting: Selection mode is on. A plain click then ticks, and so does each click of a
  ///     double click.
  static func resolve(clickCount: Int, modifiers: NSEvent.ModifierFlags, isSelecting: Bool)
    -> Action
  {
    let extends = modifiers.contains(.shift)
    if isSelecting || extends || modifiers.contains(.command) || modifiers.contains(.control) {
      return extends ? .extendRange : .toggle
    }
    return clickCount == 2 ? .activate : .select
  }
}

/// The small marks a tile wears besides its own controls: Wallpaper Engine's green trophy for
/// staff-approved wallpapers, the heart of a favorite and the arrow of an update. They are read
/// out as part of the tile's label.
struct LibraryTileMarks: Equatable {
  var isApproved: Bool
  var isFavorite: Bool
  var hasUpdate: Bool

  init(_ row: LibraryRow, isFavorite: Bool) {
    isApproved = row.isApproved
    self.isFavorite = isFavorite
    hasUpdate = row.isUpdateAvailable
  }

  var isEmpty: Bool { !isApproved && !isFavorite && !hasUpdate }

  /// What VoiceOver reads after the title and the type, in the order the marks stack.
  @MainActor
  var names: [String] {
    var names: [String] = []
    if isApproved { names.append(L("Approved by Wallpaper Engine")) }
    if isFavorite { names.append(L("Favorite")) }
    if hasUpdate { names.append(L("Update available")) }
    return names
  }
}

/// Which of an Installed tile's own controls show, where its Active pill sits and how the tile is
/// marked out: the rules `InstalledTile` draws, apart from the view so they can be tested.
struct LibraryTileChrome: Equatable {
  /// The room the check takes at the leading corner, gap included, which the pill moves past while
  /// the check shows; the heart takes as much at the trailing corner.
  static var controlRoom: CGFloat { LibraryGridGeometry.controlSize + 4 }

  /// The check: on a ticked tile, on the one the pointer or the keyboard is on, on the one whose
  /// hold is arming, and on every tile while tiles are being ticked (selection mode, or anything
  /// ticked), so it is clear where to click.
  let showsCheck: Bool
  /// The heart: on a favorite, and on the tile the pointer or the keyboard is on. Ticking does not
  /// bring it out: a heart beside every check would only be in the way.
  let showsHeart: Bool
  /// How the tile is set apart. A ticked tile is ringed and dimmed; the one the inspector shows
  /// keeps the accent ring only while nothing is being ticked, and drops to a thin neutral ring
  /// meanwhile, so it is never taken for one more ticked tile before a Move to Trash.
  let emphasis: TileEmphasis

  init(
    isChecked: Bool, isChosen: Bool, isFavorite: Bool, isHovering: Bool, isFocused: Bool,
    isArming: Bool, isSelecting: Bool, hasSelection: Bool
  ) {
    let isTicking = isSelecting || hasSelection
    showsCheck = isChecked || isHovering || isFocused || isArming || isTicking
    showsHeart = isFavorite || isHovering || isFocused
    if isChecked {
      emphasis = .checked
    } else if isChosen {
      emphasis = isTicking ? .quietSelection : .selected
    } else {
      emphasis = .none
    }
  }

  /// How far the Active or Other display pill sits from the leading corner: at the corner, and past
  /// the check while the check shows, so the check never covers it.
  var pillLeadingInset: CGFloat { showsCheck ? Self.controlRoom : 0 }

  /// Whether the quiet picture glyph stands in for a missing cover. A status ring over the tile
  /// (applying, or waiting to be applied) replaces it rather than drawing on top of it.
  static func showsPlaceholder(hasCover: Bool, hasApplyState: Bool) -> Bool {
    !hasCover && !hasApplyState
  }
}

extension LibraryRow.Kind {
  /// The type as a person reads it, in the panel's language.
  @MainActor
  var label: String {
    switch self {
    case .scene: L("Scene")
    case .video: L("Video")
    case .web: L("Web")
    case .unknown: L("Unknown")
    }
  }
}

/// Which tile plays its animation: the one under the pointer once it has rested there, else the
/// one holding keyboard focus. Never more than one, and nothing while a button is held (a
/// selection drag), or from a focus that a click gave.
///
/// The target only says which tile is wanted; the page waits `dwell` before it loads anything, so
/// sweeping across tiles or tabbing quickly starts nothing.
struct LivePreviewTarget: Equatable, Sendable {
  /// How long the pointer or focus must rest on a tile before its animation loads.
  static let dwell = Duration.milliseconds(160)

  private(set) var pointer: String?
  private(set) var focus: String?

  /// The tile that is wanted: the pointer's, which wins over focus.
  var id: String? { pointer ?? focus }

  mutating func pointerEntered(_ id: String, isButtonDown: Bool) {
    pointer = isButtonDown ? nil : id
  }

  /// The pointer left `id`; a tile the pointer had already left for another does not clear it.
  mutating func pointerLeft(_ id: String) {
    if pointer == id { pointer = nil }
  }

  /// Focus arrived at or left `id`. Only focus that came from the keyboard counts.
  mutating func focusChanged(_ id: String, isFocused: Bool, byKeyboard: Bool) {
    if isFocused {
      focus = byKeyboard ? id : nil
    } else if focus == id {
      focus = nil
    }
  }

  /// Everything is released: the window lost focus, was hidden, or the page changed.
  mutating func reset() {
    pointer = nil
    focus = nil
  }
}
