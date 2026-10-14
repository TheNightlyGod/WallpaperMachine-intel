import AppKit
import CryptoKit
import Darwin
import Observation

@MainActor
@Observable
final class LockScreenWallpaperService {
  private(set) var isEnabled = false
  private(set) var isRequested = false
  private(set) var isBusy = false
  private(set) var status = String(localized: "Off")
  private(set) var errorMessage: String?
  private(set) var screenSaverRequested = false
  private(set) var screenSaverEnabled = false
  private(set) var screenSaverStatus = String(localized: "Off")
  private(set) var screenSaverError: String?
  var anyRequested: Bool { isRequested || screenSaverRequested }
  var canRefreshAutomatically: Bool {
    anyRequested && screenSaverError == nil
      && (errorMessage == nil || (screenSaverRequested && lockScreenActivationError != nil))
  }
  /// Whether the native provider has the desktop picture, or an animated lock screen is on its way
  /// to taking it. Poster sync then stays out of the way; a screen saver chosen on its own and a
  /// lock screen that failed to start leave the picture to the posters.
  var claimsDesktopPicture: Bool {
    ownsDesktopProvider || (isRequested && canRefreshAutomatically && errorMessage == nil)
  }
  /// Whether the choice to write the desktop picture is not the user's to make right now: from the
  /// moment the lock screen is asked for until it has handed the desktop back, even when it failed.
  var locksDesktopPictureChoice: Bool { isRequested || ownsDesktopProvider }
  @ObservationIgnored var beforeActivation: (() throws -> Void)?
  @ObservationIgnored var afterDeactivation: (() throws -> Void)?

  private static let preference = "WallpaperMachineAnimateLockScreen"
  private static let screenSaverPreference = "WallpaperMachineUseWallpaperAsScreenSaver"
  @ObservationIgnored private let scenes: () async throws -> [BridgeLockScreenScene]
  @ObservationIgnored private let selection: LockScreenWallpaperSelection
  @ObservationIgnored private let exchange: URL
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let scheduleMonitor: (@escaping @MainActor () -> Void) -> Timer
  @ObservationIgnored private let displayUUID: (UInt32) -> String?
  @ObservationIgnored private let persistConfiguration: (URL, Data) throws -> Void
  @ObservationIgnored private let notifyConfigurationChanged: () -> Void
  @ObservationIgnored private let prepareExtension: () async throws -> Void
  @ObservationIgnored private let enableExtension: () async throws -> Void
  @ObservationIgnored private let expectedExtensionBundle: URL
  @ObservationIgnored private let runningExtensionBundles: () -> [URL]
  @ObservationIgnored private let readinessTimeout: TimeInterval
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var extensionPreparation: Task<Void, Error>?
  @ObservationIgnored private var copyRecoveryAttempted = false
  /// The last activation stopped because macOS has the renderer switched off, so a Retry may
  /// switch it on again. Cleared by any other outcome and when nothing is requested any more.
  @ObservationIgnored private var electionRepairOffered = false
  /// A Retry click asked for that repair; the next preparation does it, once.
  @ObservationIgnored private var electionRepairArmed = false
  @ObservationIgnored private var monitor: Timer?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var recovered = false
  @ObservationIgnored private var stopping = false
  @ObservationIgnored private(set) var ownsDesktopProvider = false
  @ObservationIgnored private var lastInputs: [LockScreenPublishInput]?
  @ObservationIgnored private var lastContentRevision: UInt64?
  @ObservationIgnored private let contentRevision: () -> UInt64
  @ObservationIgnored private var lastLockScreenRequested: Bool?
  @ObservationIgnored private var lastScreenSaverRequested = false
  @ObservationIgnored private var lastHasWebWallpapers = false
  @ObservationIgnored private var published: LockScreenConfiguration?
  /// The published activation whose first frame has not arrived, and when the wait for it gives
  /// up. A refresh that interrupts the wait waits on for the same revision until that deadline.
  @ObservationIgnored private var unconfirmed: (revision: String, deadline: Date)?
  @ObservationIgnored private var lockScreenActivationError: String?

  convenience init(bridge: WallpaperBridge, contentRevision: @escaping () -> UInt64 = { 0 }) {
    let registration = LockScreenExtensionRegistration(processes: .live)
    self.init(
      prepareExtension: { try await registration.prepare() },
      enableExtension: { try await registration.enableExtension() },
      notifyConfigurationChanged: {
        CFNotificationCenterPostNotification(
          CFNotificationCenterGetDarwinNotifyCenter(),
          CFNotificationName(LockScreenConfiguration.changedNotification as CFString), nil, nil, true)
      },
      scenes: { try await bridge.lockScreenScenes() },
      selection: LockScreenWallpaperSelection(
        folder: ClientPaths.supportURL.appendingPathComponent("LockScreen")),
      exchange: LockScreenConfiguration.exchangeDirectory, contentRevision: contentRevision)
  }

  init(
    prepareExtension: @escaping () async throws -> Void,
    enableExtension: @escaping () async throws -> Void = {},
    notifyConfigurationChanged: @escaping () -> Void,
    scenes: @escaping () async throws -> [BridgeLockScreenScene],
    selection: LockScreenWallpaperSelection, exchange: URL,
    defaults: UserDefaults = ClientPreferences.defaults,
    scheduleMonitor: @escaping (@escaping @MainActor () -> Void) -> Timer =
      LockScreenWallpaperService.scheduleMonitorTimer,
    displayUUID: @escaping (UInt32) -> String? = LockScreenWallpaperService.onlineDisplayUUID,
    persistConfiguration: @escaping (URL, Data) throws -> Void = { url, data in
      try data.write(to: url, options: .atomic)
    },
    expectedExtensionBundle: URL = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Extensions/WallpaperMachineExtension.appex"),
    runningExtensionBundles: @escaping () -> [URL] = LockScreenExtensionDiagnostics.runningExtensionBundles,
    readinessTimeout: TimeInterval = 35,
    contentRevision: @escaping () -> UInt64 = { 0 }
  ) {
    self.scenes = scenes
    self.selection = selection
    self.exchange = exchange
    self.defaults = defaults
    self.scheduleMonitor = scheduleMonitor
    self.displayUUID = displayUUID
    self.persistConfiguration = persistConfiguration
    self.notifyConfigurationChanged = notifyConfigurationChanged
    self.prepareExtension = prepareExtension
    self.enableExtension = enableExtension
    self.expectedExtensionBundle = expectedExtensionBundle
    self.runningExtensionBundles = runningExtensionBundles
    self.readinessTimeout = readinessTimeout
    self.contentRevision = contentRevision
  }

  nonisolated private static func onlineDisplayUUID(_ displayID: UInt32) -> String? {
    guard CGDisplayIsOnline(displayID) != 0,
      let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
  }

  /// Always recover before either native or PNG providers are allowed to start.
  func start() throws {
    defer { updateMonitor() }
    isRequested = defaults.bool(forKey: Self.preference)
    screenSaverRequested = defaults.bool(forKey: Self.screenSaverPreference)
    do {
      try selection.recover()
      recovered = true
      if isRequested { status = String(localized: "Waiting for committed wallpapers…") }
      if screenSaverRequested {
        screenSaverStatus = String(localized: "Waiting for committed wallpapers…")
      }
    } catch {
      errorMessage = error.localizedDescription
      status = String(localized: "Recovery failed — action required")
      if screenSaverRequested {
        screenSaverError = error.localizedDescription
        screenSaverStatus = status
      }
      throw error
    }
  }

  func setEnabled(_ enabled: Bool) {
    guard !stopping else { return }
    isRequested = enabled
    dropRepairOfferIfNothingIsRequested()
    updateMonitor()
    if !enabled { defaults.set(false, forKey: Self.preference) }
    refresh(retryingLockScreen: true)
  }

  func setScreenSaverEnabled(_ enabled: Bool) {
    guard !stopping else { return }
    cancelExtensionPreparation()
    copyRecoveryAttempted = false
    screenSaverRequested = enabled
    dropRepairOfferIfNothingIsRequested()
    updateMonitor()
    if !enabled { defaults.set(false, forKey: Self.screenSaverPreference) }
    refresh()
  }

  /// A click on the Retry button of the lock-screen row (`lockScreen`) or the screen-saver
  /// row. Only this asks for the election repair: the app switches the renderer back on for a
  /// click on that button, not for the monitor, a snapshot refresh, a relaunch or a switch.
  func retry(lockScreen: Bool) {
    guard !stopping else { return }
    electionRepairArmed = electionRepairOffered
    refresh(retryingLockScreen: lockScreen)
  }

  /// The offer belongs to a failure shown in a row; with both modes off no row shows one.
  private func dropRepairOfferIfNothingIsRequested() {
    if !anyRequested { electionRepairOffered = false }
  }

  func refresh(retryingLockScreen: Bool = false) {
    guard !stopping else { return }
    if retryingLockScreen || (!isBusy && !canRefreshAutomatically) {
      cancelExtensionPreparation()
      copyRecoveryAttempted = false
    }
    if retryingLockScreen {
      // The committed display mapping must survive a retry for disable during wake.
      if lockScreenActivationError != nil { lastLockScreenRequested = nil }
      lockScreenActivationError = nil
      errorMessage = nil
    }
    generation &+= 1
    let revision = generation
    let previous = work
    previous?.cancel()
    isBusy = true
    work = Task { [weak self] in
      await previous?.value
      guard let self, !Task.isCancelled, self.generation == revision else { return }
      await self.update(revision: revision)
    }
  }

  private func updateMonitor() {
    guard canRefreshAutomatically, recovered, !stopping else {
      monitor?.invalidate()
      monitor = nil
      return
    }
    guard monitor == nil else { return }
    monitor = scheduleMonitor { [weak self] in
      guard let self, self.canRefreshAutomatically, !self.stopping, !self.isBusy
      else { return }
      // The bridge applies battery policy without opening the control panel.
      self.refresh()
    }
  }

  static let monitorInterval: TimeInterval = 2

  static func scheduleMonitorTimer(_ callback: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { _ in
      MainActor.assumeIsolated { callback() }
    }
    // The tick only reconciles state that has no notification of its own (a battery
    // pause, a new Space, a choice in System Settings), so a check that slides by a
    // second is harmless and lets the system coalesce it with other wakeups.
    timer.tolerance = monitorInterval / 2
    return timer
  }

  func shutdown(restoringDesktop: () async throws -> Void = {}) async throws {
    stopping = true
    updateMonitor()
    generation &+= 1
    cancelExtensionPreparation()
    work?.cancel()
    await work?.value
    work = nil
    do {
      try restoreNativeSelection()
      ownsDesktopProvider = false
      isEnabled = false
      screenSaverEnabled = false
      lastInputs = nil
      // The native journal can restore a poster. Its owner must then
      // restore the user's original after WallpaperAgent has reloaded.
      try await restoringDesktop()
      isBusy = false
    } catch {
      stopping = false
      isBusy = false
      errorMessage = error.localizedDescription
      status = String(localized: "Restoration failed — quit cancelled")
      if screenSaverRequested {
        screenSaverError = error.localizedDescription
        screenSaverStatus = status
      }
      throw error
    }
  }

  private func update(revision: UInt64) async {
    let affectedLockScreen = isRequested || ownsDesktopProvider
    let affectedScreenSaver = screenSaverRequested || screenSaverEnabled
    defer {
      if generation == revision {
        isBusy = false
        // A click's repair is for the update that follows it; an update that never needed the
        // renderer (nothing applied yet) must not leave it behind for a later refresh.
        electionRepairArmed = false
        updateMonitor()
      }
    }
    do {
      if !recovered {
        try selection.recover()
        recovered = true
      }
      // A disable must not wait for a waking display to regain its UUID.
      // Use the last committed mapping to relinquish only the disabled mode.
      if var committed = published, let lastInputs,
        (committed.lockScreenEnabled && !isRequested)
          || (committed.screenSaverEnabled && !screenSaverRequested)
      {
        committed.revision = UUID().uuidString
        committed.lockScreenEnabled = committed.lockScreenEnabled && isRequested
        committed.screenSaverEnabled = committed.screenSaverEnabled && screenSaverRequested
        if !committed.screenSaverEnabled {
          committed.scenes.removeAll { $0.webEntryFile != nil }
        }
        if !committed.lockScreenEnabled && !committed.screenSaverEnabled {
          committed.scenes.removeAll()
        }
        try publish(committed)
        try applySelection(committed, inputs: lastInputs)
        if !committed.lockScreenEnabled, ownsDesktopProvider {
          ownsDesktopProvider = false
          try afterDeactivation?()
        }
        updateStatuses(committed, hasWebWallpapers: lastHasWebWallpapers)
      }
      guard (isRequested && lockScreenActivationError == nil) || screenSaverRequested else {
        status = String(localized: "Restoring system wallpapers…")
        screenSaverStatus = status
        try deactivate()
        updateStatuses(LockScreenConfiguration(scenes: []))
        return
      }
      let records = try await scenes()
      try Task.checkCancellation()
      guard generation == revision else { return }
      var inputs: [LockScreenPublishInput] = []
      for record in records {
        guard let uuid = displayUUID(record.displayId) else {
          // Keep the last complete mapping while Core Graphics settles during wake.
          if isRequested, errorMessage == nil {
            status = String(localized: "Waiting for committed wallpapers…")
          }
          if screenSaverRequested, screenSaverError == nil {
            screenSaverStatus = String(localized: "Waiting for committed wallpapers…")
          }
          AppLog.debug("Native wallpaper topology pending: display \(record.displayId) is not online")
          return
        }
        let mode: Int32
        switch record.scalingMode {
        case .none: mode = 0
        case .stretch: mode = 1
        case .match: mode = 2
        case .fill: mode = 3
        }
        inputs.append(LockScreenPublishInput(
          displayID: record.displayId,
          displayUUID: uuid,
          wallpaperID: record.wallpaperId, title: record.title,
          projectPath: record.projectPath, assetsPath: record.assetsPath, fps: record.fps,
          scalingMode: mode, scalingFactor: record.scalingFactor,
          framing: LockScreenFraming(panX: record.framing.panX, panY: record.framing.panY),
          propertiesJSON: record.propertiesJson, paused: record.paused))
      }
      inputs.sort { $0.displayID < $1.displayID }
      let currentContentRevision = contentRevision()
      if inputs == lastInputs, let published, unconfirmed?.revision != published.revision,
        lastContentRevision == currentContentRevision,
        lastLockScreenRequested == isRequested,
        lastScreenSaverRequested == screenSaverRequested
      {
        try checkReadinessFailures(published)
        // New Spaces and choices made in System Settings change only the system store.
        // The selection takes over the former and reports the latter, rereading the
        // store only after something wrote it.
        try applySelection(published, inputs: inputs)
        updateStatuses(published, hasWebWallpapers: lastHasWebWallpapers)
        return
      }
      guard !inputs.isEmpty else {
        try deactivate()
        updateStatuses(LockScreenConfiguration(scenes: []))
        return
      }
      try selection.checkCompatibility()
      if isRequested { status = String(localized: "Preparing committed wallpapers…") }
      if screenSaverRequested { screenSaverStatus = String(localized: "Preparing committed wallpapers…") }
      let root = exchange
      let userAssets = UserAssetStorage.managedRootURL
      let includeWeb = screenSaverRequested
      let staging = Task.detached(priority: .utility) {
        try LockScreenAssetPublisher.prepare(
          inputs: inputs, exchange: root, userAssets: userAssets, includeWeb: includeWeb)
      }
      let prepared = try await withTaskCancellationHandler {
        try await staging.value
      } onCancel: {
        staging.cancel()
      }
      try Task.checkCancellation()
      guard generation == revision, anyRequested else { return }
      var configuration = prepared.configuration
      configuration.lockScreenEnabled = isRequested && lockScreenActivationError == nil
        && configuration.scenes.contains { $0.webEntryFile == nil }
      configuration.screenSaverEnabled = screenSaverRequested && !configuration.scenes.isEmpty
      if (configuration.lockScreenEnabled || configuration.screenSaverEnabled)
        && (published?.scenes.isEmpty != false
          || (configuration.lockScreenEnabled && published?.lockScreenEnabled != true)
          || (configuration.screenSaverEnabled && published?.screenSaverEnabled != true))
      {
        if isRequested { status = String(localized: "Checking the system wallpaper renderer…") }
        if screenSaverRequested { screenSaverStatus = String(localized: "Checking the system wallpaper renderer…") }
        // A snapshot refresh cancels its waiter, not the shared registration work.
        // Keep the result until publication so the next waiter cannot restart it.
        if extensionPreparation == nil {
          let repairElection = electionRepairArmed
          extensionPreparation = Task {
            if repairElection {
              try await enableExtension()
              electionRepairArmed = false
            }
            try await prepareExtension()
          }
        }
        try await extensionPreparation?.value
        try Task.checkCancellation()
        guard generation == revision, anyRequested else { return }
      }
      if let published, published.scenes == configuration.scenes,
         published.lockScreenEnabled == configuration.lockScreenEnabled,
         published.screenSaverEnabled == configuration.screenSaverEnabled {
        lastInputs = inputs
        lastContentRevision = currentContentRevision
        lastLockScreenRequested = isRequested
        lastScreenSaverRequested = screenSaverRequested
        lastHasWebWallpapers = prepared.hasWebWallpapers
        try checkReadinessFailures(published)
        try applySelection(published, inputs: inputs)
        guard unconfirmed?.revision == published.revision else {
          updateStatuses(published, hasWebWallpapers: prepared.hasWebWallpapers)
          return
        }
        // A refresh interrupted the wait for this activation's first frame. It is still not
        // confirmed, so wait on for the same revision rather than claim it or publish again.
        configuration = published
      } else {
        if configuration.lockScreenEnabled, !ownsDesktopProvider {
          try beforeActivation?()
          ownsDesktopProvider = true
        }
        try publish(configuration)
        extensionPreparation = nil
        LockScreenAssetPublisher.collectGarbage(
          exchange: root, keeping: prepared.referencedRevisions)
        try applySelection(configuration, inputs: inputs)
        if !configuration.lockScreenEnabled, ownsDesktopProvider {
          ownsDesktopProvider = false
          try afterDeactivation?()
        }
      }
      // Idle-only selections need not be acquired until macOS starts the saver.
      // Report selection, not rendered readiness; lock-screen activation still
      // waits for its desktop-backed surfaces to produce real pixels.
      if configuration.lockScreenEnabled {
        status = String(localized: "Waiting for the system wallpaper renderer…")
        do {
          try await awaitReadiness(configuration)
        } catch let error as RendererUnavailable where configuration.screenSaverEnabled {
          // Idle selection is valid without an acquired surface. A missing
          // Desktop acknowledgement must not take that independent choice down.
          configuration.revision = UUID().uuidString
          configuration.lockScreenEnabled = false
          try publish(configuration)
          try applySelection(configuration, inputs: inputs)
          ownsDesktopProvider = false
          try afterDeactivation?()
          lockScreenActivationError = error.localizedDescription
          AppLog.error("Native lock screen: \(error.localizedDescription)")
        }
      }
      try Task.checkCancellation()
      guard generation == revision, anyRequested else { return }
      lastInputs = inputs
      lastContentRevision = currentContentRevision
      lastLockScreenRequested = isRequested
      lastScreenSaverRequested = screenSaverRequested
      lastHasWebWallpapers = prepared.hasWebWallpapers
      updateStatuses(configuration, hasWebWallpapers: prepared.hasWebWallpapers)
      copyRecoveryAttempted = false
      electionRepairOffered = false
      if isEnabled { defaults.set(true, forKey: Self.preference) }
      if screenSaverEnabled { defaults.set(true, forKey: Self.screenSaverPreference) }
    } catch is CancellationError {
      // A newer request owns the next publication; keep the committed surfaces.
    } catch {
      guard generation == revision else { return }
      var failure = error
      if (error as? LockScreenWallpaperFailure)?.reason == .differentExtensionCopy,
        !copyRecoveryAttempted
      {
        // Discovery can race a new Debug build, or macOS can retain the old process.
        // Restore first, then let a fresh activation repair registration and reselect once.
        do {
          copyRecoveryAttempted = true
          AppLog.info("Native extension copy changed; repairing registration and retrying activation once")
          try deactivate()
          try Task.checkCancellation()
          await update(revision: revision)
          return
        } catch is CancellationError {
          return
        } catch { failure = error }
      }
      lockScreenActivationError = nil
      electionRepairOffered = (failure as? LockScreenWallpaperFailure)?.reason == .extensionTurnedOff
      var message = failure.localizedDescription
      do { try deactivate() } catch {
        message += " " + String(localized: "Restoration also failed: \(error.localizedDescription)")
      }
      if affectedLockScreen || !affectedScreenSaver {
        errorMessage = message
        status = String(localized: "Not enabled — action required")
      }
      if affectedScreenSaver {
        screenSaverError = message
        screenSaverStatus = String(localized: "Not enabled — action required")
      }
      AppLog.error("Native wallpaper: \(message)")
    }
  }

  private func applySelection(
    _ configuration: LockScreenConfiguration, inputs: [LockScreenPublishInput]
  ) throws {
    let lockIDs = Set(configuration.scenes.lazy.filter { $0.webEntryFile == nil }.map(\.displayID))
    let allIDs = Set(configuration.scenes.lazy.map(\.displayID))
    try selection.synchronize(
      desktopDisplays: configuration.lockScreenEnabled
        ? Set(inputs.lazy.filter { lockIDs.contains($0.displayID) }.map(\.displayUUID)) : [],
      screenSaverDisplays: configuration.screenSaverEnabled
        ? Set(inputs.lazy.filter { allIDs.contains($0.displayID) }.map(\.displayUUID)) : [],
      revision: configuration.revision)
  }

  private func updateStatuses(
    _ configuration: LockScreenConfiguration, hasWebWallpapers: Bool = false
  ) {
    let lockCount = configuration.scenes.reduce(0) { $0 + ($1.webEntryFile == nil ? 1 : 0) }
    isEnabled = isRequested && configuration.lockScreenEnabled && lockCount > 0
    screenSaverEnabled = screenSaverRequested && configuration.screenSaverEnabled
      && !configuration.scenes.isEmpty
    errorMessage = isRequested ? lockScreenActivationError : nil
    status = !isRequested ? String(localized: "Off") : errorMessage != nil
      ? String(localized: "Not enabled — action required") : isEnabled
        ? String(localized: "Enabled for \(lockCount) display(s)")
        : hasWebWallpapers
          ? String(localized: "Not applicable — web wallpapers have no lock-screen support")
          : String(localized: "Waiting for an applied video or live scene on a connected display")
    let count = configuration.scenes.count
    screenSaverStatus = !screenSaverRequested ? String(localized: "Off") : screenSaverEnabled
      ? String(localized: "Selected for \(count) display(s) — starts when macOS is idle")
      : String(localized: "Waiting for an applied wallpaper on a connected display")
    screenSaverError = nil
  }

  private func checkReadinessFailures(_ configuration: LockScreenConfiguration) throws {
    try checkExtensionFailure(configuration)
    for scene in configuration.scenes {
      let file = exchange.appendingPathComponent("ready-\(scene.displayID).json")
      if let data = try? Data(contentsOf: file),
        let state = try? JSONDecoder().decode(LockScreenReadiness.self, from: data),
        state.revision == configuration.revision, state.displayID == scene.displayID,
        let error = state.error
      {
        throw LockScreenWallpaperFailure(message: error)
      }
    }
  }

  private func checkExtensionFailure(_ configuration: LockScreenConfiguration) throws {
    guard let data = try? Data(contentsOf: exchange.appendingPathComponent(LockScreenExtensionStatus.fileName)),
      let status = try? JSONDecoder().decode(LockScreenExtensionStatus.self, from: data),
      let failure = LockScreenExtensionDiagnostics.failure(
        status: status, revision: configuration.revision, expectedBundle: expectedExtensionBundle)
    else { return }
    AppLog.error("Native extension: bundle=\(status.bundlePath) configurationVersion=\(status.supportedVersion) error=\(status.error ?? "none")")
    throw failure
  }

  /// Restore the native selection and hand the desktop back to the poster
  /// provider. Both steps always run so a failed restoration can never leave
  /// the poster sync suspended; the first error is rethrown afterwards.
  private func deactivate() throws {
    cancelExtensionPreparation()
    isEnabled = false
    screenSaverEnabled = false
    lastInputs = nil
    var firstError: Error?
    do { try restoreNativeSelection() } catch { firstError = error }
    if ownsDesktopProvider {
      ownsDesktopProvider = false
      do { try afterDeactivation?() } catch { if firstError == nil { firstError = error } }
    }
    if let firstError { throw firstError }
  }

  private func cancelExtensionPreparation() {
    extensionPreparation?.cancel()
    extensionPreparation = nil
  }

  private struct RendererUnavailable: LocalizedError {
    var errorDescription: String? {
      String(localized: "macOS did not load the lock-screen renderer. The original wallpaper has been restored. Check for another wallpaper app or a conflicting system-wide wallpaper selection.")
    }
  }

  /// Waits for every lock-screen display to report a frame of `configuration`. Cancelled, the
  /// wait stays owed and keeps its deadline, so refreshes can neither skip nor postpone it.
  private func awaitReadiness(_ configuration: LockScreenConfiguration) async throws {
    let deadline = unconfirmed.flatMap { $0.revision == configuration.revision ? $0.deadline : nil }
      ?? Date().addingTimeInterval(readinessTimeout)
    unconfirmed = (configuration.revision, deadline)
    do {
      try await awaitFrames(configuration, until: deadline)
      unconfirmed = nil
      AppLog.info(
        "Native lock screen: first frame acknowledged after \(waited(until: deadline)) s "
          + "(waited from selection reload)")
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      unconfirmed = nil
      throw error
    }
  }

  /// Seconds since this activation began waiting, which includes the time an interrupted wait
  /// already spent: a wait ends `readinessTimeout` after it began, whichever refresh resumes it.
  private func waited(until deadline: Date) -> String {
    let began = deadline.addingTimeInterval(-readinessTimeout)
    return LockScreenFirstFrameTiming.seconds(.seconds(max(0, Date().timeIntervalSince(began))))
  }

  private func awaitFrames(_ configuration: LockScreenConfiguration, until deadline: Date) async throws {
    while Date() < deadline {
      try Task.checkCancellation()
      try checkExtensionFailure(configuration)
      var ready = true
      for scene in configuration.scenes where scene.webEntryFile == nil {
        let file = exchange.appendingPathComponent("ready-\(scene.displayID).json")
        guard let data = try? Data(contentsOf: file),
          let state = try? JSONDecoder().decode(LockScreenReadiness.self, from: data),
          state.revision == configuration.revision, state.displayID == scene.displayID
        else {
          ready = false
          continue
        }
        if let error = state.error { throw LockScreenWallpaperFailure(message: error) }
      }
      if ready { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    try Task.checkCancellation()
    try checkExtensionFailure(configuration)
    let expected = expectedExtensionBundle.resolvingSymlinksInPath().standardizedFileURL
    if let other = runningExtensionBundles().first(where: {
      !LockScreenExtensionDiagnostics.isSameBundle($0, expected)
    }) {
      AppLog.error(
        "Native extension timeout: running bundle=\(other.path), expected=\(expected.path), "
          + "waited \(waited(until: deadline)) s")
      throw LockScreenWallpaperFailure(
        message: LockScreenExtensionDiagnostics.differentCopyMessage, reason: .differentExtensionCopy)
    }
    AppLog.error("Native lock screen: no first frame acknowledged after \(waited(until: deadline)) s")
    throw RendererUnavailable()
  }

  private func restoreNativeSelection() throws {
    var manifestError: Error?
    do { try clearManifest() } catch { manifestError = error }
    // A full disk or inaccessible exchange directory must never prevent restoring the
    // user's native selections. Preserve both errors when recovery also fails.
    do { try selection.synchronize(desktopDisplays: [], screenSaverDisplays: []) } catch {
      if let manifestError {
        throw LockScreenWallpaperFailure(
          message:
            "\(manifestError.localizedDescription) Native restoration: \(error.localizedDescription)"
        )
      }
      throw error
    }
    if let manifestError { throw manifestError }
  }

  private func clearManifest() throws {
    // Do not create the exchange directory merely because the feature is off.
    guard
      FileManager.default.fileExists(
        atPath: exchange.appendingPathComponent(LockScreenConfiguration.fileName).path)
    else {
      published = nil
      return
    }
    try publish(LockScreenConfiguration(scenes: []))
  }

  private func publish(_ configuration: LockScreenConfiguration) throws {
    guard configuration != published else { return }
    try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try persistConfiguration(
      exchange.appendingPathComponent(LockScreenConfiguration.fileName), encoder.encode(configuration))
    try encoder.encode(LockScreenExtensionRequest(revision: configuration.revision)).write(
      to: exchange.appendingPathComponent(LockScreenExtensionRequest.fileName), options: .atomic)
    published = configuration
    notifyConfigurationChanged()
  }
}

private struct LockScreenPublishInput: Equatable, Sendable {
  var displayID: UInt32
  var displayUUID: String
  var wallpaperID: String
  var title: String
  var projectPath: String
  var assetsPath: String
  var fps: UInt32
  var scalingMode: Int32
  var scalingFactor: Double
  /// Part of the input, so moving a wallpaper on its display republishes a revision.
  var framing: LockScreenFraming
  var propertiesJSON: String?
  var paused: Bool
}

/// A source-tree metadata fingerprint reuses immutable snapshots without reading
/// gigabytes of unchanged video. Copies never follow symlinks out of a project.
private enum LockScreenAssetPublisher {
  private struct Item {
    var relative: String
    var directory: Bool
    var size: Int
    var modified: Date
  }

  /// A published configuration, plus every revision directory it names. The caller
  /// needs the second to know what is safe to collect.
  struct Prepared {
    var configuration: LockScreenConfiguration
    var referencedRevisions: Set<String>
    var hasWebWallpapers: Bool
  }

  static func prepare(
    inputs: [LockScreenPublishInput], exchange: URL, userAssets: URL, includeWeb: Bool
  ) throws -> Prepared {
    var sources: [String: String] = [:]
    var scenes: [LockScreenScene] = []
    var hasWebWallpapers = false
    for input in inputs {
      try Task.checkCancellation()
      guard input.projectPath.hasPrefix("/"), input.assetsPath.hasPrefix("/") else {
        throw LockScreenWallpaperFailure(
          message: String(localized: "The committed wallpaper contains a non-absolute source path."))
      }
      let project = URL(fileURLWithPath: input.projectPath)
      guard project.lastPathComponent == "project.json" else {
        throw LockScreenWallpaperFailure(
          message: String(localized: "The committed wallpaper does not reference project.json."))
      }
      let source = project.deletingLastPathComponent()
      let data = try Data(contentsOf: project)
      guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type = metadata["type"] as? String
      else {
        throw LockScreenWallpaperFailure(
          message: String(localized: "The committed wallpaper does not declare a project type."))
      }
      let isWeb = type.lowercased() == "web"
      hasWebWallpapers = hasWebWallpapers || isWeb
      if isWeb && !includeWeb { continue }
      guard ["video", "scene", "web"].contains(type.lowercased()) else {
        throw LockScreenWallpaperFailure(
          message: String(localized: "This wallpaper type cannot be presented by the native wallpaper provider."))
      }
      let webEntry: String?
      if isWeb {
        guard let file = metadata["file"] as? String,
          let entry = WebWallpaperProtocol.canonicalEntryURL(projectURL: source, entryFile: file),
          FileManager.default.isReadableFile(atPath: entry.path),
          try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else {
          throw LockScreenWallpaperFailure(
            message: String(localized: "The web wallpaper entry must be a readable file inside its project."))
        }
        webEntry = file
      } else {
        webEntry = nil
      }
      var projectRevision = try snapshot(source: source, exchange: exchange, reused: &sources)
      var assetsRevision: String
      if type.lowercased() == "scene" {
        assetsRevision = try snapshot(
          source: URL(fileURLWithPath: input.assetsPath, isDirectory: true),
          exchange: exchange, reused: &sources)
      } else {
        // Video rendering does not consume shared scene assets.
        assetsRevision = projectRevision
      }
      var properties = try publishUserAssets(
        input: input, exchange: exchange, userAssets: userAssets, web: isWeb, reused: &sources)
      if isWeb {
        (projectRevision, properties) = try isolateWebAssets(
          projectRevision: projectRevision, properties: properties, exchange: exchange, reused: &sources)
        assetsRevision = projectRevision
      }
      scenes.append(
        LockScreenScene(
          displayID: input.displayID, title: input.title,
          projectPath: projectRevision + "/project.json", assetsPath: assetsRevision,
          previewPath: nil,
          fps: input.fps, scalingMode: input.scalingMode, scalingFactor: input.scalingFactor,
          propertiesJSON: properties, paused: input.paused, webEntryFile: webEntry,
          // A web page fills its window, so it has no position to carry.
          framing: isWeb ? nil : input.framing))
    }
    return Prepared(
      configuration: LockScreenConfiguration(scenes: scenes),
      referencedRevisions: Set(sources.values), hasWebWallpapers: hasWebWallpapers)
  }

  /// WebKit's read grant covers exactly this project and its referenced imports,
  /// never another display's revision or private renderer assets.
  private static func isolateWebAssets(
    projectRevision: String, properties: String?, exchange: URL, reused: inout [String: String]
  ) throws -> (String, String?) {
    guard let properties,
      var values = try JSONSerialization.jsonObject(with: Data(properties.utf8)) as? [String: [String: Any]]
    else { return (projectRevision, properties) }
    let project = exchange.appendingPathComponent(projectRevision, isDirectory: true)
    let imports = values.keys.sorted().compactMap { key -> (String, URL, Bool)? in
      guard let property = values[key], let type = property["type"] as? String,
        type == "file" || type == "directory", let value = property["value"] as? String,
        let url = URL(string: value), url.isFileURL,
        url.path.hasPrefix(exchange.path + "/revisions/"),
        !url.path.hasPrefix(project.path + "/")
      else { return nil }
      return (key, url, type == "directory")
    }
    guard !imports.isEmpty else { return (projectRevision, properties) }
    let hash = SHA256.hash(data: Data((projectRevision + "\u{0}" + properties).utf8))
      .map { String(format: "%02x", $0) }.joined()
    let relative = "revisions/" + hash
    let destination = exchange.appendingPathComponent(relative, isDirectory: true)
    let manager = FileManager.default
    let pending = exchange.appendingPathComponent("revisions/.pending-\(UUID().uuidString)", isDirectory: true)
    let needsCopy = !manager.fileExists(atPath: destination.path)
    defer { if needsCopy { try? manager.removeItem(at: pending) } }
    if needsCopy { try copyTree(project, to: pending) }
    for (index, imported) in imports.enumerated() {
      let (key, source, directory) = imported
      let assetPath = ".mwe-native-assets/\(index)" + (directory ? "" : "/" + source.lastPathComponent)
      if needsCopy {
        let target = pending.appendingPathComponent(assetPath, isDirectory: directory)
        if directory { try copyTree(source, to: target) }
        else {
          try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          try copyFile(from: source, to: target)
        }
      }
      values[key]?["value"] = destination.appendingPathComponent(assetPath, isDirectory: directory).absoluteString
    }
    if needsCopy {
      try Task.checkCancellation()
      try manager.moveItem(at: pending, to: destination)
    }
    reused["web:" + relative] = relative
    let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    return (relative, String(decoding: data, as: UTF8.self))
  }

  private static func copyTree(_ source: URL, to destination: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    for item in try inventory(source) {
      try Task.checkCancellation()
      let target = destination.appendingPathComponent(item.relative, isDirectory: item.directory)
      if item.directory { try manager.createDirectory(at: target, withIntermediateDirectories: true) }
      else {
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copyFile(from: source.appendingPathComponent(item.relative), to: target)
      }
    }
  }

  /// Copies the managed user assets this wallpaper actually references into the
  /// exchange directory and rewrites the property values to point at the copy.
  ///
  /// Only the referenced assets travel: the store may hold imports for every wallpaper
  /// in the library, and the extension has no business seeing any of them. The copy
  /// goes through the same fingerprint-and-atomic-move path as the project payload, so
  /// an unchanged selection is recognised and nothing is copied again on the next
  /// status update.
  ///
  /// Returns the property payload the extension should receive, unchanged when the
  /// wallpaper references no managed asset.
  private static func publishUserAssets(
    input: LockScreenPublishInput, exchange: URL, userAssets: URL, web: Bool,
    reused: inout [String: String]
  ) throws -> String? {
    guard let json = input.propertiesJSON, !input.wallpaperID.isEmpty else {
      return input.propertiesJSON
    }
    let store = ManagedUserAssetStore(root: userAssets)
    let manifest = try store.manifest(wallpaperId: input.wallpaperID)
    guard !manifest.properties.isEmpty,
      let data = json.data(using: .utf8),
      var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return input.propertiesJSON }

    let manager = FileManager.default
    // Planned before anything is copied: the plan is what the fingerprint covers, so a
    // manifest entry this wallpaper does not reference cannot change the revision, and
    // an unchanged selection is recognised without reading a byte.
    var plan: [(property: String, isFile: Bool, files: [(name: String, source: URL, digest: String)])] = []
    for (propertyId, record) in manifest.properties.sorted(by: { $0.key < $1.key }) {
      guard root[propertyId] != nil else { continue }
      var files: [(name: String, source: URL, digest: String)] = []
      for asset in record.assets.sorted(by: { $0.fileName < $1.fileName }) {
        let stored = try store.storedURL(
          wallpaperId: input.wallpaperID, propertyId: propertyId, asset: asset)
        guard manager.fileExists(atPath: stored.path) else { continue }
        files.append((asset.fileName, stored, asset.digest))
      }
      guard record.kind == .directory || !files.isEmpty else { continue }
      plan.append((propertyId, record.kind == .file, files))
    }
    guard !plan.isEmpty else { return input.propertiesJSON }

    // Content digests rather than file metadata: a clone preserves modification
    // times but a chunked fallback copy does not, and a fingerprint that moved with
    // the copy would republish the same assets on every status update.
    var hash = SHA256()
    hash.update(data: Data("user-assets\u{0}".utf8))
    for entry in plan {
      hash.update(data: Data("\u{0}\(entry.property)\u{0}\(entry.isFile)".utf8))
      for file in entry.files {
        hash.update(data: Data("\u{0}\(file.name)\u{0}\(file.digest)".utf8))
      }
    }
    let relative = "revisions/" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    let published = exchange.appendingPathComponent(relative, isDirectory: true)
    if !manager.fileExists(atPath: published.path) {
      let revisions = exchange.appendingPathComponent("revisions", isDirectory: true)
      try manager.createDirectory(at: revisions, withIntermediateDirectories: true)
      let pending = revisions.appendingPathComponent(
        ".pending-\(UUID().uuidString)", isDirectory: true)
      defer { try? manager.removeItem(at: pending) }
      for entry in plan {
        let directory = pending.appendingPathComponent(entry.property, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in entry.files {
          try Task.checkCancellation()
          try copyFile(from: file.source, to: directory.appendingPathComponent(file.name))
        }
      }
      try Task.checkCancellation()
      try manager.moveItem(at: pending, to: published)
    }
    reused["user-assets:" + relative] = relative

    for entry in plan {
      let directory = published.appendingPathComponent(entry.property, isDirectory: true)
      // A `file` property names one published file; a `directory` property names the
      // folder, exactly as the renderer already expects on the desktop side.
      let target = entry.isFile
        ? directory.appendingPathComponent(entry.files[0].name) : directory
      if web, var property = root[entry.property] as? [String: Any] {
        property["value"] = target.absoluteString
        root[entry.property] = property
      } else {
        root[entry.property] = target.path
      }
    }
    guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    else { return input.propertiesJSON }
    return String(data: encoded, encoding: .utf8)
  }

  /// Removes revision trees the published configuration no longer names.
  ///
  /// Nothing collected this before, so every asset revision the user ever activated
  /// stayed there for good. Only the revisions the caller passes are kept,
  /// and only complete fingerprint directories are candidates: a `.pending-` tree
  /// belongs to a publish that is still running.
  static func collectGarbage(exchange: URL, keeping referenced: Set<String>) {
    let manager = FileManager.default
    let revisions = exchange.appendingPathComponent("revisions", isDirectory: true)
    guard let entries = try? manager.contentsOfDirectory(
      at: revisions, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
    let live = Set(referenced.map { URL(fileURLWithPath: $0).lastPathComponent })
    for entry in entries {
      let name = entry.lastPathComponent
      guard !name.hasPrefix("."), !live.contains(name) else { continue }
      guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
        continue
      }
      do {
        try manager.removeItem(at: entry)
      } catch {
        AppLog.warn("lock screen: could not remove unused revision \(name): \(error.localizedDescription)")
      }
    }
  }

  private static func snapshot(source: URL, exchange: URL, reused: inout [String: String]) throws
    -> String
  {
    let source = source.standardizedFileURL
    if let existing = reused[source.path] { return existing }
    let items = try inventory(source)
    let fingerprint = digest(source: source, items: items)
    let relative = "revisions/\(fingerprint)"
    let destination = exchange.appendingPathComponent(relative, isDirectory: true)
    let manager = FileManager.default
    if !manager.fileExists(atPath: destination.path) {
      let revisions = exchange.appendingPathComponent("revisions", isDirectory: true)
      try manager.createDirectory(at: revisions, withIntermediateDirectories: true)
      let pending = revisions.appendingPathComponent(
        ".pending-\(UUID().uuidString)", isDirectory: true)
      try manager.createDirectory(at: pending, withIntermediateDirectories: false)
      defer { try? manager.removeItem(at: pending) }
      for item in items {
        try Task.checkCancellation()
        let target = pending.appendingPathComponent(item.relative, isDirectory: item.directory)
        if item.directory {
          try manager.createDirectory(at: target, withIntermediateDirectories: true)
        } else {
          try manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          // APFS clones isolate writes without duplicating large files;
          // a chunked fallback keeps cancellation responsive elsewhere.
          try copyFile(from: source.appendingPathComponent(item.relative), to: target)
        }
      }
      guard digest(source: source, items: try inventory(source)) == fingerprint else {
        throw LockScreenWallpaperFailure(
          message:
            String(localized: "Wallpaper assets changed while preparing native playback. Retry after the download or edit finishes.")
        )
      }
      try Task.checkCancellation()
      try manager.moveItem(at: pending, to: destination)
    }
    reused[source.path] = relative
    return relative
  }

  private static func inventory(_ source: URL) throws -> [Item] {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      .fileSizeKey, .contentModificationDateKey,
    ]
    let root = try source.resourceValues(forKeys: keys)
    guard root.isDirectory == true, root.isSymbolicLink != true else {
      throw LockScreenWallpaperFailure(
        message: String(localized: "The wallpaper asset source must be a real directory: \(source.path)"))
    }
    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: source, includingPropertiesForKeys: Array(keys),
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw LockScreenWallpaperFailure(message: String(localized: "Cannot enumerate wallpaper assets: \(source.path)"))
    }
    var result: [Item] = []
    for case let file as URL in enumerator {
      try Task.checkCancellation()
      let values = try file.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true,
        values.isDirectory == true || values.isRegularFile == true
      else {
        throw LockScreenWallpaperFailure(
          message: String(localized: "Native wallpaper assets cannot contain symbolic links or special files: \(file.path)")
        )
      }
      result.append(
        Item(
          relative: String(file.path.dropFirst(source.path.count + 1)),
          directory: values.isDirectory == true, size: values.fileSize ?? 0,
          modified: values.contentModificationDate ?? .distantPast))
    }
    if let enumerationError { throw enumerationError }
    return result.sorted { $0.relative < $1.relative }
  }

  private static func digest(source: URL, items: [Item]) -> String {
    var hash = SHA256()
    hash.update(data: Data(source.path.utf8))
    for item in items {
      hash.update(
        data: Data(
          "\u{0}\(item.relative)\u{0}\(item.directory)\u{0}\(item.size)\u{0}\(item.modified.timeIntervalSince1970)"
            .utf8))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func copyFile(from source: URL, to destination: URL) throws {
    if clonefile(source.path, destination.path, 0) == 0 { return }
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw LockScreenWallpaperFailure(
        message: String(localized: "Cannot create native wallpaper asset: \(destination.path)"))
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    while true {
      try Task.checkCancellation()
      guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
      try output.write(contentsOf: chunk)
    }
  }
}
