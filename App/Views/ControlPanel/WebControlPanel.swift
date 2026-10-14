import AppKit
import Combine
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The page is app-owned. WKWebView supplies the reply-capable script bridge that
/// WebPage does not expose; renderer content is never loaded into this web view.
struct WebControlPanel: NSViewRepresentable {
  let store: BridgeStore
  let navigation: ControlPanelNavigation
  let workshop: WorkshopStore
  let pixiv: PixivStore
  let updater: AppUpdateStore
  let imports: LibraryImportStore

  func makeCoordinator() -> WebPanelController {
    let controller = WebPanelController(
      store: store, navigation: navigation, workshop: workshop, pixiv: pixiv, updater: updater,
      imports: imports, automations: .shared, displayLayouts: .shared, spaces: .shared)
    // Discover previews start caching the moment Steam's page arrives, and the following page
    // is fetched behind the one on show, so neither waits for the web view to ask. The pixiv
    // tab does the same with its thumbnails and its next page.
    workshop.prefetchesNextPage = true
    workshop.onPreviewsAvailable = { [cache = controller.assets.thumbnailCache] in cache.warm($0) }
    pixiv.prefetchesNextPage = true
    pixiv.onThumbnailsAvailable = { [cache = controller.assets.pixivThumbnailCache] in cache.warm($0) }
    return controller
  }

  func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
  func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.scheduleUpdate() }
  static func dismantleNSView(_ view: WKWebView, coordinator: WebPanelController) {
    coordinator.stop()
  }
}

/// A `file` or `directory` property's chosen path, reduced to what the page shows.
///
/// `matches` and `truncated` describe a folder: how many files inside it the importer
/// would take, and whether it holds more than the import limit. Both are nil / false for
/// a single file, and `matches` stays nil for a folder that could not be read.
struct WebPanelPropertyAsset: Equatable {
  let path: String
  let name: String
  var matches: Int?
  var truncated = false
}

@MainActor
final class WebPanelController: NSObject, WKNavigationDelegate {
  let store: BridgeStore
  let navigation: ControlPanelNavigation
  let workshop: WorkshopStore
  let pixiv: PixivStore
  let updater: AppUpdateStore
  /// Library imports, owned by the app so one outlives this page.
  let imports: LibraryImportStore
  let importPicker = WallpaperImportPicker()
  let theme: AppThemeStore
  let appLanguage: AppLanguageStore
  let playback: PlaybackPreferences
  let playlists: PlaylistStore
  let automations: WallpaperAutomationStore
  let displayLayouts: WallpaperDisplayLayoutStore
  let spaces: WallpaperSpaceMonitor
  let hotKeys: HotKeyPreferences
  let collections: WallpaperCollectionStore
  let presets: WallpaperPresetStore
  let backup: WallpaperBackupStore
  let imagePlacement: StillImagePlacementStore
  let compatibility: WallpaperCompatibilityStore
  let letterbox: VideoLetterboxStore
  /// The scale factor the Black bars card last set, while it can still be waiting in the draft.
  var letterboxStaged: LetterboxStagedFactor?
  var imagePlacementRequestSequence: UInt64 = 0
  var imagePlacementRequests: [String: UInt64] = [:]
  /// Tests pass a closure so choosing an app does not open a panel. Nil uses the sheet.
  var chooseApplication: (@MainActor () async -> URL?)?
  /// Tests pass a closure that answers a pixiv session, so signing in opens no window. Nil
  /// opens pixiv's sign-in page in `WebSignInWindowController`.
  var signInToPixiv: (@MainActor () async -> String?)?
  /// The same for Steam Community, whose session lets Discover list subscriptions.
  var signInToSteamWeb: (@MainActor () async -> String?)?
  /// Support links open only on a deliberate choice; tests capture their destinations.
  var openSupportURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
  /// Shows System Settings › General › Login Items, where the user allows a launch at login
  /// they switched off there. Tests capture the call so no Settings window opens.
  var openLoginItemsSettings: @MainActor () -> Void = { SMAppService.openSystemSettingsLoginItems() }
  /// Tests capture what would be shared, and where, so no share menu opens. Nil shows macOS's.
  var presentSharePicker: (@MainActor ([Any], NSRect) -> Void)?
  /// Shows a file in Finder; tests capture it instead.
  var revealFile: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
  let displayTitles: DisplayTitleResolver
  weak var webView: WKWebView?
  let assets: WebPanelAssets
  /// BCP 47 tag of the localization the page renders in: the user's in-app choice, or the
  /// language macOS resolves for the bundle so the panel and native strings agree.
  var language: String { Self.pageLanguage(appLanguage.effective.tag) }
  var subscriptions = Set<AnyCancellable>()
  var isReady = false
  var stopped = false
  var updateTask: Task<Void, Never>?
  var updatePending = false
  /// The status read that follows the user's return to the panel while a Login Items note
  /// is showing; one at a time, so repeated focus changes do not stack bridge round trips.
  var loginItemRefresh: Task<Void, Never>?
  var pageGeneration: UInt64 = 0
  var librarySectionCache: LibrarySection?
  var pixivInstalledIndex: (revision: UInt64, pages: [String: [Int]])?
  var deliveredLibraryRevision: String?
  let isPresentationVisible: (@MainActor () -> Bool)?
  var observationInstalled = false
  var actionError: String?
  var remembersSession = true
  var favoriteIDs: Set<String>
  /// Each library page (`discover`, `pixiv`, `installed`) hides its filter sidebar when the
  /// user closes it with the toolbar's Filter button; the choice outlives the page.
  var filtersCollapsed: [String: Bool]
  /// Whether the first-run welcome has been dismissed. The page shows the welcome over
  /// the content while this is false and reports `welcomeSeen` once the user has read or
  /// skipped it, or started using the app; it is never shown again on its own.
  var welcomeSeen: Bool
  /// Whether the user has swept across tiles to select them, or dismissed the tip that
  /// teaches it. Installed's selection row carries that tip until then.
  var dragSelectLearned: Bool
  /// Folder sizes and dates for Installed's sort menu, measured off the main thread.
  let libraryMetrics: LibraryMetricsService
  /// Stamps of the Installed tiles' preview files, read off the main thread, so a cover is
  /// requested again only when its preview changed.
  let libraryCovers: LibraryCoverStamps
  /// Energy readout on Settings › Performance; samples only while Settings is on screen.
  let energyUsage: EnergyUsageMonitor
  let defaults: UserDefaults
  var displayOptions: [String: BridgeWallpaperOptionsSnapshot] = [:]
  var displayOptionsRevision: UInt64?
  var displayOptionsTask: Task<Void, Never>?
  var displayOptionsGeneration: UInt64 = 0
  /// Measured `file` / `directory` property paths, by wallpaper then property id.
  var propertyAssets: [String: [String: WebPanelPropertyAsset]] = [:]
  /// Why choosing or clearing a path failed, by wallpaper then property id. It belongs
  /// beside the control the user just used, not in the window-wide error banner.
  var propertyPathErrors: [String: [String: String]] = [:]
  /// Bytes the last cache purge released, or nil when none has run this session.
  /// Nil and zero are different answers — "not run" versus "nothing to release" —
  /// so the page is given the distinction rather than a substituted 0.
  var userAssetsReleasedBytes: UInt64?
  var recoveryBudget = WebPanelRecoveryBudget()
  var dismissedErrorRevision: UInt64 = 0
  var dismissedLibraryError: String?
  var dismissedDownloadError: String?
  static let favoriteKey = "WallpaperMachine.favoriteWallpaperIDs"
  /// Where each page's sidebar choice is stored; Discover keeps the key earlier builds used.
  static let filtersCollapsedKeys = [
    "discover": "WallpaperMachine.workshopFiltersCollapsed",
    "pixiv": "WallpaperMachine.pixivFiltersCollapsed",
    "installed": "WallpaperMachine.installedFiltersCollapsed",
  ]
  static let welcomeSeenKey = "WallpaperMachine.welcomeSeen"
  static let dragSelectLearnedKey = "WallpaperMachine.dragSelectLearned"
  static let hideAfterActivatingKey = "WallpaperMachine.hideAfterActivating"
  /// Whether applying a wallpaper hides the app so the result is visible; off unless turned on,
  /// so the panel stays open until the user closes it.
  var hidesAfterActivating: Bool { defaults.object(forKey: Self.hideAfterActivatingKey) as? Bool ?? false }
  /// Earlier builds stored a dragged inspector width here; the width now follows the
  /// window alone, so the key is cleared rather than read.
  static let legacyInspectorWidthKey = "WallpaperMachine.inspectorWidth"

  init(
    store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore,
    pixiv: PixivStore? = nil,
    updater: AppUpdateStore? = nil,
    imports: LibraryImportStore? = nil,
    isPresentationVisible: (@MainActor () -> Bool)? = nil,
    theme: AppThemeStore? = nil,
    displayTitles: DisplayTitleResolver = .system,
    defaults: UserDefaults = ClientPreferences.defaults,
    libraryMetrics: LibraryMetricsService? = nil,
    libraryCovers: LibraryCoverStamps? = nil,
    assets: WebPanelAssets? = nil,
    energyUsage: EnergyUsageMonitor? = nil,
    appLanguage: AppLanguageStore? = nil,
    playback: PlaybackPreferences? = nil,
    playlists: PlaylistStore? = nil,
    hotKeys: HotKeyPreferences? = nil,
    collections: WallpaperCollectionStore? = nil,
    presets: WallpaperPresetStore? = nil,
    backup: WallpaperBackupStore? = nil,
    imagePlacement: StillImagePlacementStore? = nil,
    compatibility: WallpaperCompatibilityStore? = nil,
    letterbox: VideoLetterboxStore? = nil,
    chooseApplication: (@MainActor () async -> URL?)? = nil,
    automations: WallpaperAutomationStore? = nil,
    displayLayouts: WallpaperDisplayLayoutStore? = nil,
    spaces: WallpaperSpaceMonitor? = nil
  ) {
    self.store = store
    self.assets = assets ?? WebPanelAssets()
    self.appLanguage = appLanguage ?? .shared
    self.navigation = navigation
    self.workshop = workshop
    self.pixiv = pixiv ?? PixivStore()
    self.updater =
      updater ?? AppUpdateStore(currentVersion: "0.0.0", client: DisabledAppUpdateClient())
    self.imports = imports ?? LibraryImportStore()
    self.displayTitles = displayTitles
    self.isPresentationVisible = isPresentationVisible
    self.theme = theme ?? .shared
    self.defaults = defaults
    self.playback = playback ?? .shared
    self.playlists = playlists ?? .shared
    self.automations = automations ?? WallpaperAutomationStore(defaults: defaults)
    self.displayLayouts = displayLayouts ?? WallpaperDisplayLayoutStore(defaults: defaults)
    self.spaces = spaces ?? WallpaperSpaceMonitor()
    self.hotKeys = hotKeys ?? .shared
    self.collections = collections ?? .shared
    self.presets = presets ?? .shared
    self.backup = backup ?? WallpaperBackupStore(defaults: defaults)
    self.imagePlacement = imagePlacement ?? .shared
    self.compatibility = compatibility ?? WallpaperCompatibilityStore()
    self.letterbox = letterbox ?? Self.letterboxStore(for: store)
    self.chooseApplication = chooseApplication
    filtersCollapsed = Self.filtersCollapsedKeys.mapValues { defaults.bool(forKey: $0) }
    welcomeSeen = defaults.bool(forKey: Self.welcomeSeenKey)
    dragSelectLearned = defaults.bool(forKey: Self.dragSelectLearnedKey)
    self.libraryMetrics = libraryMetrics ?? LibraryMetricsService()
    self.libraryCovers = libraryCovers ?? LibraryCoverStamps()
    self.energyUsage = energyUsage ?? EnergyUsageMonitor()
    defaults.removeObject(forKey: Self.legacyInspectorWidthKey)
    favoriteIDs = Set(
      (try? JSONDecoder().decode(
        [String].self, from: defaults.data(forKey: Self.favoriteKey) ?? Data())) ?? [])
    super.init()
    self.libraryMetrics.onChange = { [weak self] in self?.scheduleUpdate() }
    self.libraryCovers.onChange = { [weak self] in self?.scheduleUpdate() }
    self.energyUsage.onChange = { [weak self] in self?.pushEnergyUsage() }
    // What the engine routed to the native player: the report Settings shows as In use now.
    self.energyUsage.nativeVideoPlaying = { [weak self] in
      self?.store.settingsSnapshot.videoBackends.contains { $0.backend == "native" } ?? false
    }
    self.backup.onChange = { [weak self] in self?.scheduleUpdate() }
    self.compatibility.onChange = { [weak self] in self?.scheduleUpdate() }
    self.letterbox.onChange = { [weak self] in self?.scheduleUpdate() }
  }

  func makeWebView() -> WKWebView {
    let content = WKUserContentController()
    content.addScriptMessageHandler(
      WebPanelMessageProxy(owner: self), contentWorld: .page, name: "native")
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = content
    configuration.setURLSchemeHandler(assets, forURLScheme: "mwe-ui")
    // The panel sets WebKit's inactive scheduling policy. WebKit applies it when
    // it considers the view inactive; the view stays in the window tree, so nothing
    // relies on the page being suspended while hidden. A snapshot skipped while
    // hidden is delivered on reveal.
    configuration.preferences.inactiveSchedulingPolicy = .suspend
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = self
    view.underPageBackgroundColor = .windowBackgroundColor
    view.allowsBackForwardNavigationGestures = false
    #if DEBUG
      view.isInspectable = true
    #endif
    webView = view
    theme.$preferences.sink { [weak self] preferences in
      self?.applyTheme(preferences)
    }.store(in: &subscriptions)
    for name in [
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
      NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
      NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
    ] {
      NotificationCenter.default.publisher(for: name)
        .sink { [weak self] note in
          MainActor.assumeIsolated {
            guard let self, let window = note.object as? NSWindow,
              window === self.webView?.window
            else { return }
            self.windowStateChanged(note.name)
          }
        }
        .store(in: &subscriptions)
    }
    NotificationCenter.default.publisher(for: PlaybackPreferences.didChangeNotification, object: playback)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.scheduleUpdate() }
      }
      .store(in: &subscriptions)
    NotificationCenter.default.publisher(for: HotKeyPreferences.didChangeNotification, object: hotKeys)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.scheduleUpdate() }
      }
      .store(in: &subscriptions)
    NotificationCenter.default.publisher(for: PlaylistStore.didChangeNotification, object: playlists)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.scheduleUpdate() }
      }
      .store(in: &subscriptions)
    let featureNotifications: [(Notification.Name, AnyObject)] = [
      (WallpaperCollectionStore.didChangeNotification, collections),
      (WallpaperPresetStore.didChangeNotification, presets),
      (StillImagePlacementStore.didChangeNotification, imagePlacement),
      (WallpaperAutomationStore.didChangeNotification, automations),
      (WallpaperAutomationStore.statusChangedNotification, automations),
      (WallpaperDisplayLayoutStore.didChangeNotification, displayLayouts),
      (WallpaperSpaceMonitor.didChangeNotification, spaces),
    ]
    for (name, object) in featureNotifications {
      NotificationCenter.default.publisher(for: name, object: object)
        .sink { [weak self] _ in
          Task { @MainActor [weak self] in self?.scheduleUpdate() }
        }
        .store(in: &subscriptions)
    }
    // Playback shows whether Low Power Mode, heat or a Focus filter is in effect right now.
    for name in [
      Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
      FocusFilterState.didChangeNotification,
    ] {
      NotificationCenter.default.publisher(for: name)
        .sink { [weak self] _ in
          Task { @MainActor [weak self] in self?.scheduleUpdate() }
        }
        .store(in: &subscriptions)
    }
    navigation.objectWillChange.sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.scheduleUpdate() }
    }.store(in: &subscriptions)
    view.load(URLRequest(url: WebPanelAssets.indexURL))
    observeState()
    return view
  }

  /// This is the panel's only user script. It is replaced whenever the theme or language
  /// changes so every reload, including WebContent recovery, starts with the latest saved
  /// choices before first paint.
  func installUserScript(theme preferences: AppThemePreferences? = nil) {
    guard let view = webView else { return }
    // `$preferences` publishes before the store's value changes, so the sink passes its own.
    let preferences = preferences ?? theme.preferences
    let content = view.configuration.userContentController
    content.removeAllUserScripts()
    // Mode/tone/icon are closed enums, accent is validated as six hexadecimal digits and the
    // language tag is reduced to letters, digits and hyphens by pageLanguage.
    content.addUserScript(
      WKUserScript(
        source:
          "window.__appTheme = {mode:'\(preferences.mode.rawValue)',accent:'\(preferences.accent)',tone:'\(preferences.tone.rawValue)',icon:'\(preferences.icon.rawValue)'};window.__appLanguage='\(language)';",
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
  }

  private func applyTheme(_ preferences: AppThemePreferences) {
    guard let view = webView else { return }
    view.appearance = preferences.mode.appearance
    installUserScript(theme: preferences)
    guard isReady, !stopped else { return }
    Task { @MainActor [weak self, weak view] in
      guard let self, !self.stopped, let view else { return }
      do {
        _ = try await view.callAsyncJavaScript(
          "window.appTheme?.apply(theme)", arguments: ["theme": self.theme.preferences.snapshot],
          in: nil, contentWorld: .page)
      } catch {
        self.actionError = String(
          localized: "The appearance could not update: \(error.localizedDescription)")
      }
      self.scheduleUpdate()
    }
  }

  /// A tag safe to splice into the user script; anything else falls back to English.
  static func pageLanguage(_ tag: String?) -> String {
    guard let tag, !tag.isEmpty,
      tag.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" })
    else { return "en" }
    return tag
  }

  func stop() {
    stopped = true
    importPicker.cancel()
    energyUsage.setActive(false)
    pageGeneration &+= 1
    updateTask?.cancel()
    updateTask = nil
    loginItemRefresh?.cancel()
    loginItemRefresh = nil
    updatePending = false
    cancelDisplayOptions()
    letterbox.cancelAll()
    subscriptions.removeAll()
    webView?.configuration.userContentController.removeScriptMessageHandler(
      forName: "native", contentWorld: .page)
    webView?.navigationDelegate = nil
    webView?.stopLoading()
  }

  func observeState() {
    guard !stopped, !observationInstalled else { return }
    observationInstalled = true
    withObservationTracking {
      trackSnapshotDependencies()
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.observationInstalled = false
        self.scheduleUpdate()
        self.observeState()
      }
    }
  }

  func presentationAllowsUpdates() -> Bool {
    if let isPresentationVisible { return isPresentationVisible() }
    guard let window = webView?.window else { return false }
    return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
  }

  /// Sampling costs about 3 ms of kernel calls every two seconds, so it runs only while
  /// the panel is visible on Settings. Settings tabs switch inside the page without
  /// telling native, so the other tabs sample too; that costs less than reporting them.
  func updateEnergyMonitoring() {
    let showsSettings = navigation.selection == .settings || navigation.selection == .display
    energyUsage.setActive(!stopped && isReady && showsSettings && presentationAllowsUpdates())
  }

  /// The readout changes every two seconds, so it bypasses the full snapshot and patches
  /// only its own row.
  private func pushEnergyUsage() {
    guard !stopped, isReady, let view = webView, presentationAllowsUpdates() else {
      updateEnergyMonitoring()
      return
    }
    let reading = energyUsage.snapshot
    Task { @MainActor in
      do {
        _ = try await view.callAsyncJavaScript(
          "window.wallpaperUI.energy?.(reading)", arguments: ["reading": reading], in: nil,
          contentWorld: .page)
      } catch {
        AppLog.debug("Energy readout could not update: \(error.localizedDescription)")
      }
    }
  }

  private var needsDisplayOptions: Bool {
    switch navigation.selection {
    case .settings, .display: true
    default: false
    }
  }

  /// Only a library section this page acknowledged can be omitted from the next push.
  /// Command replies remain full snapshots so a newly loaded page can recover on its own.
  func deliverySnapshot() -> [String: Any] {
    var state = snapshot()
    if let revision = state["libraryRevision"] as? String,
      revision == deliveredLibraryRevision
    {
      state.removeValue(forKey: "wallpapers")
    }
    return state
  }

  /// The panel's window changed how it is presented (key, minimized, occluded, full screen).
  /// Coming back to the panel also rereads what changes outside the app while the user is
  /// away, and every change delivers any snapshot that was waiting.
  func windowStateChanged(_ name: Notification.Name) {
    if name == NSWindow.didBecomeKeyNotification {
      // Assets Steam installed or someone removed while the panel was away show up
      // when the user comes back to it.
      workshop.refreshSceneAssetsReadiness()
      refreshLoginItemApproval()
    }
    scheduleUpdate()
  }

  /// A login item waiting for approval is allowed in System Settings, which does not tell
  /// the app. The bridge keeps its status for two seconds, so the read the user's return
  /// triggers sees their change. Nothing is read while no approval is pending.
  func refreshLoginItemApproval() {
    guard !stopped, store.settingsSnapshot.launchAtLoginNeedsApproval, loginItemRefresh == nil
    else { return }
    loginItemRefresh = Task { @MainActor [weak self] in
      try? await self?.store.refreshAllAsync()
      self?.loginItemRefresh = nil
    }
  }

  func scheduleUpdate() {
    guard !stopped else { return }
    updateEnergyMonitoring()
    updatePending = true
    reconcileDismissedErrors()
    if !presentationAllowsUpdates() || !needsDisplayOptions
      || displayOptionsRevision != store.snapshotRevision
    {
      cancelDisplayOptions()
    }
    guard updateTask == nil else { return }
    let generation = pageGeneration
    updateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.pageGeneration == generation { self.updateTask = nil }
      }
      while self.updatePending && !Task.isCancelled && self.pageGeneration == generation {
        guard !self.stopped, self.isReady, let view = self.webView else {
          self.cancelDisplayOptions()
          return
        }
        // Hidden, minimized or occluded: leave the snapshot pending. The
        // occlusion and deminiaturize observers call back here once this task
        // has ended, and that call delivers it along with the energy readout.
        guard self.presentationAllowsUpdates() else { return }
        // A day the panel was on screen, for the star prompt's count.
        self.store.supportPrompt?.recordPanelUse()
        self.refreshDisplayOptions()
        self.updatePending = false
        let state = self.deliverySnapshot()
        let libraryRevision = state["libraryRevision"] as? String
        do {
          let result = try await view.callAsyncJavaScript(
            "return window.wallpaperUI.receive(state)", arguments: ["state": state], in: nil,
            contentWorld: .page)
          guard !Task.isCancelled, self.pageGeneration == generation else { return }
          if result as? String == "needsFullSnapshot" {
            self.deliveredLibraryRevision = nil
            self.updatePending = true
          } else {
            self.deliveredLibraryRevision = libraryRevision
          }
        } catch {
          guard !Task.isCancelled, self.pageGeneration == generation else { return }
          self.actionError = String(
            localized: "The interface could not update: \(error.localizedDescription)")
          self.updatePending = true
          return
        }
      }
    }
  }

  private func cancelDisplayOptions() {
    displayOptionsGeneration &+= 1
    displayOptionsTask?.cancel()
    displayOptionsTask = nil
    displayOptionsRevision = nil
    displayOptions.removeAll(keepingCapacity: true)
  }

  func refreshDisplayOptions() {
    guard !stopped, presentationAllowsUpdates(), needsDisplayOptions else {
      cancelDisplayOptions()
      return
    }
    let revision = store.snapshotRevision
    guard displayOptionsRevision != revision else { return }
    cancelDisplayOptions()
    displayOptionsRevision = revision
    var ids = Set<String>()
    for row in store.monitorInformationSnapshot.rows
    where row.mirrorTargetDisplayId == nil && !row.wallpaperId.isEmpty
      && row.wallpaperId != store.wallpaperOptionsSnapshot?.wallpaperId
    {
      ids.insert(row.wallpaperId)
    }
    guard !ids.isEmpty else { return }
    let generation = displayOptionsGeneration
    displayOptionsTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.displayOptionsGeneration == generation { self.displayOptionsTask = nil }
      }
      var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
      for id in ids {
        guard !Task.isCancelled, !self.stopped, self.displayOptionsGeneration == generation,
          self.store.snapshotRevision == revision, self.presentationAllowsUpdates(),
          self.needsDisplayOptions
        else { return }
        let value = try? await self.store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
        guard !Task.isCancelled, !self.stopped, self.displayOptionsGeneration == generation,
          self.store.snapshotRevision == revision, self.presentationAllowsUpdates(),
          self.needsDisplayOptions
        else { return }
        if let value { options[id] = value }
      }
      guard !self.stopped, self.store.snapshotRevision == revision,
        self.presentationAllowsUpdates(), self.needsDisplayOptions
      else { return }
      self.displayOptions = options
      self.scheduleUpdate()
    }
  }

  func receive(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
    guard message.frameInfo.isMainFrame,
      message.frameInfo.securityOrigin.protocol == "mwe-ui",
      message.frameInfo.securityOrigin.host == "app",
      message.webView === webView,
      let body = message.body as? [String: Any], let action = body["action"] as? String
    else {
      reply(nil, String(localized: "This page is not allowed to control the application."))
      return
    }
    // Title-bar gestures reply immediately: a drag must start on the mouse event that
    // caused it, and neither gesture changes any state worth pushing back to the page.
    if action == "dragWindow" || action == "titleDoubleClick" {
      handleTitleBarGesture(action)
      reply(nil, nil)
      return
    }
    // The page reports its view state while the person types and scrolls. It is stored and
    // acknowledged without building or pushing a snapshot.
    if action == "viewState" {
      storeViewState(body)
      reply(nil, nil)
      return
    }
    // A position slider or a property's slider or colour reports every step of a drag. The
    // wallpaper follows, but nothing is saved and no state changed, so there is no snapshot to
    // build or push, and a refusal is not an error to show: the release that ends the drag
    // reports its own.
    if action == "displayPositionPreview" || action == "propertyPreview" {
      Task { @MainActor in
        do {
          try await perform(action, body: body)
          reply(nil, nil)
        } catch {
          reply(nil, error.localizedDescription)
        }
      }
      return
    }
    Task { @MainActor in
      do {
        try await perform(action, body: body)
        reconcileDismissedErrors()
        var state = snapshot()
        // A page that has just loaded asks once with `ready`; the reply also carries what
        // the previous page left, so a reopened panel resumes where it was closed.
        if action == "ready", let viewState = navigation.viewState {
          state["restoreViewState"] = viewState.payload
        }
        reply(state, nil)
      } catch {
        actionError = error.localizedDescription
        reply(nil, error.localizedDescription)
      }
      scheduleUpdate()
    }
  }

  private func handleTitleBarGesture(_ action: String) {
    guard let window = webView?.window, window.titleVisibility == .hidden,
      !window.styleMask.contains(.fullScreen)
    else { return }
    switch action {
    case "dragWindow":
      guard let event = NSApp.currentEvent,
        event.window === window,
        event.type == .leftMouseDown || event.type == .leftMouseDragged
      else { return }
      window.performDrag(with: event)
    case "titleDoubleClick":
      // Mirror the Desktop & Dock preference that native title bars follow.
      switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
      case "None": break
      case "Minimize": window.miniaturize(nil)
      case "Fill": window.zoom(nil)
      default: window.zoom(nil)
      }
    default: break
    }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard action.targetFrame?.isMainFrame == true, action.request.url == WebPanelAssets.indexURL
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isReady = false
    deliveredLibraryRevision = nil
    updateEnergyMonitoring()
    pageGeneration &+= 1
    updateTask?.cancel()
    updateTask = nil
    updatePending = true
    cancelDisplayOptions()
    guard recoveryBudget.permitRestart(at: ProcessInfo.processInfo.systemUptime) else {
      showLoadFailure(
        String(
          localized:
            "The interface stopped unexpectedly. Close and reopen the control panel to retry."))
      return
    }
    webView.load(URLRequest(url: WebPanelAssets.indexURL))
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    showLoadFailure(error.localizedDescription)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    showLoadFailure(error.localizedDescription)
  }

  private func showLoadFailure(_ message: String) {
    guard let view = webView else { return }
    // Native recovery remains available even when JavaScript cannot start.
    let alert = NSAlert()
    alert.messageText = String(localized: "Couldn’t load the interface")
    alert.informativeText = message
    alert.addButton(withTitle: String(localized: "Reload"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    guard let window = view.window else {
      actionError = message
      return
    }
    alert.beginSheetModal(for: window) { [weak self, weak view] response in
      if response == .alertFirstButtonReturn {
        self?.recoveryBudget.reset()
        view?.load(URLRequest(url: WebPanelAssets.indexURL))
      }
    }
  }
}

@MainActor
private final class WebPanelMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
  weak var owner: WebPanelController?
  init(owner: WebPanelController) { self.owner = owner }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    guard let owner else {
      replyHandler(nil, String(localized: "The control panel has closed."))
      return
    }
    owner.receive(message, reply: replyHandler)
  }
}

@MainActor
final class WebPanelAssets: NSObject, WKURLSchemeHandler {
  static let indexURL = URL(string: "mwe-ui://app/index.html")!
  /// Library preview files by wallpaper id, served as `mwe-ui://preview/<id>`.
  var previews: [String: URL] = [:]
  /// The same preview files, served as small still covers at `mwe-ui://library-thumbnail/<id>`.
  /// Installed tiles show these; `previews` stays for the inspector and a tile's hover animation.
  var libraryThumbnails: [String: URL] = [:]
  /// Workshop preview URLs by item id, served as still thumbnails at `mwe-ui://thumbnail/<id>`
  /// and relayed with their animation at `mwe-ui://animated/<id>`.
  var thumbnails: [String: URL] = [:]
  /// pixiv thumbnails by work id, and page previews by `<work id>-p<page>`, served as
  /// `mwe-ui://pixiv-thumbnail/<key>`.
  var pixivThumbnails: [String: URL] = [:]
  var propertyImages: [String: URL] = [:]
  private let propertyImageCache = PropertyImageCache()
  let thumbnailCache: WorkshopThumbnailCache
  /// A cache of its own, so pixiv's images and Steam's never evict each other.
  let pixivThumbnailCache: WorkshopThumbnailCache
  /// Still covers of the library's own previews. It keeps no animation: a tile that animates
  /// plays the preview file itself.
  let libraryThumbnailCache: WorkshopThumbnailCache
  /// In-flight loads by scheme task identity. WebKit frees a stopped task, and a new one can
  /// land on the same address, so each entry carries a unique ticket: a finished job may only
  /// act when the entry for its key still belongs to it.
  private var tasks: [ObjectIdentifier: (ticket: UInt64, job: Task<Void, Never>)] = [:]
  private var nextTicket: UInt64 = 0
  private static let files: Set<String> = [
    "index.html", "panel.js", "panel.css", "settings.js", "settings.css", "welcome.js",
    "welcome.css", "theme.js", "icons.js", "i18n.js", "property-label.js", "pixiv.js", "support-prompt.js",
    "collections.js", "presets.js", "placement.js", "compatibility.js", "letterbox.js", "plans.js", "backup.js", "playlist-order.js", "automation.js", "display-layouts.js",
    "app-icons/minimal.png", "app-icons/day.png", "app-icons/night.png",
  ]
  /// One catalog module per shipped language, served as `mwe-ui://app/locales/<tag>.js`.
  private static let localeFiles: Set<String> = Set(
    AppLanguage.supported.filter { $0.tag != AppLanguage.english.tag }.map {
      "locales/\($0.tag).js"
    })

  enum Route: Equatable {
    case file(URL)
    case thumbnail(URL)
    case animated(URL)
    case pixivThumbnail(URL)
    case libraryThumbnail(URL)
    case propertyImage(URL)
  }

  init(
    thumbnailCache: WorkshopThumbnailCache = WorkshopThumbnailCache(),
    pixivThumbnailCache: WorkshopThumbnailCache = WorkshopThumbnailCache(
      directory: ClientPaths.pixivThumbnailCacheURL, fetcher: PixivThumbnailFetcher(),
      maxConcurrentFetches: 6, byteLimit: 256 * 1024 * 1024),
    libraryThumbnailCache: WorkshopThumbnailCache = WorkshopThumbnailCache(
      directory: ClientPaths.libraryThumbnailCacheURL, fetcher: LibraryPreviewFetcher(),
      maxConcurrentFetches: 4, byteLimit: 128 * 1024 * 1024, keepsAnimation: false,
      sourceByteLimit: LibraryPreviewFetcher.maximumBytes)
  ) {
    self.thumbnailCache = thumbnailCache
    self.pixivThumbnailCache = pixivThumbnailCache
    self.libraryThumbnailCache = libraryThumbnailCache
    super.init()
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    let key = ObjectIdentifier(task)
    guard let url = task.request.url, let route = route(url) else {
      task.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    nextTicket += 1
    let ticket = nextTicket
    let job = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let data: Data
        var headers = [
          "Access-Control-Allow-Origin": "mwe-ui://app", "X-Content-Type-Options": "nosniff",
        ]
        switch route {
        case .file(let file):
          data = try await Task.detached(priority: .utility) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            return try Data(contentsOf: file, options: .mappedIfSafe)
          }.value
          headers["Content-Type"] = Self.mimeType(for: file)
        case .thumbnail(let preview):
          data = try await thumbnailCache.thumbnail(for: preview)
          headers["Content-Type"] = "image/jpeg"
          // The disk cache is the source of truth; this only lets WebKit skip re-asking for
          // tiles that scroll in and out of view within one session.
          headers["Cache-Control"] = "max-age=86400"
        case .animated(let preview):
          data = try await thumbnailCache.animatedPreview(for: preview)
          headers["Content-Type"] = WorkshopThumbnailCache.mimeType(of: data)
          headers["Cache-Control"] = "max-age=86400"
        case .pixivThumbnail(let image):
          data = try await pixivThumbnailCache.thumbnail(for: image)
          headers["Content-Type"] = "image/jpeg"
          headers["Cache-Control"] = "max-age=86400"
        case .libraryThumbnail(let file):
          // Stamped with the file's modification time and size, so a replaced preview is a new
          // cache entry; the address's own stamp keeps the page from reusing the old image.
          let root = ClientPaths.libraryURL
          let identity = try await Task.detached(priority: .utility) {
            try LibraryPreviewFetcher.identity(of: file, in: root)
          }.value
          data = try await libraryThumbnailCache.thumbnail(for: identity)
          headers["Content-Type"] = "image/jpeg"
          headers["Cache-Control"] = "max-age=86400"
        case .propertyImage(let source):
          let image = try await propertyImageCache.image(for: source)
          data = image.data
          headers["Content-Type"] = image.mimeType
          headers["Cache-Control"] = "max-age=86400"
        }
        guard finish(key, ticket: ticket) else { return }
        headers["Content-Length"] = String(data.count)
        let response = HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
      } catch {
        guard finish(key, ticket: ticket) else { return }
        task.didFailWithError(error)
      }
    }
    tasks.updateValue((ticket, job), forKey: key)?.job.cancel()
  }

  /// Releases the entry for a completed job. Returns false when WebKit already stopped the
  /// task or the key now belongs to a newer task, in which case the task must not be touched.
  private func finish(_ key: ObjectIdentifier, ticket: UInt64) -> Bool {
    guard !Task.isCancelled, tasks[key]?.ticket == ticket else { return false }
    tasks.removeValue(forKey: key)
    return true
  }

  private static func mimeType(for file: URL) -> String {
    switch file.pathExtension.lowercased() {
    case "html": "text/html"
    case "js": "text/javascript"
    case "css": "text/css"
    default:
      UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
        ?? "application/octet-stream"
    }
  }

  func route(_ url: URL) -> Route? {
    if let file = resourceURL(url) { return .file(file) }
    if url.scheme == "mwe-ui", url.host == "property-image", url.user == nil,
      url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
      let image = propertyImages[String(url.path.dropFirst())], PropertyImageCache.allowedURL(image)
    { return .propertyImage(image) }
    if url.scheme == "mwe-ui", url.host == "pixiv-thumbnail", url.user == nil,
      url.password == nil, url.port == nil,
      let image = pixivThumbnails[String(url.path.dropFirst())], PixivService.isImageURL(image)
    { return .pixivThumbnail(image) }
    if url.scheme == "mwe-ui", url.host == "library-thumbnail", url.user == nil,
      url.password == nil, url.port == nil, url.fragment == nil, Self.isStampQuery(url.query),
      let file = libraryThumbnails[String(url.path.dropFirst())]
    { return .libraryThumbnail(file) }
    guard url.scheme == "mwe-ui", let host = url.host, url.user == nil, url.password == nil,
      url.port == nil, let preview = thumbnails[String(url.path.dropFirst())],
      preview.scheme == "https"
    else { return nil }
    switch host {
    case "thumbnail": return .thumbnail(preview)
    case "animated": return .animated(preview)
    default: return nil
    }
  }

  /// The only query an address may carry: the stamp of the preview file (`v=<digits>`) it was announced with.
  private static func isStampQuery(_ query: String?) -> Bool {
    guard let query else { return true }
    guard query.hasPrefix("v="), (3...22).contains(query.count) else { return false }
    return query.dropFirst(2).unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(task))?.job.cancel()
  }

  func resourceURL(_ url: URL) -> URL? {
    guard url.scheme == "mwe-ui", url.user == nil, url.password == nil, url.port == nil else {
      return nil
    }
    let name = String(url.path.dropFirst())
    if url.host == "app", Self.files.contains(name) || Self.localeFiles.contains(name) {
      return Bundle.main.resourceURL?.appendingPathComponent("WebUI", isDirectory: true)
        .appendingPathComponent(name)
    }
    if url.host == "preview", let file = previews[name] {
      return LibraryPreviewFetcher.confined(file, in: ClientPaths.libraryURL)
    }
    return nil
  }
}
