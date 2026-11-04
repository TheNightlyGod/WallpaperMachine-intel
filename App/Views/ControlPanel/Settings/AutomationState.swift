import Foundation

/// What Settings › Displays shows of one display's automatic wallpaper selection: the saved rules
/// and the state the scheduler and the Space monitor keep beside them.
struct AutomationState: Equatable, Sendable {
  let mode: DisplayWallpaperAutomation.Mode
  /// The choices of Follow system appearance; nil leaves the wallpaper as it is.
  let light: WallpaperAutomationTarget?
  let dark: WallpaperAutomationTarget?
  /// The time schedule, in the order the list shows. When two rules fall due together, the later one
  /// wins.
  let rules: [WallpaperAutomationRule]
  /// The next scheduled change and what it will switch to.
  let next: Date?
  let nextTarget: WallpaperAutomationTarget?
  /// A Focus filter holds this display's wallpaper; manual choices stay possible.
  let isFocused: Bool
  /// Why the last automatic change failed; Retry clears it.
  let error: String?
  /// Whether Different wallpaper for each desktop can be chosen: Space information is read for
  /// this display and no animated lock screen owns the desktop.
  let spacesAvailable: Bool
  /// The animated lock screen is requested or owns the desktop, which Space choices conflict with.
  let spacesBlocked: Bool
  /// The regular desktops of this display, in order, and the choice saved for each.
  let desktops: [Desktop]
  /// The id of the desktop showing now; nil in a full-screen Space or when unknown.
  let currentDesktop: String?
  /// Choices saved for desktops that no longer exist, by desktop id.
  let missingDesktops: [MissingDesktop]

  struct Desktop: Identifiable, Equatable, Sendable {
    /// The Space's UUID. Choices follow it, never the number, so reordering desktops moves the
    /// label and keeps the choice.
    let id: String
    let number: Int
    /// The desktop's own choice.
    let target: WallpaperAutomationTarget?
    /// Desktop 1's choice, which this desktop shows while it has none of its own; nil for
    /// Desktop 1 itself.
    var firstDesktopTarget: WallpaperAutomationTarget? = nil
  }

  struct MissingDesktop: Identifiable, Equatable, Sendable {
    let id: String
    let target: WallpaperAutomationTarget
  }

  /// Why Different wallpaper for each desktop cannot be chosen, when it cannot.
  var spacesUnavailableReason: SpacesUnavailableReason? {
    if spacesAvailable { return nil }
    return spacesBlocked ? .lockScreenOwnsDesktop : .noInformation
  }

  enum SpacesUnavailableReason: Equatable, Sendable {
    case lockScreenOwnsDesktop, noInformation
  }
}

/// What an automatic choice can switch to: the wallpapers that can play and the saved playlists.
struct AutomationTargets: Equatable, Sendable {
  struct Choice: Identifiable, Equatable, Sendable {
    let target: WallpaperAutomationTarget
    let title: String
    /// The kind and the id together: one list holds wallpapers and plans.
    var id: String { "\(target.kind.rawValue):\(target.id)" }
  }

  let wallpapers: [Choice]
  let playlists: [Choice]

  /// The title of a saved choice, or nil when it no longer resolves (a deleted wallpaper or plan),
  /// which the list words as unavailable.
  func title(of target: WallpaperAutomationTarget) -> String? {
    (target.kind == .wallpaper ? wallpapers : playlists).first { $0.target == target }?.title
  }
}
