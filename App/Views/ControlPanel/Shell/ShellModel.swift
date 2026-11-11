import AppKit
import Observation
import SwiftUI

/// The popovers the shell presents through `ShellModel.popover(_:)`. Only one of them is open at a
/// time: opening one closes whichever was open, and a change of page closes it. The library
/// presents its Import popover from its own state, which `ShellModel.isPopoverOpen` reads.
enum ShellPopover: Hashable, Sendable {
  /// Now Playing's Recently used list.
  case history
  /// Now Playing's details: what the bar names, at a size that has room for it.
  case nowPlaying
  /// Now Playing's playlist: what the target display rotates through, and Change now and Stop.
  case playlist
  /// The downloads button's list.
  case downloads
}

/// How the window adapts to its width. Below `compactWidth` there is not room for a readable grid,
/// the inspector and a filters panel at once, so the inspector starts closed (the toolbar button
/// still opens it).
enum ShellLayout {
  /// The width under which the inspector starts closed: the width the rail layout of the web panel
  /// began at.
  static let compactWidth: CGFloat = 960

  /// Where a window of `width` stands. A width under the window's own floor is a view that has not
  /// been laid out in its window yet, and says nothing.
  enum Width: Equatable {
    case unplaced, compact, regular

    init(width: CGFloat) {
      if width < ControlPanelWindow.minimumContentSize.width - 1 {
        self = .unplaced
      } else {
        self = width < ShellLayout.compactWidth ? .compact : .regular
      }
    }
  }
}

/// The window shell: what page is on show, the window-level presentation state, and the derived
/// state the tabs, the toolbar and the banners read.
///
/// It reads and acts through `controller`, which owns every store. Views start navigation through
/// `show(_:)`, `open(_:)` and `setTarget(_:)`, which run the typed actions under the keys and
/// policies the page used (latest wins for both), so a quick run of clicks lands on the last one.
@MainActor
@Observable
final class ShellModel {
  unowned let controller: PanelController

  // MARK: Window state

  /// The window is too narrow for a readable grid, the inspector and a filters panel together
  /// (`ShellLayout.compactWidth`). The root reports it when the window crosses that width.
  private(set) var isCompact = false
  @ObservationIgnored private var hasMeasuredWidth = false
  @ObservationIgnored private var compactTask: Task<Void, Never>?
  /// How long the window must stay on one side of the compact width before the layout follows it.
  /// The inspector opening or closing while the window is still being resized sends AppKit into an
  /// endless constraint pass, so the layout waits for the resize to settle.
  @ObservationIgnored var compactDelay = Duration.milliseconds(350)
  /// The person's choice about the inspector, once they have made one; nil follows the window's
  /// width.
  private(set) var inspectorChoice: Bool?
  /// The Filters sidebar is open beside the page. One for the window: it stays open from one
  /// library page to the next, showing that page's filters, and waits out Settings, which has none.
  /// It starts closed and is not stored.
  private(set) var isFiltersChoice = false
  /// The inspector column's width, which dragging its edge changes within `InspectorColumn.widths`.
  /// Window memory only, as the system column's was.
  var inspectorWidth: CGFloat = InspectorColumn<EmptyView>.idealWidth
  /// The welcome guide was asked for again, from Settings. The guide also opens by itself, and for
  /// good, until the first-run flag is set.
  var isWelcomeRequested = false

  // MARK: Popovers

  /// The popover the shell presents, if any.
  private(set) var activePopover: ShellPopover?
  /// A popover a view reported through `isPopoverOpen` instead of presenting it through
  /// `popover(_:)`.
  private var isReportedPopoverOpen = false

  // MARK: Notices

  /// The last batch result of a collection change ("Deleted “Night”."), shown for a few seconds.
  private(set) var notice: String?
  /// How long a notice stays. A seam: tests hand a `ManualSleeper`.
  @ObservationIgnored var noticeLifetime = Duration.seconds(5)
  @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = {
    try await Task.sleep(for: $0)
  }
  /// How a notice reaches VoiceOver. A seam: tests record it.
  @ObservationIgnored var announce: @MainActor (String) -> Void = {
    AccessibilityNotification.Announcement($0).post()
  }
  @ObservationIgnored private var noticeTask: Task<Void, Never>?

  /// The inline name field of the Collections section.
  @ObservationIgnored lazy var collectionEditor = CollectionEditorModel(controller: controller)

  init(controller: PanelController) { self.controller = controller }

  // MARK: Derived state

  /// The page on show. Reading it subscribes the view to navigation changes, which the app makes
  /// from outside the window (menu commands, links, the status item).
  var selection: SidebarSelection {
    _ = controller.revisions.navigation
    return controller.navigation.selection ?? .wallpaper
  }

  /// Whether the pages around the guide are disabled and hidden from VoiceOver.
  var isWelcomeOpen: Bool { !controller.welcomeSeen || isWelcomeRequested }

  /// Whether the page on show has an inspector column.
  var hasInspector: Bool { selection != .settings }

  /// Whether the page on show has filters, and so a Filters sidebar.
  var hasFilters: Bool { selection != .settings }

  /// Whether the Filters sidebar is on show: open, on a page that has filters.
  var areFiltersShown: Bool { hasFilters && isFiltersChoice }

  /// Whether the inspector is open on the pages that have one. Without a choice of the person's it
  /// follows the window: open when there is room, closed in a narrow window. A choice made in a
  /// narrow window holds when the window grows, and one made in a wide window when it shrinks.
  /// Settings has no inspector, and the choice waits for the next page that has one.
  var isInspectorShown: Bool {
    get { inspectorChoice ?? !isCompact }
    // Only a change of what is on show is a choice: writing back the value on show is not.
    set { if newValue != isInspectorShown { inspectorChoice = newValue } }
  }

  /// Whether any popover of the window is open, which the support prompt waits behind: the
  /// shell's own (`popover(_:)`, which the toolbar's Downloads list uses too), the library's Import,
  /// which it presents from its own state, and one a view reported by setting this.
  ///
  /// The library's own popover is read from its model rather than from what it last reported
  /// here. A single reported flag lost track as soon as two popovers overlapped: one opening while
  /// Recently used was open was never counted, and once Recently used closed the support prompt
  /// could come up over it.
  var isPopoverOpen: Bool {
    get { activePopover != nil || isReportedPopoverOpen || isAreaPopoverOpen }
    set { isReportedPopoverOpen = newValue }
  }

  /// The popover an area presents from its own state: the library's Import.
  private var isAreaPopoverOpen: Bool { controller.library.importAnchor != nil }

  /// What the shell contributes to the support prompt's conditions: the offer waits while the guide
  /// or a popover is up and while a wallpaper is being switched or waiting to be. The presenter adds
  /// what only the downloads and pixiv areas know (a download dialog, a sign-in, a password prompt).
  var blocksSupportPrompt: Bool {
    isWelcomeOpen || isPopoverOpen || controller.isStoreBusy
      || controller.applyingWallpaperID != nil || !controller.queuedApplyIDs.isEmpty
  }

  /// The root reports where the window stands against `ShellLayout.compactWidth`: at once the first
  /// time it is placed (nothing is open yet to disturb), and after `compactDelay` on a change.
  func windowWidthChanged(_ width: ShellLayout.Width) {
    guard width != .unplaced else { return }
    let compact = width == .compact
    compactTask?.cancel()
    compactTask = nil
    guard hasMeasuredWidth else {
      hasMeasuredWidth = true
      isCompact = compact
      return
    }
    guard compact != isCompact else { return }
    let delay = compactDelay
    let sleep = sleep
    compactTask = Task { [weak self] in
      do { try await sleep(delay) } catch { return }
      self?.isCompact = compact
    }
  }

  /// A change of layout waiting on the delay, for a test to await.
  var pendingCompactChange: Task<Void, Never>? { compactTask }

  // MARK: Navigation

  private var navigateKey: String { PanelActionCoordinator.key("navigate") }

  /// Shows a page. A page opened for the first time starts its own first load (the model's
  /// `navigate`). Several quick calls end on the last.
  @discardableResult
  func open(_ selection: SidebarSelection) -> Task<Void, Never> {
    let controller = controller
    return controller.launch(navigateKey, policy: .latestWins) {
      try await controller.navigate(selection)
    }
  }

  /// Chooses the display wallpapers are applied to. Only an enabled display with a wallpaper of its
  /// own is accepted (the model refuses another); several quick choices end on the last.
  @discardableResult
  func setTarget(_ displayID: String) -> Task<Void, Never> {
    let controller = controller
    return controller.launch(PanelActionCoordinator.key("target"), policy: .latestWins) {
      try await controller.setTargetDisplay(displayID)
    }
  }

  // MARK: Now Playing

  /// What the Now Playing bar's buttons do, each under its own key so one in flight disables only
  /// itself.
  @discardableResult
  func togglePlayback() -> Task<Void, Never> {
    let controller = controller
    return controller.launch(PanelActionCoordinator.key("playback")) {
      try await controller.togglePlayback()
    }
  }

  @discardableResult
  func previousWallpaper() -> Task<Void, Never> {
    let controller = controller
    let display = controller.targetDisplayID
    return controller.launch(PanelActionCoordinator.key("previousWallpaper", displayID: display)) {
      try await controller.previousWallpaper(displayID: display)
    }
  }

  @discardableResult
  func nextWallpaper() -> Task<Void, Never> {
    let controller = controller
    let display = controller.targetDisplayID
    return controller.launch(PanelActionCoordinator.key("nextWallpaper", displayID: display)) {
      try await controller.nextWallpaper(displayID: display)
    }
  }

  /// Whether each of those is in flight, which disables its own button and no other.
  var isPlaybackBusy: Bool { controller.isBusy(PanelActionCoordinator.key("playback")) }
  var isPreviousBusy: Bool {
    controller.isBusy(
      PanelActionCoordinator.key("previousWallpaper", displayID: controller.targetDisplayID))
  }
  var isNextBusy: Bool {
    controller.isBusy(
      PanelActionCoordinator.key("nextWallpaper", displayID: controller.targetDisplayID))
  }

  /// Show in library: opens Installed with the wallpaper selected.
  @discardableResult
  func showInstalled(_ id: String) -> Task<Void, Never> {
    let controller = controller
    return controller.launch(PanelActionCoordinator.key("showInstalled", id: id)) {
      try await controller.showInstalled(id)
    }
  }

  /// A row of Recently used: applies the wallpaper to the target display.
  @discardableResult
  func apply(_ id: String) -> Task<Void, Never> {
    let controller = controller
    return controller.launch(PanelActionCoordinator.key("activate", id: id)) {
      try await controller.activate(id)
    }
  }

  /// Clear history: forgets what the target display showed.
  @discardableResult
  func clearHistory() -> Task<Void, Never> {
    let controller = controller
    let display = controller.targetDisplayID
    return controller.launch(PanelActionCoordinator.key("historyClear", displayID: display)) {
      try await controller.clearHistory(display: display)
    }
  }

  /// The wallpapers of the Recently used list: the target display's recent ones that are still in the
  /// library, newest first, with the one on show marked.
  var recentlyUsed: [RecentWallpaper] {
    let current = controller.nowPlaying.item?.id
    return controller.libraryHistory.recentIDs.compactMap { id in
      controller.libraryRow(id: id).map { RecentWallpaper(row: $0, isCurrent: $0.id == current) }
    }
  }

  // MARK: Held wallpapers

  /// A held wallpaper's Try again: asks the engine to load it again. A refusal shows in the error
  /// line and the row stays; the row goes when the hold is released.
  @discardableResult
  func releaseHeld(_ id: String) -> Task<Void, Never> {
    let controller = controller
    return controller.launch(Self.releaseHeldKey(id)) { try await controller.releaseHeld(id) }
  }

  /// Whether Try again for `id` is in flight, which disables that row's button.
  func isReleasingHeld(_ id: String) -> Bool { controller.isBusy(Self.releaseHeldKey(id)) }

  private static func releaseHeldKey(_ id: String) -> String {
    PanelActionCoordinator.key("releaseHeld", id: id)
  }

  // MARK: Side columns

  /// Opens or closes the Filters sidebar. In a narrow window there is no room for a readable grid
  /// between it and the inspector, so opening it closes the inspector, as the person sees.
  func setFiltersShown(_ shown: Bool) {
    guard hasFilters, shown != isFiltersChoice else { return }
    if shown && isCompact && isInspectorShown { isInspectorShown = false }
    isFiltersChoice = shown
  }

  /// The Filter buttons and the sidebar's own button.
  func toggleFilters() { setFiltersShown(!areFiltersShown) }

  /// The toolbar's inspector button. Opening the inspector in a narrow window closes the Filters
  /// sidebar, for the same reason.
  func toggleInspector() {
    let shown = !isInspectorShown
    if shown && isCompact && areFiltersShown { isFiltersChoice = false }
    isInspectorShown = shown
  }

  // MARK: Popovers

  /// A binding for a popover's `isPresented`. Opening it closes any other popover of the shell;
  /// closing it leaves one that has since opened alone.
  func popover(_ popover: ShellPopover) -> Binding<Bool> {
    Binding(
      get: { [self] in activePopover == popover },
      set: { [self] isPresented in
        if isPresented {
          activePopover = popover
        } else if activePopover == popover {
          activePopover = nil
        }
      })
  }

  /// Closes the shell's popover and forgets a reported one, which a change of page does: a popover
  /// belongs to the page it was opened on. The library closes its own as it leaves.
  func closePopover() {
    activePopover = nil
    isReportedPopoverOpen = false
  }

  // MARK: Keyboard

  /// Escape, for what the shell owns. An open name field of the Collections section is cancelled
  /// first, then an open popover; a selection (the library's) is left to the library page. True when
  /// the shell used the key.
  @discardableResult
  func handleEscape() -> Bool {
    if collectionEditor.isOpen {
      collectionEditor.cancel()
      return true
    }
    if activePopover != nil {
      closePopover()
      return true
    }
    return false
  }

  /// Command-F: puts the keyboard in the page's search bar. False when the window has none.
  @discardableResult
  func focusSearch() -> Bool {
    guard let window = controller.presentation.window else { return false }
    return PanelSearchFocus.focus(in: window)
  }

  // MARK: Notices

  /// Shows `text` for `noticeLifetime` and tells VoiceOver, which says it once however often the same
  /// sentence is repeated.
  func say(_ text: String) {
    notice = text
    announce(text)
    noticeTask?.cancel()
    let lifetime = noticeLifetime
    let sleep = sleep
    noticeTask = Task { [weak self] in
      do { try await sleep(lifetime) } catch { return }
      self?.expireNotice(text)
    }
  }

  private func expireNotice(_ text: String) {
    if notice == text { notice = nil }
    noticeTask = nil
  }

  /// The notice task of a test to await.
  var pendingNotice: Task<Void, Never>? { noticeTask }
}

/// A row of Recently used.
struct RecentWallpaper: Identifiable, Equatable {
  let row: LibraryRow
  /// It is the wallpaper the target display shows now.
  let isCurrent: Bool
  var id: String { row.id }
}
