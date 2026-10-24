import AppKit
import Observation
import ServiceManagement

/// Everything the panel's views read and every action they start, over the app's stores.
///
/// Created by `ControlPanelView` for the life of the panel window: closing the window releases it,
/// and a new one is built around the same stores and `ControlPanelNavigation`. It owns what the
/// web panel's controller owned: the favorites and the first-run flags, the error banner, the
/// per-display options, the measured property files, the letterbox and image-placement staging.
/// Each area (shell, library, inspector, Workshop, downloads, pixiv, settings, welcome) has its own
/// view model hanging off it, and the typed actions live in `PanelController+<Group>.swift`.
///
/// Every collaborator is injectable with the app's own store as the default, so a test builds one
/// over temporary defaults, a snapshot-only bridge and fakes, and never reaches the installed app.
/// Nothing runs until `start()`: the controller then wires the stores' hooks, subscribes to the
/// ones SwiftUI cannot observe and starts its window-driven duties. `stop()` undoes all of it.
@MainActor
@Observable
final class PanelController {
  // MARK: Stores

  let store: BridgeStore
  let navigation: ControlPanelNavigation
  let workshop: WorkshopStore
  let pixiv: PixivStore
  let updater: AppUpdateStore
  /// Library imports, owned by the app so one outlives this panel.
  let imports: LibraryImportStore
  let importPicker = WallpaperImportPicker()
  let theme: AppThemeStore
  let appLanguage: AppLanguageStore
  let playback: PlaybackPreferences
  let playlists: PlaylistStore
  let automations: WallpaperAutomationStore
  let solarLocationTracker: SolarLocationTracker
  let displayLayouts: WallpaperDisplayLayoutStore
  let spaces: WallpaperSpaceMonitor
  /// The condition rules engaged now, as the app's `SystemConditionMonitor` publishes them.
  let systemConditions: SystemConditionState
  let hotKeys: HotKeyPreferences
  let collections: WallpaperCollectionStore
  let presets: WallpaperPresetStore
  let backup: WallpaperBackupStore
  /// Where the library and the downloads are kept, and a move of them (Settings › Storage).
  let libraryLocation: StorageLocationStore
  let imagePlacement: StillImagePlacementStore
  let compatibility: WallpaperCompatibilityStore
  let letterbox: VideoLetterboxStore
  let displayTitles: DisplayTitleResolver
  /// Folder sizes and dates for Installed's sort, measured off the main thread.
  let libraryMetrics: LibraryMetricsService
  /// Stamps of the Installed tiles' preview files, read off the main thread, so a cover is
  /// requested again only when its preview changed.
  let libraryCovers: LibraryCoverStamps
  /// Energy readout on Settings › Performance; samples only while Settings is on screen.
  let energyUsage: EnergyUsageMonitor
  let defaults: UserDefaults

  // MARK: Core services

  let images: PanelImagePipeline
  let dialogs: any PanelDialogs
  let presentation: PanelPresentation
  let revisions: PanelStoreRevisions
  let errors: PanelErrorState
  let actions: PanelActionCoordinator

  // MARK: Test seams

  /// Tests pass a closure so choosing an app opens no panel. Nil uses the sheet.
  @ObservationIgnored var chooseApplication: (@MainActor () async -> URL?)?
  /// Tests pass a closure that answers a pixiv session, so signing in opens no window. Nil opens
  /// pixiv's sign-in page in `WebSignInWindowController`.
  @ObservationIgnored var signInToPixiv: (@MainActor () async -> String?)?
  /// The same for Steam Community, whose session lets Discover list subscriptions.
  @ObservationIgnored var signInToSteamWeb: (@MainActor () async -> WebSignInCookies?)?
  /// Support links open only on a deliberate choice; tests capture their destinations.
  @ObservationIgnored var openSupportURL: @MainActor (URL) -> Bool = { DesktopActions.current.open($0) }
  /// Shows System Settings › General › Login Items, where the user allows a launch at login they
  /// switched off there. Tests capture the call so no Settings window opens.
  @ObservationIgnored var openLoginItemsSettings: @MainActor () -> Void = {
    DesktopActions.current.openLoginItemsSettings()
  }

  // MARK: Controller state

  /// The favorite wallpapers, persisted as the sorted JSON array under
  /// `PanelPreferences.favoritesKey` by the favorite action.
  var favoriteIDs: Set<String>
  /// Whether the first-run welcome has been read, skipped or used past. The welcome opens on its
  /// own while this is false and is never offered again; Settings can show it on request.
  var welcomeSeen: Bool
  /// Whether the user has swept across tiles to select them, or dismissed the tip that teaches it.
  var dragSelectLearned: Bool
  /// Whether the Steam sign-in keeps its session while the download runs; a running download's own
  /// choice wins over this.
  var remembersSession = true
  /// The scale factor the Black bars card last set, while it can still be waiting in the draft.
  var letterboxStaged: LetterboxStagedFactor?
  /// Measured `file` / `directory` property paths, by wallpaper then property id.
  var propertyAssets: [String: [String: PanelPropertyAsset]] = [:]
  /// Why choosing or clearing a path failed, by wallpaper then property id. It belongs beside the
  /// control the user just used, not in the window-wide error banner.
  var propertyPathErrors: [String: [String: String]] = [:]
  /// Bytes the last cache purge released, or nil when none has run this session. Nil and zero are
  /// different answers, "not run" versus "nothing to release", so a view is given the distinction.
  var userAssetsReleasedBytes: UInt64?
  @ObservationIgnored var imagePlacementRequestSequence: UInt64 = 0
  @ObservationIgnored var imagePlacementRequests: [String: UInt64] = [:]
  /// The status read that follows the user's return to the panel while a Login Items note is
  /// showing; one at a time, so repeated focus changes do not stack bridge round trips.
  @ObservationIgnored var loginItemRefresh: Task<Void, Never>?
  /// `start()` has run and `stop()` has not.
  private(set) var isStarted = false
  /// `stop()` has run: the panel is closing or closed, so an action that needs a window it no
  /// longer has should do nothing.
  private(set) var isStopped = false
  @ObservationIgnored private var lifecycleLoop: ObservationLoop?
  @ObservationIgnored private var errorLoop: ObservationLoop?

  // MARK: M-core state
  // M-core (the library agent) adds its stored properties here (library rows cache, history,
  // now-playing inputs, host and held states), between these markers only.

  /// The Installed rows, kept until one of their inputs moves.
  @ObservationIgnored let libraryRowsCache = LibraryRowsCache()
  /// Why the last Apply of each wallpaper failed, until an apply of that wallpaper succeeds. The
  /// inspector and the tile offer a report beside it; the banner shows the same failure once.
  var activationFailures: [String: String] = [:]
  /// What the previous window left in `navigation.viewState`, taken the first time this window
  /// asks for it or stores its own: the later reports of this window replace the original.
  @ObservationIgnored lazy var restoredViewState: PanelViewState? = navigation.viewState
  /// Hides the app after a wallpaper was applied, when the setting is on. Tests capture the call
  /// so the test host is never hidden.
  @ObservationIgnored var hideApplication: @MainActor () -> Void = { DesktopActions.current.hideApplication() }
  /// Selects wallpaper folders in Finder. Tests capture the call so no Finder window opens.
  @ObservationIgnored var revealInFinder: @MainActor ([URL]) -> Void = {
    DesktopActions.current.reveal($0)
  }
  /// Tests pass a closure that answers the import picker, so no sheet opens. Nil uses the picker.
  @ObservationIgnored var chooseImportFiles: ImportFileChooser?
  /// Moves a wallpaper's library folder to the Trash. Tests record the folder instead of trashing it.
  @ObservationIgnored var recycleWallpaperFolder: (URL) throws -> Void = {
    try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
  }
  // MARK: end M-core state

  /// Whether applying a wallpaper hides the app so the result is visible.
  var hidesAfterActivating: Bool { PanelPreferences.hidesAfterActivating(in: defaults) }

  /// The per-display options of Settings › Displays, read only while Settings is visible.
  @ObservationIgnored lazy var displayOptions = DisplayOptionsLoader(store: store) {
    [unowned self] in self.isStarted && self.presentation.isVisible && self.showsSettings
  }

  /// Whether Settings is the page on show, which is when the energy readout and the per-display
  /// options can be seen.
  var showsSettings: Bool { navigation.selection == .settings }

  // MARK: M-inspector state
  // M-inspector adds its stored properties here (option and property rows, delivery report, presets,
  // placement, compatibility and letterbox derived state), between these markers only.

  /// Values just chosen for a property that the bridge has not taken yet, by wallpaper then
  /// property id. A control keeps showing its value while the edit waits its turn and goes out; the
  /// entry goes when the edit ends, taken or refused, and the row reads the bridge's value again.
  var pendingPropertyValues: [String: [String: BridgePropertyValue]] = [:]
  /// Runs `reconcileInspectorContext()` whenever the selection, the target display, the options or
  /// a library refresh changes; started the first time an inspector reads its state.
  @ObservationIgnored var inspectorContextLoop: ObservationLoop?
  // MARK: end M-inspector state

  /// The panel's typed state blocks are spaced apart so that parallel edits never touch the
  /// same lines.

  // MARK: M-media state
  // M-media's caches and test seams; its derived state is computed in `PanelController+Workshop`,
  // `+Downloads` and `+Pixiv`.

  /// The ids of the wallpapers in the library, rebuilt only when the library changes. Every Discover
  /// tile and download row asks whether its wallpaper is installed on each progress tick, and a
  /// library of 10,000 must not be walked for each of them.
  @ObservationIgnored var mediaLibraryIndex: (revision: UInt64, ids: Set<String>)?
  /// The saved pages of pixiv works in the library, cached the same way.
  @ObservationIgnored var pixivInstalledIndex: (revision: UInt64, pages: [String: [Int]])?
  /// The Steam Community sign-in that is running. The sign-in action returns at once, so a second
  /// click can bring the window forward; this is what a test awaits.
  @ObservationIgnored var steamWebSignInTask: Task<Void, Never>?
  /// Tests replace this so choosing an assets folder writes nothing to the installed app's
  /// preferences. The default checks the folder holds Wallpaper Engine's shared shaders and
  /// materials and remembers it.
  @ObservationIgnored var configureSceneAssets: (URL) throws -> Void = {
    try ClientPaths.configureAssetsFolder(at: $0)
  }
  // MARK: end M-media state

  // MARK: Area view models

  @ObservationIgnored lazy var shell = ShellModel(controller: self)
  @ObservationIgnored lazy var library = InstalledBrowserModel(controller: self)
  @ObservationIgnored lazy var inspector = InspectorModel(controller: self)
  @ObservationIgnored lazy var workshopBrowser = WorkshopBrowserModel(controller: self)
  @ObservationIgnored lazy var downloads = DownloadsModel(controller: self)
  @ObservationIgnored lazy var pixivBrowser = PixivBrowserModel(controller: self)
  @ObservationIgnored lazy var settings = SettingsModel(controller: self)
  @ObservationIgnored lazy var displaysSettings = DisplaysSettingsModel(controller: self)
  @ObservationIgnored lazy var welcome = FirstRunModel(controller: self)
  @ObservationIgnored lazy var supportPrompt = SupportPromptPresenter(controller: self)

  // MARK: M-settings state
  /// Counts the times the Mac's own facts were read again. Some settings live where nothing tells the
  /// app they changed (macOS's own desktop-click preference, the battery, preferences another surface
  /// writes), so a getter reads this first and a view asks again after `refreshSystemReadings()`.
  var systemReadingsRevision: UInt64 = 0
  /// The charge of the internal battery, nil on a Mac without one. Read when the controller is made
  /// and by `refreshSystemReadings()`; it is how the low-battery rows know to appear.
  var batteryPercent: Int? = BatteryReading.read()?.percent
  /// Opens a folder or a System Settings pane for the user. Tests capture the destination, so no
  /// Finder or System Settings window opens.
  @ObservationIgnored var openSystemURL: @MainActor (URL) -> Bool = { DesktopActions.current.open($0) }
  /// Shows the exported diagnostics report in Finder, selected. Tests capture the call.
  @ObservationIgnored var revealDiagnosticsReport: @MainActor (URL) -> Void = {
    DesktopActions.current.reveal([$0])
  }
  /// Shows the performance data report the next upload would send, selected. Tests capture the call.
  @ObservationIgnored var revealPerformanceData: @MainActor (URL) -> Void = {
    DesktopActions.current.reveal([$0])
  }
  // MARK: end M-settings state

  // MARK: Initialization

  init(
    store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore,
    pixiv: PixivStore? = nil,
    updater: AppUpdateStore? = nil,
    imports: LibraryImportStore? = nil,
    presentation: PanelPresentation? = nil,
    theme: AppThemeStore? = nil,
    displayTitles: DisplayTitleResolver = .system,
    defaults: UserDefaults = ClientPreferences.defaults,
    libraryMetrics: LibraryMetricsService? = nil,
    libraryCovers: LibraryCoverStamps? = nil,
    images: PanelImagePipeline? = nil,
    dialogs: (any PanelDialogs)? = nil,
    energyUsage: EnergyUsageMonitor? = nil,
    appLanguage: AppLanguageStore? = nil,
    playback: PlaybackPreferences? = nil,
    playlists: PlaylistStore? = nil,
    hotKeys: HotKeyPreferences? = nil,
    collections: WallpaperCollectionStore? = nil,
    presets: WallpaperPresetStore? = nil,
    backup: WallpaperBackupStore? = nil,
    libraryLocation: StorageLocationStore? = nil,
    imagePlacement: StillImagePlacementStore? = nil,
    compatibility: WallpaperCompatibilityStore? = nil,
    letterbox: VideoLetterboxStore? = nil,
    chooseApplication: (@MainActor () async -> URL?)? = nil,
    automations: WallpaperAutomationStore? = nil,
    solarLocationTracker: SolarLocationTracker? = nil,
    displayLayouts: WallpaperDisplayLayoutStore? = nil,
    spaces: WallpaperSpaceMonitor? = nil,
    systemConditions: SystemConditionState? = nil
  ) {
    let pixiv = pixiv ?? PixivStore()
    let imports = imports ?? LibraryImportStore()
    let presentation = presentation ?? PanelPresentation()
    let theme = theme ?? .shared
    let appLanguage = appLanguage ?? .shared
    let playback = playback ?? .shared
    let playlists = playlists ?? .shared
    let hotKeys = hotKeys ?? .shared
    let collections = collections ?? .shared
    let presets = presets ?? .shared
    let imagePlacement = imagePlacement ?? .shared
    let automations = automations ?? WallpaperAutomationStore(defaults: defaults)
    let displayLayouts = displayLayouts ?? WallpaperDisplayLayoutStore(defaults: defaults)
    let spaces = spaces ?? WallpaperSpaceMonitor()
    let systemConditions = systemConditions ?? .shared
    let errors = PanelErrorState(store: store, imports: imports, workshop: workshop, pixiv: pixiv)

    self.store = store
    self.navigation = navigation
    self.workshop = workshop
    self.pixiv = pixiv
    self.updater = updater ?? AppUpdateStore(currentVersion: "0.0.0", client: DisabledAppUpdateClient())
    self.imports = imports
    self.theme = theme
    self.appLanguage = appLanguage
    self.playback = playback
    self.playlists = playlists
    self.automations = automations
    self.solarLocationTracker = solarLocationTracker ?? SolarLocationTracker(store: automations)
    self.displayLayouts = displayLayouts
    self.spaces = spaces
    self.systemConditions = systemConditions
    self.hotKeys = hotKeys
    self.collections = collections
    self.presets = presets
    self.backup = backup ?? WallpaperBackupStore(defaults: defaults)
    self.libraryLocation = libraryLocation ?? StorageLocationStore()
    self.imagePlacement = imagePlacement
    self.compatibility = compatibility ?? WallpaperCompatibilityStore()
    self.letterbox = letterbox ?? Self.letterboxStore(for: store)
    self.displayTitles = displayTitles
    self.libraryMetrics = libraryMetrics ?? LibraryMetricsService()
    self.libraryCovers = libraryCovers ?? LibraryCoverStamps()
    self.energyUsage = energyUsage ?? EnergyUsageMonitor()
    self.defaults = defaults
    self.images = images ?? PanelImagePipeline()
    self.dialogs =
      dialogs ?? AppKitPanelDialogs(window: { [weak presentation] in presentation?.window })
    self.presentation = presentation
    self.errors = errors
    self.actions = PanelActionCoordinator(
      report: { errors.report($0) }, succeeded: { errors.reconcile() })
    self.revisions = PanelStoreRevisions(
      playback: playback, hotKeys: hotKeys, playlists: playlists, collections: collections,
      presets: presets, imagePlacement: imagePlacement, automations: automations,
      displayLayouts: displayLayouts, spaces: spaces, conditions: systemConditions, theme: theme,
      appLanguage: appLanguage, navigation: navigation)
    self.chooseApplication = chooseApplication
    welcomeSeen = PanelPreferences.welcomeSeen(in: defaults)
    dragSelectLearned = PanelPreferences.dragSelectLearned(in: defaults)
    favoriteIDs = PanelPreferences.favorites(in: defaults)
    PanelPreferences.removeLegacyKeys(from: defaults)

    self.libraryMetrics.onChange = { [weak self] in self?.revisions.bump(.libraryMetrics) }
    self.libraryCovers.onChange = { [weak self] in self?.revisions.bump(.libraryCovers) }
    self.energyUsage.onChange = { [weak self] in self?.revisions.bump(.energy) }
    // What the engine routed to the native player: the report Settings shows as In use now.
    self.energyUsage.nativeVideoPlaying = { [weak self] in
      self?.store.settingsSnapshot.videoBackends.contains { $0.backend == "native" } ?? false
    }
    lifecycleLoop = ObservationLoop(
      track: { [weak self] in
        guard let self else { return }
        _ = self.presentation.isVisible
        _ = self.revisions.navigation
        _ = self.store.snapshotRevision
      },
      onChange: { [weak self] in self?.refreshVisibilityGatedWork() })
    errorLoop = ObservationLoop(
      track: { [weak self] in self?.errors.trackSources() },
      onChange: { [weak self] in self?.errors.reconcile() })
  }

  // MARK: M-org state
  // M-org adds its stored properties here (displays rows, playlists, plans, layouts, automation and
  // hotkeys derived state), between these markers only.
  // MARK: end M-org state

  // MARK: Lifecycle

  /// Wires the panel to the stores and starts what the window drives. A second call does nothing.
  func start() {
    guard !isStarted else { return }
    isStarted = true
    isStopped = false
    presentation.onBecameKey = { [weak self] in self?.windowDidBecomeKey() }
    presentation.onClose = { [weak self] in self?.stop() }
    revisions.start()
    // Discover previews start caching the moment Steam's page arrives, and the following page is
    // fetched behind the one on show, so neither waits for a tile to ask. The pixiv page does the
    // same with its thumbnails and its next page. Set once, as the web panel did, and left in place.
    workshop.prefetchesNextPage = true
    workshop.onPreviewsAvailable = { [cache = images.thumbnailCache] in cache.warm($0) }
    pixiv.prefetchesNextPage = true
    pixiv.onThumbnailsAvailable = { [cache = images.pixivThumbnailCache] in cache.warm($0) }
    // Opening the panel looks for SteamCMD once, so Discover and the download dialog know whether
    // it is installed without a visit to Settings.
    Task { await workshop.steamCMDSetup.refresh() }
    errors.reconcile()
    errorLoop?.start()
    lifecycleLoop?.start()
    refreshVisibilityGatedWork()
  }

  /// Ends everything `start()` began. Work the app owns (imports, downloads, setup, queued
  /// commands) is not the panel's and keeps running.
  func stop() {
    guard isStarted else { return }
    isStarted = false
    isStopped = true
    importPicker.cancel()
    energyUsage.setActive(false)
    loginItemRefresh?.cancel()
    loginItemRefresh = nil
    displayOptions.cancel()
    letterbox.cancelAll()
    revisions.stop()
    lifecycleLoop?.stop()
    errorLoop?.stop()
    stopInspectorContextObservation()
    presentation.onBecameKey = nil
    presentation.onClose = nil
  }

  /// Re-evaluates what is gated on the window being visible and Settings being open: the energy
  /// sampler, the per-display options fetch and the day the panel counts as used. The lifecycle
  /// observation calls this whenever one of its inputs changes (visibility, navigation, a new
  /// snapshot); tests call it directly after `presentation.show()` or a navigation.
  func refreshVisibilityGatedWork() {
    updateEnergyMonitoring()
    displayOptions.refresh()
    // A day the panel was on screen, for the star prompt; each calendar day counts once.
    if isStarted, presentation.isVisible { store.supportPrompt?.recordPanelUse() }
  }

  /// Sampling costs about 3 ms of kernel calls every two seconds, so it runs only while the panel
  /// is visible on Settings. The sampler does not know which section is open, so every Settings
  /// section samples; that costs less than reporting them.
  private func updateEnergyMonitoring() {
    energyUsage.setActive(isStarted && showsSettings && presentation.isVisible)
  }

  /// The panel's window became key. Assets Steam installed, or someone removed, while the panel was
  /// away show up when the user comes back to it, and so do a Login Items approval and the system
  /// readings that post no change of their own (battery level, the desktop-click preference).
  func windowDidBecomeKey() {
    guard isStarted else { return }
    workshop.refreshSceneAssetsReadiness()
    refreshLoginItemApproval()
    refreshSystemReadings()
  }

  /// A login item waiting for approval is allowed in System Settings, which does not tell the app.
  /// The bridge keeps its status for two seconds, so the read the user's return triggers sees
  /// their change. Nothing is read while no approval is pending, and never two reads at once.
  func refreshLoginItemApproval() {
    guard isStarted, store.settingsSnapshot.launchAtLoginNeedsApproval, loginItemRefresh == nil
    else { return }
    loginItemRefresh = Task { @MainActor [weak self] in
      try? await self?.store.refreshAllAsync()
      self?.loginItemRefresh = nil
    }
  }

  /// The installed video file for the Black bars check, found through the same library validation
  /// the live preview uses instead of a third copy of the path checks.
  static func letterboxStore(for store: BridgeStore) -> VideoLetterboxStore {
    let letterbox = VideoLetterboxStore(entry: { [weak store] id, displayID in
      guard let store else { throw CancellationError() }
      let request = try await store.wallpaperPreviewRequestAsync(id: id, displayID: displayID)
      let validated = try await WallpaperPreviewLoader().validate(request)
      guard validated.kind == .video else { throw VideoLetterboxProbe.Failure.noVideoTrack }
      return validated.projectURL.appendingPathComponent(validated.entryFile)
    })
    letterbox.viewportProvider = { [weak store] displayID in
      guard let store else { return nil }
      let title = store.settingsSnapshot.displays.first { $0.displayId == displayID }?.title ?? ""
      guard let screen = DisplayGeometry.screen(displayID: displayID, title: title),
        screen.frame.width > 0, screen.frame.height > 0
      else { return nil }
      return screen.frame.size
    }
    return letterbox
  }

  // MARK: F-C state
  // F-C adds its stored properties here (window-level presentation state such as sheets, the
  // welcome overlay and the inspector's visibility), between these markers only.
  // MARK: end F-C state
}
