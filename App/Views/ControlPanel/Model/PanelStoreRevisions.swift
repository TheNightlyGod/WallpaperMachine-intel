import Combine
import Foundation
import Observation

/// One counter per app store that SwiftUI cannot observe, bumped whenever that store says it
/// changed.
///
/// Most stores are `@Observable` and need nothing. These are not: they post a notification, call
/// a closure, or publish through Combine. A typed getter on the controller that reads one of
/// them must first read its counter (`_ = controller.revisions.playlists`), which is what makes
/// SwiftUI ask the getter again when the store changes; without that read the view silently
/// freezes at the value it first saw. The counters hold no data and only ever go up.
///
/// Subscribes once in `start()` and unsubscribes in `stop()`, so a closed panel leaves nothing
/// listening. `bump(_:)` is also the entry point for the stores that call a closure instead of
/// posting (`LibraryMetricsService`, `LibraryCoverStamps`, `EnergyUsageMonitor`), which the
/// controller wires.
@MainActor
@Observable
final class PanelStoreRevisions {
  enum Source: CaseIterable, Sendable {
    case playback, hotKeys, playlists, collections, presets, imagePlacement
    case automationSettings, automationStatus, displayLayouts, spaces, focus
    /// Low Power Mode and the thermal state, which the Playback section reports "in effect now".
    case power
    /// Which Playback & Power condition rules are engaged and what they do (`SystemConditionState`).
    case conditions
    case energy, libraryMetrics, libraryCovers
    case theme, language, navigation
  }

  private(set) var playback: UInt64 = 0
  private(set) var hotKeys: UInt64 = 0
  private(set) var playlists: UInt64 = 0
  private(set) var collections: UInt64 = 0
  private(set) var presets: UInt64 = 0
  private(set) var imagePlacement: UInt64 = 0
  /// The automation rules and settings changed.
  private(set) var automationSettings: UInt64 = 0
  /// The automation's status changed: the next change, a failure, the focused app.
  private(set) var automationStatus: UInt64 = 0
  private(set) var displayLayouts: UInt64 = 0
  private(set) var spaces: UInt64 = 0
  private(set) var focus: UInt64 = 0
  private(set) var power: UInt64 = 0
  private(set) var conditions: UInt64 = 0
  private(set) var energy: UInt64 = 0
  private(set) var libraryMetrics: UInt64 = 0
  private(set) var libraryCovers: UInt64 = 0
  private(set) var theme: UInt64 = 0
  private(set) var language: UInt64 = 0
  private(set) var navigation: UInt64 = 0

  @ObservationIgnored private let playbackStore: PlaybackPreferences
  @ObservationIgnored private let hotKeyStore: HotKeyPreferences
  @ObservationIgnored private let playlistStore: PlaylistStore
  @ObservationIgnored private let collectionStore: WallpaperCollectionStore
  @ObservationIgnored private let presetStore: WallpaperPresetStore
  @ObservationIgnored private let imagePlacementStore: StillImagePlacementStore
  @ObservationIgnored private let automationStore: WallpaperAutomationStore
  @ObservationIgnored private let displayLayoutStore: WallpaperDisplayLayoutStore
  @ObservationIgnored private let spaceMonitor: WallpaperSpaceMonitor
  @ObservationIgnored private let conditionState: SystemConditionState
  @ObservationIgnored private let themeStore: AppThemeStore
  @ObservationIgnored private let languageStore: AppLanguageStore
  @ObservationIgnored private let navigationModel: ControlPanelNavigation
  @ObservationIgnored private var tokens: [NSObjectProtocol] = []
  @ObservationIgnored private var cancellables = Set<AnyCancellable>()
  @ObservationIgnored private(set) var isStarted = false

  init(
    playback: PlaybackPreferences, hotKeys: HotKeyPreferences, playlists: PlaylistStore,
    collections: WallpaperCollectionStore, presets: WallpaperPresetStore,
    imagePlacement: StillImagePlacementStore, automations: WallpaperAutomationStore,
    displayLayouts: WallpaperDisplayLayoutStore, spaces: WallpaperSpaceMonitor,
    conditions: SystemConditionState, theme: AppThemeStore, appLanguage: AppLanguageStore,
    navigation: ControlPanelNavigation
  ) {
    playbackStore = playback
    hotKeyStore = hotKeys
    playlistStore = playlists
    collectionStore = collections
    presetStore = presets
    imagePlacementStore = imagePlacement
    automationStore = automations
    displayLayoutStore = displayLayouts
    spaceMonitor = spaces
    conditionState = conditions
    themeStore = theme
    languageStore = appLanguage
    navigationModel = navigation
  }

  deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }

  /// Counts one change of `source`.
  func bump(_ source: Source) {
    switch source {
    case .playback: playback &+= 1
    case .hotKeys: hotKeys &+= 1
    case .playlists: playlists &+= 1
    case .collections: collections &+= 1
    case .presets: presets &+= 1
    case .imagePlacement: imagePlacement &+= 1
    case .automationSettings: automationSettings &+= 1
    case .automationStatus: automationStatus &+= 1
    case .displayLayouts: displayLayouts &+= 1
    case .spaces: spaces &+= 1
    case .focus: focus &+= 1
    case .power: power &+= 1
    case .conditions: conditions &+= 1
    case .energy: energy &+= 1
    case .libraryMetrics: libraryMetrics &+= 1
    case .libraryCovers: libraryCovers &+= 1
    case .theme: theme &+= 1
    case .language: language &+= 1
    case .navigation: navigation &+= 1
    }
  }

  /// The counter of `source`, for a caller that picks its source at run time.
  func revision(of source: Source) -> UInt64 {
    switch source {
    case .playback: playback
    case .hotKeys: hotKeys
    case .playlists: playlists
    case .collections: collections
    case .presets: presets
    case .imagePlacement: imagePlacement
    case .automationSettings: automationSettings
    case .automationStatus: automationStatus
    case .displayLayouts: displayLayouts
    case .spaces: spaces
    case .focus: focus
    case .power: power
    case .conditions: conditions
    case .energy: energy
    case .libraryMetrics: libraryMetrics
    case .libraryCovers: libraryCovers
    case .theme: theme
    case .language: language
    case .navigation: navigation
    }
  }

  /// Subscribes to every store; a second call does nothing.
  func start() {
    guard !isStarted else { return }
    isStarted = true
    observe(PlaybackPreferences.didChangeNotification, playbackStore, .playback)
    observe(HotKeyPreferences.didChangeNotification, hotKeyStore, .hotKeys)
    observe(PlaylistStore.didChangeNotification, playlistStore, .playlists)
    observe(WallpaperCollectionStore.didChangeNotification, collectionStore, .collections)
    observe(WallpaperPresetStore.didChangeNotification, presetStore, .presets)
    observe(StillImagePlacementStore.didChangeNotification, imagePlacementStore, .imagePlacement)
    observe(WallpaperAutomationStore.didChangeNotification, automationStore, .automationSettings)
    observe(WallpaperAutomationStore.statusChangedNotification, automationStore, .automationStatus)
    observe(WallpaperDisplayLayoutStore.didChangeNotification, displayLayoutStore, .displayLayouts)
    observe(WallpaperSpaceMonitor.didChangeNotification, spaceMonitor, .spaces)
    // Playback shows whether Low Power Mode, heat or a Focus filter is in effect right now. Neither
    // the system nor the Focus filter state names an object to filter on.
    observe(.NSProcessInfoPowerStateDidChange, nil, .power)
    observe(ProcessInfo.thermalStateDidChangeNotification, nil, .power)
    observe(FocusFilterState.didChangeNotification, nil, .focus)
    // And whether a low-battery, Low Power Mode or heat rule is engaged, which only the app's
    // condition monitor knows (the low-battery rule has hysteresis).
    observe(SystemConditionState.didChangeNotification, conditionState, .conditions)
    // `objectWillChange` and `$preferences` publish before the value is stored, which is fine
    // here: a view reads the counter and the store later, in its own update.
    themeStore.$preferences.dropFirst().sink { [weak self] _ in self?.bump(.theme) }
      .store(in: &cancellables)
    languageStore.objectWillChange.sink { [weak self] _ in self?.bump(.language) }
      .store(in: &cancellables)
    navigationModel.objectWillChange.sink { [weak self] _ in self?.bump(.navigation) }
      .store(in: &cancellables)
  }

  /// Unsubscribes from every store.
  func stop() {
    for token in tokens { NotificationCenter.default.removeObserver(token) }
    tokens.removeAll()
    cancellables.removeAll()
    isStarted = false
  }

  private func observe(_ name: Notification.Name, _ object: AnyObject?, _ source: Source) {
    // Delivered on the posting thread, so a post from the main actor bumps before it returns.
    // The power and thermal notifications come from other threads and hop.
    tokens.append(
      NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) {
        [weak self] _ in
        if Thread.isMainThread {
          MainActor.assumeIsolated { self?.bump(source) }
        } else {
          Task { @MainActor [weak self] in self?.bump(source) }
        }
      })
  }
}
