import Foundation

/// The window's Now Playing bar: what the target display shows and which controls work.
///
/// Play and pause act on every display, so the status line reports them even when the target is
/// empty, and the toggle works while any display has a wallpaper. Previous and Next act on the
/// target display only.
struct NowPlayingState: Equatable {
  /// The target display's name; empty when the target is not in the display list.
  var displayTitle: String
  /// The wallpaper the target display shows, when it is in the library. A wallpaper that is not
  /// installed leaves the card empty even though the display has an assignment.
  var item: LibraryRow?
  /// Whether any display shows a wallpaper.
  var hasWallpaper: Bool
  var isPaused: Bool
  /// The card's title: the wallpaper's, or that the display shows nothing.
  var title: String
  /// "No wallpaper playing", "Playback paused" or "Playback running".
  var status: String
  /// The line under the title: the status, or what to do when nothing plays anywhere.
  var detail: String
  /// The title bar tooltip of the card.
  var help: String
  /// "Now playing on {display}".
  var accessibilityLabel: String
  /// "Show {title} in your library" for the artwork button; nil with no wallpaper.
  var showInLibraryLabel: String?
  /// The toggle's label: what pressing it does.
  var playbackLabel: String
  /// The toggle shows Play when nothing plays or playback is paused, Pause otherwise.
  var showsPlay: Bool
  /// The equalizer runs only while the shown wallpaper plays.
  var isEqualizerRunning: Bool
  /// The toggle is locked while a command runs, and without any wallpaper to play or pause.
  var canTogglePlayback: Bool
  /// Previous needs a previous wallpaper on a display that can show its own.
  var canGoPrevious: Bool
  /// Next needs such a display and a supported wallpaper other than the one it shows.
  var canGoNext: Bool

  /// - Parameters:
  ///   - target: The display being targeted; nil if it is no longer in the display list.
  ///   - item: The library row of the target's wallpaper.
  ///   - hasWallpaper: Whether any display shows a wallpaper.
  ///   - hasOtherWallpaper: Whether the library holds a supported wallpaper other than the
  ///     target's own.
  ///   - previousID: The wallpaper Previous would apply.
  ///   - isBusy: A command runs, or a wallpaper is being applied.
  @MainActor
  static func make(
    target: TargetDisplayOption?, item: LibraryRow?, hasWallpaper: Bool, hasOtherWallpaper: Bool,
    previousID: String?, isPaused: Bool, isBusy: Bool
  ) -> NowPlayingState {
    let isUsable = target?.isSelectable ?? false
    let status =
      !hasWallpaper
      ? L("No wallpaper playing") : isPaused ? L("Playback paused") : L("Playback running")
    let display = target?.title ?? ""
    return NowPlayingState(
      displayTitle: display, item: item, hasWallpaper: hasWallpaper, isPaused: isPaused,
      title: item?.title ?? L("Nothing on this display"), status: status,
      detail: hasWallpaper ? status : L("Pick a wallpaper and press Play to show it here."),
      help: item == nil ? status : "\(display) · \(status)",
      accessibilityLabel: L("Now playing on \(display)"),
      showInLibraryLabel: item.map { L("Show \($0.title) in your library") },
      playbackLabel: !hasWallpaper
        ? L("No wallpaper playing")
        : isPaused ? L("Resume wallpaper playback") : L("Pause wallpaper playback"),
      showsPlay: !hasWallpaper || isPaused, isEqualizerRunning: item != nil && !isPaused,
      canTogglePlayback: !isBusy && hasWallpaper,
      canGoPrevious: previousID != nil && isUsable, canGoNext: isUsable && hasOtherWallpaper)
  }
}
