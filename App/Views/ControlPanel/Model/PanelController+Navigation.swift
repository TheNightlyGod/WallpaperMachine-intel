import Foundation

/// Where the panel is, what it remembers across a closed window, the first-run flags and the
/// appearance and language choices: the shell's actions.
extension PanelController {
  // MARK: Navigation

  /// Shows `selection`. A page opened for the first time starts its own first load, as every route
  /// to it (the tabs, a menu command, a link) always did: Discover searches and pixiv asks for
  /// its default list, unless one is already loaded or loading.
  ///
  /// An `E` action: it leaves an older banner showing. A view that fires it for every click starts
  /// it with `.latestWins` under `PanelActionCoordinator.key("navigate")`, so the newest page wins.
  func navigate(_ selection: SidebarSelection) async throws {
    try await run(.immediate) {
      navigation.selection = selection
      switch selection {
      case .workshop:
        if !workshop.hasLoaded && !workshop.isLoading { workshop.search() }
      case .pixiv:
        if !pixiv.hasLoaded && !pixiv.isLoading { pixiv.apply(pixiv.query) }
      case .wallpaper, .settings:
        break
      }
    }
  }

  /// Opens Installed with `id` selected: what the Now Playing artwork, a download row's Show in
  /// library and a Discover tile of an installed item do.
  func showInstalled(_ id: String) async throws {
    try await navigate(.wallpaper)
    try await select(id)
  }

  /// Sets the target display, then shows Installed: Settings › Displays' Choose wallpaper.
  func chooseDisplayWallpaper(on displayID: String) async throws {
    try await setTargetDisplay(displayID)
    try await navigate(.wallpaper)
  }

  /// Reveals `section` and opens Settings: the link from a note that names a setting on another
  /// page, such as a frame-rate limit and the page of the setting that sets it.
  func openSettings(_ section: SettingsSection) async throws {
    navigation.revealSettingsSection(section)
    try await navigate(.settings)
  }

  /// The error banner's Dismiss button.
  func dismissError() { errors.dismiss() }

  /// The display that Apply, Now Playing, the history and the cards of the inspector act on.
  /// Read through here, so a view that shows it follows `ControlPanelNavigation`, which SwiftUI
  /// cannot observe.
  var targetDisplayID: String {
    _ = revisions.navigation
    return navigation.targetDisplayID
  }

  // MARK: Reopening the panel

  /// What the last window left behind, as it was when this one first asked or stored: Installed's
  /// filters and each library page's scroll offset. Read once, so a later report from this window
  /// cannot be mistaken for it, and nil on a fresh launch.
  @discardableResult
  func storeViewState(_ state: PanelViewState) -> Bool {
    // The capture must come before the first write, which replaces what is captured.
    _ = restoredViewState
    guard let kept = state.normalized() else {
      AppLog.debug("Panel view state ignored: it is outside its limits")
      return false
    }
    navigation.viewState = kept
    return true
  }

  // MARK: First-run flags

  /// Reading, skipping or simply starting to use the app all count: the welcome is offered once,
  /// and afterwards only on request from Settings. Persisted for the launch rule and What's New.
  func markWelcomeSeen() {
    welcomeSeen = true
    PanelPreferences.markWelcomeSeen(in: defaults)
  }

  /// The user swept across tiles to select them, or dismissed the tip that teaches it.
  func markDragSelectLearned() {
    dragSelectLearned = true
    PanelPreferences.markDragSelectLearned(in: defaults)
  }

  // MARK: Appearance

  /// The window appearance, read so a view that shows it follows `AppThemeStore`'s changes.
  var themePreferences: AppThemePreferences {
    _ = revisions.theme
    return theme.preferences
  }

  func setThemeMode(_ mode: AppThemePreferences.Mode) throws {
    try theme.set("mode", value: mode.rawValue)
  }

  /// `hex` is `#rrggbb`; any other form is refused, as a control never offers one.
  func setThemeAccent(_ hex: String) throws { try theme.set("accent", value: hex) }

  func setThemeTone(_ tone: AppThemePreferences.Tone) throws {
    try theme.set("tone", value: tone.rawValue)
  }

  func setThemeIcon(_ icon: AppThemePreferences.Icon) throws {
    try theme.set("icon", value: icon.rawValue)
  }

  func resetTheme() { theme.reset() }

  // MARK: Language

  /// The language the user chose, or nil while the app follows macOS.
  var languagePreference: AppLanguage? {
    _ = revisions.language
    return AppLanguage.named(appLanguage.preference)
  }

  /// The language the interface shows right now.
  var effectiveLanguage: AppLanguage {
    _ = revisions.language
    return appLanguage.effective
  }

  /// Switches the interface to `language`, or back to macOS's with nil. A language the app does
  /// not ship is refused. The panel and the import picker change at once; the menus and other
  /// dialogs follow at the next launch.
  func setLanguage(_ language: AppLanguage?) async throws {
    try appLanguage.set(language?.tag ?? AppLanguageStore.systemChoice)
    // A wallpaper's own label tables follow the language too, and the open wallpaper's options
    // are read again in them. The switch has already happened, so a failure here is logged and
    // never fails it.
    do {
      try await store.setLabelLanguageAsync(appLanguage.effective)
    } catch {
      AppLog.warn(
        "Property labels could not follow the new language: \(error.localizedDescription)")
    }
  }
}
