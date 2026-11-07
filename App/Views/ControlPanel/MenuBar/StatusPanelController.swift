import Foundation
import Observation

/// What the menu bar panel reads from the app and asks it to do. `AppDelegate` answers over its
/// stores (`AppDelegate+StatusPanel`); a test answers with fixtures.
@MainActor
protocol StatusPanelSource: AnyObject {
  /// Everything the panel shows, read now. The panel reads it inside observation tracking, so a
  /// change of an observable store it reads (the bridge store, its command queue, the history)
  /// brings the next refresh.
  func statusPanelInput() -> StatusPanelModel.Input
  /// Carries out a command through the paths the menu bar menu and the control panel use.
  func performStatusPanel(_ command: StatusPanelModel.Command) async throws
  /// The saved volume and mute of an installed wallpaper.
  func statusPanelVolume(of wallpaperID: String) async throws -> StatusPanelModel.Volume
}

/// The menu bar panel's state and typed actions, for one opening of the panel.
///
/// Nothing runs before `start()`, which the popover calls as it opens, and `stop()`, called as it
/// closes, ends all of it: the observation of the stores, the preference notifications, the reads
/// of the covers' stamps and a volume read still on its way. A new controller is made for every
/// opening, so the covers it decoded leave with it. Views start the typed actions through
/// `launch`; what failed shows under the panel until an action succeeds.
@MainActor
@Observable
final class StatusPanelController {
  /// What the view draws.
  private(set) var panel = StatusPanelModel.Panel()
  /// The shown wallpaper's own volume and mute; nil until read, and with nothing shown.
  private(set) var volume: StatusPanelModel.Volume?
  /// Stamps of the covers on show, by wallpaper id: a cover is drawn once its stamp is known.
  private(set) var coverStamps: [String: UInt64] = [:]
  /// Why the last action failed; cleared by the next one that succeeds.
  private(set) var failure: String?
  /// The quick switcher's batch, in order.
  private(set) var stripIDs: [String] = []
  /// The display the panel acts on.
  private(set) var displayID: String?

  let images: PanelImagePipeline
  @ObservationIgnored private(set) lazy var actions = PanelActionCoordinator(
    report: { [weak self] error in self?.failure = error.localizedDescription },
    succeeded: { [weak self] in self?.failure = nil })

  /// The preferences that announce a change instead of being observable.
  static let notifications = [
    PlaybackPreferences.didChangeNotification, SystemConditionState.didChangeNotification,
    PanelPreferences.favoritesDidChangeNotification,
  ]

  @ObservationIgnored private weak var source: (any StatusPanelSource)?
  @ObservationIgnored private let covers: LibraryCoverStamps
  @ObservationIgnored private let center: NotificationCenter
  @ObservationIgnored private let dismiss: @MainActor () -> Void
  @ObservationIgnored private var dice: Dice
  @ObservationIgnored private var input: StatusPanelModel.Input?
  /// The batch the panel showed the last time it was open, which a first batch avoids.
  @ObservationIgnored private let previousStrip: [String]
  @ObservationIgnored private var stripDisplayID: String?
  /// The pool the batch on show was drawn from, which its caption names until the next draw.
  @ObservationIgnored private var stripSource: StatusPanelModel.StripSource?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  /// Moves with every refresh and with `stop()`, so a change seen by an older observation does
  /// nothing.
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var volumeRead: (key: VolumeKey, task: Task<Void, Never>)?
  @ObservationIgnored private(set) var isStarted = false

  /// - Parameters:
  ///   - display: The display the panel chose the last time it was open.
  ///   - previousStrip: The batch it showed then.
  ///   - random: What the quick switcher shuffles with; a test passes a seeded one.
  ///   - dismiss: Closes the popover, before an action that opens a window or quits.
  init(
    source: any StatusPanelSource, display: String? = nil, previousStrip: [String] = [],
    images: PanelImagePipeline? = nil, covers: LibraryCoverStamps? = nil,
    center: NotificationCenter = .default,
    random: any RandomNumberGenerator = SystemRandomNumberGenerator(),
    dismiss: @escaping @MainActor () -> Void = {}
  ) {
    self.source = source
    displayID = display
    self.previousStrip = previousStrip
    self.images = images ?? PanelImagePipeline()
    self.covers = covers ?? LibraryCoverStamps()
    self.center = center
    dice = Dice(base: random)
    self.dismiss = dismiss
  }

  // MARK: Lifecycle

  /// The popover opens: reads what the panel shows and follows it until `stop()`.
  func start() {
    guard !isStarted else { return }
    isStarted = true
    covers.onChange = { [weak self] in self?.coversChanged() }
    for name in Self.notifications {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.refresh() }
        })
    }
    refresh()
  }

  /// The popover closed: nothing the panel started keeps running.
  func stop() {
    guard isStarted else { return }
    isStarted = false
    generation &+= 1
    for observer in observers { center.removeObserver(observer) }
    observers = []
    covers.onChange = nil
    volumeRead?.task.cancel()
    volumeRead = nil
  }

  /// Reads the input again and observes what it read, so the next change of it refreshes again.
  private func refresh() {
    guard isStarted, let source else { return }
    generation &+= 1
    let generation = generation
    let input = withObservationTracking {
      source.statusPanelInput()
    } onChange: { [weak self] in
      // Called before the change lands, so the new value is read on the next turn.
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        self.refresh()
      }
    }
    self.input = input
    let chosen = StatusPanelModel.display(displayID, in: input)?.id
    if chosen != displayID { displayID = chosen }
    if stripIDs.isEmpty || stripDisplayID != chosen {
      drawStrip(avoiding: stripIDs.isEmpty ? previousStrip : stripIDs)
    }
    rebuild()
  }

  private func rebuild() {
    guard let input else { return }
    let next = StatusPanelModel.make(input, display: displayID, strip: stripIDs, drawnFrom: stripSource)
    if next != panel { panel = next }
    readCovers(revision: input.libraryRevision)
    readVolume(revision: input.snapshotRevision)
  }

  private func drawStrip(avoiding previous: [String]) {
    guard let input else { return }
    let batch = StatusPanelModel.drawStrip(input, display: displayID, avoiding: Set(previous), using: &dice)
    stripIDs = batch.ids
    stripSource = batch.source
    stripDisplayID = displayID
  }

  // MARK: Covers and sound

  /// The cover of `wallpaper` once its stamp has been read; nil draws the placeholder.
  func cover(for wallpaper: StatusPanelModel.Wallpaper) -> PanelImageSource? {
    guard let file = wallpaper.previewFile, let stamp = coverStamps[wallpaper.id] else { return nil }
    return .libraryCover(file: file, stamp: stamp)
  }

  /// Asks for the stamps of the covers on show only, which are read in the background.
  private func readCovers(revision: UInt64) {
    var files: [String: URL] = [:]
    for wallpaper in [panel.wallpaper].compactMap({ $0 }) + panel.strip + panel.recent {
      if let file = wallpaper.previewFile { files[wallpaper.id] = file }
    }
    let stamps = covers.stamps(for: files, revision: revision)
    if stamps != coverStamps { coverStamps = stamps }
  }

  private func coversChanged() {
    guard isStarted, covers.stamps != coverStamps else { return }
    coverStamps = covers.stamps
  }

  private struct VolumeKey: Equatable {
    var wallpaperID: String
    var revision: UInt64
  }

  /// Reads the shown wallpaper's sound settings once for each snapshot that could have changed
  /// them. A read for another wallpaper or an older snapshot that lands late is dropped.
  private func readVolume(revision: UInt64) {
    guard let id = panel.wallpaper?.id else {
      volumeRead?.task.cancel()
      volumeRead = nil
      if volume != nil { volume = nil }
      return
    }
    let key = VolumeKey(wallpaperID: id, revision: revision)
    guard volumeRead?.key != key else { return }
    volumeRead?.task.cancel()
    if volume?.wallpaperID != id { volume = nil }
    let task = Task { [weak self] in
      guard let source = self?.source else { return }
      let read = try? await source.statusPanelVolume(of: id)
      guard let self, !Task.isCancelled, self.isStarted, self.volumeRead?.key == key,
        let read, read != self.volume
      else { return }
      self.volume = read
    }
    volumeRead = (key, task)
  }

  /// Resolves once the cover stamps and the volume asked for so far have been read, so a test
  /// never sleeps for them.
  func settled() async {
    await covers.settled()
    await volumeRead?.task.value
  }

  // MARK: Starting actions

  @discardableResult
  func launch(
    _ key: String, policy: PanelActionCoordinator.Policy = .dropDuplicates,
    operation: @escaping @MainActor () async throws -> Void
  ) -> Task<Void, Never> {
    actions.launch(key, policy: policy, operation: operation)
  }

  func isBusy(_ key: String) -> Bool { actions.isBusy(key) }

  /// The key of one of the panel's controls, for the display it acts on.
  func key(_ action: String, id: String? = nil) -> String {
    PanelActionCoordinator.key("statusPanel." + action, id: id, displayID: displayID)
  }

  // MARK: Navigation

  /// Makes `id` the display the panel acts on; the quick switcher draws a batch for it.
  func chooseDisplay(_ id: String) {
    guard id != displayID, panel.displays.contains(where: { $0.id == id }) else { return }
    displayID = id
    refresh()
  }

  /// Another batch in the quick switcher, keeping out the one on show while there are enough others.
  func showOtherWallpapers() {
    drawStrip(avoiding: stripIDs)
    rebuild()
  }

  // MARK: Actions

  /// The commands the menu gives the display's own items, for the display on show.
  func previous() async throws { try await send(.menu(.previous(display: try chosenDisplay()))) }
  func next() async throws { try await send(.menu(.next(display: try chosenDisplay()))) }
  func randomWallpaper() async throws { try await send(.menu(.random(display: try chosenDisplay()))) }
  func apply(_ wallpaperID: String) async throws {
    try await send(.menu(.apply(wallpaper: wallpaperID, display: try chosenDisplay())))
  }

  /// Play/Pause acts on every display, as the menu's does.
  func togglePlayback() async throws { try await send(.menu(.playPause)) }
  func unmuteAll() async throws { try await send(.unmuteAll) }

  func toggleFavorite() async throws {
    try await send(.toggleFavorite(wallpaper: try shownWallpaper()))
  }

  /// The shown wallpaper's own volume, from 0 to 1.
  func setVolume(_ fraction: Double) async throws {
    try await send(.setVolume(wallpaper: try shownWallpaper(), volume: fraction))
  }

  func setMuted(_ muted: Bool) async throws {
    try await send(.setMuted(wallpaper: try shownWallpaper(), muted: muted))
  }

  /// The control panel, with the display on show as its target.
  @discardableResult
  func openControlPanel() -> Task<Void, Never> {
    dismissThen(panel.displayID.map { .menu(.openInPanel(display: $0)) } ?? .menu(.openControlPanel))
  }

  @discardableResult
  func openSettings() -> Task<Void, Never> { dismissThen(.openSettings) }

  @discardableResult
  func openUpdates() -> Task<Void, Never> { dismissThen(.openUpdates) }

  @discardableResult
  func quit() -> Task<Void, Never> { dismissThen(.quit) }

  private func send(_ command: StatusPanelModel.Command) async throws {
    guard let source else { throw CancellationError() }
    try await source.performStatusPanel(command)
  }

  /// Closes the panel, then acts on the next turn: a window that opens or a quit that asks must not
  /// meet a popover that is still closing.
  private func dismissThen(_ command: StatusPanelModel.Command) -> Task<Void, Never> {
    let source = source
    dismiss()
    return Task { @MainActor in
      do { try await source?.performStatusPanel(command) } catch {
        AppLog.warn("menu bar panel: \(String(describing: command)) failed: \(error.localizedDescription)")
      }
    }
  }

  private func chosenDisplay() throws -> String {
    guard let displayID = panel.displayID else { throw AutomationError.notReady }
    return displayID
  }

  private func shownWallpaper() throws -> String {
    guard let id = panel.wallpaper?.id else {
      throw WallpaperActionError(message: L("This wallpaper is no longer installed. Refresh your library."))
    }
    return id
  }
}

/// A random source of any kind behind one concrete type, so the batch draw can take it `inout`.
private struct Dice: RandomNumberGenerator {
  var base: any RandomNumberGenerator
  mutating func next() -> UInt64 { base.next() }
}
